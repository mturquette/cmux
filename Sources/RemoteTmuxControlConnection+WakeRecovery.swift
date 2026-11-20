import Foundation

extension RemoteTmuxControlConnection: RemoteTmuxWakeRecoverableStream {
    /// The command used to check a stream after wake. Any command works; this one has no
    /// side effects and a one-line reply.
    static let wakeCheckCommand = "display-message -p cmux-wake-check"

    func answersWakeCheck(timeoutSeconds: Double) async -> Bool {
        true
    }
}
