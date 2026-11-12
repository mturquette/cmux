import Foundation

/// Errors raised while talking to a remote tmux server over SSH.
enum RemoteTmuxError: Error, Sendable, Equatable {
    /// The `ssh` (or remote) command exited non-zero for a reason cmux does
    /// not treat as benign. Carries the exit code and captured stderr.
    case commandFailed(exitCode: Int32, stderr: String)

    /// The local `ssh` binary could not be launched at all.
    case launchFailed(String)

    /// The remote host is not reachable / the SSH master could not be opened.
    case unreachable(String)

    /// cmux could not create the local window requested for a dedicated mirror.
    case windowCreationFailed

    /// The remote tmux is older than ``RemoteTmuxVersion/minimumSupported``, so the
    /// control-mode mirror would attach into a broken/degraded state (no live pane
    /// subscriptions, or no `%begin`/`%end` framing). Carries the detected version
    /// string for the message.
    case unsupportedTmux(detected: String)

    /// The remote host has no tmux binary anywhere cmux's resolver probes.
    case tmuxNotFound(destination: String)

    /// The connection is waiting for credentials cmux cannot supply. Distinct from
    /// ``unreachable`` on purpose: the host answered, and telling the user to check the network
    /// sends them to the wrong place. Carries the destination for the message.
    case authenticationRequired(String)

    /// The local transport found no tmux binary on this Mac.
    case localTmuxNotFound

    /// The local tmux is older than ``RemoteTmuxVersion/minimumSupported``.
    case localTmuxUnsupported(detected: String)

    /// The local tmux control client could not be started, for example because its pty could not
    /// be set up.
    case localLaunchFailed(String)

    /// Nothing answers on the local server socket, and the local transport leaves starting a
    /// server to the CLI. Carries the socket path.
    case localServerNotRunning(socketPath: String)

    /// The local socket failed its re-check before a spawn. Carries the already localized reason.
    case localSocketRefused(String)

    /// A local tmux command did not finish before its deadline, for example because the server is
    /// stopped. Carries the socket path.
    case localTmuxTimedOut(socketPath: String)

    /// A local tmux command failed. The local wording of ``commandFailed(exitCode:stderr:)``.
    case localCommandFailed(exitCode: Int32, stderr: String)

    /// A local mirror could not be reached or attached. The local wording of ``unreachable(_:)``.
    case localUnreachable(String)

    /// The tmux client cmux found and the running server are different versions, which tmux
    /// refuses to connect. Carries tmux's own message.
    case localTmuxVersionMismatch(String)

    /// The running server's own tmux binary is gone (usually after a package upgrade), and the
    /// tmux cmux would use instead is a different release. tmux control mode does not work
    /// across releases even when both report the same protocol version, so cmux refuses rather
    /// than start a client that never answers.
    /// Carries both releases, the path of the tmux cmux found, and the server's socket, so the
    /// message can name the exact command that ends this server and no other.
    case localTmuxVersionsDiffer(server: String, client: String, clientPath: String, socketPath: String)

    /// The local tmux control client started but did not answer in control mode within the
    /// transport's time limit, so cmux stopped it. The server and its sessions are untouched.
    case localControlModeTimedOut

    /// A working mirror lost its control client, and every reconnect attempt since then started a
    /// client that never answered, up to the limit, so the connection ended rather than retry
    /// without end. The server and its sessions are untouched.
    case localReconnectGaveUp
}

extension RemoteTmuxError {
    /// Whether a reconnect that failed this way would fail the same way on every later attempt,
    /// so the connection should end instead of backing off and retrying.
    var refusesEveryRetry: Bool {
        if case .localSocketRefused = self { return true }
        return false
    }

    static var unknownVersionDisplayName: String {
        String(localized: "remoteTmux.version.unknown", defaultValue: "unknown")
    }

