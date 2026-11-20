import Foundation

/// Where one mirrored control stream stands when the Mac wakes, as wake recovery sees it.
enum RemoteTmuxWakeStreamPhase: Sendable, Equatable {
    /// In control mode with its attach result consumed, so a command can be sent to check it.
    case connected
    /// Still connecting, or in control mode before its attach result arrived. Commands sent
    /// now would race the attach result, so wake recovery leaves it alone.
    case attaching
    /// Reconnecting and waiting out the backoff between attempts, with no process running.
    case waitingToRetry
    /// Reconnecting with an attempt's process running.
    case retryInFlight
    /// Parked until the user completes an interactive login; retrying would prompt again.
    case waitingForLogin
    /// Held by wake recovery until the host's shared connection has been renewed.
    case heldForWake
    /// Permanently ended.
    case ended
}
