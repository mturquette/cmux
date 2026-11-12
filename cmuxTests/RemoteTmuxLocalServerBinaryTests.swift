import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The local mirror runs the tmux client from the running server's own binary, so the client and
/// server are always the same build. When that binary is gone, it falls back to the tmux it would
/// otherwise use only if that is exactly the server's release, and otherwise refuses with a
/// message naming both releases and the fix.
@Suite struct RemoteTmuxLocalServerBinaryTests {
    // MARK: Finding the server's binary

    /// The listener on a socket is found from the socket alone. Here the listener is this test
    /// process, so its binary is the one the lookup must name.
    @Test func theServersOwnBinaryIsFoundFromItsSocket() throws {
        let socket = try ListeningSocket()
        defer { socket.cleanUp() }
        let ownBinary = try #require(RemoteTmuxLocalServerBinary.executablePath(ofProcess: getpid()))

        #expect(RemoteTmuxLocalServerBinary.serverProcessID(socketPath: socket.path) == getpid())
        #expect(RemoteTmuxLocalServerBinary.executable(forSocket: socket.path) == ownBinary)
    }

    /// After a package upgrade the server keeps running from a binary that no longer exists. That
    /// path must not be run.
    @Test func aServerBinaryThatIsGoneIsNotUsed() throws {
        let socket = try ListeningSocket()
        defer { socket.cleanUp() }

        #expect(RemoteTmuxLocalServerBinary.executable(forSocket: socket.path, isExecutable: { _ in false }) == nil)
    }

    @Test func noListenerMeansNoServerBinary() throws {
        let socket = try ListeningSocket(listening: false)
        defer { socket.cleanUp() }

        #expect(RemoteTmuxLocalServerBinary.executable(forSocket: socket.path) == nil)
        #expect(RemoteTmuxLocalServerBinary.executable(forSocket: socket.directory + "/absent") == nil)
    }

    /// A binary is taken only from a server that runs as the user.
    @Test func aServerOfAnotherUserIsNotUsed() throws {
        let socket = try ListeningSocket()
        defer { socket.cleanUp() }

        #expect(RemoteTmuxLocalServerBinary.executable(forSocket: socket.path, userID: getuid() &+ 1) == nil)
    }

