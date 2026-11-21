import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Switching to cmux with Command-Tab or a Dock click counts as using the terminal in the
/// window that becomes key, with no click or key press needed (owner report, 2026-11-21).
///
/// macOS posts the app's `didBecomeActive` before its window becomes key, so at that moment
/// there is no key window yet. The owner's log shows it: about 30 activations, and only one
/// found a terminal to count. The activation is therefore carried to the window that becomes
/// key right after it. A window that becomes key with no activation from a person (cmux
/// moving focus by itself) never counts, so cmux and another tmux client cannot fight over
/// the size.
@MainActor
@Suite struct TerminalAppActivationObserverTests {
    @MainActor
    final class Fake {
        var keyWindow: NSWindow?
        var userCaused = true
        var now: TimeInterval = 100
        /// Windows whose first responder is a terminal.
        var terminalWindows: [NSWindow] = []
        var noted: [NSWindow] = []

        func environment() -> TerminalAppActivationObserver.Environment {
            TerminalAppActivationObserver.Environment(
                keyWindow: { self.keyWindow },
                activationIsUserCaused: { self.userCaused },
                now: { self.now },
                noteUse: { window in
                    guard self.terminalWindows.contains(where: { $0 === window }) else { return false }
                    self.noted.append(window)
                    return true
                }
            )
        }
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    }

    private func activate(_ center: NotificationCenter) {
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    private func becomeKey(_ window: NSWindow, _ center: NotificationCenter) {
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @Test func anActivationWithItsWindowAlreadyKeyCountsOnce() {
        let center = NotificationCenter()
        let fake = Fake()
        let main = window()
        fake.keyWindow = main
        fake.terminalWindows = [main]
        let observer = TerminalAppActivationObserver(center: center, environment: fake.environment())

        activate(center)
        becomeKey(main, center)

        #expect(fake.noted.count == 1)
        #expect(fake.noted.first === main)
        _ = observer
    }

    // The reported case: Command-Tab back to cmux with no input.
    @Test func anActivationCountsWhenItsWindowBecomesKeyRightAfter() {
        let center = NotificationCenter()
        let fake = Fake()
        let main = window()
        fake.terminalWindows = [main]
        let observer = TerminalAppActivationObserver(center: center, environment: fake.environment())

        activate(center)
        #expect(fake.noted.isEmpty)
        fake.now += 0.05
        becomeKey(main, center)
        becomeKey(main, center)

        #expect(fake.noted.count == 1)
        #expect(fake.noted.first === main)
        _ = observer
    }

    // A window whose focus is not a terminal (a settings panel) does not use up the activation.
    @Test func theActivationWaitsForAWindowWithATerminal() {
        let center = NotificationCenter()
        let fake = Fake()
        let panel = window()
        let main = window()
        fake.terminalWindows = [main]
        let observer = TerminalAppActivationObserver(center: center, environment: fake.environment())

        activate(center)
        becomeKey(panel, center)
        becomeKey(main, center)

        #expect(fake.noted.count == 1)
        #expect(fake.noted.first === main)
        _ = observer
    }

    // No fight: an activation cmux asked for itself never counts, now or when a window becomes key.
    @Test func anActivationNobodyCausedNeverCounts() {
        let center = NotificationCenter()
        let fake = Fake()
        let main = window()
        fake.terminalWindows = [main]
        fake.userCaused = false
        let observer = TerminalAppActivationObserver(center: center, environment: fake.environment())

        activate(center)
        becomeKey(main, center)

        #expect(fake.noted.isEmpty)
        _ = observer
    }

    // No fight: a window becoming key with no activation before it (cmux moving focus by
    // itself) does not count.
    @Test func aWindowBecomingKeyWithoutAnActivationDoesNotCount() {
        let center = NotificationCenter()
        let fake = Fake()
        let main = window()
        fake.terminalWindows = [main]
        let observer = TerminalAppActivationObserver(center: center, environment: fake.environment())

        becomeKey(main, center)

        #expect(fake.noted.isEmpty)
        _ = observer
    }

    // A window that becomes key long after the activation was not caused by it.
    @Test func aWindowBecomingKeyLongAfterTheActivationDoesNotCount() {
        let center = NotificationCenter()
        let fake = Fake()
        let main = window()
        fake.terminalWindows = [main]
        let observer = TerminalAppActivationObserver(center: center, environment: fake.environment())

        activate(center)
        fake.now += TerminalUserActivation.freshness + 0.5
        becomeKey(main, center)

        #expect(fake.noted.isEmpty)
        _ = observer
    }
}
