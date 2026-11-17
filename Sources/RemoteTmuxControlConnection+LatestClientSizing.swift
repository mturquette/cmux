import CmuxRemoteSession
import Foundation

/// What a connection keeps for ``RemoteTmuxControlConnection`` latest-client sizing.
struct RemoteTmuxLatestClientSizingState {
    /// Whether the session's client roster subscription is live on this client.
    var subscribed = false
    /// The last roster tmux pushed, the baseline the next one is compared with.
    var roster: RemoteTmuxClientRoster?
    /// Whether this mirror has set tmux's `ignore-size` flag because the user
    /// used another client. Kept across reconnects.
    var isStandingAside = false
    /// When the user last gave this mirror direct input (see
    /// ``RemoteTmuxControlConnection/noteUserInputForSizing(windowId:)``).
    var lastDirectUserInputAt: ContinuousClock.Instant?
}

/// Keeps `window-size latest` meaningful while a mirror shares a session with
/// other tmux clients.
///
/// tmux sizes a window to the client the user used last, but it applies a
/// control client's per-window size (`refresh-client -C @id:WxH`) as a ceiling
/// whichever client that is. Left alone, the mirror's per-window sizes clip
/// every other client to the mirror's size. So when another client is used
/// the mirror stands aside with tmux's own `ignore-size` client flag, and it
/// takes the session back only on its user's own input (keys, text, paste,
/// a click, or switching to cmux).
///
/// Only the session's `window-size latest` setting triggers any of this; under
/// `smallest`, `largest` or `manual` the mirror behaves as before. Nothing here
/// changes a server, session or window option, or another client's flags.
///
/// Limits, all from tmux itself:
/// - tmux keeps a latest client per window and updates it only for the
///   session's current window. Taking the session back makes this mirror the
///   latest client of tmux's current window, which can differ from the tab the
///   user is in; other windows keep the client that was latest when they were
///   last current. Becoming latest for a window that is not current would mean
///   switching the current window for every client, so it is not done.
/// - Taking the session back sends `select-window`, which runs the user's
///   `after-select-window` hook if one is set. No other command makes a control
///   client latest; `switch-client` to the same session also does, but fires
///   `client-session-changed`.
/// - A user of iTerm2's tmux integration is a control client whose typing
///   never moves its activity time, so this mirror does not see it as used.
extension RemoteTmuxControlConnection {
    /// The session-scoped subscription that reports the session's clients
    /// (see ``RemoteTmuxClientRoster/subscriptionFormat``). tmux evaluates it at
    /// most once a second and pushes it only when the value changes.
    static let clientRosterSubscriptionName = "cmux_clients"

    static var clientRosterSubscriptionCommand: String {
        "refresh-client -B '\(clientRosterSubscriptionName)::\(RemoteTmuxClientRoster.subscriptionFormat)'"
    }

    /// How long after direct input to this mirror a roster report of another
    /// client's use is taken to be older than that input. tmux checks
    /// subscriptions once a second and reports activity in whole seconds, so a
    /// key press in another terminal just before the user switched here can
    /// arrive up to about a second later. A real later use of the other client
    /// is reported again on its next key press, so ignoring one costs little.
    ///
    /// Two costs, both accepted: when two people type at once, one here and one
    /// in another terminal, this mirror keeps the window while its person keeps
    /// typing; and when the user types here and switches to another terminal
    /// within the window only to read, that terminal stays at this mirror's
    /// size until its first key press.
    static let lateRosterReportWindow: Duration = .milliseconds(1500)

    /// Subscribes to the session's client roster after an attach or reattach.
    ///
    /// A mirror that had stood aside reattaches with `ignore-size` already set
    /// (see ``reconnectAttachMode``); the flag is sent again here in case the
    /// server dropped it, and the size is re-sent so tmux applies it.
    func subscribeClientRoster() {
        guard !isSharedViewStream, !latestClientSizing.subscribed else { return }
        latestClientSizing.subscribed = true
        latestClientSizing.roster = nil
        send(Self.clientRosterSubscriptionCommand)
        if latestClientSizing.isStandingAside {
            send("refresh-client -f ignore-size")
            nudgeSizeRecalculation()
        }
    }

