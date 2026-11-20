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
        guard !Self.hasHiddenCharacter(rawPath) else { throw Refusal.hiddenCharacter }
        // The directories come first, so an unsafe place is reported as unsafe even when nothing
        // listens there yet. Otherwise the CLI would read "missing" as "no server" and start one
        // in a directory another user can tamper with.
        let rawDirectory = (rawPath as NSString).deletingLastPathComponent
        guard let directory = Self.realPath(rawDirectory) else {
            // tmux creates `tmux-<uid>` on first use, so the directory may not exist yet. The
            // nearest one that does is where tmux will create it, and it gets the same check, so
            // an unsafe TMUX_TMPDIR is refused before a server is started there.
            try Self.requirePrivateAncestors(of: Self.nearestExistingAncestor(of: rawDirectory), userID: userID)
            throw Refusal.missing(path: rawPath)
        }
        try Self.requirePrivateAncestors(of: directory, userID: userID)
        // realpath fails with ENOENT for a missing socket or a dangling link, and resolves every
        // symlink otherwise, so the ownership check below is made on the file tmux will open.
        guard let canonical = Self.realPath(rawPath) else { throw Refusal.missing(path: rawPath) }
        let canonicalDirectory = (canonical as NSString).deletingLastPathComponent
        if canonicalDirectory != directory {
            // A symlinked socket resolves into another directory, which gets the same check.
            try Self.requirePrivateAncestors(of: canonicalDirectory, userID: userID)
        }
        var status = stat()
        guard lstat(canonical, &status) == 0 else { throw Refusal.missing(path: rawPath) }
        guard status.st_mode & S_IFMT == S_IFSOCK else { throw Refusal.notASocket(path: canonical) }
        guard status.st_uid == userID else { throw Refusal.notOwnedByUser(path: canonical) }
        path = canonical
    }

    /// Refuses `directory` or any directory above it that another user could rearrange.
    ///
    /// The socket's own ownership is only as good as every directory on its path: anyone who can
    /// write to an ancestor can rename the user's directory aside and put their own in its place,
    /// without any permission on the user's directory itself. tmux applies the same rule to its own
    /// socket directory.
    static func requirePrivateAncestors(of directory: String, userID: uid_t) throws {
        var current = directory
        while true {
            var status = stat()
            guard stat(current, &status) == 0, isPrivateDirectory(status, userID: userID) else {
                throw Refusal.directoryNotPrivate(path: current)
            }
            if current == "/" || current.isEmpty { return }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Whether only `userID` (or root) can replace entries in a directory with this status.
    ///
    /// A directory others can write to passes only when it is sticky, as `/private/tmp` is, because
    /// the sticky bit stops them renaming or removing entries they do not own. Any owner other than
    /// the user or root is refused.
    static func isPrivateDirectory(_ status: stat, userID: uid_t) -> Bool {
        guard status.st_uid == userID || status.st_uid == 0 else { return false }
        let writableByOthers = status.st_mode & (S_IWGRP | S_IWOTH) != 0
        let sticky = status.st_mode & S_ISVTX != 0
        return !writableByOthers || sticky
    }

    /// The canonical form of the closest directory at or above `path` that exists; `/` at worst.
    private static func nearestExistingAncestor(of path: String) -> String {
        var current = path
        while true {
            if let resolved = realPath(current) { return resolved }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return "/" }
            current = parent
        }
    }

    /// The canonical form of `path`, or nil when it does not exist.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Control, format and separator scalars, which no socket path should contain. Kept here, not
    /// shared, so the CLI can compile this type on its own.
    static func hasHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            if scalar.properties.isDefaultIgnorableCodePoint { return true }
            if scalar.value < 0x20 || scalar.value == 0x7f { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
}
