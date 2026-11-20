import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A new tab in a mirrored workspace carries its starting input, the way a local
/// new tab already does: an action, tab-bar button or `new-surface --command` that
/// opens a tab running a command creates one tmux window and types that command
/// into it, and into no other pane.
///
/// The window is created with `-P -F '#{window_id}'` so tmux reports the new
/// window's id in the reply to that exact command, and the input is then sent to
/// that window by id. A brand-new window has exactly one pane, so `-t @id`
/// reaches it however the session's current window moves in between.
@Suite struct RemoteTmuxMirrorNewTabStartingInputTests {
    // A background request that carries input still asks tmux for the window id,
    // and stays detached so tmux's selected window does not move.
    @Test func backgroundRequestWithInputReportsWindowIdAndStaysDetached() {
        #expect(
            RemoteTmuxController.newWindowCommand(
                afterWindowId: 7,
                workingDirectory: nil,
                focus: false,
                reportsWindowId: true
            ) == "new-window -d -P -F '#{window_id}' -a -t @7"
        )
    }

    // A focused request already reports the id, so carrying input changes nothing.
    @Test func focusedRequestWithInputIsTodaysFocusedCommand() {
        #expect(
            RemoteTmuxController.newWindowCommand(
                afterWindowId: nil,
                workingDirectory: "/srv/app",
                focus: true,
                reportsWindowId: true
            ) == "new-window -P -F '#{window_id}' -a -t '{end}' -c '/srv/app'"
        )
    }

    // Without input, every existing command is unchanged.
    @Test(arguments: [false, true])
    func requestWithoutInputIsUnchanged(focus: Bool) {
        #expect(
            RemoteTmuxController.newWindowCommand(
                afterWindowId: 3, workingDirectory: "/tmp", focus: focus, reportsWindowId: false
            ) == RemoteTmuxController.newWindowCommand(afterWindowId: 3, workingDirectory: "/tmp", focus: focus)
        )
    }

    // The multiplexer's session-scoped builder follows the same rule.
    @Test func sessionScopedBackgroundRequestWithInputReportsWindowId() {
        #expect(
            RemoteTmuxController.newWindowCommandInSession(
                "work",
                sessionId: 4,
                workingDirectory: nil,
                focus: false,
                reportsWindowId: true
            ) == "new-window -d -P -F '#{window_id}' -a -t '$4:{end}'"
        )
    }

    // The input goes to the new window by id, as the same bytes a local tab receives.
    @Test func startingInputIsSentToTheNewWindowByteForByte() {
        #expect(
            RemoteTmuxController.startingInputCommand(windowId: 12, input: "claude\n")
                == "send-keys -t @12 -H 63 6c 61 75 64 65 0a"
        )
    }

    @Test func emptyStartingInputSendsNothing() {
        #expect(RemoteTmuxController.startingInputCommand(windowId: 12, input: "") == nil)
    }

    // Quotes, separators, tmux formats, newlines and non-ASCII text reach the shell
    // literally: the command line holds only the target and hex bytes.
    @Test(arguments: [
        "echo 'single' \"double\"; rm -rf /tmp/x\n",
        "printf '#{pane_id} %s' $HOME\n",
        "line one\nline two\r\n",
        "claude --resume \"café ☕︎\"\n",
    ])
    func startingInputIsAlwaysOneLineOfHexBytes(input: String) throws {
        let command = try #require(RemoteTmuxController.startingInputCommand(windowId: 5, input: input))
        let prefix = "send-keys -t @5 -H "
        #expect(command.hasPrefix(prefix))
        let hex = command.dropFirst(prefix.count)
        #expect(hex.allSatisfy { $0 == " " || $0.isHexDigit })
        let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        #expect(bytes == Array(input.utf8))
    }
}
