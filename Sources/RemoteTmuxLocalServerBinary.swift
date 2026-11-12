import Darwin
import Foundation
import os

/// The binary a running tmux server was started from, as the kernel reports it, before cmux has
/// checked that it really is that server's tmux.
///
/// The process is named by its pid and its start time together, so a later process that reuses the
/// pid is a different candidate. The file is named by its device, inode and modification time, so
/// a binary rebuilt in place at the same path is a different candidate too, and is checked again.
struct RemoteTmuxServerBinaryCandidate: Sendable, Hashable {
    let path: String
    let processID: pid_t
    /// Microseconds since the epoch at which the process started.
    let startTime: Int64
    let file: FileIdentity

    init(path: String, processID: pid_t, startTime: Int64, file: FileIdentity = FileIdentity()) {
        self.path = path
        self.processID = processID
        self.startTime = startTime
        self.file = file
    }

    /// What `stat` says about the file at ``path``: which file it is, and when it last changed.
    struct FileIdentity: Sendable, Hashable {
        var device: Int64 = 0
        var inode: UInt64 = 0
        var modifiedSeconds: Int64 = 0
        var modifiedNanoseconds: Int64 = 0

        /// The identity of the file at `path`, or nil when it cannot be read.
        static func of(path: String) -> FileIdentity? {
            var status = stat()
            guard stat(path, &status) == 0 else { return nil }
            return FileIdentity(
                device: Int64(status.st_dev),
                inode: UInt64(status.st_ino),
                modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec)
            )
        }
    }
}

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
/// `proc_pidpath` gives that pid's executable. The kernel's answer is only a candidate. Before it
/// is used, the transport runs it once with `-V` and accepts it only if it prints the server's own
/// release (``RemoteTmuxServerBinaryVerifications``), which rules out a reused pid and a binary
/// rebuilt in place as another release.
struct RemoteTmuxLocalServerBinary: Sendable {
    /// The user the server must run as.
    let userID: uid_t
    /// Whether a path names an executable file; injected so a test can make the binary disappear.
    let isExecutable: @Sendable (String) -> Bool

    init(
        userID: uid_t = getuid(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.userID = userID
        self.isExecutable = isExecutable
    }

    /// The executable of the tmux server listening on `socketPath`, or nil when there is none to try.
    ///
    /// Nil when nothing listens there, when the listener or its process belongs to another user, or
    /// when its binary no longer exists. The last is common: `brew upgrade tmux` deletes the old
    /// release while its server keeps running, and the kernel still reports the deleted path.
    func candidate(forSocket socketPath: String) -> RemoteTmuxServerBinaryCandidate? {
        guard let pid = serverProcessID(socketPath: socketPath),
              let process = Self.processInfo(pid), process.pbi_uid == userID,
              let path = Self.executablePath(ofProcess: pid),
              path.hasPrefix("/"),
              isExecutable(path),
              let file = RemoteTmuxServerBinaryCandidate.FileIdentity.of(path: path)
        else { return nil }
        let startTime = Int64(process.pbi_start_tvsec) * 1_000_000 + Int64(process.pbi_start_tvusec)
        _ = file  // Red stub: the file is not part of the key yet.
        return RemoteTmuxServerBinaryCandidate(path: path, processID: pid, startTime: startTime)
    }

    /// The pid of the process listening on `socketPath`, when it runs as ``userID``.
    func serverProcessID(socketPath: String) -> pid_t? {
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

    /// The owner and start time of `pid`.
    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize)) == expectedSize else { return nil }
        return info
    }

    /// The release in `tmux -V` output: `tmux 3.2a` gives `3.2a`, `tmux next-3.6` gives `next-3.6`.
    /// Anything else, including the output of a program that is not tmux, gives nil.
    static func release(fromClientVersionOutput output: String) -> String? {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0] == "tmux" else { return nil }
        return String(words[1])
    }

    /// The release in the server's `#{version}` answer: `3.2a\n` gives `3.2a`.
    static func release(fromServerVersionOutput output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What cmux learned when it ran a server's candidate binary with `-V`, kept per server process so
/// each server costs one extra process however many commands cmux sends it.
///
/// One table for the app, because the answer belongs to the server process and its file, not to
/// any one mirror: every profile value for the same socket (they are rebuilt for each command) must
/// see the check another one made. A profile is built from a host with no route to the controller,
/// so the table cannot be passed down without threading it through every host, and tests inject
/// their own instead. The lock guards a small dictionary that is read and written from the
/// transport actors and the main actor; each access is one lookup or one insert, never held across
/// a suspension point.
final class RemoteTmuxServerBinaryVerifications: Sendable {
    /// The app's one table. Tests make their own.
    static let shared = RemoteTmuxServerBinaryVerifications()

    /// The most entries kept. A server that exited leaves its entry behind, so the oldest go first.
    let capacity: Int

    private struct Table {
        var results: [RemoteTmuxServerBinaryCandidate: Bool] = [:]
        /// Insertion order, oldest first, for eviction.
        var order: [RemoteTmuxServerBinaryCandidate] = []
    }

    private let table = OSAllocatedUnfairLock(initialState: Table())

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// Whether `candidate` printed its server's release, or nil when it has not been run yet.
    func result(for candidate: RemoteTmuxServerBinaryCandidate) -> Bool? {
        table.withLock { $0.results[candidate] }
    }

    func record(_ candidate: RemoteTmuxServerBinaryCandidate, matchesServer: Bool) {
        let capacity = capacity
        table.withLock { table in
            if table.results.updateValue(matchesServer, forKey: candidate) == nil {
                table.order.append(candidate)
            }
            // Only the oldest entries go. A mirror whose entry went anyway is checked again before
            // its next reconnect, which is the only time it starts a new client.
            while table.order.count > capacity {
                table.results.removeValue(forKey: table.order.removeFirst())
            }
        }
    }
}
