import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The control connection's side of wake recovery: the check command, holding a stream, and
/// releasing it, run against fake transport clients that reach control mode and then either
/// answer every command or stay silent, the way a stream over a dead connection does.
@MainActor
@Suite(.serialized) struct RemoteTmuxConnectionWakeRecoveryTests {
    private struct FakeClientProfile: RemoteTmuxTransportProfile {
        let executable: String
        func executablePath() -> String { executable }
        func controlStreamArgv(host: RemoteTmuxHost, sessionName: String, mode: RemoteTmuxControlAttachMode) -> [String] { [] }
        func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] { [] }
        var requiresPseudoTerminal: Bool { false }
        var remoteHalfSurvivesLocalExit: Bool { false }
        var wakeRecovery: RemoteTmuxWakeRecovery { .checkThenRenewSharedConnection }
    }

    private enum ClientBehavior {
        /// Reaches control mode and answers every command with an empty reply.
        case answers
        /// Reaches control mode and then never answers.
        case silent
        /// Never reaches control mode.
        case neverEnters
    }

    private struct FakeClient {
        let root: URL
        let script: URL
        let launches: URL

        func launchCount() -> Int {
            ((try? String(contentsOf: launches, encoding: .utf8)) ?? "")
                .split(separator: "\n").count
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeClient(_ behavior: ClientBehavior) throws -> FakeClient {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-tmux-wake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let launches = root.appendingPathComponent("launches")
        let script = root.appendingPathComponent("client")
        let body: String
        switch behavior {
        case .answers:
            body = """
            printf '\\033P1000p%%begin 1 1 0\\n%%end 1 1 0\\n'
            i=2
            while IFS= read -r line; do
              printf '%%begin 1 %d 0\\n%%end 1 %d 0\\n' "$i" "$i"
              i=$((i + 1))
            done
            """
        case .silent:
            body = """
            printf '\\033P1000p%%begin 1 1 0\\n%%end 1 1 0\\n'
            sleep 60 &
            wait $!
            """
        case .neverEnters:
            body = """
            sleep 60 &
            wait $!
            """
        }
        try """
        #!/bin/sh
        echo launch >> '\(launches.path)'
        \(body)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return FakeClient(root: root, script: script, launches: launches)
    }

    private func makeConnection(_ client: FakeClient) -> RemoteTmuxControlConnection {
        RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "wake-\(UUID().uuidString)@example.test"),
            sessionName: "dev",
            transportProfile: FakeClientProfile(executable: client.script.path)
        )
    }

    /// Starts a connection and returns once its attach result has been consumed. The check is the
    /// barrier: its reply can only arrive after the attach block.
    private func connectedAndDrained(_ client: FakeClient) async throws -> RemoteTmuxControlConnection {
        let connection = makeConnection(client)
        try connection.start()
        try #require(await connection.waitUntilConnected())
        try #require(await connection.answersWakeCheck(timeoutSeconds: 10))
        try #require(connection.wakeStreamPhase == .connected)
        return connection
    }

    @Test(.timeLimit(.minutes(1)))
    func aStreamThatAnswersPassesTheCheck() async throws {
        let client = try makeClient(.answers)
        defer { client.remove() }
        let connection = makeConnection(client)
        defer { connection.stop() }
        try connection.start()
        try #require(await connection.waitUntilConnected())

        #expect(await connection.answersWakeCheck(timeoutSeconds: 10))
        #expect(connection.wakeStreamPhase == .connected)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSilentStreamFailsTheCheckWithoutReconnectingByItself() async throws {
        let client = try makeClient(.silent)
        defer { client.remove() }
        let connection = makeConnection(client)
        defer { connection.stop() }
        try connection.start()
        try #require(await connection.waitUntilConnected())

        #expect(await connection.answersWakeCheck(timeoutSeconds: 0.5) == false)
        // The check only reports; holding and reconnecting are the coordinator's decision.
        #expect(connection.connectionState == .connected)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHeldStreamReconnectsOnceWhenReleased() async throws {
        let client = try makeClient(.answers)
        defer { client.remove() }
        let connection = try await connectedAndDrained(client)
        defer { connection.stop() }

        #expect(connection.holdReconnectForWake())
        #expect(connection.wakeStreamPhase == .heldForWake)

        connection.resumeReconnectAfterWake()
        #expect(connection.wakeStreamPhase == .retryInFlight)
        #expect(await connection.waitUntilConnected())
        #expect(client.launchCount() == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondReleaseStartsNothing() async throws {
        let client = try makeClient(.answers)
        defer { client.remove() }
        let connection = try await connectedAndDrained(client)
        defer { connection.stop() }
        #expect(connection.holdReconnectForWake())

        connection.resumeReconnectAfterWake()
        let generation = connection.processGeneration
        connection.resumeReconnectAfterWake()

        #expect(connection.processGeneration == generation)
        #expect(connection.wakeStreamPhase == .retryInFlight)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStreamWaitingBetweenAttemptsRetriesAtOnce() async throws {
        let client = try makeClient(.answers)
        defer { client.remove() }
        let connection = try await connectedAndDrained(client)
        defer { connection.stop() }

        connection.beginReconnecting()
        #expect(connection.wakeStreamPhase == .waitingToRetry)

        connection.retryReconnectNow()
        #expect(connection.wakeStreamPhase == .retryInFlight)
        #expect(await connection.waitUntilConnected())
    }

    @Test(.timeLimit(.minutes(1)))
    func aStreamStillAttachingIsNotHeld() async throws {
        let client = try makeClient(.neverEnters)
        defer { client.remove() }
        let connection = makeConnection(client)
        defer { connection.stop() }
        try connection.start()

        #expect(connection.wakeStreamPhase == .attaching)
        #expect(connection.holdReconnectForWake() == false)
        #expect(connection.wakeStreamPhase == .attaching)
    }

    // Adversarial: a stream stopped while held (its mirror was closed during the wait for the
    // unlock) must not be restarted by the release.
    @Test(.timeLimit(.minutes(1)))
    func aHeldStreamThatIsStoppedIsNotRestarted() async throws {
        let client = try makeClient(.answers)
        defer { client.remove() }
        let connection = try await connectedAndDrained(client)
        #expect(connection.holdReconnectForWake())

        connection.stop()
        let generation = connection.processGeneration
        connection.resumeReconnectAfterWake()

        #expect(connection.wakeStreamPhase == .ended)
        #expect(connection.processGeneration == generation)
        #expect(client.launchCount() == 1)
    }

    // Adversarial: a retry request for a stream that is not waiting between attempts changes nothing.
    @Test(.timeLimit(.minutes(1)))
    func aRetryRequestForAConnectedStreamChangesNothing() async throws {
        let client = try makeClient(.answers)
        defer { client.remove() }
        let connection = try await connectedAndDrained(client)
        defer { connection.stop() }
        let generation = connection.processGeneration

        connection.retryReconnectNow()

        #expect(connection.processGeneration == generation)
        #expect(connection.wakeStreamPhase == .connected)
    }

    // The controller groups every live stream by host, once each, with the host transport's wake
    // behavior: ssh renews its shared connection, et keeps its own recovery.
    @Test func streamsAreGroupedByHostWithTheirTransportsWakeBehavior() {
        let sshHost = RemoteTmuxHost(destination: "user@group.wake.test")
        let etHost = RemoteTmuxHost(destination: "user@group.wake.test", transport: .et)
        let first = RemoteTmuxControlConnection(host: sshHost, sessionName: "one")
        let second = RemoteTmuxControlConnection(host: sshHost, sessionName: "two")
        let viaET = RemoteTmuxControlConnection(host: etHost, sessionName: "three")

        let groups = RemoteTmuxController.wakeHostGroups(for: [first, viaET, second, first])

        #expect(groups.count == 2)
        #expect(groups.first?.recovery == .checkThenRenewSharedConnection)
        #expect(groups.first?.streams.map { ObjectIdentifier($0) } == [ObjectIdentifier(first), ObjectIdentifier(second)])
        #expect(groups.last?.recovery == .retryWaitingAttemptsNow)
        #expect(groups.last?.streams.map { ObjectIdentifier($0) } == [ObjectIdentifier(viaET)])
    }
}
