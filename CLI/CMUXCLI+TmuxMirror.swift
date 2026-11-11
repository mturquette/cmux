import CmuxFoundation
import Darwin
import Foundation

extension CMUXCLI {
    /// `cmux tmux-mirror`: shows a tmux server on this Mac as cmux workspaces, with no SSH.
    ///
    /// The CLI does the two things only the calling shell can: it resolves which server the user
    /// means (``TmuxServerSocketResolver``), and when no server is running it starts the first
    /// session with the shell's own environment and working directory
    /// (``TmuxMirrorStartDirectory``), so that session does not inherit the app's bare PATH. Then
    /// it sends the same `remote.tmux.mirror`, `remote.tmux.window` or `remote.tmux.sessions` RPC
    /// that `cmux ssh-tmux` sends, with `transport: "local"` and the socket path.
    func runTmuxMirror(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let invocation = try TmuxMirrorInvocation.parse(commandArgs)
        let socketPath = try TmuxServerSocketResolver().socketPath(for: invocation.server)
        var params: [String: Any] = ["transport": "local", "socket_path": socketPath]

        if case .list = invocation.action {
            let result = try client.sendV2(method: "remote.tmux.sessions", params: params, waitUntilCompletion: true)
            printTmuxMirrorSessions(result, socketPath: socketPath, jsonOutput: jsonOutput)
            return
        }

        // Ask the app first, so a disabled feature or a refused socket fails before anything is
        // created. Only the plain mirror starts a server, and only when none is running: `attach`
        // names a session that has to exist already.
        var startNotice: String?
        if try tmuxMirrorServerIsMissing(params: params, socketPath: socketPath, client: client),
           case .mirror = invocation.action {
            startNotice = try startTmuxMirrorServerIfNeeded(socketPath: socketPath)
        }
        if let startNotice, !jsonOutput {
            print(startNotice)
        }
        if let name = invocation.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            params["workspace_name"] = name
        }
        params["activate"] = invocation.focus ?? Self.defaultFocusForUserOpen()
        if case let .attach(session) = invocation.action {
            params["session"] = session
        }
        if !invocation.newWindow {
            try applyWindowOrCallerContext(to: &params, client: client, windowRaw: nil)
        }
        let method = invocation.newWindow ? "remote.tmux.window" : "remote.tmux.mirror"
        let result = try client.sendV2(method: method, params: params, waitUntilCompletion: true)
        guard (result["mirrored"] as? Bool) == true else {
            throw CLIError(message: String(
                localized: "cli.tmuxMirror.error.unexpectedResponse",
                defaultValue: "tmux-mirror: unexpected response from cmux"
            ))
        }
        if jsonOutput {
            var payload = result
            if let startNotice { payload["start_notice"] = startNotice }
            print(jsonString(payload))
        } else {
            let windowId = (result["window_id"] as? String) ?? ""
            let count = (result["workspace_ids"] as? [Any])?.count ?? 0
            print("OK socket=\(socketPath) workspaces=\(count) window=\(windowId)")
        }
    }

    /// Whether no tmux server is running at `socketPath`, as the app sees it.
    ///
    /// The app answers first, so a disabled feature or a refused path stops the command before it
    /// creates anything. A socket that does not exist yet is refused by the app as missing, and
    /// that, alone among refusals, means "no server".
    func tmuxMirrorServerIsMissing(params: [String: Any], socketPath: String, client: SocketClient) throws -> Bool {
        do {
            let result = try client.sendV2(method: "remote.tmux.sessions", params: params, waitUntilCompletion: true)
            return ((result["sessions"] as? [Any]) ?? []).isEmpty
        } catch let error as CLIError where error.v2Code == "invalid_params" {
            var status = stat()
            guard lstat(socketPath, &status) != 0, errno == ENOENT else { throw error }
            return true
        }
    }

    /// Starts a session on the server at `socketPath` when no server answers there.
    ///
    /// Runs in the CLI, so the session gets the calling shell's environment (minus `TMUX` and
    /// `TMUX_PANE`, which would make tmux refuse to nest) and its working directory. If another
    /// client starts the server between the check and `new-session`, tmux simply adds this
    /// session to it and the mirror shows both.
    ///
    /// - Returns: the one-line notice to print when the home directory was used instead.
    func startTmuxMirrorServerIfNeeded(socketPath: String) throws -> String? {
        let probe = try runTmuxForMirror(["-S", socketPath, "list-sessions", "-F", "#{session_id}"])
        if probe.status == 0 { return nil }
        guard Self.tmuxMirrorReportsNoServer(probe.stderr) else {
            throw tmuxMirrorFailure(probe)
        }
        let choice = TmuxMirrorStartDirectory().choose()
        let created = try runTmuxForMirror(["-S", socketPath, "new-session", "-d", "-c", choice.tmuxArgument])
        guard created.status == 0 else { throw tmuxMirrorFailure(created) }
        return choice.notice
    }

    /// Whether tmux's stderr says nothing is listening on the socket.
    static func tmuxMirrorReportsNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
            || (lowered.contains("error connecting to") && lowered.contains("no such file or directory"))
            || (lowered.contains("error connecting to") && lowered.contains("connection refused"))
    }

    private func tmuxMirrorFailure(_ result: (status: Int32, stderr: String)) -> CLIError {
        if result.status == 127, result.stderr.contains(RemoteTmuxCommandBuilder.notFoundSentinel) {
            return CLIError(message: String(
                localized: "cli.tmuxMirror.error.tmuxNotFound",
                defaultValue: "tmux-mirror: tmux is not installed; install it with brew install tmux"
            ))
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return CLIError(message: String(
            format: String(
                localized: "cli.tmuxMirror.error.tmuxFailed",
                defaultValue: "tmux-mirror: tmux failed: %@"
            ),
            detail
        ))
    }

    /// How long one tmux command may take before the CLI gives up on it.
    static let tmuxMirrorCommandTimeoutSeconds = 10

    /// Runs tmux through the shared resolver, which also finds Homebrew and MacPorts installs.
    ///
    /// Bounded, because a frozen server, a hanging tmux, or a wrapper whose background child keeps
    /// stderr open must produce a message instead of a CLI that never returns. stderr goes
    /// to a temporary file rather than a pipe, so the CLI waits for tmux to exit, not for every
    /// holder of the pipe to close it. The wait is a deadline on that exit, not a poll.
    private func runTmuxForMirror(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let argv = RemoteTmuxCommandBuilder(arguments: arguments).remoteCommandArguments
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-mirror-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: stderrURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CLIError(message: String(
                format: String(localized: "cli.tmuxMirror.error.tmuxFailed", defaultValue: "tmux-mirror: tmux failed: %@"),
                stderrURL.path
            ))
        }
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }
        process.standardError = stderrHandle
        // The one synchronous wait in this command: a deadline on tmux's exit, signalled by
        // the termination handler, so a racing exit and timeout resolve exactly once.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let timeout = Self.tmuxMirrorCommandTimeoutSeconds
        if exited.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + .seconds(1)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + .seconds(1))
            }
            throw CLIError(message: String(
                localized: "cli.tmuxMirror.error.tmuxTimedOut",
                defaultValue: "tmux-mirror: tmux did not answer in time; the server may be frozen"
            ))
        }
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, stderr)
    }

    private func printTmuxMirrorSessions(_ result: [String: Any], socketPath: String, jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(result))
            return
        }
        let sessions = (result["sessions"] as? [Any]) ?? []
        if sessions.isEmpty {
            print(String(
                format: String(
                    localized: "cli.tmuxMirror.list.empty",
                    defaultValue: "No tmux sessions on the server at %@."
                ),
                socketPath
            ))
            return
        }
        print(String(localized: "cli.sshTmux.list.header", defaultValue: "NAME  WINDOWS  ATTACHED"))
        for item in sessions {
            guard let session = item as? [String: Any], let name = session["name"] as? String else { continue }
            let windows = session["windows"] as? Int ?? 0
            let attached = (session["attached"] as? Bool) == true ? "yes" : "no"
            print("\(name)\t\(windows)\t\(attached)")
        }
    }
}
