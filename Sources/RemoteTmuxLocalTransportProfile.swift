import CmuxFoundation
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
/// The control client runs on a pty cmux owns (``ownsPseudoTerminal``), so a crashed cmux drops its
/// client at once instead of leaving it attached.
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

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
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
        // The resolver's argv starts with `/bin/sh`, which is the executable, not an argument.
        Array(
            RemoteTmuxCommandBuilder(
                arguments: tmuxServerArguments(host: host) + mode.tmuxArguments(sessionName: sessionName)
            )
            .remoteCommandArguments
            .dropFirst()
        )
    }

    /// `/bin/sh -c <command>`: the same resolver command ssh hands a remote shell, with the same
    /// quoting, run by the local shell instead.
    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] {
        ["-c", remoteCommand]
    }

    func oneShotExecutablePath() -> String { Self.shellPath }

    func oneShotEnvironment(inheriting base: [String: String]) -> [String: String] {
        base.filter { !Self.strippedEnvironmentKeys.contains($0.key) }
    }

    func childProcessEnvironment(inheriting base: [String: String]) -> [String: String] {
        oneShotEnvironment(inheriting: base)
    }

    /// No ssh, so no master to open, check or close.
    var usesSharedControlMaster: Bool { false }

    /// `tmux -CC` on a pipe fails at `tcgetattr`.
    var requiresPseudoTerminal: Bool { true }

    /// The pty is cmux's own rather than `script(1)`'s; see the type's documentation.
    var ownsPseudoTerminal: Bool { true }

    /// Killing the client closes its pty, so tmux drops the client by itself.
    var remoteHalfSurvivesLocalExit: Bool { false }

    /// There is no login to offer: the socket either is the user's or is refused.
    var authenticationIsSSHShaped: Bool { false }

    /// Worded for this Mac rather than a remote host.
    func tmuxNotFoundError(host: RemoteTmuxHost) -> RemoteTmuxError { .localTmuxNotFound }

    func unsupportedTmuxError(detected: String) -> RemoteTmuxError {
        .localTmuxUnsupported(detected: detected)
    }

    /// The CLI starts the first session from the user's shell (DESIGN.md D7), so an empty server
    /// here means nothing is running, and that is reported rather than papered over (R6).
    func emptyServerRefusal(host: RemoteTmuxHost) -> RemoteTmuxError? {
        .localServerNotRunning(socketPath: host.serverSocketPath ?? "")
    }

    /// A local mirror whose server dies ends with a message (R19).
    var announcesEndedMirror: Bool { true }

    /// A tmux command against a local server answers in milliseconds. Ten seconds matches ssh's
    /// `ConnectTimeout` and the CLI's own deadline, so a stopped server (A15) fails the call
    /// with a message instead of leaving a tmux process behind.
    var oneShotDeadline: Duration? { .seconds(10) }

    func oneShotTimeoutError(host: RemoteTmuxHost) -> RemoteTmuxError {
        .localTmuxTimedOut(socketPath: host.serverSocketPath ?? "")
    }

    /// Re-checks the socket before every spawn (R20). The boundary checked it once, but a
    /// reconnect can come long after, and the path may have changed hands in between.
    ///
    /// A path that no longer exists passes: tmux then reports "no server running" itself, which
    /// the reconnect path already reads as the end of the mirror (R19). A path that exists but is
    /// no longer a socket owned by this user, or now resolves somewhere else, is refused.
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
            return .localSocketRefused("\(error)")
        }
    }
}
