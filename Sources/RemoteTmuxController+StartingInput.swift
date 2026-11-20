import Foundation

extension RemoteTmuxController {
    /// The command that types a new mirror tab's starting input into the window tmux
    /// just created, or `nil` when there is nothing to type.
    ///
    /// The bytes go through `send-keys -H` (hex), the same binary-safe path typed keys
    /// use, so quotes, `;`, `#{...}` formats, newlines and non-ASCII text reach the
    /// shell exactly as a local new tab would receive them, and the command line stays
    /// one line. The target is the new window's stable id: a new window has exactly one
    /// pane, and `@id` does not follow tmux's current window.
    nonisolated static func startingInputCommand(windowId: Int, input: String) -> String? {
        let bytes = Data(input.utf8)
        guard !bytes.isEmpty else { return nil }
        return "send-keys -t @\(windowId) -H \(RemoteTmuxControlConnection.hexByteArguments(bytes))"
    }

    /// The `new-window` verb and flags. Focused requests, and background requests that
    /// carry starting input, ask tmux to print the new window's id in the reply.
    nonisolated static func newWindowVerb(focus: Bool, reportsWindowId: Bool) -> String {
        if focus { return "new-window -P -F '#{window_id}'" }
        return reportsWindowId ? "new-window -d -P -F '#{window_id}'" : "new-window -d"
    }
}
