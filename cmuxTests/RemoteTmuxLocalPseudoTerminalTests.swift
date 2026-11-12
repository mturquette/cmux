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
    /// The fake client tests its descriptors before redirecting anything, then reports through a
    /// FIFO, which the test reads to end-of-file: an edge, not a
    /// poll.
    @MainActor
    @Test func aConnectionOnTheOwnedPtyGivesTheClientATerminalAndKeepsStderrAPipe() async throws {
        let directory = NSTemporaryDirectory() + "remote-tmux-owned-pty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let report = directory + "/report"
        try #require(mkfifo(report, 0o600) == 0)
        let client = directory + "/client"
        let script = """
        #!/bin/sh
        r=""
        [ -t 0 ] && r="${r}stdin-tty "
        [ -t 1 ] && r="${r}stdout-tty "
        [ -t 2 ] || r="${r}stderr-pipe "
        printf '%s' "$r" > '\(report)'
        exec sleep 30
        """
        try script.write(toFile: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client)

        // A blocking open: it returns once the client opens the FIFO to write its report, and the
        // read then ends when the client closes it.
        let reading = Task.detached { () -> String in
            let descriptor = Darwin.open(report, O_RDONLY)
            guard descriptor >= 0 else { return "open failed: errno \(errno)" }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        }
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost.local(serverSocketPath: directory + "/no-server"),
            sessionName: "s",
            transportProfile: OwnedPtyProfile(executable: client)
        )
        try connection.start()
        defer { connection.stop() }

        let reported = await reading.value
        #expect(reported == "stdin-tty stdout-tty stderr-pipe ", "the client reported \(reported.debugDescription)")
    }

    // MARK: - Helpers

    /// A transport that runs one fixed program on a pty cmux owns, with no arguments.
    private struct OwnedPtyProfile: RemoteTmuxTransportProfile {
        let executable: String

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
