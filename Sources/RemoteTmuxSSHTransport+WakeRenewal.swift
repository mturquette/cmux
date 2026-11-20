import Foundation

extension RemoteTmuxSSHTransport {
    /// Closes the host's shared ControlMaster and opens one fresh one, confirmed ready.
    ///
    /// After sleep the old master's process can still answer `ssh -O check` while its TCP
    /// connection is dead, so ``ensureMasterReady()`` alone would report it ready and every
    /// reconnect would hang on it. Closing it first (awaited, unlike the fire-and-forget
    /// ``spawnControlMasterExit(host:sshExecutablePath:)``) means the warm-up opens one new master
    /// that every stream then shares. A warm-up another caller started on the old master is never
    /// joined (see ``closeAndReopenMaster()``).
    ///
    /// - Returns: whether the fresh master was confirmed ready.
    func renewSharedMaster() async -> Bool {
        await closeAndReopenMaster()
    }
}
