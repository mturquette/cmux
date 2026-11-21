import AppKit
import CmuxTerminal

/// Counts a person switching to cmux (a Dock click or Command-Tab) as using the terminal in
/// the window that becomes key, so a mirrored tmux window takes cmux's size back without a
/// click or a key press.
///
/// macOS posts the app's `didBecomeActive` before it makes the app's window key, so at that
/// moment there is usually no key window to look in. An activation a person caused is
/// therefore remembered and counted for the first window with a focused terminal that
/// becomes key within ``TerminalUserActivation/freshness``. A window that becomes key with no
/// such activation before it (cmux moving focus by itself) never counts, so cmux and another
/// tmux client cannot take the size back and forth.
///
/// Owned by ``GhosttyApp``, which passes the live AppKit reads; tests pass their own.
@MainActor
final class TerminalAppActivationObserver {
    /// What the observer reads from, and does to, the app.
    struct Environment {
        /// The app's key window right now, if any.
        var keyWindow: @MainActor () -> NSWindow?
        /// Whether the app activation being handled was caused by a person, and not requested
        /// by cmux itself.
        var activationIsUserCaused: @MainActor () -> Bool
        /// The current time on the event clock.
        var now: @MainActor () -> TimeInterval
        /// Counts the use for the terminal that has focus in `window`.
        /// - Returns: whether `window`'s first responder is a terminal.
        var noteUse: @MainActor (NSWindow) -> Bool
    }

    private let environment: Environment
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    /// When a person's activation arrived that no terminal has counted yet.
    private var uncountedActivationAt: TimeInterval?

    /// - Parameters:
    ///   - center: where the app and window notifications are posted. Both are posted on the
    ///     main thread, so they are handled synchronously.
    ///   - environment: the app reads and the action.
    init(center: NotificationCenter, environment: Environment) {
        self.environment = environment
        self.center = center
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.windowDidBecomeKey(window) }
        })
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    private func appDidBecomeActive() {
        uncountedActivationAt = nil
        guard environment.activationIsUserCaused() else { return }
        if let window = environment.keyWindow(), environment.noteUse(window) { return }
        uncountedActivationAt = environment.now()
    }

    private func windowDidBecomeKey(_ window: NSWindow) {
        guard let activatedAt = uncountedActivationAt else { return }
        guard environment.now() - activatedAt <= TerminalUserActivation.freshness else {
            uncountedActivationAt = nil
            return
        }
        if environment.noteUse(window) { uncountedActivationAt = nil }
    }
}
