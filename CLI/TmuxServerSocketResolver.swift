import Foundation

/// Works out which tmux server `cmux tmux-mirror` means, as an absolute socket path.
///
/// The mirror has to show the server that `tmux ls` would show in the calling shell. Only the CLI
/// can see that shell's environment: an app launched from the Dock or Finder never gets the
/// shell's `TMUX` or `TMUX_TMPDIR`. So the CLI resolves the socket here and hands the app a path,
/// and the app never reads those variables itself.
///
/// The order follows tmux's own rules:
///
/// 1. `--socket-path <p>`, made absolute against the working directory.
/// 2. `--socket-name <n>`, which tmux's `-L` turns into `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<n>`.
/// 3. Inside tmux, the server of the current pane: the first comma-separated field of `$TMUX`.
/// 4. Otherwise the default server, `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default`.
struct TmuxServerSocketResolver {
    /// What the caller asked for on the command line.
    enum Request: Equatable {
        case callerDefault
        case socketName(String)
        case socketPath(String)
    }

    /// The calling shell's environment.
    let environment: [String: String]
    /// The calling user's id, which names tmux's per-user socket directory.
    let userID: uid_t
    /// The calling shell's working directory, for a relative `--socket-path`.
    let currentDirectory: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userID: uid_t = getuid(),
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.environment = environment
        self.userID = userID
        self.currentDirectory = currentDirectory
    }

    /// The absolute socket path for `request`.
    ///
    /// - Throws: `CLIError` when a socket name could not name a file in tmux's socket directory.
    func socketPath(for request: Request) throws -> String {
        switch request {
        case let .socketPath(path):
            let absolute = path.hasPrefix("/")
                ? path
                : (currentDirectory as NSString).appendingPathComponent(path)
            return (absolute as NSString).standardizingPath
        case let .socketName(name):
            guard Self.isUsableSocketName(name) else {
                throw CLIError(message: String(
                    localized: "cli.tmuxMirror.error.socketNameInvalid",
                    defaultValue: "tmux-mirror: --socket-name must be a plain name, without / or control characters"
                ))
            }
            return socketDirectory + "/" + name
        case .callerDefault:
            if let current = environment["TMUX"], let socket = current.split(
                separator: ",", maxSplits: 1, omittingEmptySubsequences: false
            ).first, socket.hasPrefix("/") {
                return String(socket)
            }
            return socketDirectory + "/default"
        }
    }

    /// `${TMUX_TMPDIR:-/tmp}/tmux-<uid>`, as tmux builds it. An empty `TMUX_TMPDIR` counts as unset,
    /// as it does for tmux.
    var socketDirectory: String {
        let base = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        let trimmed = base.count > 1 && base.hasSuffix("/") ? String(base.dropLast()) : base
        return "\(trimmed)/tmux-\(userID)"
    }

    /// A name `-L` can use: not empty, not `.` or `..`, no `/`, no control or hidden characters.
    static func isUsableSocketName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        return !name.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f || scalar.properties.isDefaultIgnorableCodePoint
        }
    }
}
