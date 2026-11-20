import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Real tmux servers and clients of two releases, 3.2a and 3.6a. Both report protocol version 8,
/// and a 3.6a control client against a 3.2a server answers nothing and never exits, so these are
/// the cases where picking the client binary decides whether a mirror works at all.
///
/// Runs only where both releases are installed under `/opt/tmux`, as in the test VM.
@MainActor
@Suite(.serialized, .enabled(if: remoteTmuxMixedReleasesInstalled))
struct RemoteTmuxLocalMixedReleaseTests {
    nonisolated static let oldTmux = remoteTmuxOldRelease
    nonisolated static let newTmux = remoteTmuxNewRelease

    /// A 3.2a server, mirrored by an app whose PATH finds 3.6a first: the client is the server's
    /// own 3.2a binary, and the mirror publishes its windows.
    @Test func anOlderServerIsMirroredWithItsOwnBinary() async throws {
        let server = try TmuxServer(binary: Self.oldTmux)
        defer { server.stop() }
        let profile = server.profile(path: "\((Self.newTmux as NSString).deletingLastPathComponent):/usr/bin:/bin")

        let sessions = try await server.transport(profile).discoverMirrorSessions(createIfEmpty: false)
        #expect(sessions.map(\.name) == ["main"])
        #expect(profile.serverTmuxExecutable(host: server.host) == (try Self.canonical(Self.oldTmux)))
        #expect(try await server.mirrorPublishes(profile), "the 3.2a server did not mirror through its own binary")
    }

    /// The server's binary was deleted while it ran, and the tmux cmux finds is the same release:
    /// that tmux is used, and the mirror works.
    @Test func aDeletedServerBinaryFallsBackToTheSameRelease() async throws {
        let server = try TmuxServer(binary: Self.oldTmux, deletingBinaryAfterStart: true)
        defer { server.stop() }
        let profile = server.profile(path: "\((Self.oldTmux as NSString).deletingLastPathComponent):/usr/bin:/bin")

        #expect(profile.serverTmuxExecutable(host: server.host) == nil)
        try await server.transport(profile).assertClientMatchesServer()
        #expect(try await server.mirrorPublishes(profile), "the same-release fallback did not mirror")
    }

