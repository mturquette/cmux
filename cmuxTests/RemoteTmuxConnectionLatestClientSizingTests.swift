import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The commands a mirror sends to tmux as it stands aside for another client
/// and takes the session back (requirements L1 to L7 of the latest-client
/// sizing change), driven through a connection on a fake control stream.
@MainActor
@Suite struct RemoteTmuxConnectionLatestClientSizingTests {
    private static let me = "/dev/ttys008"
    private static let iterm = "/dev/ttys000"

    private struct Wire {
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
    }

    private func makeWriter(label: String) -> (RemoteTmuxControlPipeWriter, Pipe) {
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: label,
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        return (writer, pipe)
    }

    /// A connected per-session stream with a known client size (120x40) and
    /// per-window sizing live, the state a mirror is in while the user works.
    private func connectedWire(label: String) -> Wire {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@latest-size.test"), sessionName: "work"
        )
        let (writer, pipe) = makeWriter(label: label)
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
        connection.pendingAttachRedrawKick = false
        connection.lastClientSize = (columns: 120, rows: 40)
        return Wire(connection: connection, writer: writer, pipe: pipe)
    }

    private func reattach(_ wire: Wire, label: String) -> Wire {
        wire.writer.close()
        try? wire.pipe.fileHandleForReading.close()
        let (writer, pipe) = makeWriter(label: label)
        wire.connection.installStdinWriterForTesting(writer)
        return Wire(connection: wire.connection, writer: writer, pipe: pipe)
    }

    private func sentCommands(_ wire: Wire) throws -> [String] {
        wire.writer.close()
        let data = try wire.pipe.fileHandleForReading.readToEnd() ?? Data()
        try? wire.pipe.fileHandleForReading.close()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The commands this change sends, in order, ignoring everything else the
    /// stream sends (window lists, pane subscriptions).
    private func sizingCommands(_ wire: Wire) throws -> [String] {
        try sentCommands(wire).filter {
            $0.hasPrefix("refresh-client -f") || $0 == "select-window"
                || $0.hasPrefix("refresh-client -C ") || $0.contains("cmux_clients")
        }
    }

    private func roster(windowSize: String = "latest", itermActivity: Int, focused: Bool = true) -> String {
        "\(Self.me)|\(windowSize)|@3|\(Self.me)/1/1794863536/120//0/1;"
            + "\(Self.iterm)/0/\(itermActivity)/264/47/0/\(focused ? 1 : 0);"
    }

    private func push(_ wire: Wire, _ value: String) {
        wire.connection.handleMessageForTesting(
            .subscriptionChanged(name: RemoteTmuxControlConnection.clientRosterSubscriptionName, value: value)
        )
    }

    /// Puts the connection in the stood-aside state through the real path and
    /// returns a fresh wire so later assertions see only later commands.
    private func standAside(_ wire: Wire) throws -> Wire {
        push(wire, roster(itermActivity: 100))
        push(wire, roster(itermActivity: 101))
        #expect(wire.connection.latestClientSizing.isStandingAside)
        _ = try sentCommands(wire)
        return reattachKeepingState(wire)
    }

    private func reattachKeepingState(_ wire: Wire) -> Wire {
        let (writer, pipe) = makeWriter(label: "latest-size-next")
        wire.connection.installStdinWriterForTesting(writer)
        return Wire(connection: wire.connection, writer: writer, pipe: pipe)
    }

    @Test func subscribesToTheRosterAfterAttach() throws {
        let wire = connectedWire(label: "latest-size-subscribe")
        defer { wire.connection.stop() }
        let commands = try sentCommands(wire)
        #expect(commands.contains(RemoteTmuxControlConnection.clientRosterSubscriptionCommand))
        #expect(!commands.contains("refresh-client -f ignore-size"))
    }

    @Test func theFirstReportIsOnlyABaseline() throws {
        let wire = connectedWire(label: "latest-size-baseline")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        push(next, roster(itermActivity: 100))
        #expect(!next.connection.latestClientSizing.isStandingAside)
        #expect(try sizingCommands(next).isEmpty)
    }

    @Test func anotherClientsUseStandsAsideAndRecalculates() throws {
        let wire = connectedWire(label: "latest-size-stand-aside")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        push(next, roster(itermActivity: 100))
        push(next, roster(itermActivity: 101))
        #expect(next.connection.latestClientSizing.isStandingAside)
        #expect(try sizingCommands(next) == ["refresh-client -f ignore-size", "refresh-client -C 120x40"])
    }

    /// Review F1: with `focus-events on`, switching from iTerm to cmux moves
    /// iTerm's activity through a focus-out, which is not use.
    @Test func aFocusOutInAnotherClientDoesNotStandAside() throws {
        let wire = connectedWire(label: "latest-size-focus-out")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        push(next, roster(itermActivity: 100))
        push(next, roster(itermActivity: 101, focused: false))
        #expect(!next.connection.latestClientSizing.isStandingAside)
        #expect(try sizingCommands(next).isEmpty)
    }

    /// Review F2: a report of a key press in iTerm that tmux delivers after the
    /// user already moved to cmux must not stand cmux aside.
    @Test func aLateReportAfterDirectInputDoesNotStandAside() throws {
        let wire = connectedWire(label: "latest-size-late")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        push(next, roster(itermActivity: 100))
        next.connection.noteUserInputForSizing(windowId: 3)
        push(next, roster(itermActivity: 101))
        #expect(!next.connection.latestClientSizing.isStandingAside)
        #expect(try sizingCommands(next).isEmpty)
    }

    @Test func aReportWellAfterDirectInputStillStandsAside() throws {
        let wire = connectedWire(label: "latest-size-not-late")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        push(next, roster(itermActivity: 100))
        next.connection.latestClientSizing.lastDirectUserInputAt = .now - .seconds(5)
        push(next, roster(itermActivity: 101))
        #expect(next.connection.latestClientSizing.isStandingAside)
    }

    @Test func directInputTakesTheSessionBack() throws {
        let wire = connectedWire(label: "latest-size-take-back")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let aside = try standAside(reattachKeepingState(wire))
        aside.connection.noteUserInputForSizing(windowId: 3)
        #expect(!aside.connection.latestClientSizing.isStandingAside)
        #expect(try sizingCommands(aside) == ["refresh-client -f '!ignore-size'", "select-window"])
    }

    @Test func directInputWhileNotStandingAsideSendsNothing() throws {
        let wire = connectedWire(label: "latest-size-idle-input")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        next.connection.noteUserInputForSizing(windowId: 3)
        next.connection.noteUserInputForSizing(windowId: 3)
        #expect(try sizingCommands(next).isEmpty)
    }

    /// A window tmux holds below this mirror's claim, as when another client
    /// became tmux's latest one without this mirror standing aside (a report
    /// ignored as late, or one that never arrived). Reported 2026-11-21: a split
    /// window claimed at 209x57 stayed at 209x46, and its bottom pane never
    /// reached the bottom of the cmux pane, however much the user typed.
    private func holdWindowBelowClaim(_ wire: Wire, windowSize: String = "latest") {
        push(wire, roster(windowSize: windowSize, itermActivity: 100))
        wire.connection.lastWindowSizes[3] = (209, 57)
        let pane = RemoteTmuxLayoutNode(width: 209, height: 46, x: 0, y: 0, content: .pane(1))
        wire.connection.windowsByID[3] = RemoteTmuxWindow(id: 3, width: 209, height: 46, layout: pane)
    }

    @Test func directInputTakesBackAWindowHeldBelowThisMirrorsClaim() throws {
        let wire = connectedWire(label: "latest-size-shortfall")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        holdWindowBelowClaim(next)

        next.connection.noteUserInputForSizing(windowId: 3)

        #expect(try sizingCommands(next) == ["select-window"])
    }

    @Test func aShortfallIsTakenBackOnceNotOnEveryKey() throws {
        let wire = connectedWire(label: "latest-size-shortfall-once")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        holdWindowBelowClaim(next)

        next.connection.noteUserInputForSizing(windowId: 3)
        next.connection.noteUserInputForSizing(windowId: 3)
        next.connection.noteUserInputForSizing(windowId: 3)

        #expect(try sizingCommands(next) == ["select-window"])
    }

    @Test func aShortfallUnderAnotherWindowSizeSettingIsLeftAlone() throws {
        let wire = connectedWire(label: "latest-size-shortfall-smallest")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        holdWindowBelowClaim(next, windowSize: "smallest")

        next.connection.noteUserInputForSizing(windowId: 3)

        #expect(try sizingCommands(next).isEmpty)
    }

    @Test func leavingWindowSizeLatestRejoinsWithoutClaiming() throws {
        let wire = connectedWire(label: "latest-size-rejoin")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let aside = try standAside(reattachKeepingState(wire))
        push(aside, roster(windowSize: "smallest", itermActivity: 101))
        #expect(!aside.connection.latestClientSizing.isStandingAside)
        #expect(try sizingCommands(aside) == ["refresh-client -f '!ignore-size'", "refresh-client -C 120x40"])
    }

    @Test func otherWindowSizeSettingsNeverStandAside() throws {
        let wire = connectedWire(label: "latest-size-smallest")
        defer { wire.connection.stop() }
        _ = try sentCommands(wire)
        let next = reattachKeepingState(wire)
        push(next, roster(windowSize: "smallest", itermActivity: 100))
        push(next, roster(windowSize: "smallest", itermActivity: 101))
        #expect(!next.connection.latestClientSizing.isStandingAside)
        #expect(try sizingCommands(next).isEmpty)
    }

    /// Review F7: a mirror standing aside reattaches already flagged, and the
    /// fresh client re-sends the flag and its size once attached.
    @Test func aReconnectWhileStandingAsideStaysAside() throws {
        let wire = connectedWire(label: "latest-size-reconnect")
        let aside = try standAside(reattachKeepingState(wire))
        defer { aside.connection.stop() }
        #expect(aside.connection.reconnectAttachMode == .attachIgnoringSize)
        // The mode the reconnect spawn actually uses, once the stream has reached control mode.
        #expect(aside.connection.reconnectSpawnMode == .attachIgnoringSize)
        #expect(RemoteTmuxControlAttachMode.attachIgnoringSize.tmuxArguments(sessionName: "work")
            == ["-CC", "attach-session", "-f", "ignore-size", "-t", "work"])
        aside.connection.beginReconnecting()
        #expect(!aside.connection.latestClientSizing.subscribed)
        let again = reattach(aside, label: "latest-size-reconnect-b")
        again.connection.handleMessageForTesting(.enter)
        // Only the real spawn re-arms the attach-block drain, so the test runs
        // the post-attach step it triggers, as the environment-push tests do.
        again.connection.subscribeClientRoster()
        #expect(again.connection.latestClientSizing.isStandingAside)
        // The reattach also replays the recorded sizes, so only the order of
        // this change's own commands, and the absence of a take-back, matter.
        let commands = try sizingCommands(again)
        let subscribed = try #require(commands.firstIndex(of: RemoteTmuxControlConnection.clientRosterSubscriptionCommand))
        let flagged = try #require(commands.firstIndex(of: "refresh-client -f ignore-size"))
        #expect(flagged > subscribed)
        #expect(commands.suffix(from: flagged).contains("refresh-client -C 120x40"))
        #expect(!commands.contains("refresh-client -f '!ignore-size'"))
        #expect(!commands.contains("select-window"))
    }

    /// Review N1: et types its command into a line-limited pty. A session name
    /// that fits the plain attach but not the flagged one must reconnect with
    /// the plain attach, or every reconnect would be refused before it starts.
    @Test func aLineLimitedTransportFallsBackToThePlainAttachForALongName() {
        let profile = RemoteTmuxETTransportProfile(port: 2022)
        let longest = String(repeating: "s", count: RemoteTmuxETTransportProfile.maxSessionNameBytes(mode: .attach))
        #expect(profile.commandLengthOverrun(sessionName: longest, mode: .attach) == nil)
        #expect(profile.commandLengthOverrun(sessionName: longest, mode: .attachIgnoringSize) != nil)
        let long = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@et.test"), sessionName: longest, transportProfile: profile
        )
        long.latestClientSizing.isStandingAside = true
        #expect(long.reconnectAttachMode == .attach)
        let short = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@et.test"), sessionName: "work", transportProfile: profile
        )
        short.latestClientSizing.isStandingAside = true
        #expect(short.reconnectAttachMode == .attachIgnoringSize)
    }

    @Test func aReconnectWhileNotStandingAsideUsesThePlainAttach() {
        let wire = connectedWire(label: "latest-size-reconnect-plain")
        defer { wire.connection.stop() }
        #expect(wire.connection.reconnectAttachMode == .attach)
    }

    /// Standing aside, the window follows another client on purpose, so the
    /// claim repair must not fight it.
    @Test func standingAsideSuspendsClaimRepair() throws {
        let wire = connectedWire(label: "latest-size-claim-repair")
        defer { wire.connection.stop() }
        wire.connection.lastWindowSizes = [3: (120, 40)]
        wire.connection.sentWindowSizes = [3: (120, 40)]
        _ = try sentCommands(wire)
        let aside = try standAside(reattachKeepingState(wire))
        aside.connection.reassertWindowClaimIfLayoutDisagrees(windowId: 3, layoutColumns: 264, layoutRows: 46)
        // Without the guard the repair spends a re-arm on this window and re-sends its claim.
        #expect(aside.connection.windowClaimParityRearmsSpent[3] == nil)
        #expect(try sentCommands(aside).allSatisfy { !$0.contains("@3:") })
    }
}
