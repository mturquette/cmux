import Foundation

/// A mirrored control stream that wake recovery can check, hold, and release.
///
/// ``RemoteTmuxControlConnection`` is the only production conformer; the protocol exists so
/// ``RemoteTmuxWakeRecoveryCoordinator`` can be tested without spawning transports.
@MainActor
protocol RemoteTmuxWakeRecoverableStream: AnyObject, Sendable {
    /// Where the stream stands right now.
    var wakeStreamPhase: RemoteTmuxWakeStreamPhase { get }

    /// Sends one short command and reports whether tmux answered within `timeoutSeconds`.
    ///
    /// A `%error` reply counts as an answer: the server is talking, so the stream is alive.
    func answersWakeCheck(timeoutSeconds: Double) async -> Bool

    /// Tears down the stream's process and keeps it reconnecting with no attempt scheduled.
    ///
    /// - Returns: whether the stream is now held. A stream that is attaching, waiting for a
    ///   login, already held, or ended is left as it is.
    @discardableResult
    func holdReconnectForWake() -> Bool

    /// Releases a held stream with an immediate reconnect attempt at the base of the backoff.
    /// Does nothing unless the stream is held.
    func resumeReconnectAfterWake()

    /// Starts the next reconnect attempt now, at the base of the backoff, for a stream that is
    /// waiting between attempts. Does nothing in any other phase.
    func retryReconnectNow()
}