    /// The server's binary was deleted, and the tmux cmux finds is another release: refused with
    /// both releases named, before any control client starts.
    @Test func aDeletedServerBinaryWithAnotherFallbackReleaseIsRefused() async throws {
        let server = try TmuxServer(binary: Self.oldTmux, deletingBinaryAfterStart: true)
        defer { server.stop() }
        let profile = server.profile(path: "\((Self.newTmux as NSString).deletingLastPathComponent):/usr/bin:/bin")

        await #expect(throws: RemoteTmuxError.localTmuxVersionsDiffer(
            server: "3.2a", client: "3.6a", clientPath: Self.newTmux, socketPath: server.socketPath)) {
            _ = try await server.transport(profile).discoverMirrorSessions(createIfEmpty: false)
        }
    }

    /// The server's binary was rebuilt in place as another release while the server ran, as
    /// `make install` over the same path does. The kernel still names that path, but it now prints
    /// 3.6a, so it is not used, and the 3.6a fallback is refused with the clear message.
    @Test func aServerBinaryRebuiltInPlaceAsAnotherReleaseIsNotUsed() async throws {
        let server = try TmuxServer(binary: Self.oldTmux, replacingBinaryAfterStartWith: Self.newTmux)
        defer { server.stop() }
        let profile = server.profile(path: "\((Self.newTmux as NSString).deletingLastPathComponent):/usr/bin:/bin")

        await #expect(throws: RemoteTmuxError.localTmuxVersionsDiffer(
            server: "3.2a", client: "3.6a", clientPath: Self.newTmux, socketPath: server.socketPath)) {
            _ = try await server.transport(profile).discoverMirrorSessions(createIfEmpty: false)
        }
        #expect(profile.serverTmuxExecutable(host: server.host) == nil)
    }

    /// The backstop: a control client that never answers, here a 3.6a client against a 3.2a
    /// server with the version check bypassed, is stopped at the time limit with its own error.
    @Test func aControlClientThatNeverAnswersIsStoppedAtTheTimeLimit() async throws {
        let server = try TmuxServer(binary: Self.oldTmux, deletingBinaryAfterStart: true)
        defer { server.stop() }
        let profile = server.profile(
            path: "\((Self.newTmux as NSString).deletingLastPathComponent):/usr/bin:/bin",
            controlModeStartDeadline: .seconds(2)
        )
        let connection = RemoteTmuxControlConnection(
            host: server.host, sessionName: "main", transportProfile: profile)
        let start = ContinuousClock().now

        try connection.start()
        defer { connection.stop() }
        let connected = await Self.within(.seconds(15)) { await connection.waitUntilInitialTopology() }

        #expect(connected == false, "the hung client must end before the bound, not publish")
        #expect(ContinuousClock().now - start < .seconds(10))
        #expect(connection.startFailure == .localControlModeTimedOut)
        #expect(connection.connectionState == .ended)
    }

    /// The mirror is working through the server's own 3.2a binary when `brew upgrade` deletes that
    /// binary, and then its client dies while the server keeps running. The reconnect must not run
    /// the 3.6a fallback, which would never answer: the same release check attach runs happens
    /// first, and the connection ends with the refusal that names both releases.
    @Test func aReconnectAfterTheServersBinaryIsGoneEndsWithTheReleaseRefusal() async throws {
        let server = try TmuxServer(binary: Self.oldTmux, fromACopy: true)
        defer { server.stop() }
        let profile = server.profile(path: "\((Self.newTmux as NSString).deletingLastPathComponent):/usr/bin:/bin")
        _ = try await server.transport(profile).discoverMirrorSessions(createIfEmpty: false)
        let connection = RemoteTmuxControlConnection(host: server.host, sessionName: "main", transportProfile: profile)
        try connection.start()
        defer { connection.stop() }
        let published = await Self.within(.seconds(10)) { await connection.waitUntilInitialTopology() }
        try #require(published == true, "the 3.2a server did not mirror through its own binary")
        let outcome = ExitOutcome()
        let ended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            outcome.continuation = continuation
            connection.addObserver(onExit: { outcome.finish(true) }, onConnectionStateChanged: { _ in })
            do {
                try server.deleteBinary()
                try server.killClients()
            } catch {
                outcome.finish(false)
                return
            }
            // A bound on the whole scenario, so a regression fails instead of stalling the suite.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(40))
                outcome.finish(false)
            }
        }

        #expect(ended, "the connection kept retrying instead of ending")
        #expect(connection.startFailure == .localTmuxVersionsDiffer(
            server: "3.2a", client: "3.6a", clientPath: Self.newTmux, socketPath: server.socketPath))
    }

    // MARK: - Helpers

    /// A tmux server on a private socket, optionally started from a copy of its binary that is
    /// deleted once the server runs, as `brew upgrade` does to a running server's release.
    private struct TmuxServer {
        let directory: String
        let socketPath: String
        let host: RemoteTmuxHost
        private let killBinary: String

        init(
            binary: String,
            fromACopy: Bool = false,
            deletingBinaryAfterStart: Bool = false,
            replacingBinaryAfterStartWith replacement: String? = nil
        ) throws {
            directory = "/tmp/cmux-mr-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(chmod(directory, 0o700) == 0)
            socketPath = try RemoteTmuxLocalMixedReleaseTests.canonical(directory) + "/s"
            var launched = binary
            if fromACopy || deletingBinaryAfterStart || replacement != nil {
                launched = directory + "/copy/tmux"
                try FileManager.default.createDirectory(
                    atPath: directory + "/copy", withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: binary, toPath: launched)
            }
            killBinary = binary
            let status = try Self.run(launched, ["-S", socketPath, "-f", "/dev/null",
                                                 "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"])
            try #require(status == 0, "\(launched) could not start a server")
            if deletingBinaryAfterStart {
                try FileManager.default.removeItem(atPath: directory + "/copy")
            }
            if let replacement {
                // Unlink and copy, as `make install` does, so the running server keeps its old text.
                try FileManager.default.removeItem(atPath: launched)
                try FileManager.default.copyItem(atPath: replacement, toPath: launched)
            }
            host = RemoteTmuxHost.local(serverSocketPath: socketPath)
        }

        func profile(
            path: String, controlModeStartDeadline: Duration = .seconds(5)
        ) -> RemoteTmuxLocalTransportProfile {
            RemoteTmuxLocalTransportProfile(
                homeDirectory: directory,
                verifications: RemoteTmuxServerBinaryVerifications(),
                environmentOverrides: ["PATH": path],
                controlModeStartDeadline: controlModeStartDeadline
            )
        }

        func transport(_ profile: RemoteTmuxLocalTransportProfile) -> RemoteTmuxSSHTransport {
            RemoteTmuxSSHTransport(host: host, transportProfile: profile)
        }

        /// Whether a control connection on `main` publishes its windows within ten seconds.
        @MainActor
        func mirrorPublishes(_ profile: RemoteTmuxLocalTransportProfile) async throws -> Bool {
            let connection = RemoteTmuxControlConnection(
                host: host, sessionName: "main", transportProfile: profile)
            try connection.start()
            defer { connection.stop() }
            return await RemoteTmuxLocalMixedReleaseTests.within(.seconds(10)) {
                await connection.waitUntilInitialTopology()
            } ?? false
        }

        /// Deletes the copy the server was started from, as `brew upgrade` does to a running
        /// server's release.
        func deleteBinary() throws {
            try FileManager.default.removeItem(atPath: directory + "/copy")
        }

        /// Kills every client attached to the server, as a stalled or overflowing client is killed,
        /// while the server keeps running.
        func killClients() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: killBinary)
            process.arguments = ["-S", socketPath, "list-clients", "-F", "#{client_pid}"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let pids = text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
            try #require(!pids.isEmpty, "no client was attached to kill")
            for pid in pids { kill(pid, SIGKILL) }
        }

        func stop() {
            _ = try? Self.run(killBinary, ["-S", socketPath, "kill-server"])
            try? FileManager.default.removeItem(atPath: directory)
        }

        private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TERM": "xterm-256color"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    /// The value of `body`, or nil when it has not finished after `limit`.
    static func within<T: Sendable>(
        _ limit: Duration, _ body: @escaping @MainActor @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await ContinuousClock().sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    nonisolated static func canonical(_ path: String) throws -> String {
        let resolved = try #require(realpath(path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The two releases the suite needs, at the paths the test VM installs them. File-level, because
/// a suite's own traits cannot refer to the suite type.
private let remoteTmuxOldRelease = "/opt/tmux/3.2a/bin/tmux"
private let remoteTmuxNewRelease = "/opt/tmux/3.6a/bin/tmux"
private let remoteTmuxMixedReleasesInstalled =
    FileManager.default.isExecutableFile(atPath: remoteTmuxOldRelease)
        && FileManager.default.isExecutableFile(atPath: remoteTmuxNewRelease)

/// Whether a connection ended before the bound, resumed exactly once.
@MainActor
private final class ExitOutcome {
    var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ ended: Bool) {
        continuation?.resume(returning: ended)
        continuation = nil
    }
}
