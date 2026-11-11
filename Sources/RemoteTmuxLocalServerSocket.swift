import Darwin
import Foundation

/// A tmux server socket the app has agreed to connect to.
///
/// The control socket is reachable by anything running as the user, so a `socket_path` parameter
/// is checked here before it becomes a host: it has to be absolute, free of hidden or control
/// characters, and, once symlinks are resolved, a socket owned by the current user. The resolved
/// path is what the host keeps, so two spellings of one server (`/tmp/...` and `/private/tmp/...`,
/// or a symlinked directory) are one endpoint. Nothing here names an executable.
struct RemoteTmuxLocalServerSocket: Sendable, Equatable {
    /// Why a local host's parameters were refused.
    enum Refusal: Error, Sendable, Equatable {
        /// A parameter that only describes a remote machine, such as `host` or `port`.
        case parameterNotAllowed(name: String)
        case socketPathRequired
        case notAbsolute
        case hiddenCharacter
        case missing(path: String)
        case notASocket(path: String)
        case notOwnedByUser(path: String)
        /// Someone else can replace files in the socket's directory.
        case directoryNotPrivate(path: String)

        /// A localized, user-presentable reason. It talks about local tmux only.
        var message: String {
            switch self {
            case let .directoryNotPrivate(path):
                return String(
                    format: String(
                        localized: "remoteTmux.local.socket.directoryNotPrivate",
                        defaultValue: "other users can replace files in %@, so the tmux socket there cannot be trusted"
                    ),
                    path
                )
            case let .parameterNotAllowed(name):
                return String(
                    format: String(
                        localized: "remoteTmux.local.parameterNotAllowed",
                        defaultValue: "%@ does not apply to a local tmux server; pass socket_path only"
                    ),
                    name
                )
            case .socketPathRequired:
                return String(
                    localized: "remoteTmux.local.socketPathRequired",
                    defaultValue: "socket_path is required for a local tmux server"
                )
            case .notAbsolute:
                return String(
                    localized: "remoteTmux.local.socket.notAbsolute",
                    defaultValue: "the tmux socket path must be absolute"
                )
            case .hiddenCharacter:
                return String(
                    localized: "remoteTmux.local.socket.hiddenCharacter",
                    defaultValue: "the tmux socket path contains a control or hidden character"
                )
            case let .missing(path):
                return String(
                    format: String(
                        localized: "remoteTmux.local.socket.missing",
                        defaultValue: "no tmux server socket at %@; is tmux running?"
                    ),
                    path
                )
            case let .notASocket(path):
                return String(
                    format: String(
                        localized: "remoteTmux.local.socket.notASocket",
                        defaultValue: "%@ is not a tmux server socket"
                    ),
                    path
                )
            case let .notOwnedByUser(path):
                return String(
                    format: String(
                        localized: "remoteTmux.local.socket.notOwned",
                        defaultValue: "the tmux socket %@ belongs to another user"
                    ),
                    path
                )
            }
        }
    }

    /// The canonical, absolute socket path: symlinks resolved, `.` and `..` removed.
    let path: String

    /// Checks `rawPath` and resolves it to its canonical form.
    ///
    /// - Parameters:
    ///   - rawPath: the path a caller sent, used exactly as given (no trimming), since a trailing
    ///     space is a legal part of a file name.
    ///   - userID: the user the socket must belong to; the current user unless a test says otherwise.
    /// - Throws: ``Refusal`` naming the first check that failed.
    init(validating rawPath: String, userID: uid_t = getuid()) throws {
        guard rawPath.hasPrefix("/") else { throw Refusal.notAbsolute }
        guard !RemoteTmuxBrokerRegistry.hasHiddenCharacter(rawPath) else { throw Refusal.hiddenCharacter }
        // realpath fails with ENOENT for a missing socket or a dangling link, and resolves every
        // symlink otherwise, so the ownership check below is made on the file tmux will open.
        guard let resolved = realpath(rawPath, nil) else { throw Refusal.missing(path: rawPath) }
        let canonical = String(cString: resolved)
        free(resolved)
        var status = stat()
        guard lstat(canonical, &status) == 0 else { throw Refusal.missing(path: rawPath) }
        guard status.st_mode & S_IFMT == S_IFSOCK else { throw Refusal.notASocket(path: canonical) }
        guard status.st_uid == userID else { throw Refusal.notOwnedByUser(path: canonical) }
        // The ownership check above is only as good as the directory around the socket: anyone who
        // can write there can rename their own socket into place after it. tmux applies the same
        // rule to its own socket directory.
        let directory = (canonical as NSString).deletingLastPathComponent
        var directoryStatus = stat()
        guard stat(directory, &directoryStatus) == 0,
              Self.isPrivateDirectory(directoryStatus, userID: userID)
        else { throw Refusal.directoryNotPrivate(path: directory) }
        path = canonical
    }

    /// Whether only `userID` (or root) can replace entries in a directory with this status.
    ///
    /// The user's own directory may be group- or world-writable only if it is sticky, and the same
    /// holds for a root-owned one such as `/private/tmp`. Any other owner is refused.
    static func isPrivateDirectory(_ status: stat, userID: uid_t) -> Bool {
        guard status.st_uid == userID || status.st_uid == 0 else { return false }
        let writableByOthers = status.st_mode & (S_IWGRP | S_IWOTH) != 0
        let sticky = status.st_mode & S_ISVTX != 0
        return !writableByOthers || sticky
    }
}
