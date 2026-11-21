import AppKit
import CmuxTerminal
import CmuxTerminalCore

/// Input a person gave a terminal view directly through AppKit. Everything here
/// reaches ``TerminalSurface/onDirectUserInput``; socket and CLI sends never do.
extension GhosttyNSView {
    /// Called only from AppKit's direct input paths (key down, committed text,
    /// paste commands), never for socket or CLI sends.
    func recordDirectAgentHibernationTerminalInput() {
        guard let terminalSurface else { return }
        terminalSurface.onDirectUserInput?()
        GhosttyApp.terminalSurfaceRuntimeDependencies
            .hibernationRecorder.recordTerminalInput(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id
            )
    }

    /// A mouse press in this view: the user choosing this surface, as a focus
    /// event does in a terminal.
    func noteDirectPointerPress() {
        terminalSurface?.onDirectUserInput?()
    }

    /// Counts the app becoming active as direct input to this focused surface.
    /// ``TerminalAppActivationObserver`` calls it only for an activation a person caused.
    /// - Returns: whether this view has a surface to count it for.
    func noteAppActivation() -> Bool {
        guard let terminalSurface else { return false }
        #if DEBUG
        cmuxDebugLog("terminal.activation counted surface=\(terminalSurface.id.uuidString.prefix(5))")
        #endif
        terminalSurface.onDirectUserInput?()
        return true
    }

    /// Whether the app activation AppKit is handling was caused by a person (a click, a key
    /// press, or the window server's Dock or Command-Tab activation) and not requested by cmux.
    static func appActivationIsUserCaused() -> Bool {
        let event = NSApp.currentEvent
        let now = ProcessInfo.processInfo.systemUptime
        let judged = TerminalUserActivation(event: event, now: now)
        // macOS answers cmux's own activation request with the same event a
        // Dock click or Command-Tab produces, so a request cmux made itself
        // just before rules the activation out.
        let requestedByCmux = AppDelegate.shared?.mainWindowVisibilityController
            .requestedOwnActivation(within: .seconds(TerminalUserActivation.freshness)) ?? false
        #if DEBUG
        let subtype = event?.type == .appKitDefined ? "\(event?.subtype.rawValue ?? -1)" : "-"
        let age = event.map { String(format: "%.3f", now - $0.timestamp) } ?? "-"
        cmuxDebugLog(
            "terminal.activation userCaused=\(judged.isUserCaused) requestedByCmux=\(requestedByCmux) " +
            "type=\(event.map { "\($0.type.rawValue)" } ?? "nil") subtype=\(subtype) age=\(age)"
        )
        #endif
        return judged.isUserCaused && !requestedByCmux
    }
}
