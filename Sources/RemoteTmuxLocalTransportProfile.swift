import CmuxFoundation
import Darwin
import Foundation

/// The local transport: tmux on this Mac, reached through its server socket, with no ssh at all.
///
/// Every tmux command this profile builds names the server with `-S <socket>`, the control stream
/// and every one-shot alike, so discovery, mutations and the `-CC` stream cannot end up on
/// different servers. The socket comes from the host (``RemoteTmuxHost/serverSocketPath``), which
/// the CLI resolved from the caller's shell, because an app launched from the Dock never sees that
/// shell's `TMUX` or `TMUX_TMPDIR`.
///
/// tmux is found with the same `/bin/sh` resolver the ssh transport sends to a remote host, so a
/// Homebrew or MacPorts install is found from a GUI app's bare PATH, and a missing binary is
/// reported with the same sentinel.
///
/// The control client runs on a pty cmux owns (``RemoteTmuxPseudoTerminalKind/owned``), so a
/// crashed cmux drops its client at once instead of leaving it attached.
struct RemoteTmuxLocalTransportProfile: RemoteTmuxTransportProfile {
    /// The shell that runs the tmux resolver.
    static let shellPath = "/bin/sh"

    /// Variables that would let the app's own environment point tmux at another server.
    ///
    /// `-S` already wins over all three, but a child that does not see them cannot be confused by
    /// them, and `TMUX` inside the client's environment would also make tmux refuse to nest.
    static let strippedEnvironmentKeys: Set<String> = ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"]

    /// Where a session the app creates starts. Injected so tests can use a temporary directory.
    let homeDirectory: String

    /// Finds the running server's binary from its socket path. Injected so tests can stand in for
    /// a server, for one whose binary is gone, or for a binary that is not the server's release.
    let serverCandidate: @Sendable (String) -> RemoteTmuxServerBinaryCandidate?

    /// What running each candidate with `-V` showed. Injected so each test starts empty.
    let verifications: RemoteTmuxServerBinaryVerifications

    /// Variables set on every child on top of the app's environment. Tests use it to choose which
    /// tmux the resolver finds; the app passes none.
    let environmentOverrides: [String: String]

    /// The time limit the app uses. `RemoteTmuxError.localControlModeTimedOut` names it in its text.
    static let defaultControlModeStartLimit: Duration = .seconds(5)

    /// See ``controlModeStartDeadline``. Injected so a test can use a short limit.
    let controlModeStartLimit: Duration

    init(
        homeDirectory: String,
        serverCandidate: @escaping @Sendable (String) -> RemoteTmuxServerBinaryCandidate? = {
            RemoteTmuxLocalServerBinary().candidate(forSocket: $0)
        },
        verifications: RemoteTmuxServerBinaryVerifications = .shared,
        environmentOverrides: [String: String] = [:],
        controlModeStartDeadline: Duration = Self.defaultControlModeStartLimit
    ) {
        self.homeDirectory = homeDirectory
        self.serverCandidate = serverCandidate
        self.verifications = verifications
        self.environmentOverrides = environmentOverrides
        self.controlModeStartLimit = controlModeStartDeadline
    }

    func executablePath() -> String { Self.shellPath }

    /// `-c <home>` for a session the app creates, an idea from PR #8421. The app has no caller
    /// directory to use, and its own working directory means nothing to the user. tmux expands
    /// `#{...}` formats in `-c`, so every `#` is doubled to keep the path literal.
    func appCreatedSessionArguments() -> [String] {
        ["-c", homeDirectory.replacingOccurrences(of: "#", with: "##")]
    }

    func tmuxServerArguments(host: RemoteTmuxHost) -> [String] {
        guard let socket = host.serverSocketPath else { return [] }
        return ["-S", socket]
    }

    func controlStreamArgv(
        host: RemoteTmuxHost,
        sessionName: String,
        mode: RemoteTmuxControlAttachMode
    ) -> [String] {
        let tmuxArguments = tmuxServerArguments(host: host) + mode.tmuxArguments(sessionName: sessionName)
        // The server's own binary, passed as `$0` so no path is ever parsed by the shell.
        if let binary = serverTmuxExecutable(host: host) {
            return ["-c", Self.execScript, binary] + tmuxArguments
        }
        // The resolver's argv starts with `/bin/sh`, which is the executable, not an argument.
        return Array(RemoteTmuxCommandBuilder(arguments: tmuxArguments).remoteCommandArguments.dropFirst())
    }