    /// A short, user-presentable description.
    ///
    /// Raw remote ssh/tmux stderr (and launch/unreachable detail) is sanitized before
    /// it reaches socket/CLI-facing error text: control/format/separator scalars
    /// (terminal escapes, NUL, CR, …) are flattened to spaces and the result is capped,
    /// so a noisy or hostile remote can't inject control bytes or unbounded output into
    /// our error bodies. Only the rendered `message` is sanitized — the stored
    /// associated `stderr`/`detail` are left untouched for the stderr-classification
    /// paths that pattern-match them (`indicatesNoServer`, `indicatesAuthRequired`,
    /// `indicatesProxyCommandTransportClosed`).
    var message: String {
        switch self {
        case let .commandFailed(exitCode, stderr):
            let detail = Self.sanitizedDetail(stderr)
            if detail.isEmpty {
                let format = String(
                    localized: "remoteTmux.error.commandFailed",
                    defaultValue: "remote command failed (exit %d)"
                )
                return String(format: format, Int(exitCode))
            }
            let format = String(
                localized: "remoteTmux.error.commandFailedWithDetail",
                defaultValue: "remote command failed (exit %d): %@"
            )
            return String(format: format, Int(exitCode), detail)
        case let .launchFailed(detail):
            let format = String(
                localized: "remoteTmux.error.launchFailed",
                defaultValue: "failed to launch SSH: %@"
            )
            return String(format: format, Self.sanitizedDetail(detail))
        case let .unreachable(detail):
            let format = String(
                localized: "remoteTmux.error.unreachable",
                defaultValue: "host unreachable: %@"
            )
            return String(format: format, Self.sanitizedDetail(detail))
        case .windowCreationFailed:
            return String(
                localized: "remoteTmux.error.windowCreationFailed",
                defaultValue: "cmux could not create a new window"
            )
        case let .unsupportedTmux(detected):
            let format = String(
                localized: "remoteTmux.error.unsupportedVersion",
                defaultValue: "remote session server is too old (found %@; cmux needs version %@ or newer)"
            )
            return String(
                format: format,
                Self.sanitizedDetail(detected),
                RemoteTmuxVersion.minimumSupported.displayString
            )
        case let .authenticationRequired(detail):
            let format = String(
                localized: "remoteTmux.error.authenticationRequired",
                defaultValue: "%@ asked for credentials and cmux has nowhere to type them. Log in to the host, then try again."
            )
            return String(format: format, Self.sanitizedDetail(detail))
        case let .tmuxNotFound(destination):
            let format = String(
                localized: "remoteTmux.error.tmuxNotFound",
                defaultValue: "tmux was not found on %@. cmux ssh-tmux mirrors a remote tmux server (tmux %@ or newer required).\nInstall it on the host: brew install tmux (macOS), apt install tmux (Debian/Ubuntu), dnf install tmux (Fedora)."
            )
            return String(
                format: format,
                Self.sanitizedDetail(destination),
                RemoteTmuxVersion.minimumSupported.displayString
            )
        case .localTmuxNotFound:
            let format = String(
                localized: "remoteTmux.error.localTmuxNotFound",
                defaultValue: "tmux was not found on this Mac. cmux tmux-mirror needs tmux %@ or newer; install it with brew install tmux."
            )
            return String(format: format, RemoteTmuxVersion.minimumSupported.displayString)
        case let .localTmuxUnsupported(detected):
            let format = String(
                localized: "remoteTmux.error.localUnsupportedVersion",
                defaultValue: "the local tmux is too old (found %@; cmux needs version %@ or newer)"
            )
            return String(
                format: format,
                Self.sanitizedDetail(detected),
                RemoteTmuxVersion.minimumSupported.displayString
            )
        case let .localLaunchFailed(detail):
            let format = String(
                localized: "remoteTmux.error.localLaunchFailed",
                defaultValue: "failed to start local tmux: %@"
            )
            return String(format: format, Self.sanitizedDetail(detail))
        case let .localServerNotRunning(socketPath):
            let format = String(
                localized: "remoteTmux.error.localServerNotRunning",
                defaultValue: "no tmux server is running at %@; run cmux tmux-mirror from a shell to start one"
            )
            return String(format: format, Self.sanitizedDetail(socketPath))
        case let .localSocketRefused(reason):
            return Self.sanitizedDetail(reason)
        case let .localTmuxTimedOut(socketPath):
            let format = String(
                localized: "remoteTmux.error.localTmuxTimedOut",
                defaultValue: "the tmux server at %@ did not answer in time; it may be frozen"
            )
            return String(format: format, Self.sanitizedDetail(socketPath))
        case let .localCommandFailed(exitCode, stderr):
            let detail = Self.sanitizedDetail(stderr)
            if detail.isEmpty {
                return String(
                    format: String(localized: "remoteTmux.error.localCommandFailed", defaultValue: "local tmux failed (exit %d)"),
                    Int(exitCode)
                )
            }
            return String(
                format: String(
                    localized: "remoteTmux.error.localCommandFailedWithDetail",
                    defaultValue: "local tmux failed (exit %d): %@"
                ),
                Int(exitCode), detail
            )
        case let .localUnreachable(detail):
            return String(
                format: String(localized: "remoteTmux.error.localUnreachable", defaultValue: "local tmux mirror failed: %@"),
                Self.sanitizedDetail(detail)
            )
        case let .localTmuxVersionMismatch(detail):
            return String(
                format: String(
                    localized: "remoteTmux.error.localVersionMismatch",
                    defaultValue: "the tmux on this Mac is a different version from the running tmux server, and tmux refuses to connect them (%@)"
                ),
                Self.sanitizedDetail(detail)
            )
        case let .localTmuxVersionsDiffer(server, client, clientPath, socketPath):
            return String(
                format: String(
                    localized: "remoteTmux.error.localVersionsDiffer",
                    defaultValue: "the tmux server at %1$@ runs tmux %2$@, but its own tmux binary is gone, and the tmux cmux found, %3$@, is tmux %4$@. tmux cannot mirror across versions. To mirror this server, install tmux %2$@ in place of %3$@, or end the server with tmux -S %5$@ kill-server (this closes every session on it, with every program running in them) and start it again."
                ),
                Self.sanitizedDetail(socketPath), Self.sanitizedDetail(server),
                Self.sanitizedDetail(clientPath), Self.sanitizedDetail(client),
                // Quoted for the shell, so the command can be copied as it stands.
                RemoteTmuxHost.shellSingleQuoted(Self.sanitizedDetail(socketPath))
            )
        case .localControlModeTimedOut:
            // The limit is fixed in the app (RemoteTmuxLocalTransportProfile.defaultControlModeStartLimit),
            // so the text names it rather than formatting a count.
            return String(
                localized: "remoteTmux.error.localControlModeTimedOut",
                defaultValue: "tmux on this Mac did not answer within 5 seconds, so cmux stopped its client. The session is still running; try again."
            )
        case .localReconnectGaveUp:
            return String(
                localized: "remoteTmux.error.localReconnectGaveUp",
                defaultValue: "the mirror lost its connection to tmux on this Mac and stopped after 3 reconnect attempts that got no answer. The session is still running; mirror it again to retry."
            )
        }
    }

    /// Flattens control/format/separator scalars to spaces and caps length, so raw
    /// remote diagnostics stay readable and bounded in user-facing error text. Mirrors
    /// the scalar categories rejected by `TerminalController.remoteTmuxValueHasHiddenCharacter`.
    private static func sanitizedDetail(_ raw: String) -> String {
        let space: Unicode.Scalar = " "
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                scalars.append(space)
            default:
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 200
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }
}

// `String(describing:)` and `error.localizedDescription` both surface the
// crafted ``message`` instead of the default enum reflection dump, so the
// socket/CLI error path (which maps thrown errors via `String(describing:)`)
// returns the readable form rather than `commandFailed(exitCode: 1, …)`.
extension RemoteTmuxError: CustomStringConvertible {
    var description: String { message }
}

extension RemoteTmuxError: LocalizedError {
    var errorDescription: String? { message }
}
