import Foundation

/// What a transport's mirrored control streams do when the Mac wakes from sleep.
///
/// Declared per transport on ``RemoteTmuxTransportProfile/wakeRecovery`` because the right
/// answer depends on how the transport is carried: an ssh stream rides a shared ControlMaster
/// whose TCP connection sleep can silently kill, EternalTerminal recovers its own connection,
/// and a transport with no network leg has nothing to recover.
enum RemoteTmuxWakeRecovery: Sendable, Equatable {
    /// Leave every stream alone. The default, so a transport opts in explicitly.
    case nothing
    /// Retry at once any stream that is waiting between reconnect attempts, and leave every
    /// other stream to the transport's own recovery.
    case retryWaitingAttemptsNow
    /// Check each connected stream with one short command. If any stays silent, or any is
    /// already reconnecting, hold the host's streams, wait until the screen is unlocked, renew
    /// the host's shared ssh connection once, and then release the streams to reconnect over it.
    case checkThenRenewSharedConnection
}
