import AppKit
import Testing
import CmuxTerminal

/// Requirement L2b of the latest-client sizing fix: a click into a mirrored
/// pane or switching to cmux counts as the user using cmux, but cmux's own
/// focus and activation changes do not.
@Suite struct TerminalUserActivationTests {
    private static let now: TimeInterval = 5_000

    private func judge(_ type: NSEvent.EventType, subtype: Int16? = nil, age: TimeInterval = 0.05) -> Bool {
        TerminalUserActivation(type: type, subtype: subtype, timestamp: Self.now - age, now: Self.now).isUserCaused
    }

    @Test func freshClicksAndKeyPressesCount() {
        #expect(judge(.leftMouseDown))
        #expect(judge(.rightMouseDown))
        #expect(judge(.otherMouseDown))
        #expect(judge(.keyDown))
    }

    @Test func theWindowServersActivationEventCounts() {
        let activated = NSEvent.EventSubtype.applicationActivated.rawValue
        #expect(judge(.appKitDefined, subtype: activated))
    }

    @Test func otherAppKitEventsDoNotCount() {
        let deactivated = NSEvent.EventSubtype.applicationDeactivated.rawValue
        let moved = NSEvent.EventSubtype.windowMoved.rawValue
        #expect(!judge(.appKitDefined, subtype: deactivated))
        #expect(!judge(.appKitDefined, subtype: moved))
        #expect(!judge(.appKitDefined, subtype: nil))
    }

    /// A socket command or a restore runs between events; the last event
    /// AppKit handled is then old, and must not be taken as the cause.
    @Test func staleEventsDoNotCount() {
        #expect(!judge(.leftMouseDown, age: TerminalUserActivation.freshness + 0.5))
        #expect(!judge(.keyDown, age: 30))
        #expect(!judge(.appKitDefined, subtype: NSEvent.EventSubtype.applicationActivated.rawValue, age: 5))
    }

    @Test func eventsThatAreNotUserActionsDoNotCount() {
        #expect(!judge(.mouseMoved))
        #expect(!judge(.leftMouseUp))
        #expect(!judge(.keyUp))
        #expect(!judge(.flagsChanged))
        #expect(!judge(.scrollWheel))
        #expect(!judge(.periodic))
        #expect(!judge(.applicationDefined))
    }

    @Test func noEventDoesNotCount() {
        #expect(!TerminalUserActivation(event: nil, now: Self.now).isUserCaused)
    }

    @Test func anEventFromTheFutureDoesNotCount() {
        #expect(!judge(.leftMouseDown, age: -2))
    }
}
