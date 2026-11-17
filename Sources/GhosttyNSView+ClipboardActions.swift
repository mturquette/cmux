import AppKit
import CmuxTerminal
import CmuxTerminalCore

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

    /// Reports the app becoming active as direct input to this focused surface,
    /// but only when the event AppKit is handling shows a person caused it
    /// (a click, a key press, or the window server's Dock or Command-Tab
    /// activation). cmux's own activations run outside such an event.
    func noteAppActivationIfUserCaused() {
        guard let terminalSurface,
              TerminalUserActivation(event: NSApp.currentEvent, now: ProcessInfo.processInfo.systemUptime).isUserCaused
        else { return }
        terminalSurface.onDirectUserInput?()
    }

    @IBAction func paste(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "paste.missingSurface") else {
            return
        }
        recordDirectAgentHibernationTerminalInput()
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        guard prepareSurfaceForPaste(
            reason: "pasteAsPlainText.missingSurface"
        ) else {
            return
        }
        recordDirectAgentHibernationTerminalInput()
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }

    /// The clipboard's plain text when it spans several lines, the case where
    /// "Paste as One Line" differs from Paste.
    var multiLineClipboardPlainText: String? {
        guard let pasteboard = GhosttyApp.terminalPasteboard.pasteboard(for: GHOSTTY_CLIPBOARD_STANDARD),
              let text = GhosttyApp.terminalPasteboard.fallbackPlainTextContents(from: pasteboard),
              TerminalPasteLineJoin(text).spansMultipleLines else {
            return nil
        }
        return text
    }

    /// Pastes the clipboard's plain text with its line breaks joined into one
    /// line, so a command that was copied with a break at every wrap point
    /// reaches the shell whole. It goes through the same paste path as
    /// `cmux paste` and never presses Return.
    @IBAction func pasteAsOneLine(_ sender: Any?) {
        guard let text = multiLineClipboardPlainText else { return }
        let joined = TerminalPasteLineJoin(text).joined
        guard !joined.isEmpty else { return }
        _ = terminalSurface?.sendTextResult(joined)
    }
}
