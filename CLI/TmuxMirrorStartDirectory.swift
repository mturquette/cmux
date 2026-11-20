import Darwin
import Foundation

/// Chooses where the first session starts when `cmux tmux-mirror` has to start a tmux server.
///
/// The session opens in the directory the command was run from. `$PWD` is preferred when it names
/// the same directory as the real working directory, which keeps a symlinked path as the user
/// typed it. When that directory was deleted, cannot be entered, or has a control character in its
/// path, the session opens in the home directory instead and the command prints one line saying
/// so.
struct TmuxMirrorStartDirectory {
    /// Why the working directory was not used.
    enum Fallback: Equatable {
        /// `getcwd` failed: the directory was removed after the shell entered it.
        case workingDirectoryGone
        /// The directory exists but cannot be entered (`access(X_OK)` failed).
        case notEnterable(path: String)
        /// A newline or other control character, which tmux's `-c` cannot take safely.
        case controlCharacter
    }

    /// The directory chosen, and the reason when it is the home directory.
    struct Choice: Equatable {
        /// The directory the session starts in, as the user would read it.
        let directory: String
        /// Set when ``directory`` is the home directory because the working directory failed.
        let fallback: Fallback?

        /// The value for `tmux new-session -c`. tmux expands `#{...}` formats there, so every `#`
        /// is doubled to keep the path literal. Spaces, quotes and Unicode need nothing: the
        /// value travels in argv, not through a shell.
        var tmuxArgument: String { directory.replacingOccurrences(of: "#", with: "##") }

        /// The one line printed when the home directory was used, in the user's language.
        var notice: String? {
            guard let fallback else { return nil }
            switch fallback {
            case .workingDirectoryGone:
                return String(
                    format: String(
                        localized: "cli.tmuxMirror.startDirectory.gone",
                        defaultValue: "tmux-mirror: the current directory no longer exists; the new session starts in %@"
                    ),
                    directory
                )
            case let .notEnterable(path):
                return String(
                    format: String(
                        localized: "cli.tmuxMirror.startDirectory.notEnterable",
                        defaultValue: "tmux-mirror: cannot enter %@; the new session starts in %@"
                    ),
                    path, directory
                )
            case .controlCharacter:
                return String(
                    format: String(
                        localized: "cli.tmuxMirror.startDirectory.controlCharacter",
                        defaultValue: "tmux-mirror: the current directory's path has a control character; the new session starts in %@"
                    ),
                    directory
                )
            }
        }
    }

    /// `$PWD` from the calling shell, if set.
    let shellWorkingDirectory: String?
    /// The physical working directory from `getcwd`, or nil when it failed.
    let physicalWorkingDirectory: String?
    /// `$HOME`, the fallback.
    let homeDirectory: String
    /// Whether two paths name the same directory (same device and inode).
    let namesSameDirectory: (String, String) -> Bool
    /// Whether a directory exists and can be entered.
    let canEnter: (String) -> Bool

    init(
        shellWorkingDirectory: String?,
        physicalWorkingDirectory: String?,
        homeDirectory: String,
        namesSameDirectory: @escaping (String, String) -> Bool,
        canEnter: @escaping (String) -> Bool
    ) {
        self.shellWorkingDirectory = shellWorkingDirectory
        self.physicalWorkingDirectory = physicalWorkingDirectory
        self.homeDirectory = homeDirectory
        self.namesSameDirectory = namesSameDirectory
        self.canEnter = canEnter
    }

    /// The real process state: `$PWD`, `getcwd`, `$HOME`, `stat` and `access`.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let physical = getcwd(&buffer, buffer.count).map { _ in String(cString: buffer) }
        self.init(
            shellWorkingDirectory: environment["PWD"],
            physicalWorkingDirectory: physical,
            homeDirectory: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(),
            namesSameDirectory: { lhs, rhs in
                var a = stat(), b = stat()
                guard stat(lhs, &a) == 0, stat(rhs, &b) == 0 else { return false }
                return a.st_dev == b.st_dev && a.st_ino == b.st_ino
            },
            canEnter: { path in
                var status = stat()
                guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return false }
                return access(path, X_OK) == 0
            }
        )
    }

    /// Picks the start directory.
    func choose() -> Choice {
        guard let physical = physicalWorkingDirectory else {
            return Choice(directory: homeDirectory, fallback: .workingDirectoryGone)
        }
        let candidate: String
        if let shell = shellWorkingDirectory, shell.hasPrefix("/"), namesSameDirectory(shell, physical) {
            candidate = shell
        } else {
            candidate = physical
        }
        if candidate.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return Choice(directory: homeDirectory, fallback: .controlCharacter)
        }
        guard canEnter(candidate) else {
            return Choice(directory: homeDirectory, fallback: .notEnterable(path: candidate))
        }
        return Choice(directory: candidate, fallback: nil)
    }
}
