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

        if let notice = try startTmuxMirrorServerIfNeeded(socketPath: socketPath), !jsonOutput {
            print(notice)
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
            print(jsonString(result))
        } else {
            let windowId = (result["window_id"] as? String) ?? ""
            let count = (result["workspace_ids"] as? [Any])?.count ?? 0
            print("OK socket=\(socketPath) workspaces=\(count) window=\(windowId)")
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

    /// Runs tmux through the shared resolver, which also finds Homebrew and MacPorts installs.
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
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        // tmux's stderr is a line or two; reading to EOF before waiting cannot fill the pipe.
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stderr, as: UTF8.self))
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
