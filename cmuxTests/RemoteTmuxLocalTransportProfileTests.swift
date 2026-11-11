import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The `local` transport: tmux on this Mac, named by its server socket, with no ssh.
///
/// Covers what the transport builds and refuses without running tmux: every tmux command names
/// the server with `-S`, nothing ssh-shaped runs, the app's own `TMUX*` variables never reach the
/// child, a local endpoint's identity is its canonical socket path, and the socket boundary
/// refuses anything that is not the user's own socket.
@Suite struct RemoteTmuxLocalTransportProfileTests {
    // MARK: Kind and profile

    @Test func localParsesAndRefusesRemoteOnlyOptions() {
        #expect(RemoteTmuxTransportKind.parse("local") == .local)
        #expect(RemoteTmuxTransportKind.parse(" LOCAL ") == .local)
        #expect(!RemoteTmuxTransportKind.local.usesTransportBroker)
        #expect(!RemoteTmuxTransportKind.local.supportsTransportHelperPath)
    }

    @Test func profileDescribesALocalPtyClientWithNoSSH() {
        let profile = RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default").transportProfile
        #expect(profile is RemoteTmuxLocalTransportProfile)
        #expect(profile.requiresPseudoTerminal)
        #expect(profile.ownsPseudoTerminal)
        #expect(!profile.usesSharedControlMaster)
        #expect(!profile.remoteHalfSurvivesLocalExit)
        #expect(!profile.authenticationIsSSHShaped)
        #expect(profile.executablePath() == "/bin/sh")
        #expect(profile.oneShotExecutablePath() == "/bin/sh")
    }

    @Test(arguments: [
        RemoteTmuxControlAttachMode.attach,
        .attachOrCreate,
        .attachOrCreateSized(columns: 120, rows: 40),
    ])
    func controlStreamNamesTheServerBeforeControlMode(mode: RemoteTmuxControlAttachMode) {
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/dir with space/sock")
        let argv = host.transportProfile.controlStreamArgv(host: host, sessionName: "work", mode: mode)

        #expect(argv.first == "-c", "argv runs the resolver script with /bin/sh -c")
        // The resolver passes everything after the sentinel to tmux unchanged.
        let tmuxArgs = Array(argv.drop(while: { $0 != RemoteTmuxHost.tmuxNotFoundSentinel }).dropFirst())
        #expect(tmuxArgs == ["-S", "/tmp/dir with space/sock"] + mode.tmuxArguments(sessionName: "work"))
        #expect(!argv.contains { $0.contains("ssh") })
    }

    @Test func oneShotsNameTheServerAndRunThroughTheLocalShell() async throws {
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default")
        // The injected binary stands in for /bin/sh, so nothing runs tmux.
        let transport = RemoteTmuxSSHTransport(host: host, sshExecutablePath: recorder.executablePath)

        _ = try await transport.runTmux(["list-sessions"])

        let command = RemoteTmuxHost.tmuxRemoteCommand(
            arguments: ["-S", "/tmp/cmux-lt-absent/default", "list-sessions"]
        )
        #expect(recorder.invocations() == [["-c", command]])
    }

    @Test func noMasterStepRunsForALocalHost() async throws {
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default"),
            sshExecutablePath: recorder.executablePath
        )

        #expect(try await transport.ensureMasterReady())
        await transport.shutdownMaster()
        RemoteTmuxSSHTransport.spawnControlMasterExit(
            host: RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default"),
            sshExecutablePath: recorder.executablePath
        )

