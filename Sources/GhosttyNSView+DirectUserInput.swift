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

    /// Reports the app becoming active as direct input to this focused surface,
    /// but only when the event AppKit is handling shows a person caused it
    /// (a click, a key press, or the window server's Dock or Command-Tab
    /// activation).
    func noteAppActivationIfUserCaused() {
        guard let terminalSurface else { return }
        let event = NSApp.currentEvent
        let now = ProcessInfo.processInfo.systemUptime
        let judged = TerminalUserActivation(event: event, now: now)
        #if DEBUG
        let subtype = event?.type == .appKitDefined ? "\(event?.subtype.rawValue ?? -1)" : "-"
        let age = event.map { String(format: "%.3f", now - $0.timestamp) } ?? "-"
        cmuxDebugLog(
            "terminal.activation surface=\(terminalSurface.id.uuidString.prefix(5)) " +
            "userCaused=\(judged.isUserCaused) type=\(event.map { "\($0.type.rawValue)" } ?? "nil") " +
            "subtype=\(subtype) age=\(age)"
        )
        #endif
        // macOS answers cmux's own activation request with the same event a
        // Dock click or Command-Tab produces, so a request cmux made itself
        // just before rules the activation out.
        let requestedByCmux = AppDelegate.shared?.mainWindowVisibilityController
            .requestedOwnActivation(within: .seconds(TerminalUserActivation.freshness)) ?? false
        guard judged.isUserCaused, !requestedByCmux else { return }
        terminalSurface.onDirectUserInput?()
    }
}
