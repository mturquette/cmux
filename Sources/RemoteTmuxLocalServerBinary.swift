import Darwin
import Foundation

/// Finds the tmux binary a running local server was started from, so cmux's client is always the
/// same build as the server it talks to.
///
/// A tmux client and server of different releases can share a protocol version and still fail:
/// a tmux 3.6a client run in control mode against a 3.2a server (both protocol 8) answers nothing
/// and never exits. Plain one-shot commands work across those releases, control mode does not.
/// Running the server's own binary removes the mismatch whenever that binary still exists.
///
/// The server is found from its socket, with no tmux process: connecting to a listening Unix
/// socket gives the listener's pid (`LOCAL_PEERPID`) and user (`LOCAL_PEERCRED`), and
/// `proc_pidpath` gives that pid's executable. This is the same answer `#{pid}` and
/// `ps -o comm=` give, measured on tmux 3.2a and 3.6a, without starting a client to ask.
enum RemoteTmuxLocalServerBinary {
    /// The executable of the tmux server listening on `socketPath`, or nil when there is none to use.
    ///
    /// Nil when nothing listens there, when the listener belongs to another user, or when its
    /// binary no longer exists. The last is common: `brew upgrade tmux` deletes the old release
    /// while its server keeps running, and the kernel still reports the deleted path.
    ///
    /// - Parameters:
    ///   - socketPath: the server socket, already checked by ``RemoteTmuxLocalServerSocket``.
    ///   - userID: the user the server must run as; the current user unless a test says otherwise.
    ///   - isExecutable: whether a path names an executable file; injected so a test can make the
    ///     binary disappear.
    static func executable(
        forSocket socketPath: String,
        userID: uid_t = getuid(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        guard let pid = serverProcessID(socketPath: socketPath, userID: userID),
              let path = executablePath(ofProcess: pid),
              path.hasPrefix("/"),
              isExecutable(path)
        else { return nil }
        return path
    }

    /// The pid of the process listening on `socketPath`, when it runs as `userID`.
    static func serverProcessID(socketPath: String, userID: uid_t = getuid()) -> pid_t? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var credentials = xucred()
        var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsSize) == 0,
              credentials.cr_uid == userID
        else { return nil }
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The executable path of `pid`, as the kernel recorded it at exec.
    static func executablePath(ofProcess pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// The release in `tmux -V` output: `tmux 3.2a` gives `3.2a`, `tmux next-3.6` gives `next-3.6`.
    static func release(fromClientVersionOutput output: String) -> String? {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard let last = words.last, words.count >= 2, words.first == "tmux" else { return nil }
        return String(last)
    }

    /// The release in the server's `#{version}` answer: `3.2a\n` gives `3.2a`.
    static func release(fromServerVersionOutput output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
