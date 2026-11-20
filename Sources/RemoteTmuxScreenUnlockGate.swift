import AppKit
import Foundation

/// Waits until the screen is unlocked. Stub: never waits.
@MainActor
final class RemoteTmuxScreenUnlockGate {
    /// One notification that can mean the screen was unlocked.
    struct UnlockSignal {
        let center: NotificationCenter
        let name: Notification.Name
    }

    private let isLocked: @MainActor () -> Bool
    private let unlockSignals: [UnlockSignal]

    /// - Parameters:
    ///   - isLocked: whether the screen is locked right now.
    ///   - unlockSignals: the notifications that end the wait.
    init(
        isLocked: @escaping @MainActor () -> Bool = { RemoteTmuxScreenUnlockGate.liveScreenIsLocked() },
        unlockSignals: [UnlockSignal] = RemoteTmuxScreenUnlockGate.liveUnlockSignals()
    ) {
        self.isLocked = isLocked
        self.unlockSignals = unlockSignals
    }

    /// Returns once the screen is unlocked, immediately if it already is.
    func waitUntilUnlocked() async {}

    /// Whether the session dictionary or the observed lock notifications say the screen is locked.
    nonisolated static func screenIsLocked(sessionDictionary: [String: Any]?, observedLocked: Bool) -> Bool {
        false
    }

    static func liveScreenIsLocked() -> Bool {
        screenIsLocked(
            sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any],
            observedLocked: ScreenLockObserver.shared.isLockedObserved
        )
    }

    static func liveUnlockSignals() -> [UnlockSignal] {
        [
            UnlockSignal(
                center: DistributedNotificationCenter.default(),
                name: Notification.Name("com.apple.screenIsUnlocked")
            ),
            UnlockSignal(
                center: NSWorkspace.shared.notificationCenter,
                name: NSWorkspace.sessionDidBecomeActiveNotification
            ),
        ]
    }
}
