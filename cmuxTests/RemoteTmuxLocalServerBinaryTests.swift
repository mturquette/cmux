import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The local mirror runs the tmux client from the running server's own binary, so the client and
/// server are always the same build. The binary the kernel names is run once with `-V` first and
/// used only if it prints the server's release. Otherwise the mirror falls back to the tmux it
/// would otherwise use, but only if that is exactly the server's release, and refuses with a
/// message naming both releases, that tmux's path, and the command that ends this server.
@Suite struct RemoteTmuxLocalServerBinaryTests {
    // MARK: Finding the server's binary

    /// The listener on a socket is found from the socket alone. Here the listener is this test
    /// process, so its binary is the one the lookup must name.
    @Test func theServersBinaryIsFoundFromItsSocket() throws {
        let socket = try ListeningSocket()
        defer { socket.cleanUp() }
        let ownBinary = try #require(RemoteTmuxLocalServerBinary.executablePath(ofProcess: getpid()))

        let candidate = try #require(RemoteTmuxLocalServerBinary().candidate(forSocket: socket.path))
        #expect(candidate.processID == getpid())
        #expect(candidate.path == ownBinary)
        #expect(candidate.startTime > 0)
    }

    /// After a package upgrade the server keeps running from a binary that no longer exists. That
    /// path must not be run.
    @Test func aServerBinaryThatIsGoneIsNotACandidate() throws {
        let socket = try ListeningSocket()
        defer { socket.cleanUp() }

        #expect(RemoteTmuxLocalServerBinary(isExecutable: { _ in false }).candidate(forSocket: socket.path) == nil)
    }

    @Test func noListenerMeansNoCandidate() throws {
        let socket = try ListeningSocket(listening: false)
        defer { socket.cleanUp() }

        #expect(RemoteTmuxLocalServerBinary().candidate(forSocket: socket.path) == nil)
        #expect(RemoteTmuxLocalServerBinary().candidate(forSocket: socket.directory + "/absent") == nil)
    }

    /// A binary is taken only from a server that runs as the user.
    @Test func aServerOfAnotherUserIsNotACandidate() throws {
        let socket = try ListeningSocket()
        defer { socket.cleanUp() }

        #expect(RemoteTmuxLocalServerBinary(userID: getuid() &+ 1).candidate(forSocket: socket.path) == nil)
    }

