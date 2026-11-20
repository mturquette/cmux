import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What the mirror does with its streams when the Mac wakes (requirements R1, R3, R4, R6 to R9
/// and the owner's decisions Q-H1, Q-H2 and Q-H4 in the wake-reconnect brief), driven through
/// the coordinator with fake streams and a fake environment so the order of every step is visible.
@MainActor
@Suite struct RemoteTmuxWakeRecoveryCoordinatorTests {
    @MainActor
    final class EventLog {
        var events: [String] = []
        func append(_ event: String) { events.append(event) }
    }

    @MainActor
    final class FakeStream: RemoteTmuxWakeRecoverableStream {
        let name: String
        var phase: RemoteTmuxWakeStreamPhase
        let answers: Bool
        let log: EventLog
        var checkTimeouts: [Double] = []

        init(_ name: String, _ phase: RemoteTmuxWakeStreamPhase, answers: Bool = true, log: EventLog) {
            self.name = name
            self.phase = phase
            self.answers = answers
            self.log = log
        }

        var wakeStreamPhase: RemoteTmuxWakeStreamPhase { phase }

        func answersWakeCheck(timeoutSeconds: Double) async -> Bool {
            checkTimeouts.append(timeoutSeconds)
            log.append("check \(name)")
            return answers
        }

        func holdReconnectForWake() -> Bool {
            switch phase {
            case .connected, .waitingToRetry, .retryInFlight:
                phase = .heldForWake
                log.append("hold \(name)")
                return true
            case .attaching, .waitingForLogin, .heldForWake, .ended:
                return false
            }
        }

        func resumeReconnectAfterWake() {
            guard phase == .heldForWake else { return }
            phase = .retryInFlight
            log.append("resume \(name)")
        }

        func retryReconnectNow() {
            guard phase == .waitingToRetry else { return }
            phase = .retryInFlight
            log.append("retry \(name)")
        }
    }

    @MainActor
    final class FakeEnvironment: RemoteTmuxWakeRecoveryEnvironment {
        let log: EventLog
        var renewResult = true
        /// When set, the unlock wait lasts until the test yields into it.
        var unlockGate: AsyncStream<Void>?
        let reachedUnlockWait: AsyncStream<Void>
        private let reachedUnlockWaitContinuation: AsyncStream<Void>.Continuation

        init(log: EventLog) {
            self.log = log
            (reachedUnlockWait, reachedUnlockWaitContinuation) = AsyncStream<Void>.makeStream()
        }

        func waitForScreenUnlock() async {
            log.append("unlock-wait")
            reachedUnlockWaitContinuation.yield()
            if let unlockGate {
                for await _ in unlockGate { break }
            }
            log.append("unlocked")
        }

        func renewSharedConnection(for host: RemoteTmuxHost) async -> Bool {
            log.append("renew \(host.destination)")
            return renewResult
        }
    }

    private static let hostA = RemoteTmuxHost(destination: "user@a.wake.test")
    private static let hostB = RemoteTmuxHost(destination: "user@b.wake.test")

    private func group(
        _ host: RemoteTmuxHost = hostA,
        _ recovery: RemoteTmuxWakeRecovery = .checkThenRenewSharedConnection,
        _ streams: [FakeStream]
    ) -> RemoteTmuxWakeHostGroup {
        RemoteTmuxWakeHostGroup(host: host, recovery: recovery, streams: streams)
    }

    private func recoverAndWait(
        _ coordinator: RemoteTmuxWakeRecoveryCoordinator,
        _ groups: [RemoteTmuxWakeHostGroup]
    ) async -> Int {
        let started = coordinator.recover(groups)
        for task in started { await task.value }
        return started.count
    }

    // R1, R4: silent streams are held, the host's shared connection is renewed once after the
    // screen is unlocked, and only then are the streams released.
    @Test func silentStreamsAreHeldAndReleasedAfterOneRenewal() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment, checkTimeoutSeconds: 5)
        let streams = (1...3).map { FakeStream("s\($0)", .connected, answers: false, log: log) }

        let started = await recoverAndWait(coordinator, [group(streams)])

        #expect(started == 1)
        #expect(log.events == [
            "check s1",
            "hold s1", "hold s2", "hold s3",
            "unlock-wait", "unlocked",
            "renew user@a.wake.test",
            "resume s1", "resume s2", "resume s3",
        ])
        #expect(streams[0].checkTimeouts == [5])
    }

    // R3: streams that answer are left exactly as they are.
    @Test func answeringStreamsAreLeftAlone() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let streams = [FakeStream("s1", .connected, log: log), FakeStream("s2", .connected, log: log)]

        _ = await recoverAndWait(coordinator, [group(streams)])

        #expect(log.events == ["check s1", "check s2"])
        #expect(streams.allSatisfy { $0.phase == .connected })
    }

    // R7: a stream already reconnecting needs no check; the host is renewed and every stream on
    // it is held, since closing the shared connection ends them all.
    @Test func aStreamAlreadyReconnectingRenewsTheHostWithoutChecks() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let streams = [
            FakeStream("s1", .waitingToRetry, log: log),
            FakeStream("s2", .connected, log: log),
        ]

        _ = await recoverAndWait(coordinator, [group(streams)])

        #expect(log.events == [
            "hold s1", "hold s2", "unlock-wait", "unlocked",
            "renew user@a.wake.test", "resume s1", "resume s2",
        ])
    }

    // R8: a stream waiting for the user's login is neither held nor retried.
    @Test func aStreamWaitingForLoginIsNotRetried() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let parked = FakeStream("parked", .waitingForLogin, log: log)
        let silent = FakeStream("silent", .connected, answers: false, log: log)

        _ = await recoverAndWait(coordinator, [group([parked, silent])])

        #expect(parked.phase == .waitingForLogin)
        #expect(!log.events.contains { $0.hasSuffix(" parked") })
        #expect(log.events.contains("resume silent"))
    }

    // Q-H2: nothing authenticates until the screen is unlocked.
    @Test(.timeLimit(.minutes(1)))
    func renewalWaitsForTheScreenToBeUnlocked() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        let (gate, unlock) = AsyncStream<Void>.makeStream()
        environment.unlockGate = gate
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let stream = FakeStream("s1", .connected, answers: false, log: log)

        let started = coordinator.recover([group([stream])])
        for await _ in environment.reachedUnlockWait { break }

        #expect(stream.phase == .heldForWake)
        #expect(!log.events.contains { $0.hasPrefix("renew") })

        unlock.yield()
        for task in started { await task.value }
        #expect(log.events.suffix(3) == ["unlocked", "renew user@a.wake.test", "resume s1"])
    }

    // R6: a second wake while a host is still recovering starts nothing more for that host, and
    // once the first recovery is finished the next wake is handled again.
    @Test(.timeLimit(.minutes(1)))
    func aSecondWakeDuringRecoveryStartsNothingForThatHost() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        let (gate, unlock) = AsyncStream<Void>.makeStream()
        environment.unlockGate = gate
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let stream = FakeStream("s1", .connected, answers: false, log: log)

        let first = coordinator.recover([group([stream])])
        for await _ in environment.reachedUnlockWait { break }
        let second = coordinator.recover([group([stream])])
        #expect(first.count == 1)
        #expect(second.isEmpty)

        unlock.yield()
        for task in first { await task.value }
        #expect(log.events.filter { $0.hasPrefix("renew") }.count == 1)

        environment.unlockGate = nil
        let third = await recoverAndWait(coordinator, [group([FakeStream("s2", .connected, log: log)])])
        #expect(third == 1)
    }

    // R9: a transport that declares no wake behavior (the local transport) is left alone.
    @Test func aTransportWithNoWakeBehaviorIsLeftAlone() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let streams = [
            FakeStream("s1", .connected, answers: false, log: log),
            FakeStream("s2", .waitingToRetry, log: log),
        ]

        _ = await recoverAndWait(coordinator, [group(hostA, .nothing, streams)])

        #expect(log.events.isEmpty)
    }

    // R9, Q-H4: et keeps its own recovery; only a stream waiting between cmux's attempts is
    // retried now, and nothing is checked, held, or renewed.
    @Test func etRetriesOnlyStreamsWaitingBetweenAttempts() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let waiting = FakeStream("waiting", .waitingToRetry, log: log)
        let inFlight = FakeStream("inflight", .retryInFlight, log: log)
        let connected = FakeStream("connected", .connected, answers: false, log: log)

        _ = await recoverAndWait(coordinator, [group(hostA, .retryWaitingAttemptsNow, [waiting, inFlight, connected])])

        #expect(log.events == ["retry waiting"])
        #expect(connected.phase == .connected)
    }

    // Adversarial: one silent stream is enough to renew the host, and the streams that answered
    // are held too, because closing the shared connection ends them as well.
    @Test func oneSilentStreamRenewsTheWholeHost() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let streams = [
            FakeStream("s1", .connected, log: log),
            FakeStream("s2", .connected, answers: false, log: log),
            FakeStream("s3", .connected, log: log),
        ]

        _ = await recoverAndWait(coordinator, [group(streams)])

        #expect(log.events == [
            "check s1", "check s2",
            "hold s1", "hold s2", "hold s3",
            "unlock-wait", "unlocked", "renew user@a.wake.test",
            "resume s1", "resume s2", "resume s3",
        ])
    }

    // Adversarial: a stream still attaching is not held, checked, or released.
    @Test func anAttachingStreamIsLeftToItsAttach() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let attaching = FakeStream("attaching", .attaching, log: log)
        let silent = FakeStream("silent", .connected, answers: false, log: log)

        _ = await recoverAndWait(coordinator, [group([attaching, silent])])

        #expect(attaching.phase == .attaching)
        #expect(!log.events.contains { $0.hasSuffix(" attaching") })
    }

    // Adversarial: a renewal that fails still releases the streams, so none is left frozen.
    @Test func streamsAreReleasedWhenRenewalFails() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        environment.renewResult = false
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let streams = [
            FakeStream("s1", .connected, answers: false, log: log),
            FakeStream("s2", .retryInFlight, log: log),
        ]

        _ = await recoverAndWait(coordinator, [group(streams)])

        #expect(streams.allSatisfy { $0.phase == .retryInFlight })
        #expect(log.events.suffix(2) == ["resume s1", "resume s2"])
    }

    // Adversarial: hosts recover independently; a healthy host is not renewed because another is dead.
    @Test func eachHostRecoversOnItsOwn() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let dead = FakeStream("dead", .connected, answers: false, log: log)
        let healthy = FakeStream("healthy", .connected, log: log)

        let started = await recoverAndWait(coordinator, [group(hostA, .checkThenRenewSharedConnection, [dead]),
                                                         group(hostB, .checkThenRenewSharedConnection, [healthy])])

        #expect(started == 2)
        #expect(log.events.filter { $0.hasPrefix("renew") } == ["renew user@a.wake.test"])
        #expect(healthy.phase == .connected)
    }
}
