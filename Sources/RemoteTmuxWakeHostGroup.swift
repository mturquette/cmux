import Foundation

/// The mirrored streams of one host, recovered together after wake because they share the
/// host's transport (for ssh, one ControlMaster).
struct RemoteTmuxWakeHostGroup: Sendable {
    /// The host every stream in the group connects to.
    let host: RemoteTmuxHost
    /// What the host's transport does on wake.
    let recovery: RemoteTmuxWakeRecovery
    /// The host's streams, per-session and shared alike.
    let streams: [any RemoteTmuxWakeRecoverableStream]
}
