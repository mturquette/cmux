import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// One-shot commands (discovery and mutations) are built by the host's transport profile rather
/// than by ``RemoteTmuxSSHTransport`` itself.
///
/// The first half pins the refactor to no behavior change: for ssh and et hosts, the argv a fake
/// `ssh` actually receives is the exact command line the transport built by hand before the
/// profile owned it. The second half drives the new seam with a profile that has no shared
/// ControlMaster, which is what a transport that never goes through ssh needs.
@Suite struct RemoteTmuxOneShotProfileRoutingTests {
    static let hosts: [RemoteTmuxHost] = [
        RemoteTmuxHost(destination: "user@host"),
        RemoteTmuxHost(destination: "-oProxyCommand=evil", port: 2222, identityFile: "/tmp/id key"),
        RemoteTmuxHost(destination: "box", transport: .et),
        RemoteTmuxHost(destination: "box", port: 2200, transport: .et, transportPort: 4022),
    ]

    @Test(arguments: hosts)
    func tmuxOneShotArgvIsUnchangedForSharedMasterTransports(host: RemoteTmuxHost) async throws {
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let transport = RemoteTmuxSSHTransport(host: host, sshExecutablePath: recorder.executablePath)
        let tmuxArgs = ["list-sessions", "-F", RemoteTmuxSessionListParser.formatString]

        let result = try await transport.runTmux(tmuxArgs)

        #expect(result.succeeded)
        // The pre-refactor shape, spelled out: shared-master options, `--`, the destination, then
        // the tmux resolver command as a single argument.
        let expected = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
            + ["--", host.destination, RemoteTmuxHost.tmuxRemoteCommand(arguments: tmuxArgs)]
        #expect(recorder.invocations() == [expected])
    }

    @Test(arguments: hosts)
    func plainOneShotArgvIsUnchangedForSharedMasterTransports(host: RemoteTmuxHost) async throws {
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let transport = RemoteTmuxSSHTransport(host: host, sshExecutablePath: recorder.executablePath)

        _ = try await transport.run(["printf", "%s", "a b"])

        let expected = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
            + ["--", host.destination, "'printf' '%s' 'a b'"]
        #expect(recorder.invocations() == [expected])
    }

    @Test(arguments: hosts)
    func sshAndETProfilesKeepTheSharedMasterAndSSHForOneShots(host: RemoteTmuxHost) {
        let profile = host.transportProfile
        #expect(profile.usesSharedControlMaster)
        #expect(profile.oneShotExecutablePath() == RemoteTmuxHost.defaultSSHExecutablePath())
    }

    @Test func oneShotsUseTheProfilesExecutableAndArgvWhenNoSSHIsInjected() async throws {
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let host = RemoteTmuxHost(destination: "unused")
        let profile = NoMasterProfile(oneShotExecutable: recorder.executablePath)
        let transport = RemoteTmuxSSHTransport(host: host, transportProfile: profile)

        _ = try await transport.runTmux(["-V"])

        let command = RemoteTmuxHost.tmuxRemoteCommand(arguments: ["-V"])
        #expect(recorder.invocations() == [["-c", command]])
    }

    @Test func aTransportWithoutASharedMasterIsReadyWithoutSpawningAnything() async throws {
        let recorder = try ArgvRecorder()
        defer { recorder.cleanUp() }
        let host = RemoteTmuxHost(destination: "unused")
        let transport = RemoteTmuxSSHTransport(
            host: host,
            sshExecutablePath: recorder.executablePath,
            transportProfile: NoMasterProfile(oneShotExecutable: recorder.executablePath)
        )

        #expect(try await transport.ensureMasterReady())
        #expect(await transport.isMasterLive())
        await transport.shutdownMaster()

        // Every master step would have spawned the injected binary: the readiness probe and the
        // exit run `ssh -O`, and a cold warmup runs `true` through it. None of them may run.
        #expect(recorder.invocations().isEmpty)
    }

    // MARK: - Helpers

    /// A profile with no shared master, which runs one-shots as `<binary> -c <command>`.
    private struct NoMasterProfile: RemoteTmuxTransportProfile {
        let oneShotExecutable: String

        func executablePath() -> String { oneShotExecutable }
        func controlStreamArgv(
            host: RemoteTmuxHost, sessionName: String, mode: RemoteTmuxControlAttachMode
        ) -> [String] { [] }
        func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] { ["-c", remoteCommand] }
        func oneShotExecutablePath() -> String { oneShotExecutable }
        var usesSharedControlMaster: Bool { false }
        var requiresPseudoTerminal: Bool { false }
        var remoteHalfSurvivesLocalExit: Bool { false }
        var authenticationIsSSHShaped: Bool { false }
    }

    /// A fake binary that appends each invocation's argv to a log and exits 0 with no output.
    ///
    /// Arguments are NUL-terminated and invocations end with a record separator, so arguments
    /// containing spaces, quotes or newlines (the tmux resolver has all three) round-trip exactly.
    private struct ArgvRecorder {
        let root: URL
        let executablePath: String
        private let logPath: String

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-one-shot-\(UUID().uuidString)", isDirectory: true)
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
