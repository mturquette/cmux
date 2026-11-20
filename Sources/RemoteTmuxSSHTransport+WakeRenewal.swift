import Foundation

extension RemoteTmuxSSHTransport {
    /// Closes the host's shared ControlMaster and opens one fresh one, confirmed ready.
    ///
    /// - Returns: whether the fresh master was confirmed ready.
    func renewSharedMaster() async -> Bool {
        false
    }
}
