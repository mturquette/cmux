import CmuxRemoteSession
import Foundation

/// Keeps `window-size latest` meaningful while a mirror shares a session with
/// other tmux clients.
///
/// tmux sizes a window to the client the user used last, but it applies a
/// control client's per-window size (`refresh-client -C @id:WxH`) as a ceiling
/// whichever client that is. Left alone, the mirror's per-window sizes clip
/// every other client to the mirror's size. So when another client is used
/// the mirror stands aside with tmux's own `ignore-size` client flag, and it
/// takes the session back only on its user's own keyboard or paste input.
///
/// Only the session's `window-size latest` setting triggers any of this; under
/// `smallest`, `largest` or `manual` the mirror behaves as before. Nothing here
/// changes a server, session or window option, or another client's flags.
extension RemoteTmuxControlConnection {
    /// The session-scoped subscription that reports the session's clients
    /// (see ``RemoteTmuxClientRoster/subscriptionFormat``). tmux evaluates it at
    /// most once a second and pushes it only when the value changes.
    static let clientRosterSubscriptionName = "cmux_clients"

    static var clientRosterSubscriptionCommand: String {
        "refresh-client -B '\(clientRosterSubscriptionName)::\(RemoteTmuxClientRoster.subscriptionFormat)'"
    }

    /// Subscribes to the session's client roster after an attach or reattach.
    ///
    /// A mirror that had stood aside before a reconnect stands aside again on
    /// the new client: reattaching is not the user using this mirror, and
    /// tmux makes every newly attached client its latest one.
    func subscribeClientRoster() {
        guard !isSharedViewStream, !clientRosterSubscribed else { return }
        clientRosterSubscribed = true
        clientRoster = nil
        send(Self.clientRosterSubscriptionCommand)
        if isStandingAsideForOtherClient {
            send("refresh-client -f ignore-size")
            nudgeSizeRecalculation()
        }
    }

    /// A ``clientRosterSubscriptionName`` push.
    func handleClientRoster(_ value: String) {
        guard let roster = RemoteTmuxClientRoster(subscriptionValue: value) else {
            // A server without the client loop (before tmux 3.4) also has no
            // per-window sizes, so tmux's own latest-client rule already holds.
            clientRoster = nil
            return
        }
        let previous = clientRoster
        clientRoster = roster
        if isStandingAsideForOtherClient, !roster.followsLatestClient {
            // The user switched the session away from `latest`: take part in
            // sizing again as that setting expects, without claiming activity.
            isStandingAsideForOtherClient = false
            record("latest-size rejoin window-size=\(roster.windowSize)")
            send("refresh-client -f '!ignore-size'")
            nudgeSizeRecalculation()
            return
        }
        guard let previous,
              roster.followsLatestClient,
              supportsPerWindowSize,
              !isStandingAsideForOtherClient,
              roster.showsUseOfAnotherClient(since: previous) else { return }
        isStandingAsideForOtherClient = true
        record("latest-size stand-aside")
        send("refresh-client -f ignore-size")
        nudgeSizeRecalculation()
    }

    /// Takes the session back after the user typed or pasted into one of this
    /// mirror's panes. Does nothing unless the mirror had stood aside, so the
    /// typing path costs one comparison.
    ///
    /// `select-window` with no target selects the session's current window,
    /// which leaves the current window where it is and makes this client the
    /// window's latest one: the same thing a key press in a normal client does.
    func noteUserInputForSizing() {
        guard isStandingAsideForOtherClient, connectionState == .connected else { return }
        isStandingAsideForOtherClient = false
        record("latest-size take-back")
        send("refresh-client -f '!ignore-size'")
        send("select-window")
    }

    /// tmux does not recompute window sizes when a client's flags change, so
    /// re-send the client size the mirror already holds. This asks for nothing
    /// new; it only makes tmux apply the flag now rather than at the next key press.
    private func nudgeSizeRecalculation() {
        guard let size = lastClientSize else { return }
        send("refresh-client -C \(size.columns)x\(size.rows)")
    }
}
