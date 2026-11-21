import AppKit

/// Counts a person switching to cmux (a Dock click or Command-Tab) as using the terminal in
/// the window that becomes key, so a mirrored tmux window takes cmux's size back without a
/// click or a key press.
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

    /// - Parameters:
    ///   - center: where the app and window notifications are posted.
    ///   - environment: the app reads and the action.
    init(center: NotificationCenter, environment: Environment) {
        self.environment = environment
        self.center = center
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        })
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    private func appDidBecomeActive() {
        guard environment.activationIsUserCaused(), let window = environment.keyWindow() else { return }
        _ = environment.noteUse(window)
    }
}