    /// Runs `$0` with the remaining arguments, unchanged.
    static let execScript = "exec \"$0\" \"$@\""

    /// The running server's own binary, once running it with `-V` has shown the server's release;
    /// see ``RemoteTmuxLocalServerBinary``.
    func serverTmuxExecutable(host: RemoteTmuxHost) -> String? {
        guard let candidate = serverTmuxCandidate(host: host),
              verifications.result(for: candidate) == true
        else { return nil }
        return candidate.path
    }

    func serverTmuxCandidate(host: RemoteTmuxHost) -> RemoteTmuxServerBinaryCandidate? {
        guard let socket = host.serverSocketPath else { return nil }
        return serverCandidate(socket)
    }

    func serverTmuxVerification(_ candidate: RemoteTmuxServerBinaryCandidate) -> Bool? {
        verifications.result(for: candidate)
    }

    func recordServerTmuxVerification(_ candidate: RemoteTmuxServerBinaryCandidate, matchesServer: Bool) {
        verifications.record(candidate, matchesServer: matchesServer)
    }

    var comparesClientRelease: Bool { true }

    /// The server's own binary when it exists, otherwise the same resolver ssh uses.
    func tmuxOneShotCommand(host: RemoteTmuxHost, arguments: [String]) -> String {
        let tmuxArguments = tmuxServerArguments(host: host) + arguments
        guard let binary = serverTmuxExecutable(host: host) else {
            return RemoteTmuxHost.tmuxRemoteCommand(arguments: tmuxArguments)
        }
        return "exec " + ([binary] + tmuxArguments).map(RemoteTmuxHost.shellSingleQuoted).joined(separator: " ")
    }

    func clientVersionMismatchError(
        host: RemoteTmuxHost, server: String, client: String, clientPath: String
    ) -> RemoteTmuxError {
        .localTmuxVersionsDiffer(
            server: server, client: client, clientPath: clientPath, socketPath: host.serverSocketPath ?? "")
    }

    /// A local client answers its attach in milliseconds, so five seconds is generous, and short
    /// enough that the CLI's own deadline never runs out first.
    var controlModeStartDeadline: Duration? { controlModeStartLimit }

    func controlModeStartTimeoutError(host: RemoteTmuxHost) -> RemoteTmuxError {
        .localControlModeTimedOut
    }

    func reconnectGaveUpError(host: RemoteTmuxHost) -> RemoteTmuxError {
        .localReconnectGaveUp
    }

