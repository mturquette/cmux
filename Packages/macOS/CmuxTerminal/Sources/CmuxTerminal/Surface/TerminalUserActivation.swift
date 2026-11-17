public import AppKit

/// Whether the app became active, or a window became key, because a person
/// did something, judged from the event AppKit was handling at that moment.
///
/// cmux also activates itself and moves focus on its own (restoring a
/// session, creating a split, answering a socket command). Those changes run
/// outside any fresh input event, or inside one that is not an activation, so
/// they are not counted. A click, a key press, or the activation event the
/// window server sends for a Dock click or Command-Tab is counted when it is
/// fresh.
public struct TerminalUserActivation: Equatable, Sendable {
    /// How old an event may be and still be the cause of the activation.
    public static let freshness: TimeInterval = 1.0

    public let isUserCaused: Bool

    /// - Parameters:
    ///   - event: `NSApp.currentEvent` when the activation was reported.
    ///   - now: The current time on the event clock (`ProcessInfo.systemUptime`).
    public init(event: NSEvent?, now: TimeInterval) {
        // No event at all reads as an application-defined one, which never counts.
        let type = event?.type ?? .applicationDefined
        self.init(
            type: type,
            subtype: type == .appKitDefined ? event?.subtype.rawValue : nil,
            timestamp: event?.timestamp ?? now,
            now: now
        )
    }

    /// The same judgement from an event's parts, for callers and tests that have no `NSEvent`.
    public init(type: NSEvent.EventType, subtype: Int16?, timestamp: TimeInterval, now: TimeInterval) {
        let age = now - timestamp
        guard age >= 0, age <= Self.freshness else {
            isUserCaused = false
            return
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown:
            isUserCaused = true
        case .appKitDefined:
            isUserCaused = subtype == NSEvent.EventSubtype.applicationActivated.rawValue
        default:
            isUserCaused = false
        }
    }
}
