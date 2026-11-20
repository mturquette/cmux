import Foundation

/// The outside-world steps wake recovery needs, behind a seam so the coordinator's ordering
/// can be tested without a lock screen or an ssh server.
@MainActor
protocol RemoteTmuxWakeRecoveryEnvironment: AnyObject {
    /// Returns once the screen is unlocked, immediately if it already is.
    ///
    /// A new ssh connection may need a Touch ID touch for the user's key, and a request made
    /// while the lock screen is up can fail and push the next retry out to the backoff cap.
    func waitForScreenUnlock() async

    /// Closes the host's shared ssh connection and opens one fresh one.
    ///
    /// - Returns: whether the fresh connection was confirmed ready.
    func renewSharedConnection(for host: RemoteTmuxHost) async -> Bool

    /// Waits before the next renewal after renewal attempt `attempt` (counted from 0) failed.
    func waitBeforeRenewalRetry(attempt: Int) async
}