    @Test func releasesAreReadExactly() {
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "tmux 3.2a\n") == "3.2a")
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "tmux next-3.6\n") == "next-3.6")
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "") == nil)
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "3.2a") == nil)
        #expect(RemoteTmuxLocalServerBinary.release(fromServerVersionOutput: "3.6a\n") == "3.6a")
        #expect(RemoteTmuxLocalServerBinary.release(fromServerVersionOutput: " \n") == nil)
    }

    // MARK: Commands run the server's binary

    @Test(arguments: [
        RemoteTmuxControlAttachMode.attach,
        .attachOrCreate,
        .attachOrCreateSized(columns: 120, rows: 40),
    ])
    func theControlStreamRunsTheServersBinary(mode: RemoteTmuxControlAttachMode) {
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/dir with space/sock")
        let profile = RemoteTmuxLocalTransportProfile(
            homeDirectory: "/Users/me", serverExecutable: { _ in "/opt/tmux/3.2a/bin/tmux" })

        let argv = profile.controlStreamArgv(host: host, sessionName: "work", mode: mode)

        #expect(argv == ["-c", "exec \"$0\" \"$@\"", "/opt/tmux/3.2a/bin/tmux", "-S", "/tmp/dir with space/sock"]
            + mode.tmuxArguments(sessionName: "work"))
    }

    @Test func oneShotsRunTheServersBinary() async throws {
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default")
        let transport = RemoteTmuxSSHTransport(
            host: host,
            sshExecutablePath: recorder.executablePath,
            transportProfile: RemoteTmuxLocalTransportProfile(
                homeDirectory: "/Users/me", serverExecutable: { _ in "/opt/tmux/3.2a/bin/tmux" })
        )

        _ = try await transport.runTmux(["list-sessions", "-F", "#{session_name}"])

        #expect(recorder.invocations() == [[
            "-c",
            "exec '/opt/tmux/3.2a/bin/tmux' '-S' '/tmp/cmux-lt-absent/default' 'list-sessions' '-F' '#{session_name}'",
        ]])
    }

    /// ssh and et never look for a server binary.
    @Test func remoteTransportsKeepTheResolver() {
        let ssh = RemoteTmuxHost(destination: "user@host")
        #expect(ssh.transportProfile.serverTmuxExecutable(host: ssh) == nil)
        #expect(ssh.transportProfile.clientVersionMismatchError(server: "3.2a", client: "3.6a") == nil)
        #expect(ssh.transportProfile.controlModeStartDeadline == nil)
        #expect(ssh.transportProfile.tmuxOneShotCommand(host: ssh, arguments: ["list-sessions"])
            == RemoteTmuxHost.tmuxRemoteCommand(arguments: ["list-sessions"]))
    }

    // MARK: The fallback when the server's binary is gone

    /// The server's binary is gone and cmux's tmux is another release: refused, naming both
    /// releases and the fix, before any control client starts.
    @Test func aDifferentFallbackReleaseIsRefusedWithBothVersions() async throws {
        let fake = try VersionShell(server: "3.2a", client: "3.6a")
        defer { fake.cleanUp() }
        let transport = fake.transport(serverExecutable: nil)

        await #expect(throws: RemoteTmuxError.localTmuxVersionsDiffer(server: "3.2a", client: "3.6a")) {
            try await transport.assertMinimumTmuxVersion(checkClientWhenNoServer: false)
        }
        await #expect(throws: RemoteTmuxError.localTmuxVersionsDiffer(server: "3.2a", client: "3.6a")) {
            try await transport.assertClientMatchesServer()
        }
        let message = RemoteTmuxError.localTmuxVersionsDiffer(server: "3.2a", client: "3.6a").message
        #expect(message.contains("3.2a") && message.contains("3.6a"))
        #expect(message.contains("tmux kill-server"))
        #expect(!message.lowercased().contains("ssh"))
    }

    /// The same protocol number is not enough: only the exact release counts.
    @Test func aMatchingFallbackReleaseIsUsed() async throws {
        let fake = try VersionShell(server: "3.2a", client: "3.2a")
        defer { fake.cleanUp() }
        let transport = fake.transport(serverExecutable: nil)

        try await transport.assertMinimumTmuxVersion(checkClientWhenNoServer: false)
        try await transport.assertClientMatchesServer()
        #expect(fake.calls().contains("'-V'"))
    }

    /// While the server's binary exists, it is the client, so no comparison is needed.
    @Test func noFallbackCheckRunsWhileTheServersBinaryExists() async throws {
        let fake = try VersionShell(server: "3.2a", client: "3.6a")
        defer { fake.cleanUp() }
        let transport = fake.transport(serverExecutable: "/opt/tmux/3.2a/bin/tmux")

        try await transport.assertMinimumTmuxVersion(checkClientWhenNoServer: false)
        try await transport.assertClientMatchesServer()
        #expect(!fake.calls().contains("'-V'"))
    }

    // MARK: - Helpers

    /// A bound (and by default listening) Unix socket in a private directory under `/tmp`.
    private struct ListeningSocket {
        let directory: String
        let path: String
        private let descriptor: Int32

        init(listening: Bool = true) throws {
            directory = "/tmp/cmux-sb-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(chmod(directory, 0o700) == 0)
            path = directory + "/s"
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
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
            if listening { try #require(listen(descriptor, 4) == 0) }
        }

        func cleanUp() {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// A fake `/bin/sh` that answers the server's `#{version}` and the client's `-V`, and logs
    /// every command it is handed.
    private struct VersionShell {
        let root: String
        let path: String
        private let log: String

        init(server: String, client: String) throws {
            root = NSTemporaryDirectory() + "remote-tmux-sb-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            log = root + "/calls.log"
            path = root + "/sh"
            try """
            #!/bin/sh
            printf '%s\\n' "$2" >> '\(log)'
            case "$2" in
              *"'-V'"*) printf 'tmux \(client)\\n'; exit 0 ;;
              *"#{version}"*) printf '\(server)\\n'; exit 0 ;;
              *) exit 0 ;;
            esac
            """.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        func transport(serverExecutable: String?) -> RemoteTmuxSSHTransport {
            RemoteTmuxSSHTransport(
                host: RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default"),
                sshExecutablePath: path,
                transportProfile: RemoteTmuxLocalTransportProfile(
                    homeDirectory: "/Users/me", serverExecutable: { _ in serverExecutable })
            )
        }

        func calls() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }

        func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
    }

    /// A fake binary that appends each invocation's argv to a log and exits 0 with no output.
    private struct ArgvRecorder {
        let root: String
        let executablePath: String
        private let logPath: String

        init() throws {
            root = NSTemporaryDirectory() + "remote-tmux-sb-rec-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            logPath = root + "/argv.log"
            executablePath = root + "/recorder"
            try """
            #!/bin/sh
            if [ "$#" -gt 0 ]; then printf '%s\\0' "$@" >> '\(logPath)'; fi
            printf '\\036' >> '\(logPath)'
            exit 0
            """.write(toFile: executablePath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
        }

        func invocations() -> [[String]] {
            guard let data = FileManager.default.contents(atPath: logPath) else { return [] }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\u{1e}", omittingEmptySubsequences: false)
                .dropLast()
                .map { record in
                    record.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
                }
        }

        func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
    }
}