        #expect(recorder.invocations().isEmpty)
    }

    @Test func appEnvironmentCannotRedirectTheChild() {
        let profile = RemoteTmuxLocalTransportProfile(homeDirectory: "/Users/me")
        let decoy = [
            "TMUX": "/tmp/decoy,1,0", "TMUX_PANE": "%3", "TMUX_TMPDIR": "/tmp/decoy",
            "PATH": "/usr/bin:/bin", "HOME": "/Users/me",
        ]

        for environment in [
            profile.oneShotEnvironment(inheriting: decoy),
            profile.childProcessEnvironment(inheriting: decoy),
        ] {
            #expect(environment["TMUX"] == nil)
            #expect(environment["TMUX_PANE"] == nil)
            #expect(environment["TMUX_TMPDIR"] == nil)
            #expect(environment["PATH"] == "/usr/bin:/bin")
            #expect(environment["HOME"] == "/Users/me")
        }
    }

    @Test func appCreatedSessionsStartInHomeWithFormatsKeptLiteral() {
        #expect(RemoteTmuxLocalTransportProfile(homeDirectory: "/Users/me").appCreatedSessionArguments()
            == ["-c", "/Users/me"])
        #expect(RemoteTmuxLocalTransportProfile(homeDirectory: "/tmp/#{session_name} #1")
            .appCreatedSessionArguments() == ["-c", "/tmp/##{session_name} ##1"])
        // ssh and et keep tmux's own default.
        #expect(RemoteTmuxSSHTransportProfile().appCreatedSessionArguments().isEmpty)
    }

    // MARK: Failure wording (R6)

    @Test func missingTmuxIsReportedForThisMacWithoutSSH() async throws {
        let fake = try FakeShell(body: "printf '%s\\n' '\(RemoteTmuxHost.tmuxNotFoundSentinel)' >&2; exit 127")
        defer { fake.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default"),
            sshExecutablePath: fake.path
        )

        await #expect(throws: RemoteTmuxError.localTmuxNotFound) { _ = try await transport.listSessions() }
        #expect(!RemoteTmuxError.localTmuxNotFound.message.lowercased().contains("ssh"))
    }

    @Test func oldTmuxIsRefusedWithLocalWording() async throws {
        // No server answers; the client binary reports 3.1, below the 3.2 minimum.
        let fake = try FakeShell(body: """
        case "$2" in
          *"'-V'"*) printf 'tmux 3.1\\n'; exit 0 ;;
          *) printf 'no server running on /tmp/cmux-lt-absent/default\\n' >&2; exit 1 ;;
        esac
        """)
        defer { fake.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default"),
            sshExecutablePath: fake.path
        )

        await #expect(throws: RemoteTmuxError.localTmuxUnsupported(detected: "3.1")) {
            try await transport.assertMinimumTmuxVersion(checkClientWhenNoServer: true)
        }
        let message = RemoteTmuxError.localTmuxUnsupported(detected: "3.1").message
        #expect(message.contains("3.1"))
        #expect(!message.lowercased().contains("ssh"))
        #expect(!RemoteTmuxError.localLaunchFailed("openpty").message.lowercased().contains("ssh"))
    }

    /// R6 and D7: with no server running, the app refuses with its own message instead of
    /// starting a server whose first session would miss the user's environment.
    @Test func mirroringAnEmptyLocalServerIsRefusedAndStartsNothing() async throws {
        let log = NSTemporaryDirectory() + "remote-tmux-local-calls-\(UUID().uuidString).log"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let fake = try FakeShell(body: """
        printf '%s\\n' "$2" >> '\(log)'
        case "$2" in
          *"'-V'"*) printf 'tmux 3.6a\\n'; exit 0 ;;
          *) printf 'no server running on /tmp/x/default\\n' >&2; exit 1 ;;
        esac
        """)
        defer { fake.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost.local(serverSocketPath: "/tmp/x/default"),
            sshExecutablePath: fake.path
        )

        await #expect(throws: RemoteTmuxError.localServerNotRunning(socketPath: "/tmp/x/default")) {
            _ = try await transport.discoverMirrorSessions(createIfEmpty: true)
        }
        let calls = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(!calls.contains("'new-session'"))
        let message = RemoteTmuxError.localServerNotRunning(socketPath: "/tmp/x/default").message
        #expect(message.contains("/tmp/x/default"))
        #expect(!message.lowercased().contains("ssh"))
    }

    /// R20 and A16: the socket is checked again before every spawn, not only at the boundary.
    @Test func aSocketThatChangedHandsIsRefusedBeforeAnyCommandRuns() async throws {
        let socket = try TemporarySocket()
        defer { socket.cleanUp() }
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let host = RemoteTmuxHost.local(serverSocketPath: socket.canonicalPath)
        let transport = RemoteTmuxSSHTransport(host: host, sshExecutablePath: recorder.executablePath)

        // While the socket is the user's, commands run.
        _ = try await transport.runTmux(["list-sessions"])
        #expect(recorder.invocations().count == 1)

        // The path is replaced by something that is not a socket.
        try FileManager.default.removeItem(atPath: socket.canonicalPath)
        FileManager.default.createFile(atPath: socket.canonicalPath, contents: Data())
        await #expect(throws: RemoteTmuxError.self) { _ = try await transport.runTmux(["list-sessions"]) }
        #expect(recorder.invocations().count == 1, "nothing may run once the socket fails its check")
        let refusal = host.transportProfile.refusalBeforeSpawn(host: host)
        #expect(refusal?.refusesEveryRetry == true)

        // A path that is simply gone is left to tmux, which reports that no server is running.
        try FileManager.default.removeItem(atPath: socket.canonicalPath)
        #expect(host.transportProfile.refusalBeforeSpawn(host: host) == nil)
    }

    /// A15: a tmux command against a stopped server ends at the deadline, and its process with it.
    @Test func aLocalCommandThatNeverAnswersEndsAtTheDeadline() async throws {
        let pidFile = NSTemporaryDirectory() + "remote-tmux-local-hang-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let fake = try FakeShell(body: "echo $$ > '\(pidFile)'; exec sleep 600")
        defer { fake.cleanUp() }
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default")
        let transport = RemoteTmuxSSHTransport(host: host, sshExecutablePath: fake.path)
        let start = ContinuousClock().now

        await #expect(throws: RemoteTmuxError.localTmuxTimedOut(socketPath: "/tmp/cmux-lt-absent/default")) {
            _ = try await transport.runTmux(["list-sessions"])
        }

        #expect(ContinuousClock().now - start < .seconds(20))
        let pid = try #require(Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        // Foundation reaps the killed child on its own queue, so give it a moment to disappear.
        var alive = true
        for _ in 0..<40 where alive {
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive, "the hung command's process must not outlive the deadline")
        #expect(!RemoteTmuxError.localTmuxTimedOut(socketPath: "/s").message.lowercased().contains("ssh"))
    }

    /// R8: a local mirror pane is on this Mac, so a pasted image goes in as its local path, while
    /// ssh and et panes still upload it first.
    @Test func onlyRemoteTransportsUploadPastedFiles() {
        #expect(!RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default").transportProfile
            .pastedFilesNeedUpload)
        #expect(RemoteTmuxHost(destination: "user@host").transportProfile.pastedFilesNeedUpload)
        #expect(RemoteTmuxHost(destination: "box", transport: .et).transportProfile.pastedFilesNeedUpload)
    }

    @Test func onlyTheLocalTransportAnnouncesAnEndedMirror() {
        #expect(RemoteTmuxHost.local(serverSocketPath: "/tmp/x").transportProfile.announcesEndedMirror)
        #expect(!RemoteTmuxHost(destination: "user@host").transportProfile.announcesEndedMirror)
        #expect(!RemoteTmuxHost(destination: "box", transport: .et).transportProfile.announcesEndedMirror)
        #expect(RemoteTmuxHost(destination: "user@host").transportProfile.emptyServerRefusal(
            host: RemoteTmuxHost(destination: "user@host")) == nil)
    }

    // MARK: Identity

    @Test func localIdentityIsTheSocketPathAlone() {
        let a = RemoteTmuxHost.local(serverSocketPath: "/private/tmp/cmux-lt-absent/default")
        let b = RemoteTmuxHost.local(serverSocketPath: "/private/tmp/cmux-lt-absent/default")
        let other = RemoteTmuxHost.local(serverSocketPath: "/private/tmp/tmux-501/alt")
        #expect(a.connectionHash == b.connectionHash)
        #expect(a.connectionHash != other.connectionHash)
        // An ssh host spelled to look like the local one is still a different endpoint.
        let lookalike = RemoteTmuxHost(destination: "local", identityFile: "/private/tmp/cmux-lt-absent/default")
        #expect(lookalike.connectionHash != a.connectionHash)
    }

    @Test func sshAndETHashesAreUnchanged() {
        // The fingerprints main used before the local transport existed. These hashes name
        // ControlMaster sockets and saved mirror state, so they must not move.
        #expect(RemoteTmuxHost(destination: "user@host").connectionHash
            == RemoteTmuxHost.fnv1a64Hex("user@host\u{1f}\u{1f}"))
        #expect(RemoteTmuxHost(destination: "box", port: 2222, identityFile: "/k").connectionHash
            == RemoteTmuxHost.fnv1a64Hex("box\u{1f}2222\u{1f}/k"))
        #expect(RemoteTmuxHost(destination: "box", transport: .et).connectionHash
            == RemoteTmuxHost.fnv1a64Hex("box\u{1f}\u{1f}\u{1f}et\u{1f}2022"))
    }

    // MARK: Socket boundary

    @Test func boundaryBuildsALocalHostFromTheCanonicalSocketPath() throws {
        let socket = try TemporarySocket()
        defer { socket.cleanUp() }
        // `/tmp` is a symlink to `/private/tmp`; both spellings must give one endpoint.
        let host = try #require(TerminalController.remoteTmuxHost(
            from: ["transport": "local", "socket_path": socket.path]
        ))
        #expect(host.transport == .local)
        #expect(host.serverSocketPath == socket.canonicalPath)
        let viaSymlink = try #require(TerminalController.remoteTmuxHost(
            from: ["transport": "local", "socket_path": socket.canonicalPath]
        ))
        #expect(viaSymlink.connectionHash == host.connectionHash)
        #expect(TerminalController.remoteTmuxBrokerFailureMessage(
            from: ["transport": "local", "socket_path": socket.path]
        ) == nil)
    }

    @Test(arguments: TerminalController.remoteTmuxLocalRefusedParameters)
    func boundaryRefusesRemoteOnlyParameters(name: String) throws {
        let socket = try TemporarySocket()
        defer { socket.cleanUp() }
        let params: [String: Any] = ["transport": "local", "socket_path": socket.path, name: "x"]

        #expect(TerminalController.remoteTmuxHost(from: params) == nil)
        let message = try #require(TerminalController.remoteTmuxBrokerFailureMessage(from: params))
        #expect(message.contains(name))
    }

    @Test func boundaryRefusesBadSocketPaths() throws {
        let socket = try TemporarySocket()
        defer { socket.cleanUp() }
        let regularFile = socket.directory + "/regular"
        FileManager.default.createFile(atPath: regularFile, contents: Data())

        let cases: [(String?, RemoteTmuxLocalServerSocket.Refusal)] = [
            (nil, .socketPathRequired),
            ("relative/sock", .notAbsolute),
            ("/tmp/with\u{7}bell", .hiddenCharacter),
            ("/tmp/with\u{200b}zero-width", .hiddenCharacter),
            (socket.directory + "/absent", .missing(path: socket.directory + "/absent")),
            (regularFile, .notASocket(path: try Self.canonical(regularFile))),
        ]
        for (path, expected) in cases {
            var params: [String: Any] = ["transport": "local"]
            if let path { params["socket_path"] = path }
            #expect(TerminalController.remoteTmuxHost(from: params) == nil, "\(String(describing: path))")
            let result = TerminalController.remoteTmuxLocalHostResult(from: params)
            #expect(result.failure == expected, "\(String(describing: path))")
            let message = TerminalController.remoteTmuxBrokerFailureMessage(from: params) ?? ""
            #expect(!message.isEmpty)
            #expect(!message.lowercased().contains("ssh"))
        }
    }

    @Test func boundaryRefusesASocketOwnedByAnotherUser() throws {
        let socket = try TemporarySocket()
        defer { socket.cleanUp() }
        let result = TerminalController.remoteTmuxLocalHostResult(
            from: ["transport": "local", "socket_path": socket.path],
            userID: getuid() &+ 1
        )
        #expect(result.failure == .notOwnedByUser(path: socket.canonicalPath))
    }

    /// Another local user who can write to the socket's directory can rename their own server's
    /// socket into place between the check and tmux's connect, and the mirror would then type
    /// into their shell. Only the user's own directory, or a root-owned sticky one, is safe.
    @Test func boundaryRefusesASocketInADirectoryOthersCanWrite() throws {
        let socket = try TemporarySocket()
        defer { socket.cleanUp() }
        try #require(chmod(socket.directory, 0o777) == 0)

        let result = TerminalController.remoteTmuxLocalHostResult(
            from: ["transport": "local", "socket_path": socket.path]
        )
        #expect(result.failure != nil, "a socket in a world-writable, non-sticky directory must be refused")
        #expect(TerminalController.remoteTmuxHost(from: ["transport": "local", "socket_path": socket.path]) == nil)
    }

    /// Failures for a local mirror name this Mac, not a remote host called "local".
    @Test func localWordingNeverNamesARemoteHost() {
        let host = RemoteTmuxHost.local(serverSocketPath: "/tmp/cmux-lt-absent/default")
        #expect(host.destination != "local")
        let unknown = TerminalController.remoteTmuxBrokerFailureMessage(from: ["transport": "bogus"]) ?? ""
        #expect(unknown.contains("local"), "the unknown-transport message lists local among the choices")
    }

    @Test func boundaryRefusesASymlinkToSomethingThatIsNotASocket() throws {
        let socket = try TemporarySocket()
        defer { socket.cleanUp() }
        let target = socket.directory + "/target"
        FileManager.default.createFile(atPath: target, contents: Data())
        let link = socket.directory + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let result = TerminalController.remoteTmuxLocalHostResult(
            from: ["transport": "local", "socket_path": link]
        )
        #expect(result.failure == .notASocket(path: try Self.canonical(target)))
    }

    // MARK: - Helpers

    private static func canonical(_ path: String) throws -> String {
        let resolved = try #require(realpath(path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A bound Unix socket in a short directory under `/tmp`, short enough for `sun_path`.
    private struct TemporarySocket {
        let directory: String
        let path: String
        let canonicalPath: String
        private let descriptor: Int32

        init() throws {
            let directory = "/tmp/cmux-lt-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = directory + "/sock"
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(descriptor >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0, "bind failed: errno \(errno)")
            self.directory = directory
            self.path = path
            self.descriptor = descriptor
            canonicalPath = try RemoteTmuxLocalTransportProfileTests.canonical(path)
        }

        func cleanUp() {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// A fake `/bin/sh` stand-in with a fixed body; `$2` is the resolver command it was handed.
    private struct FakeShell {
        let root: URL
        let path: String

        init(body: String) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-local-fake-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("sh")
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            path = url.path
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A fake binary that appends each invocation's argv to a log and exits 0 with no output.
    private struct ArgvRecorder {
        let root: URL
        let executablePath: String
        private let logPath: String

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-local-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            logPath = root.appendingPathComponent("argv.log").path
            let script = """
            #!/bin/sh
            LOG='\(logPath)'
            if [ "$#" -gt 0 ]; then printf '%s\\0' "$@" >> "$LOG"; fi
            printf '\\036' >> "$LOG"
            exit 0
            """
            let url = root.appendingPathComponent("recorder")
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            executablePath = url.path
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

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
