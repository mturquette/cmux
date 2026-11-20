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
}