    @Test func releasesAreReadExactly() {
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "tmux 3.2a\n") == "3.2a")
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "tmux next-3.6\n") == "next-3.6")
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "") == nil)
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "3.2a") == nil)
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: "usage: cat [-belnstuv] [file ...]") == nil)
        #expect(RemoteTmuxLocalServerBinary.release(fromServerVersionOutput: "3.6a\n") == "3.6a")
        #expect(RemoteTmuxLocalServerBinary.release(fromServerVersionOutput: " \n") == nil)
    }

    /// A release is accepted only if it looks like one, because the text comes from a binary cmux
    /// does not trust and ends up in a message the CLI prints to the user's terminal.
    @Test(arguments: [
        ("tmux 3.2a", "3.2a"), ("tmux 3.6", "3.6"), ("tmux 3.4-rc", "3.4-rc"),
        ("tmux next-3.6", "next-3.6"), ("tmux master", "master"),
        ("tmux 3.2a\u{1b}]0;owned\u{07}", nil), ("tmux \u{1b}[31m3.2a", nil),
        ("tmux 3.2a;rm", nil), ("tmux 33333333333333333333.1", nil), ("tmux v3.2", nil),
    ] as [(String, String?)])
    func onlyAReleaseShapedVersionIsAccepted(output: String, expected: String?) {
        #expect(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: output + "\n") == expected)
        let serverOutput = String(output.dropFirst("tmux ".count))
        #expect(RemoteTmuxLocalServerBinary.release(fromServerVersionOutput: serverOutput + "\n") == expected)
    }

    /// A path is quoted in a message only if it is one absolute line with nothing hidden in it.
    @Test func onlyAPlainAbsolutePathIsQuoted() {
        #expect(RemoteTmuxLocalServerBinary.displayablePath("/opt/homebrew/bin/tmux\n") == "/opt/homebrew/bin/tmux")
        #expect(RemoteTmuxLocalServerBinary.displayablePath("tmux") == nil)
        #expect(RemoteTmuxLocalServerBinary.displayablePath("/tmp/\u{1b}[2Jx/tmux") == nil)
        #expect(RemoteTmuxLocalServerBinary.displayablePath("/a\n/b") == nil)
    }

    /// The fallback tmux prints garbage for `-V`, and the server's version probe, run through the
    /// same fallback, prints garbage too: the refusal names neither, only "unknown".
    @Test func garbageVersionsNeverReachTheMessage() async throws {
        let garbage = "tmux \u{1b}]0;owned\u{07}x"
        let fake = try VersionShell(server: "\u{1b}[31mbad", client: "", clientLine: garbage)
        defer { fake.cleanUp() }
        let transport = fake.transport(Self.profile(candidate: nil, checked: nil))
        let unknown = RemoteTmuxError.unknownVersionDisplayName

        await #expect(throws: RemoteTmuxError.localTmuxVersionsDiffer(
            server: unknown, client: unknown, clientPath: VersionShell.resolvedPath,
            socketPath: fake.host.serverSocketPath ?? "")) {
            try await transport.assertClientMatchesServer()
        }
    }

    /// The candidate names the file as well as the process, so a binary rebuilt in place at the
    /// same path, after an attach checked it, is a new candidate and is checked again.
    @Test func aCandidateNamesItsFileSoARebuildIsCheckedAgain() throws {
        let socket = try ListeningSocket()
        defer { socket.cleanUp() }
        let candidate = try #require(RemoteTmuxLocalServerBinary().candidate(forSocket: socket.path))
        #expect(candidate.file == RemoteTmuxServerBinaryCandidate.FileIdentity.of(path: candidate.path))
        #expect(candidate.file.inode != 0)

        let binary = socket.directory + "/tmux"
        try Data("one".utf8).write(to: URL(fileURLWithPath: binary))
        let before = try #require(RemoteTmuxServerBinaryCandidate.FileIdentity.of(path: binary))
        // Rewritten in place with a later modification time, as a build might.
        try Data("two".utf8).write(to: URL(fileURLWithPath: binary))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: binary)
        let rewritten = try #require(RemoteTmuxServerBinaryCandidate.FileIdentity.of(path: binary))
        // Unlinked and copied, as `make install` does.
        try FileManager.default.removeItem(atPath: binary)
        try Data("three".utf8).write(to: URL(fileURLWithPath: binary))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: binary)
        let replaced = try #require(RemoteTmuxServerBinaryCandidate.FileIdentity.of(path: binary))

        #expect(Set([before, rewritten, replaced]).count == 3)
        let table = RemoteTmuxServerBinaryVerifications()
        table.record(
            RemoteTmuxServerBinaryCandidate(path: binary, processID: 7, startTime: 1, file: before),
            matchesServer: true)
        #expect(table.result(for: RemoteTmuxServerBinaryCandidate(
            path: binary, processID: 7, startTime: 1, file: replaced)) == nil)
    }

    /// A full table drops its oldest entry, not every entry, so a recent check survives.
    @Test func aFullTableDropsOnlyItsOldestEntry() {
        let table = RemoteTmuxServerBinaryVerifications(capacity: 2)
        let candidates = (1...3).map {
            RemoteTmuxServerBinaryCandidate(path: "/t", processID: pid_t($0), startTime: 1)
        }

        for candidate in candidates { table.record(candidate, matchesServer: true) }

        #expect(table.result(for: candidates[0]) == nil)
        #expect(table.result(for: candidates[1]) == true)
        #expect(table.result(for: candidates[2]) == true)
    }

    /// A check is kept per server process, named by pid and start time, so a process that reuses
    /// the pid is checked again.
    @Test func aCheckBelongsToOneServerProcess() {
        let table = RemoteTmuxServerBinaryVerifications()
        let first = RemoteTmuxServerBinaryCandidate(path: "/opt/tmux/bin/tmux", processID: 42, startTime: 1_000)
        let reused = RemoteTmuxServerBinaryCandidate(path: "/opt/tmux/bin/tmux", processID: 42, startTime: 2_000)

        table.record(first, matchesServer: true)

        #expect(table.result(for: first) == true)
        #expect(table.result(for: reused) == nil)
    }

    // MARK: Commands run the server's binary once it is checked

    @Test(arguments: [
        RemoteTmuxControlAttachMode.attach,
        .attachOrCreate,
        .attachOrCreateSized(columns: 120, rows: 40),
    ])
    func theControlStreamRunsTheCheckedServerBinary(mode: RemoteTmuxControlAttachMode) {
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/dir with space/sock")
        let profile = Self.profile(candidate: Self.oldCandidate, checked: true)

        let argv = profile.controlStreamArgv(host: host, sessionName: "work", mode: mode)

        #expect(argv == ["-c", "exec \"$0\" \"$@\"", "/opt/tmux/3.2a/bin/tmux", "-S", "/tmp/dir with space/sock"]
            + mode.tmuxArguments(sessionName: "work"))
    }

    /// Until it is checked, the kernel's path is not run for anything but `-V`.
    @Test func anUncheckedServerBinaryIsNotUsed() {
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default")
        for checked in [false, nil] as [Bool?] {
            let profile = Self.profile(candidate: Self.oldCandidate, checked: checked)
            #expect(profile.serverTmuxExecutable(host: host) == nil)
            #expect(!profile.controlStreamArgv(host: host, sessionName: "s", mode: .attach)
                .contains("/opt/tmux/3.2a/bin/tmux"))
        }
    }

    @Test func oneShotsRunTheCheckedServerBinary() async throws {
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default")
        let transport = RemoteTmuxSSHTransport(
            host: host,
            sshExecutablePath: recorder.executablePath,
            transportProfile: Self.profile(candidate: Self.oldCandidate, checked: true)
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
        #expect(ssh.transportProfile.serverTmuxCandidate(host: ssh) == nil)
        #expect(!ssh.transportProfile.comparesClientRelease)
        #expect(ssh.transportProfile.controlModeStartDeadline == nil)
        #expect(ssh.transportProfile.tmuxOneShotCommand(host: ssh, arguments: ["list-sessions"])
            == RemoteTmuxHost.tmuxRemoteCommand(arguments: ["list-sessions"]))
    }

    // MARK: Checking the server's binary

    /// The kernel's path prints the server's release: it becomes the client, the fallback tmux is
    /// never asked, and the check runs once for that server process.
    @Test func aServerBinaryThatPrintsTheServersReleaseIsUsed() async throws {
        let fake = try VersionShell(server: "3.2a", client: "3.6a", candidateOutput: "tmux 3.2a")
        defer { fake.cleanUp() }
        let profile = Self.profile(candidate: fake.candidate, checked: nil)
        let transport = fake.transport(profile)

        try await transport.assertMinimumTmuxVersion(checkClientWhenNoServer: false)
        try await transport.assertClientMatchesServer()

        #expect(profile.serverTmuxExecutable(host: fake.host) == fake.candidate.path)
        #expect(fake.calls(running: fake.candidate.path) == 1, "one check per server process")
        #expect(!fake.callsResolver())
    }

    /// A binary rebuilt in place as another release is not the server's build: it is not used, and
    /// with a fallback of the same other release the attach is refused with the clear message.
    @Test func aServerBinaryRebuiltAsAnotherReleaseIsNotUsed() async throws {
        let fake = try VersionShell(server: "3.2a", client: "3.6a", candidateOutput: "tmux 3.6a")
        defer { fake.cleanUp() }
        let profile = Self.profile(candidate: fake.candidate, checked: nil)

        await #expect(throws: RemoteTmuxError.localTmuxVersionsDiffer(
            server: "3.2a", client: "3.6a", clientPath: VersionShell.resolvedPath, socketPath: fake.host.serverSocketPath ?? "")) {
            try await fake.transport(profile).assertMinimumTmuxVersion(checkClientWhenNoServer: false)
        }
        #expect(profile.serverTmuxExecutable(host: fake.host) == nil)
    }

    /// A reused pid names some other program, which prints no tmux release. It is not used, and the
    /// fallback decides: here it is the server's release, so the attach goes ahead.
    @Test func aProgramThatIsNotTmuxIsNotUsed() async throws {
        let fake = try VersionShell(server: "3.2a", client: "3.2a", candidateOutput: "usage: cat [-belnstuv] [file ...]")
        defer { fake.cleanUp() }
        let profile = Self.profile(candidate: fake.candidate, checked: nil)

        try await fake.transport(profile).assertMinimumTmuxVersion(checkClientWhenNoServer: false)

        #expect(profile.serverTmuxExecutable(host: fake.host) == nil)
        #expect(fake.callsResolver())
    }

    // MARK: The fallback when the server's binary is gone

    /// The server's binary is gone and cmux's tmux is another release: refused, naming both
    /// releases, the tmux cmux found, and the command that ends this server.
    @Test func aDifferentFallbackReleaseIsRefusedWithBothVersions() async throws {
        let fake = try VersionShell(server: "3.2a", client: "3.6a")
        defer { fake.cleanUp() }
        let transport = fake.transport(Self.profile(candidate: nil, checked: nil))
        let expected = RemoteTmuxError.localTmuxVersionsDiffer(
            server: "3.2a", client: "3.6a", clientPath: VersionShell.resolvedPath,
            socketPath: fake.host.serverSocketPath ?? "")

        await #expect(throws: expected) {
            try await transport.assertMinimumTmuxVersion(checkClientWhenNoServer: false)
        }
        await #expect(throws: expected) {
            try await transport.assertClientMatchesServer()
        }
    }

    /// The same protocol number is not enough: only the exact release counts.
    @Test func aMatchingFallbackReleaseIsUsed() async throws {
        let fake = try VersionShell(server: "3.2a", client: "3.2a")
        defer { fake.cleanUp() }
        let transport = fake.transport(Self.profile(candidate: nil, checked: nil))

        try await transport.assertMinimumTmuxVersion(checkClientWhenNoServer: false)
        try await transport.assertClientMatchesServer()
        #expect(fake.callsResolver())
    }

    // MARK: Wording

    /// The mismatch message names the server's socket in the command that ends it, says that this
    /// closes every session on it, and names the tmux cmux found by its path.
    @Test func theMismatchMessageNamesTheServerAndWhatEndingItCosts() {
        let message = RemoteTmuxError.localTmuxVersionsDiffer(
            server: "3.2a", client: "3.6a", clientPath: "/opt/homebrew/bin/tmux",
            socketPath: "/private/tmp/tmux-501/work"
        ).message

        #expect(message.contains("3.2a") && message.contains("3.6a"))
        #expect(message.contains("/opt/homebrew/bin/tmux"))
        #expect(message.contains("tmux -S '/private/tmp/tmux-501/work' kill-server"))
        #expect(message.contains("closes every session"))
        #expect(!message.lowercased().contains("restart"))
        #expect(!message.lowercased().contains("ssh"))
    }

    /// The time-limit message says what happened and to try again, and nothing about ending the
    /// server, because nothing points at a mismatch.
    @Test func theTimeLimitMessageSaysOnlyWhatHappened() {
        let message = RemoteTmuxError.localControlModeTimedOut.message

        #expect(message.contains("5 seconds"))
        #expect(message.contains("try again"))
        #expect(message.contains("still running"))
        #expect(!message.contains("kill-server"))
        #expect(!message.lowercased().contains("ssh"))
    }

    // MARK: - Helpers

    static let oldCandidate = RemoteTmuxServerBinaryCandidate(
        path: "/opt/tmux/3.2a/bin/tmux", processID: 4242, startTime: 1_000)

    /// A local profile whose server binary is `candidate`, already checked (`checked`) or not yet
    /// run (`nil`), with a table of its own.
    static func profile(
        candidate: RemoteTmuxServerBinaryCandidate?, checked: Bool?
    ) -> RemoteTmuxLocalTransportProfile {
        let table = RemoteTmuxServerBinaryVerifications()
        if let candidate, let checked { table.record(candidate, matchesServer: checked) }
        return RemoteTmuxLocalTransportProfile(
            homeDirectory: "/Users/me", serverCandidate: { _ in candidate }, verifications: table)
    }

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

    /// A fake `/bin/sh` that answers the server's `#{version}`, the candidate binary's `-V`, the
    /// resolver's path probe and the resolved tmux's `-V`, and logs every command it is handed.
    private struct VersionShell {
        static let resolvedPath = "/opt/fallback/bin/tmux"
        let root: String
        let path: String
        let candidate: RemoteTmuxServerBinaryCandidate
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default")
        private let log: String

        init(server: String, client: String, candidateOutput: String = "", clientLine: String? = nil) throws {
            root = NSTemporaryDirectory() + "remote-tmux-sb-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            log = root + "/calls.log"
            path = root + "/sh"
            candidate = RemoteTmuxServerBinaryCandidate(path: root + "/server-tmux", processID: 4242, startTime: 1_000)
            try """
            #!/bin/sh
            printf '%s\\n' "$2" >> '\(log)'
            case "$2" in
              *"#{version}"*) printf '\(server)\\n'; exit 0 ;;
              *"'\(candidate.path)' '-V'"*) printf '%s\\n' '\(candidateOutput)'; exit 0 ;;
              *"'-V'"*) printf '%s\\n' '\(clientLine ?? "tmux " + client)'; exit 0 ;;
              *cmux-remote-executable*) printf '\(Self.resolvedPath)\\n'; exit 0 ;;
              *) exit 0 ;;
            esac
            """.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        func transport(_ profile: RemoteTmuxLocalTransportProfile) -> RemoteTmuxSSHTransport {
            RemoteTmuxSSHTransport(host: host, sshExecutablePath: path, transportProfile: profile)
        }

        private func calls() -> [String] {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        /// How many commands ran `binary -V`.
        func calls(running binary: String) -> Int {
            calls().filter { $0.contains("'\(binary)' '-V'") }.count
        }

        /// Whether the resolver was asked for its tmux.
        func callsResolver() -> Bool {
            calls().contains { $0.contains("cmux-remote-executable") && !$0.contains("#{version}") }
        }

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
