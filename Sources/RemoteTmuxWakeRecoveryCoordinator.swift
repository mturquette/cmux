import Foundation

/// Recovers mirrored control streams after the Mac wakes, one host at a time.
///
/// Owned by ``RemoteTmuxController``. Stub: recovers nothing yet.
@MainActor
final class RemoteTmuxWakeRecoveryCoordinator {
    private let environment: any RemoteTmuxWakeRecoveryEnvironment
    private let checkTimeoutSeconds: Double

    /// - Parameters:
    ///   - environment: the lock-screen and shared-connection steps.
    ///   - checkTimeoutSeconds: how long a connected stream has to answer its check.
    init(environment: any RemoteTmuxWakeRecoveryEnvironment, checkTimeoutSeconds: Double = 5) {
        self.environment = environment
        self.checkTimeoutSeconds = checkTimeoutSeconds
    }

    /// Starts recovery for each group whose host has none in progress.
    ///
    /// - Returns: the recoveries started by this call, so a caller can await them.
    @discardableResult
    func recover(_ groups: [RemoteTmuxWakeHostGroup]) -> [Task<Void, Never>] {
        []
    }
}
