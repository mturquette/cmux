import Foundation

/// The live lock-screen and shared-connection steps for wake recovery.
@MainActor
final class RemoteTmuxLiveWakeRecoveryEnvironment: RemoteTmuxWakeRecoveryEnvironment {
    private let transportRegistry: RemoteTmuxTransportRegistry
    private let screenUnlockGate: RemoteTmuxScreenUnlockGate

    /// - Parameters:
    ///   - transportRegistry: the controller's per-host ssh transports.
    ///   - screenUnlockGate: waits for the screen to be unlocked.
    init(transportRegistry: RemoteTmuxTransportRegistry, screenUnlockGate: RemoteTmuxScreenUnlockGate) {
        self.transportRegistry = transportRegistry
        self.screenUnlockGate = screenUnlockGate
    }

    func waitForScreenUnlock() async {
        await screenUnlockGate.waitUntilUnlocked()
    }

    func renewSharedConnection(for host: RemoteTmuxHost) async -> Bool {
        await transportRegistry.transport(for: host).renewSharedMaster()
    }

    /// The same capped exponential backoff a reconnecting stream uses: 1, 2, 4 and 8 seconds, then
    /// 10 seconds per retry. A bounded backoff timer, not a wait for an event: the event (the host
    /// becoming reachable) has no notification to await, so the renewal itself is the probe.
    func waitBeforeRenewalRetry(attempt: Int) async {
        let seconds = min(Self.renewalRetryMaxSeconds, Self.renewalRetryBaseSeconds * pow(2, Double(attempt)))
        try? await ContinuousClock().sleep(for: .seconds(seconds))
    }

    private static let renewalRetryBaseSeconds: Double = 1
    private static let renewalRetryMaxSeconds: Double = 10
}
