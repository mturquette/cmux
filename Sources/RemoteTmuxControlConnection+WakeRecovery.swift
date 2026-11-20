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
}
