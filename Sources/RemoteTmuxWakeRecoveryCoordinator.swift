import Foundation

/// Recovers mirrored control streams after the Mac wakes, one host at a time.
///
/// After sleep an ssh stream and its shared ControlMaster can look alive while their TCP
/// connection is dead, and the stream only notices when ssh's keepalives give up, up to about a
/// minute later. A plain "retry now" does not help, because the retry rides the same dead master.
/// So for a transport that declares ``RemoteTmuxWakeRecovery/checkThenRenewSharedConnection``:
///
/// 1. Each connected stream gets one short command. Streams that answer are left alone, and the
///    checks stop at the first silent stream.
/// 2. If a stream was silent, or one was already reconnecting, every stream on the host is held:
///    closing the shared master ends them all, so none may race a retry over it.
/// 3. The coordinator waits until the screen is unlocked, renews the host's master once, and
///    releases the held streams to reconnect over the fresh master, so the user authenticates at
///    most once per host.
///
/// Owned by ``RemoteTmuxController``. One recovery runs per host; a wake that arrives while that
/// host is still recovering starts nothing more for it.
@MainActor
final class RemoteTmuxWakeRecoveryCoordinator {
    private let environment: any RemoteTmuxWakeRecoveryEnvironment
    private let checkTimeoutSeconds: Double
    /// The recovery running for each host, keyed by ``RemoteTmuxHost/connectionHash``.
    private var recoveriesByHost: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - environment: the lock-screen and shared-connection steps.
    ///   - checkTimeoutSeconds: how long a connected stream has to answer its check. Five
    ///     seconds leaves room for a slow link while staying well under ssh's own detection.
    init(environment: any RemoteTmuxWakeRecoveryEnvironment, checkTimeoutSeconds: Double = 5) {
        self.environment = environment
        self.checkTimeoutSeconds = checkTimeoutSeconds
    }

    /// Starts recovery for each group whose host has none in progress.
    ///
    /// - Returns: the recoveries started by this call, so a caller can await them.
    @discardableResult
    func recover(_ groups: [RemoteTmuxWakeHostGroup]) -> [Task<Void, Never>] {
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
        guard await hostNeedsRenewal(group.streams) else { return }
        var held: [any RemoteTmuxWakeRecoverableStream] = []
        for stream in group.streams where stream.holdReconnectForWake() {
            held.append(stream)
        }
        guard !held.isEmpty else { return }
        await environment.waitForScreenUnlock()
        // Released whatever the renewal reports: a stream whose attempt then fails keeps its own
        // backoff, which is better than leaving it frozen.
        _ = await environment.renewSharedConnection(for: group.host)
        for stream in held {
            stream.resumeReconnectAfterWake()
        }
    }

    private func hostNeedsRenewal(_ streams: [any RemoteTmuxWakeRecoverableStream]) async -> Bool {
        let alreadyReconnecting = streams.contains {
            $0.wakeStreamPhase == .waitingToRetry || $0.wakeStreamPhase == .retryInFlight
        }
        if alreadyReconnecting { return true }
        for stream in streams where stream.wakeStreamPhase == .connected {
            let answered = await stream.answersWakeCheck(timeoutSeconds: checkTimeoutSeconds)
            if !answered { return true }
        }
        return false
    }
}
