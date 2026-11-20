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

    private func makeFakeSSH(openSucceeds: Bool) throws -> FakeSSH {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-tmux-renew-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("log")
        let marker = root.appendingPathComponent("master")
        let executable = root.appendingPathComponent("ssh")
        let open = openSucceeds ? "touch '\(marker.path)'; exit 0" : "exit 255"
        try """
        #!/bin/sh
        case " $* " in
          *" -O exit "*) echo exit >> '\(log.path)'; rm -f '\(marker.path)'; exit 0 ;;
          *" -O check "*) echo check >> '\(log.path)'; [ -f '\(marker.path)' ] && exit 0; exit 255 ;;
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

        #expect(renewed)
        #expect(ssh.calls() == ["exit", "check", "open", "check"])
    }

    // Adversarial: a fresh master that cannot be opened reports failure instead of claiming the
    // stale one is still usable.
    @Test(.timeLimit(.minutes(1)))
    func aMasterThatCannotBeReopenedReportsFailure() async throws {
        let ssh = try makeFakeSSH(openSucceeds: false)
        defer { ssh.remove() }

        let renewed = await transport(ssh).renewSharedMaster()

        #expect(renewed == false)
        #expect(ssh.calls() == ["exit", "check", "open", "check"])
    }
}
