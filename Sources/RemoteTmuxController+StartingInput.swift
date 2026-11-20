import Foundation

extension RemoteTmuxController {
    /// The command that types a new mirror tab's starting input into the window tmux
    /// just created, or `nil` when there is nothing to type.
    nonisolated static func startingInputCommand(windowId: Int, input: String) -> String? {
        nil
    }
}
