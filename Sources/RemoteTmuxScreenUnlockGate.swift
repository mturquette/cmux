import AppKit
import Foundation

/// Waits until the screen is unlocked.
///
/// Wake usually fires while the lock screen is still up. A reconnect that authenticates then can
/// trigger a Touch ID request for the user's ssh key that fails or is cancelled, which counts as a
/// failed attempt and pushes the next one out to the backoff cap. Wake recovery waits here before
/// it opens a new connection.
///
/// macOS has no public synchronous lock query, so the lock state combines the session
/// dictionary's `CGSSessionScreenIsLocked` key with the notifications ``ScreenLockObserver`` has
/// seen. Either unlock notification ends the wait without consulting them again, because the
/// observer that flips ``ScreenLockObserver/isLockedObserved`` may run after this one.
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

    /// Returns once the screen is unlocked, immediately if it already is, or when the calling
    /// task is cancelled.
    func waitUntilUnlocked() async {
        guard isLocked() else { return }
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let tokens = unlockSignals.map { signal in
            signal.center.addObserver(forName: signal.name, object: nil, queue: nil) { _ in
                continuation.yield()
            }
        }
        defer {
            for (signal, token) in zip(unlockSignals, tokens) {
                signal.center.removeObserver(token)
            }
            continuation.finish()
        }
        // Checked again after subscribing, so an unlock between the first check and the
        // subscription is not missed.
        guard isLocked() else { return }
        for await _ in signals { return }
    }

    /// Whether the session dictionary or the observed lock notifications say the screen is locked.
    ///
    /// No dictionary means the process has no window-server session, where nothing could prompt
    /// the user, so there is nothing to wait for. Another user owning the console (fast user
    /// switching) counts as locked.
    nonisolated static func screenIsLocked(sessionDictionary: [String: Any]?, observedLocked: Bool) -> Bool {
        guard let sessionDictionary else { return false }
        let onConsole = (sessionDictionary[kCGSessionOnConsoleKey as String] as? Bool) ?? false
        let dictionaryLocked = (sessionDictionary["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return !onConsole || dictionaryLocked || observedLocked
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
