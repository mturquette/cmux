import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Renewing a host's shared ssh connection after wake (requirement R4 in the wake-reconnect
/// brief): the old master is closed before a fresh one is opened, so every stream reconnects
/// over one new connection and the user authenticates once. Run against a fake `ssh` that keeps
/// a marker file for "a master is running" and logs each call.
@Suite(.serialized) struct RemoteTmuxSSHTransportWakeRenewalTests {
    private struct FakeSSH {
        let root: URL
        let executable: URL
        let log: URL
        let marker: URL

        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// - Parameter holdFirstCheck: when true, the first `-O check` reads the master's state, logs
    ///   it, and then does not return until the test creates the `release` file, so a warm-up can be
    ///   caught after it has seen the old master but before it reports.
    /// - Parameter openStderr: what a failed open prints on stderr, as ssh would. No single quotes.
    private func makeFakeSSH(
        openSucceeds: Bool, holdFirstCheck: Bool = false, openStderr: String = ""
    ) throws -> FakeSSH {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-tmux-renew-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("log")
        let marker = root.appendingPathComponent("master")
        let release = root.appendingPathComponent("release")
        let firstDone = root.appendingPathComponent("first-check-done")
        let executable = root.appendingPathComponent("ssh")
        let open = openSucceeds
            ? "touch '\(marker.path)'; exit 0"
            : "printf '%s\\n' '\(openStderr)' >&2; exit 255"
        if !holdFirstCheck { FileManager.default.createFile(atPath: release.path, contents: Data()) }
        try """
        #!/bin/sh
        case " $* " in
          *" -O exit "*) echo exit >> '\(log.path)'; rm -f '\(marker.path)'; exit 0 ;;
          *" -O check "*)
            if [ -f '\(marker.path)' ]; then r=0; else r=255; fi
            echo check >> '\(log.path)'
            if [ ! -f '\(firstDone.path)' ]; then
              touch '\(firstDone.path)'
              while [ ! -f '\(release.path)' ]; do sleep 0.05; done
            fi
            exit $r ;;
          *) echo open >> '\(log.path)'; \(open) ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        // A master from before sleep: its process still answers `-O check`, but its TCP is dead.
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        return FakeSSH(root: root, executable: executable, log: log, marker: marker)
    }

    private func transport(_ ssh: FakeSSH) -> RemoteTmuxSSHTransport {
        RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "renew-\(UUID().uuidString)@example.test"),
            sshExecutablePath: ssh.executable.path
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func theOldMasterIsClosedBeforeOneFreshMasterIsOpened() async throws {
        let ssh = try makeFakeSSH(openSucceeds: true)
        defer { ssh.remove() }

        let renewed = await transport(ssh).renewSharedMaster()

        #expect(renewed == .renewed)
        #expect(ssh.calls() == ["exit", "check", "open", "check"])
    }

    // Adversarial: a fresh master that cannot be opened reports failure instead of claiming the
    // stale one is still usable. With nothing on stderr to say the host is unreachable, the
    // failure is not one a retry can fix (review F5).
    @Test(.timeLimit(.minutes(1)))
    func aMasterThatCannotBeReopenedReportsFailure() async throws {
        let ssh = try makeFakeSSH(openSucceeds: false)
        defer { ssh.remove() }

        let renewed = await transport(ssh).renewSharedMaster()

        #expect(renewed == .failed)
        #expect(ssh.calls() == ["exit", "check", "open", "check"])
    }

    // Review F5: only a network failure counts as an unreachable host, which is the one case
    // wake recovery retries.
    @Test(.timeLimit(.minutes(1)), arguments: [
        "ssh: connect to host petit port 22: Operation timed out",
        "ssh: connect to host petit port 22: Connection refused",
        "ssh: connect to host petit port 22: No route to host",
        "ssh: connect to host petit port 22: Network is unreachable",
        "ssh: Could not resolve hostname petit: nodename nor servname provided, or not known",
    ])
    func aNetworkFailureReportsAnUnreachableHost(stderr: String) async throws {
        let ssh = try makeFakeSSH(openSucceeds: false, openStderr: stderr)
        defer { ssh.remove() }

        #expect(await transport(ssh).renewSharedMaster() == .hostUnreachable)
    }

    // Review F5: a host that needs the user (a password or MFA, a dismissed Touch ID prompt, a
    // changed host key) or a failure no retry fixes is reported as a failure, never as unreachable.
    @Test(.timeLimit(.minutes(1)), arguments: [
        "user@petit: Permission denied (publickey,keyboard-interactive).",
        "sign_and_send_pubkey: signing failed for ED25519 from agent: agent refused operation\nuser@petit: Permission denied (publickey).",
        "Host key verification failed.",
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!",
        "kex_exchange_identification: Connection closed by remote host\nConnection closed by UNKNOWN port 65535",
    ])
    func aFailureThatNeedsTheUserIsNotReportedAsUnreachable(stderr: String) async throws {
        let ssh = try makeFakeSSH(openSucceeds: false, openStderr: stderr)
        defer { ssh.remove() }

        #expect(await transport(ssh).renewSharedMaster() == .failed)
    }

    // Review F3: a renewal that starts while another caller's warm-up is in flight, after that
    // warm-up has already seen the old master answer, must not report the old master's result.
    // It closes the old master and then confirms a fresh one of its own.
    @Test(.timeLimit(.minutes(1)))
    func aRenewalDoesNotJoinAWarmUpThatSawTheOldMaster() async throws {
        let ssh = try makeFakeSSH(openSucceeds: true, holdFirstCheck: true)
        defer { ssh.remove() }
        let transport = transport(ssh)

        let earlier = Task { try await transport.ensureMasterReady() }
        try await waitUntil { ssh.calls().contains("check") }
        let renewal = Task { await transport.renewSharedMaster() }
        // A renewal that joins the earlier warm-up closes the master at once; give it the chance
        // to, then let the earlier warm-up report what it saw.
        try? await waitUntil(limitSeconds: 2) { ssh.calls().contains("exit") }
        FileManager.default.createFile(atPath: ssh.root.appendingPathComponent("release").path, contents: Data())

        _ = try await earlier.value
        let renewed = await renewal.value

        #expect(renewed == .renewed)
        #expect(FileManager.default.fileExists(atPath: ssh.marker.path))
        #expect(Array(ssh.calls().drop { $0 != "exit" }) == ["exit", "check", "open", "check"])
    }

    private struct WaitTimedOut: Error {}

    /// Polls a condition on the fake's log file until it holds or `limitSeconds` pass. The fake is
    /// a separate process that reports only through files, so there is no event to await.
    private func waitUntil(limitSeconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(limitSeconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
    }
}
