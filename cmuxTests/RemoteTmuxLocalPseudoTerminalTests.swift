import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The pty a local tmux control client runs on: every descriptor is close-on-exec, and the slave
/// is raw, so the control stream reaches the parser byte for byte with nothing echoed back.
@Suite struct RemoteTmuxLocalPseudoTerminalTests {
    @Test func everyDescriptorIsCloseOnExec() throws {
        let pty = try RemoteTmuxLocalPseudoTerminal()
        defer { Self.closeAll(pty) }

        for handle in [pty.masterReadHandle, pty.masterWriteHandle, pty.slaveHandle] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC != 0, "descriptor \(handle.fileDescriptor) would leak into children")
        }
    }

    @Test func readerAndWriterHoldDistinctDescriptors() throws {
        let pty = try RemoteTmuxLocalPseudoTerminal()
        defer { Self.closeAll(pty) }

        #expect(pty.masterReadHandle.fileDescriptor != pty.masterWriteHandle.fileDescriptor)
        // Closing the writer must leave the reader usable, which only holds for a duplicate.
        try pty.masterWriteHandle.close()
        #expect(fcntl(pty.masterReadHandle.fileDescriptor, F_GETFD) >= 0)
    }

    @Test func slaveIsRawSoNothingIsEchoedOrTranslated() throws {
        let pty = try RemoteTmuxLocalPseudoTerminal()
        defer { Self.closeAll(pty) }

        var attributes = termios()
        try #require(tcgetattr(pty.slaveHandle.fileDescriptor, &attributes) == 0)
        #expect(attributes.c_lflag & tcflag_t(ECHO) == 0)
        #expect(attributes.c_lflag & tcflag_t(ICANON) == 0)
        #expect(attributes.c_oflag & tcflag_t(OPOST) == 0)
        #expect(attributes.c_iflag & tcflag_t(ICRNL) == 0)
    }

    @Test func bytesCrossThePtyUnchangedInBothDirections() throws {
        let pty = try RemoteTmuxLocalPseudoTerminal()
        defer { Self.closeAll(pty) }

        // cmux to tmux: a command line arrives as written.
        try pty.masterWriteHandle.write(contentsOf: Data("list-windows\r\n".utf8))
        #expect(try Self.read(pty.slaveHandle.fileDescriptor, count: 14) == Data("list-windows\r\n".utf8))

        // Nothing was echoed back towards the parser.
        let masterFD = pty.masterReadHandle.fileDescriptor
        let flags = fcntl(masterFD, F_GETFL)
        try #require(fcntl(masterFD, F_SETFL, flags | O_NONBLOCK) == 0)
        var byte: UInt8 = 0
        #expect(Darwin.read(masterFD, &byte, 1) == -1 && errno == EAGAIN)
        try #require(fcntl(masterFD, F_SETFL, flags) == 0)

        // tmux to cmux: `\n` is not rewritten as `\r\n`.
        try pty.slaveHandle.write(contentsOf: Data("%begin 1 2 0\n".utf8))
        #expect(try Self.read(masterFD, count: 13) == Data("%begin 1 2 0\n".utf8))
    }

    @Test func requestedSizeIsApplied() throws {
        let pty = try RemoteTmuxLocalPseudoTerminal(columns: 132, rows: 41)
        defer { Self.closeAll(pty) }

        // `stty size` on the slave, run as a child, reports what the pty was opened with.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/stty")
        process.arguments = ["size"]
        process.standardInput = pty.slaveHandle
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "41 132")
    }

    /// The output reader puts the master in non-blocking mode, and the writer's descriptor is a
    /// duplicate sharing that mode, so a write larger than the pty's small input queue meets
    /// `EAGAIN`. That has to wait for tmux to read, not fail the connection.
    @Test func writerFinishesALargeWriteOnANonBlockingPty() async throws {
        let pty = try RemoteTmuxLocalPseudoTerminal()
        defer { Self.closeAll(pty) }
        let master = pty.masterReadHandle.fileDescriptor
        try #require(fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) == 0)
        let payload = Data(repeating: 0x61, count: 256 * 1024)
        let slave = pty.slaveHandle.fileDescriptor
        let expected = payload.count

        let drained = Task.detached { () -> Int in
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 4096)
            while total < expected {
                let got = buffer.withUnsafeMutableBytes { Darwin.read(slave, $0.baseAddress, 4096) }
                if got > 0 { total += got } else if got < 0, errno == EINTR { continue } else { break }
            }
            return total
        }
        let written = RemoteTmuxControlPipeWriter.writeAll(payload, to: pty.masterWriteHandle.fileDescriptor)
        if !written {
            // Unblock the reader so a failure reports instead of hanging.
            try? pty.masterWriteHandle.close()
            try? pty.masterReadHandle.close()
        }

        #expect(written)
        #expect(await drained.value == expected)
    }

    /// A client that reads nothing (stopped with SIGSTOP, say) must not hold the writer's
    /// queue forever. Nothing reads the slave here, so the pty fills and the write gives up.
    @Test func writerGivesUpOnAPtyNobodyReads() throws {
        let pty = try RemoteTmuxLocalPseudoTerminal()
        defer { Self.closeAll(pty) }
        let master = pty.masterReadHandle.fileDescriptor
        try #require(fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) == 0)
        let start = ContinuousClock().now

        let written = RemoteTmuxControlPipeWriter.writeAll(
            Data(repeating: 0x61, count: 256 * 1024),
            to: pty.masterWriteHandle.fileDescriptor,
            stallTimeoutMilliseconds: 200
        )

        #expect(!written)
        #expect(ContinuousClock().now - start < .seconds(5))
    }

    @Test func setupErrorNamesTheFailedCall() {
        let error = RemoteTmuxLocalPseudoTerminal.SetupError(step: .setAttributes, code: EBADF)
        #expect(error.description.hasPrefix("setAttributes: "))
        #expect(error.description.contains(String(cString: strerror(EBADF))))
    }

    /// A control connection whose transport owns its pty gives the client a terminal on stdin and
    /// stdout and keeps stderr a pipe, so tmux control mode starts and failure text stays readable.
    /// After `start()` the app holds the master but no copy of the slave, and after `stop()` the
    /// master is closed too, so a dead cmux can never keep the client's terminal open.
    @MainActor
    @Test func theOwnedPtyIsTheClientsTerminalAndLeavesNoDescriptorBehind() async throws {
        let directory = NSTemporaryDirectory() + "remote-tmux-owned-pty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let report = directory + "/report"
        try #require(mkfifo(report, 0o600) == 0)
        // The client tests its descriptors before redirecting anything, then reports them and the
        // name of its terminal on one line.
        let client = try Self.writeScript(at: directory + "/client", body: """
        r=""
        [ -t 0 ] && r="${r}stdin-tty "
        [ -t 1 ] && r="${r}stdout-tty "
        [ -t 2 ] || r="${r}stderr-pipe "
        printf '%s%s\\n' "$r" "$(tty)" > '\(report)'
        exec sleep 30
        """)
        // Opened read-write, so the open never blocks and the read can carry a deadline.
        let reportDescriptor = Darwin.open(report, O_RDWR)
        try #require(reportDescriptor >= 0)
        defer { Darwin.close(reportDescriptor) }

        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost.local(serverSocketPath: directory + "/no-server"),
            sessionName: "s",
            transportProfile: OwnedPtyProfile(executable: client)
        )
        try connection.start()
        let line = try Self.readLine(from: reportDescriptor, within: .seconds(10))
        let parts = line.split(separator: " ").map(String.init)
        #expect(Array(parts.dropLast()) == ["stdin-tty", "stdout-tty", "stderr-pipe"], "the client reported \(line)")
        let slave = try #require(parts.last, "no terminal name in \(line)")
        #expect(slave.hasPrefix("/dev/ttys"))

        #expect(Self.descriptorsOpen(onSlave: slave) == 0, "the app must not keep the client's slave")
        #expect(Self.mastersOpen(forSlave: slave) > 0, "the app holds the master while the client runs")

        connection.stop()
        // The master is closed from the reader's queue once its stream finishes, which has no edge
        // the test can wait on, so this waits up to two seconds for that one close.
        let deadline = ContinuousClock().now + .seconds(2)
        while Self.mastersOpen(forSlave: slave) > 0, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Self.mastersOpen(forSlave: slave) == 0, "stop() must close the master")
    }

    /// A reconnect re-checks the socket. When the path has been replaced by something that is not
    /// the user's socket, the connection ends without spawning the client again.
    @MainActor
    @Test func aReplacedSocketEndsTheConnectionWithoutASecondSpawn() async throws {
        let directory = "/tmp/cmux-pty-r-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try #require(chmod(directory, 0o700) == 0)
        let socketPath = directory + "/s"
        let listener = try Self.bindSocket(at: socketPath)
        let canonicalSocket = try #require(realpath(socketPath, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let spawns = directory + "/spawns"
        // Each spawn is logged, enters control mode the way tmux announces it, and then exits, so
        // the stream ends after control mode was reached and the connection tries to reconnect.
        let client = try Self.writeScript(at: directory + "/client", body: """
        echo spawn >> '\(spawns)'
        printf '\\033P1000p\\n'
        exec sleep 0.2
        """)

        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost.local(serverSocketPath: canonicalSocket),
            sessionName: "s",
            transportProfile: OwnedPtyProfile(executable: client, checksLocalSocket: true)
        )
        let outcome = ReconnectOutcome()
        let ended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            outcome.continuation = continuation
            connection.addObserver(
                onExit: { outcome.finish(true) },
                onConnectionStateChanged: { state in
                    // The stream ended; swap the socket for a regular file before the retry.
                    guard state == .reconnecting, !outcome.replaced else { return }
                    outcome.replaced = true
                    Darwin.close(listener)
                    try? FileManager.default.removeItem(atPath: canonicalSocket)
                    FileManager.default.createFile(atPath: canonicalSocket, contents: Data())
                }
            )
            do {
                try connection.start()
            } catch {
                outcome.finish(false)
                return
            }
            // A bound on the whole scenario, so a regression fails instead of stalling the suite.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                outcome.finish(false)
            }
        }
        defer { connection.stop() }

        #expect(outcome.replaced, "the connection never tried to reconnect")
        #expect(ended, "the connection did not end after the socket was replaced")
        let spawnCount = ((try? String(contentsOfFile: spawns, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        #expect(spawnCount == 1, "the refused reconnect must not spawn the client again (\(spawnCount) spawns)")
    }

    // MARK: - Helpers

    /// A transport that runs one fixed program on a pty cmux owns, with no arguments. With
    /// `checksLocalSocket`, it re-checks the host's socket before each spawn as the local transport
    /// does.
    private struct OwnedPtyProfile: RemoteTmuxTransportProfile {
        let executable: String
        var checksLocalSocket = false

        func executablePath() -> String { executable }
        func controlStreamArgv(
            host: RemoteTmuxHost, sessionName: String, mode: RemoteTmuxControlAttachMode
        ) -> [String] { [] }
        func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] { [] }
        var requiresPseudoTerminal: Bool { true }
        var pseudoTerminal: RemoteTmuxPseudoTerminalKind { .owned }
        var usesSharedControlMaster: Bool { false }
        var remoteHalfSurvivesLocalExit: Bool { false }
        var authenticationIsSSHShaped: Bool { false }
        func refusalBeforeSpawn(host: RemoteTmuxHost) -> RemoteTmuxError? {
            guard checksLocalSocket else { return nil }
            return RemoteTmuxLocalTransportProfile(homeDirectory: "/").refusalBeforeSpawn(host: host)
        }
    }

    private static func writeScript(at path: String, body: String) throws -> String {
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Reads one newline-terminated line, failing after `limit` instead of blocking forever.
    private static func readLine(from descriptor: Int32, within limit: Duration) throws -> String {
        var data = Data()
        let deadline = ContinuousClock().now + limit
        var byte: UInt8 = 0
        while true {
            let remaining = deadline - ContinuousClock().now
            try #require(remaining > .zero, "no report within \(limit): \(String(decoding: data, as: UTF8.self))")
            let milliseconds = Int32(max(1, remaining.components.seconds * 1000
                + remaining.components.attoseconds / 1_000_000_000_000_000))
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&request, 1, milliseconds) > 0 else { continue }
            guard Darwin.read(descriptor, &byte, 1) == 1 else { continue }
            if byte == UInt8(ascii: "\n") { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
        }
    }

    /// How many of this process's descriptors are open on the terminal `path`.
    private static func descriptorsOpen(onSlave path: String) -> Int {
        var count = 0
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETFD) >= 0 {
            if fcntl(descriptor, F_GETPATH, &buffer) == 0, String(cString: buffer) == path { count += 1 }
        }
        return count
    }

    /// How many of this process's descriptors are pty masters whose slave is `path`.
    private static func mastersOpen(forSlave path: String) -> Int {
        var count = 0
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETFD) >= 0 {
            if let name = ptsname(descriptor), String(cString: name) == path { count += 1 }
        }
        return count
    }

    /// Binds a Unix socket at `path` and returns its descriptor, which the caller closes.
    private static func bindSocket(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0, "bind failed: errno \(errno)")
        return descriptor
    }

    private static func closeAll(_ pty: RemoteTmuxLocalPseudoTerminal) {
        try? pty.masterWriteHandle.close()
        try? pty.masterReadHandle.close()
        try? pty.slaveHandle.close()
    }

    /// Reads exactly `count` bytes from a blocking descriptor.
    private static func read(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count - data.count) }
            if got < 0, errno == EINTR { continue }
            try #require(got > 0, "read failed: errno \(errno)")
            data.append(contentsOf: buffer[0..<got])
        }
        return data
    }
}

/// What the refused-reconnect test saw, resumed exactly once.
@MainActor
private final class ReconnectOutcome {
    var replaced = false
    var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ ended: Bool) {
        continuation?.resume(returning: ended)
        continuation = nil
    }
}