    /// A ``clientRosterSubscriptionName`` push.
    func handleClientRoster(_ value: String) {
        guard let roster = RemoteTmuxClientRoster(subscriptionValue: value) else {
            // A server without the client loop (before tmux 3.4) also has no
            // per-window sizes, so tmux's own latest-client rule already holds.
            latestClientSizing.roster = nil
            return
        }
        let previous = latestClientSizing.roster
        latestClientSizing.roster = roster
        if latestClientSizing.isStandingAside, !roster.followsLatestClient {
            // The user switched the session away from `latest`: take part in
            // sizing again as that setting expects, without claiming activity.
            latestClientSizing.isStandingAside = false
            note("latest-size rejoin window-size=\(roster.windowSize)")
            send("refresh-client -f '!ignore-size'")
            nudgeSizeRecalculation()
            return
        }
        guard let previous,
              roster.followsLatestClient,
              supportsPerWindowSize,
              !latestClientSizing.isStandingAside,
              roster.showsUseOfAnotherClient(since: previous) else { return }
        if let input = latestClientSizing.lastDirectUserInputAt,
           ContinuousClock.now - input < Self.lateRosterReportWindow {
            note("latest-size late-report-ignored")
            return
        }
        latestClientSizing.isStandingAside = true
        note("latest-size stand-aside")
        send("refresh-client -f ignore-size")
        nudgeSizeRecalculation()
    }

    /// Records direct user input to one of this mirror's panes and, when the
    /// mirror had stood aside, takes the session back. Costs one comparison
    /// otherwise, so it is safe on the typing path.
    ///
    /// `select-window` with no target selects the session's current window,
    /// which leaves the current window where it is and makes this client the
    /// window's latest one: the same thing a key press in a normal client does.
    ///
    /// - Parameter windowId: The tmux window of the pane that got the input.
    func noteUserInputForSizing(windowId: Int?) {
        latestClientSizing.lastDirectUserInputAt = .now
        guard latestClientSizing.isStandingAside, connectionState == .connected else { return }
        latestClientSizing.isStandingAside = false
        if let windowId, let current = latestClientSizing.roster?.currentWindowId, windowId != current {
            note("latest-size take-back @\(windowId); only tmux's current window @\(current) follows this mirror")
        } else {
            note("latest-size take-back")
        }
        send("refresh-client -f '!ignore-size'")
        send("select-window")
    }

    /// The mode a reconnect spawns with: the attach mode below once the stream
    /// has reached control mode, otherwise the mode the connection was opened with.
    var reconnectSpawnMode: RemoteTmuxControlAttachMode {
        everReachedControlMode ? reconnectAttachMode : attachMode
    }

    /// The attach mode for a reconnect: a mirror standing aside comes back with
    /// `ignore-size` already set, so another mirror never sees it as a fresh,
    /// unflagged client and stands aside for it by mistake.
    ///
    /// A transport that types its command into a line-limited terminal (et)
    /// may not fit the longer flagged command for a very long session name; it
    /// then reconnects with the plain attach, which the socket boundary already
    /// checked, and the flag follows right after the attach.
    var reconnectAttachMode: RemoteTmuxControlAttachMode {
        guard latestClientSizing.isStandingAside,
              transportProfile.commandLengthOverrun(sessionName: sessionName, mode: .attachIgnoringSize) == nil
        else { return .attach }
        return .attachIgnoringSize
    }

    /// tmux does not recompute window sizes when a client's flags change, so
    /// re-send the client size the mirror already holds. This asks for nothing
    /// new; it only makes tmux apply the flag now rather than at the next key press.
    private func nudgeSizeRecalculation() {
        guard let size = lastClientSize else { return }
        send("refresh-client -C \(size.columns)x\(size.rows)")
    }

    private func note(_ event: String) {
        record(event)
        #if DEBUG
        cmuxDebugLog("remote.\(event)")
        #endif
    }
}
