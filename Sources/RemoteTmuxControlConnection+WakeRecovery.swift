import Foundation

extension RemoteTmuxControlConnection: RemoteTmuxWakeRecoverableStream {
    /// The command used to check a stream after wake. Any command works; this one has no
    /// side effects and a one-line reply.
    static let wakeCheckCommand = "display-message -p cmux-wake-check"

    /// Sends ``wakeCheckCommand`` and reports whether tmux answered in time.
    ///
    /// The check never reconnects by itself: whether a silent stream is torn down, and when it
    /// reconnects, is ``RemoteTmuxWakeRecoveryCoordinator``'s decision for the whole host.
    func answersWakeCheck(timeoutSeconds: Double) async -> Bool {
        let outcome = await queryOutcomeWithTimeout(
            Self.wakeCheckCommand, timeout: timeoutSeconds, reconnectOnTimeout: false
        )
        switch outcome {
        case .lines, .error:
            return true
        case .unanswered:
            return false
        }
    }

    /// Returns once the stream has connected, parked for a login, or ended.
    ///
    /// Resolved by the state changes themselves (the `connectionState` observer and the park in
    /// `parkForInteractiveAuth`), never by polling. Not cancellable: wake recovery's tasks are not
    /// cancelled, and every stream eventually connects, parks, or is stopped, which ends it.
    func waitForReconnectOutcome() async -> RemoteTmuxWakeStreamPhase {
        if let outcome = reconnectOutcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome = reconnectOutcome {
                continuation.resume(returning: outcome)
                return
            }
            reconnectOutcomeWaiters[UUID()] = { continuation.resume(returning: $0) }
        }
    }

    /// The outcome a waiter is waiting for, or `nil` while the stream is still reconnecting.
    var reconnectOutcome: RemoteTmuxWakeStreamPhase? {
        // Reaching control mode is enough: the stream's ssh opened the host's master.
        if connectionState == .connected { return .connected }
        switch wakeStreamPhase {
        case .waitingForLogin: return .waitingForLogin
        case .ended: return .ended
        default: return nil
        }
    }

    /// Resolves every outcome waiter if the stream has reached an outcome.
    func finishReconnectOutcomeWaiters() {
        guard !reconnectOutcomeWaiters.isEmpty, let outcome = reconnectOutcome else { return }
        let waiters = Array(reconnectOutcomeWaiters.values)
        reconnectOutcomeWaiters.removeAll()
        for waiter in waiters { waiter(outcome) }
    }
}
