import Foundation

/// Recovers mirrored control streams after the Mac wakes, one host at a time.
///
/// After sleep an ssh stream and its shared ControlMaster can look alive while their TCP
/// connection is dead, and the stream only notices when ssh's keepalives give up, up to about a
/// minute later. A plain "retry now" does not help, because the retry rides the same dead master.
/// So for a transport that declares ``RemoteTmuxWakeRecovery/checkThenRenewSharedConnection``:
///
/// 1. Each connected stream gets one short command. Streams that answer are left alone, and the
///    checks stop at the first silent stream. If every connected stream answers, the master is
///    alive: a stream waiting out its backoff retries now over it, and nothing is renewed.
/// 2. If a stream was silent, or no stream is connected and one is reconnecting, every stream on
///    the host is held: closing the shared master ends them all, so none may race a retry over it.
/// 3. The coordinator waits until the screen is unlocked, renews the host's master, and releases
///    the held streams to reconnect over the fresh master, so the user authenticates at most once
///    per host. A renewal that finds the host unreachable is retried with a growing wait while the
///    streams stay held, until it succeeds or none of them is held any more.
/// 4. A renewal that fails for any other reason (the host needs a password or MFA, the user
///    dismissed a Touch ID prompt, the host key changed) is not retried, because the same
///    non-interactive open cannot succeed. One held stream is released at a time, into its own
///    login and end handling. When it connects, the others follow it over its master; when it parks
///    for a login, the others park with it, so the host's one login resumes them all.
///
/// Owned by ``RemoteTmuxController``. One recovery runs per host; a wake that arrives while that
/// host is still recovering starts nothing more for it.
@MainActor
final class RemoteTmuxWakeRecoveryCoordinator {
    private let environment: any RemoteTmuxWakeRecoveryEnvironment
    private let checkTimeoutSeconds: Double
    private let remoteConnectionsAllowed: @MainActor () -> Bool
    /// The recovery running for each host, keyed by ``RemoteTmuxHost/connectionHash``.
    private var recoveriesByHost: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - environment: the lock-screen and shared-connection steps.
    ///   - checkTimeoutSeconds: how long a connected stream has to answer its check. Five
    ///     seconds leaves room for a slow link while staying well under ssh's own detection.
    ///   - remoteConnectionsAllowed: whether a managed-device policy allows remote connections
    ///     right now (`DisableRemoteConnections` not in force). Read at each wake.
    init(
        environment: any RemoteTmuxWakeRecoveryEnvironment,
        checkTimeoutSeconds: Double = 5,
        remoteConnectionsAllowed: @escaping @MainActor () -> Bool = { true }
    ) {
        self.environment = environment
        self.checkTimeoutSeconds = checkTimeoutSeconds
        self.remoteConnectionsAllowed = remoteConnectionsAllowed
    }

    /// Starts recovery for each group whose host has none in progress. Starts nothing while a
    /// managed-device policy disables remote connections, as `cmux ssh` does on wake.
    ///
    /// - Returns: the recoveries started by this call, so a caller can await them.
    @discardableResult
    func recover(_ groups: [RemoteTmuxWakeHostGroup]) -> [Task<Void, Never>] {
        guard remoteConnectionsAllowed() else { return [] }
        var started: [Task<Void, Never>] = []
        for group in groups {
            let key = group.host.connectionHash
            guard recoveriesByHost[key] == nil else { continue }
            // The task body runs on a later main-actor turn, so the entry below is always
            // recorded before the body can clear it.
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.recoverHost(group)
                self.recoveriesByHost[key] = nil
            }
            recoveriesByHost[key] = task
            started.append(task)
        }
        return started
    }

    private func recoverHost(_ group: RemoteTmuxWakeHostGroup) async {
        switch group.recovery {
        case .nothing:
            return
        case .retryWaitingAttemptsNow:
            for stream in group.streams where stream.wakeStreamPhase == .waitingToRetry {
                stream.retryReconnectNow()
            }
        case .checkThenRenewSharedConnection:
            await checkThenRenewSharedConnection(group)
        }
    }

    private func checkThenRenewSharedConnection(_ group: RemoteTmuxWakeHostGroup) async {
        guard await hostNeedsRenewal(group.streams) else {
            // The connected streams just proved the master alive, so a stream waiting out its
            // backoff can retry over it now, with nothing torn down.
            for stream in group.streams where stream.wakeStreamPhase == .waitingToRetry {
                stream.retryReconnectNow()
            }
            return
        }
        var held: [any RemoteTmuxWakeRecoverableStream] = []
        for stream in group.streams where stream.holdReconnectForWake() {
            held.append(stream)
        }
        guard !held.isEmpty else { return }
        await environment.waitForScreenUnlock()
        // Only one renewal, never the streams, creates the new master. A renewal that finds the
        // host unreachable keeps every stream held and is retried with a growing wait, so once the
        // host is back exactly one master is opened and the user authenticates once. Released
        // streams would each race to create the master (#6732), and each loser would log in on its
        // own.
        var attempt = 0
        while true {
            switch await environment.renewSharedConnection(for: group.host) {
            case .renewed:
                for stream in held {
                    stream.resumeReconnectAfterWake()
                }
                return
            case .failed:
                await releaseOneStreamAtATime(held)
                return
            case .hostUnreachable:
                await environment.waitBeforeRenewalRetry(attempt: attempt)
                attempt += 1
                // The user may close every held mirror while the host is unreachable.
                guard held.contains(where: { $0.wakeStreamPhase == .heldForWake }) else { return }
            }
        }
    }

    /// Hands the held streams to their own reconnect handling one at a time, after a renewal that
    /// a retry cannot fix.
    ///
    /// The lead stream's reconnect reaches the existing paths: a host that needs the user parks it
    /// and offers one login, a gone session ends it. Its outcome decides the rest. When it connects,
    /// its master is open and the others ride it. When it parks for a login, the others park too,
    /// and the host's login resumes every parked stream. When it ends, the next held stream leads.
    /// So at most one stream at a time can ask the user to authenticate.
    private func releaseOneStreamAtATime(_ held: [any RemoteTmuxWakeRecoverableStream]) async {
        var waiting = held
        while let lead = waiting.first {
            waiting.removeFirst()
            guard lead.wakeStreamPhase == .heldForWake else { continue }
            lead.resumeReconnectAfterWake()
            switch await lead.waitForReconnectOutcome() {
            case .waitingForLogin:
                for stream in waiting { stream.handOverHeldStreamToLogin() }
                return
            case .ended:
                continue
            default:
                for stream in waiting { stream.resumeReconnectAfterWake() }
                return
            }
        }
    }

    /// Whether the host's shared master must be renewed.
    ///
    /// The connected streams are checked first, stopping at the first silent one. If every
    /// connected stream answers, the master is alive and nothing is renewed, even when another
    /// stream is reconnecting. With no connected stream to vouch for the master, a host whose
    /// streams are reconnecting is renewed.
    private func hostNeedsRenewal(_ streams: [any RemoteTmuxWakeRecoverableStream]) async -> Bool {
        var checkedAny = false
        for stream in streams where stream.wakeStreamPhase == .connected {
            checkedAny = true
            let answered = await stream.answersWakeCheck(timeoutSeconds: checkTimeoutSeconds)
            if !answered { return true }
        }
        if checkedAny { return false }
        return streams.contains {
            $0.wakeStreamPhase == .waitingToRetry || $0.wakeStreamPhase == .retryInFlight
        }
    }
}
