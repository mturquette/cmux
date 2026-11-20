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

        /// What this stream's reconnect leads to when a test waits on it.
        var reconnectOutcome: RemoteTmuxWakeStreamPhase = .connected

        func waitForReconnectOutcome() async -> RemoteTmuxWakeStreamPhase {
            phase = reconnectOutcome
            log.append("outcome \(name) \(reconnectOutcome)")
            return reconnectOutcome
        }

        func handOverHeldStreamToLogin() {
            guard phase == .heldForWake else { return }
            phase = .waitingForLogin
            log.append("to-login \(name)")
        }
    }

    @MainActor
    final class FakeEnvironment: RemoteTmuxWakeRecoveryEnvironment {
        let log: EventLog
        var renewResult: RemoteTmuxWakeRenewalResult = .renewed
        /// When non-empty, each renewal takes the next result from here instead of `renewResult`.
        var renewResults: [RemoteTmuxWakeRenewalResult] = []
        /// Runs during each wait between renewal attempts, so a test can change the streams then.
        var duringRenewalWait: ((Int) -> Void)?
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

        func renewSharedConnection(for host: RemoteTmuxHost) async -> RemoteTmuxWakeRenewalResult {
            log.append("renew \(host.destination)")
            return renewResults.isEmpty ? renewResult : renewResults.removeFirst()
        }

        func waitBeforeRenewalRetry(attempt: Int) async {
            log.append("renew-wait \(attempt)")
            duringRenewalWait?(attempt)
        }
    }

    private static let hostA = RemoteTmuxHost(destination: "user@a.wake.test")
    private static let hostB = RemoteTmuxHost(destination: "user@b.wake.test")

    private func hostGroup(
        _ host: RemoteTmuxHost = Self.hostA,
        _ recovery: RemoteTmuxWakeRecovery = .checkThenRenewSharedConnection,
        _ streams: [FakeStream]
    ) -> RemoteTmuxWakeHostGroup {
        RemoteTmuxWakeHostGroup(host: host, recovery: recovery, streams: streams)
    }

    private func hostGroup(_ streams: [FakeStream]) -> RemoteTmuxWakeHostGroup {
        hostGroup(Self.hostA, .checkThenRenewSharedConnection, streams)
    }

    /// A failure that should not be retried must never reach the retry wait. If it does, the
    /// streams are ended there, so the loop stops and the test fails on its events instead of
    /// spinning forever.
    private func endStreamsIfTheRenewalIsRetried(_ environment: FakeEnvironment, _ streams: [FakeStream]) {
        environment.duringRenewalWait = { _ in
            for stream in streams { stream.phase = .ended }
        }
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

        let started = await recoverAndWait(coordinator, [hostGroup(streams)])

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

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(log.events == ["check s1", "check s2"])
        #expect(streams.allSatisfy { $0.phase == .connected })
    }

    // R3, R7, review F1: a stream in backoff beside healthy streams is retried now over the
    // master the healthy streams just proved alive. Nothing is torn down and nothing is renewed.
    @Test func aStreamInBackoffBesideHealthyStreamsIsRetriedWithoutRenewal() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let streams = [
            FakeStream("s1", .waitingToRetry, log: log),
            FakeStream("s2", .connected, log: log),
            FakeStream("s3", .connected, log: log),
        ]

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(log.events == ["check s2", "check s3", "retry s1"])
        #expect(streams[1].phase == .connected)
        #expect(streams[2].phase == .connected)
    }

    // R7: with no connected stream to prove the master alive, a host whose streams are all
    // reconnecting is renewed, and every stream on it is held first.
    @Test func aHostWithOnlyReconnectingStreamsIsRenewed() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let streams = [
            FakeStream("s1", .waitingToRetry, log: log),
            FakeStream("s2", .retryInFlight, log: log),
        ]

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(log.events == [
            "hold s1", "hold s2", "unlock-wait", "unlocked",
            "renew user@a.wake.test", "resume s1", "resume s2",
        ])
    }

    // Review F1, adversarial: a silent stream beside a stream in backoff still renews the host.
    @Test func aSilentStreamBesideAStreamInBackoffRenewsTheHost() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let streams = [
            FakeStream("s1", .waitingToRetry, log: log),
            FakeStream("s2", .connected, answers: false, log: log),
        ]

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(log.events == [
            "check s2", "hold s1", "hold s2", "unlock-wait", "unlocked",
            "renew user@a.wake.test", "resume s1", "resume s2",
        ])
    }

    // R8: a stream waiting for the user's login is neither held nor retried.
    @Test func aStreamWaitingForLoginIsNotRetried() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let parked = FakeStream("parked", .waitingForLogin, log: log)
        let silent = FakeStream("silent", .connected, answers: false, log: log)

        _ = await recoverAndWait(coordinator, [hostGroup([parked, silent])])

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

        let started = coordinator.recover([hostGroup([stream])])
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

        let first = coordinator.recover([hostGroup([stream])])
        for await _ in environment.reachedUnlockWait { break }
        let second = coordinator.recover([hostGroup([stream])])
        #expect(first.count == 1)
        #expect(second.isEmpty)

        unlock.yield()
        for task in first { await task.value }
        #expect(log.events.filter { $0.hasPrefix("renew") }.count == 1)

        environment.unlockGate = nil
        let third = await recoverAndWait(coordinator, [hostGroup([FakeStream("s2", .connected, log: log)])])
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

        _ = await recoverAndWait(coordinator, [hostGroup(Self.hostA, .nothing, streams)])

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

        _ = await recoverAndWait(coordinator, [hostGroup(Self.hostA, .retryWaitingAttemptsNow, [waiting, inFlight, connected])])

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

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

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

        _ = await recoverAndWait(coordinator, [hostGroup([attaching, silent])])

        #expect(attaching.phase == .attaching)
        #expect(!log.events.contains { $0.hasSuffix(" attaching") })
    }

    // R4, review F2: a renewal that finds the host unreachable keeps every stream held and is
    // retried with a growing wait. The streams are released together only once one master is
    // confirmed, so they never race to create it and the user authenticates once.
    @Test func anUnreachableHostKeepsStreamsHeldAndRetriesTheRenewal() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        environment.renewResults = [.hostUnreachable, .hostUnreachable, .renewed]
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let streams = [
            FakeStream("s1", .connected, answers: false, log: log),
            FakeStream("s2", .retryInFlight, log: log),
        ]

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(log.events.filter { !$0.hasPrefix("unlock") } == [
            "check s1", "hold s1", "hold s2",
            "renew user@a.wake.test", "renew-wait 0",
            "renew user@a.wake.test", "renew-wait 1",
            "renew user@a.wake.test", "resume s1", "resume s2",
        ])
        #expect(streams.allSatisfy { $0.phase == .retryInFlight })
    }

    // Review F6, Q-H2: every renewal attempt, retries included, waits for the screen to be
    // unlocked first, so a host that comes back while the Mac is locked never prompts on the
    // lock screen.
    @Test func everyRenewalAttemptWaitsForUnlockFirst() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        environment.renewResults = [.hostUnreachable, .renewed]
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let stream = FakeStream("s1", .connected, answers: false, log: log)

        _ = await recoverAndWait(coordinator, [hostGroup([stream])])

        #expect(log.events == [
            "check s1", "hold s1",
            "unlock-wait", "unlocked", "renew user@a.wake.test", "renew-wait 0",
            "unlock-wait", "unlocked", "renew user@a.wake.test", "resume s1",
        ])
    }

    // R4, R8, review F5: a renewal that fails for any reason other than an unreachable host (a
    // password or MFA host, a dismissed Touch ID prompt, a changed host key) is not retried. One
    // stream is released into its own login handling; when it parks for the login, the others
    // park with it, so the host's single login resumes them all.
    @Test func aRenewalThatNeedsTheUserIsNotRetriedAndOneStreamLeadsToTheLogin() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        environment.renewResult = .failed
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let streams = (1...3).map { FakeStream("s\($0)", .connected, answers: false, log: log) }
        streams[0].reconnectOutcome = .waitingForLogin
        endStreamsIfTheRenewalIsRetried(environment, streams)

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(log.events == [
            "check s1", "hold s1", "hold s2", "hold s3",
            "unlock-wait", "unlocked", "renew user@a.wake.test",
            "resume s1", "outcome s1 waitingForLogin",
            "to-login s2", "to-login s3",
        ])
        #expect(streams.allSatisfy { $0.phase == .waitingForLogin })
    }

    // Review F5: when the lead stream reconnects by itself (the user approved its prompt), its
    // master now exists and the other streams are released to ride it.
    @Test func whenTheLeadStreamConnectsTheOthersAreReleased() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        environment.renewResult = .failed
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let streams = (1...2).map { FakeStream("s\($0)", .connected, answers: false, log: log) }
        endStreamsIfTheRenewalIsRetried(environment, streams)

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(log.events.suffix(3) == ["resume s1", "outcome s1 connected", "resume s2"])
        #expect(!log.events.contains { $0.hasPrefix("renew-wait") })
    }

    // Review F5, adversarial: a lead stream that ends (its session is gone, or the user closed it)
    // hands the lead to the next held stream, so the streams still go one at a time.
    @Test func whenTheLeadStreamEndsTheNextStreamLeads() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        environment.renewResult = .failed
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let streams = (1...3).map { FakeStream("s\($0)", .connected, answers: false, log: log) }
        streams[0].reconnectOutcome = .ended
        endStreamsIfTheRenewalIsRetried(environment, streams)

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(Array(log.events.drop { !$0.hasPrefix("resume") }) == [
            "resume s1", "outcome s1 ended",
            "resume s2", "outcome s2 connected",
            "resume s3",
        ])
    }

    // Review F2, adversarial: once no stream on the host is still held (the user closed them),
    // the renewal stops retrying and releases nothing.
    @Test func renewalRetriesStopWhenNoStreamIsStillHeld() async {
        let log = EventLog()
        let environment = FakeEnvironment(log: log)
        environment.renewResult = .hostUnreachable
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: environment)
        let streams = [
            FakeStream("s1", .connected, answers: false, log: log),
            FakeStream("s2", .connected, answers: false, log: log),
        ]
        environment.duringRenewalWait = { _ in
            for stream in streams { stream.phase = .ended }
        }

        _ = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(log.events.filter { $0.hasPrefix("renew user") }.count == 1)
        #expect(!log.events.contains { $0.hasPrefix("resume") })
    }

    // R10: with remote connections disabled by a managed-device policy, a wake does nothing.
    @Test func nothingHappensOnWakeWhenRemoteConnectionsAreDisabled() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(
            environment: FakeEnvironment(log: log),
            remoteConnectionsAllowed: { false }
        )
        let streams = [
            FakeStream("s1", .connected, answers: false, log: log),
            FakeStream("s2", .waitingToRetry, log: log),
        ]

        let started = await recoverAndWait(coordinator, [hostGroup(streams)])

        #expect(started == 0)
        #expect(log.events.isEmpty)
        #expect(streams[0].phase == .connected)
        #expect(streams[1].phase == .waitingToRetry)
    }

    // Adversarial: hosts recover independently; a healthy host is not renewed because another is dead.
    @Test func eachHostRecoversOnItsOwn() async {
        let log = EventLog()
        let coordinator = RemoteTmuxWakeRecoveryCoordinator(environment: FakeEnvironment(log: log))
        let dead = FakeStream("dead", .connected, answers: false, log: log)
        let healthy = FakeStream("healthy", .connected, log: log)

        let started = await recoverAndWait(coordinator, [hostGroup(Self.hostA, .checkThenRenewSharedConnection, [dead]),
                                                         hostGroup(Self.hostB, .checkThenRenewSharedConnection, [healthy])])

        #expect(started == 2)
        #expect(log.events.filter { $0.hasPrefix("renew") } == ["renew user@a.wake.test"])
        #expect(healthy.phase == .connected)
    }
}
