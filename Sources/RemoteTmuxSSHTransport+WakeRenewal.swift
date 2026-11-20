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
    /// - Returns: whether the fresh master was confirmed ready, and if not, why.
    func renewSharedMaster() async -> RemoteTmuxWakeRenewalResult {
        let outcome = await closeAndReopenMaster()
        return outcome.isRunning ? .renewed : Self.wakeRenewalFailure(openStderr: outcome.openStderr)
    }

    /// Why a renewal's open failed, read from ssh's stderr.
    ///
    /// Only a network failure counts as unreachable, because that is the one case where trying the
    /// same non-interactive (`BatchMode=yes`) open again later can succeed. Anything that needs the
    /// user (a password or MFA, a dismissed Touch ID prompt, a changed host key) or that no retry
    /// fixes is a plain failure, and so is a failure ssh did not explain.
    static func wakeRenewalFailure(openStderr stderr: String) -> RemoteTmuxWakeRenewalResult {
        if indicatesInteractiveRetryWillHelp(stderr) || indicatesUnrecoverableTransportFailure(stderr) {
            return .failed
        }
        let lowered = stderr.lowercased()
        return networkFailureMarkers.contains(where: { lowered.contains($0) }) ? .hostUnreachable : .failed
    }

    /// ssh's wording when the host cannot be reached at the network level.
    private static let networkFailureMarkers: [String] = [
        "operation timed out",              // macOS TCP connect timeout
        "connection timed out",             // Linux TCP connect timeout
        "connection refused",
        "no route to host",
        "network is unreachable",
        "host is down",
        "could not resolve hostname",       // OpenSSH's DNS failure wrapper
        "nodename nor servname provided",   // macOS getaddrinfo
        "name or service not known",        // Linux getaddrinfo
        "temporary failure in name resolution",
    ]
}