    /// `/bin/sh -c <command>`: the same resolver command ssh hands a remote shell, with the same
    /// quoting, run by the local shell instead.
    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] {
        ["-c", remoteCommand]
    }

    func oneShotExecutablePath() -> String { Self.shellPath }

    func oneShotEnvironment(inheriting base: [String: String]) -> [String: String]? {
        childProcessEnvironment(inheriting: base)
    }

    func childProcessEnvironment(inheriting base: [String: String]) -> [String: String] {
        base.filter { !Self.strippedEnvironmentKeys.contains($0.key) }
            .merging(environmentOverrides) { _, override in override }
    }

    /// No ssh, so no master to open, check or close.
    var usesSharedControlMaster: Bool { false }

    /// `tmux -CC` on a pipe fails at `tcgetattr`.
    var requiresPseudoTerminal: Bool { true }

    /// cmux's own pty rather than `script(1)`'s; see the type's documentation.
    var pseudoTerminal: RemoteTmuxPseudoTerminalKind { .owned }

    /// Killing the client closes its pty, so tmux drops the client by itself.
    var remoteHalfSurvivesLocalExit: Bool { false }

    /// There is no login to offer: the socket either is the user's or is refused.
    var authenticationIsSSHShaped: Bool { false }

    /// The CLI starts the first session from the user's shell, with its environment and working
    /// directory, so an empty server here means nothing is running, and that is reported instead
    /// of starting a server the user did not ask for.
    func emptyServerRefusal(host: RemoteTmuxHost) -> RemoteTmuxError? {
        .localServerNotRunning(socketPath: host.serverSocketPath ?? "")
    }

    /// The panes run on this Mac, so a pasted image is inserted as its local path.
    var pastedFilesNeedUpload: Bool { false }

    /// A tmux command against a local server answers in milliseconds. Ten seconds matches ssh's
    /// `ConnectTimeout` and the CLI's own deadline, so a stopped server fails the call with a
    /// message instead of leaving a tmux process behind.
    var oneShotDeadline: Duration? { .seconds(10) }

    func oneShotTimeoutError(host: RemoteTmuxHost) -> RemoteTmuxError {
        .localTmuxTimedOut(socketPath: host.serverSocketPath ?? "")
    }

    /// Posted when the server itself is gone, so a mirror whose server died does not vanish
    /// silently. A session that ended while its server keeps running gets no notice, exactly as for
    /// ssh-tmux, because the user usually ended it from cmux.
    func stoppedServerNotice(host: RemoteTmuxHost) -> (title: String, body: String)? {
        guard let path = host.serverSocketPath, !Self.serverAnswers(at: path) else { return nil }
        return (
            title: String(localized: "remoteTmux.local.serverStopped.title", defaultValue: "tmux server stopped"),
            body: String(
                format: String(
                    localized: "remoteTmux.local.serverStopped.body",
                    defaultValue: "The tmux server at %@ stopped, so its mirror workspaces ended."
                ),
                path
            )
        )
    }

    /// Whether something accepts connections on the socket. A Unix-domain connect answers at once:
    /// it succeeds while a server listens and fails with ENOENT or ECONNREFUSED once it is gone.
    static func serverAnswers(at path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return true }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    /// Rewords the shared remote-host failures for this Mac, and names a tmux client and server of
    /// different versions, which tmux reports as a protocol mismatch.
    func presentableError(_ error: RemoteTmuxError) -> RemoteTmuxError {
        switch error {
        case .tmuxNotFound:
            return .localTmuxNotFound
        case let .unsupportedTmux(detected):
            return .localTmuxUnsupported(detected: detected)
        case let .launchFailed(detail):
            return .localLaunchFailed(detail)
        case let .commandFailed(exitCode, stderr):
            if Self.reportsVersionMismatch(stderr) { return .localTmuxVersionMismatch(stderr) }
            return .localCommandFailed(exitCode: exitCode, stderr: stderr)
        case let .unreachable(detail):
            if Self.reportsVersionMismatch(detail) { return .localTmuxVersionMismatch(detail) }
            return .localUnreachable(detail)
        default:
            return error
        }
    }

    /// tmux's wording when a client and server of different versions meet.
    static func reportsVersionMismatch(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("protocol version mismatch") || lowered.contains("server version is too old")
    }

    /// Re-checks the socket before every spawn. The boundary checked it once, but a reconnect can
    /// come long after, and the path may have changed hands in between.
    ///
    /// A path that no longer exists passes: tmux then reports "no server running" itself, which
    /// the reconnect path already reads as the end of the mirror. A path that exists but is no
    /// longer a socket owned by this user, sits in a directory others can write to, or now
    /// resolves somewhere else, is refused.
    func refusalBeforeSpawn(host: RemoteTmuxHost) -> RemoteTmuxError? {
        guard let path = host.serverSocketPath else { return nil }
        do {
            let socket = try RemoteTmuxLocalServerSocket(validating: path)
            guard socket.path == path else {
                return .localSocketRefused(RemoteTmuxLocalServerSocket.Refusal.notASocket(path: path).message)
            }
            return nil
        } catch RemoteTmuxLocalServerSocket.Refusal.missing {
            return nil
        } catch let refusal as RemoteTmuxLocalServerSocket.Refusal {
            return .localSocketRefused(refusal.message)
        } catch {
            return .localSocketRefused(RemoteTmuxLocalServerSocket.Refusal.notASocket(path: path).message)
        }
    }
}
