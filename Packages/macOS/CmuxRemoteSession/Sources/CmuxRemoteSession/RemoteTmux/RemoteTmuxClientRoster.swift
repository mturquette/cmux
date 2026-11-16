import Foundation

/// The tmux clients attached to a mirrored session, as one control-mode
/// subscription reports them.
///
/// tmux's `window-size latest` sizes a window to the client that last typed,
/// focused, resized its terminal, or attached. A control client's per-window
/// size (`refresh-client -C @id:WxH`) is not part of that choice: tmux applies
/// it as a ceiling on top of whatever size the latest client asked for. A
/// mirror that keeps its per-window sizes while another client is in use
/// therefore clips that client's window to the mirror's size. This roster lets
/// the mirror see when another client has been used, so it can step out of
/// sizing until the user comes back to it.
///
/// The value comes from ``subscriptionFormat``, which tmux 3.4 and later
/// expand (the `L:` client loop is new in 3.4, the same release that added
/// per-window sizes). Older servers produce a value without a usable client
/// list, and ``init(subscriptionValue:)`` returns `nil` for it.
public struct RemoteTmuxClientRoster: Equatable, Sendable {
    /// One other client attached to the same session.
    public struct Peer: Equatable, Sendable {
        /// tmux's client name, normally the client's tty path.
        public let name: String
        /// Whether the client is a control-mode client (another mirror, or iTerm2's tmux mode).
        public let isControlClient: Bool
        /// `client_activity`: the second of the client's last key press or focus event.
        public let activity: Int
        /// The client's terminal width in cells.
        public let columns: Int
        /// The client's terminal height in cells; tmux reports none for control clients.
        public let rows: Int?
        /// Whether the client has set tmux's `ignore-size` flag.
        public let ignoresSize: Bool

        public init(
            name: String,
            isControlClient: Bool,
            activity: Int,
            columns: Int,
            rows: Int?,
            ignoresSize: Bool
        ) {
            self.name = name
            self.isControlClient = isControlClient
            self.activity = activity
            self.columns = columns
            self.rows = rows
            self.ignoresSize = ignoresSize
        }
    }

    /// The `window-size` option in effect for the session's current window.
    public let windowSize: String
    /// The other clients attached to the session, in tmux's order. The
    /// subscribing client itself is never listed.
    public let peers: [Peer]

    public init(windowSize: String, peers: [Peer]) {
        self.windowSize = windowSize
        self.peers = peers
    }

    /// The `refresh-client -B` format whose value ``init(subscriptionValue:)``
    /// reads: the subscriber's own client name, the `window-size` option, then
    /// one `;`-terminated entry per client attached to the same session.
    ///
    /// Client names are tty paths or `client-<pid>`, so they never contain the
    /// separators. The session is compared inside tmux, so a session name never
    /// appears in the value.
    public static let subscriptionFormat =
        "#{client_name}|#{window-size}|#{L:#{?#{==:#{client_session},#{session_name}},"
        + "#{client_name}/#{client_control_mode}/#{client_activity}/#{client_width}/#{client_height}/"
        + "#{?#{m:*ignore-size*,#{client_flags}},1,0};,}}"

    /// Reads a value produced by ``subscriptionFormat``.
    ///
    /// Returns `nil` for a value that does not have the expected shape, which
    /// is what a server older than 3.4 produces: the caller then treats the
    /// server as one where it cannot tell which client is in use.
    public init?(subscriptionValue value: String) {
        return nil
    }

    /// Whether the session's current window is sized by `window-size latest`.
    public var followsLatestClient: Bool {
        windowSize == "latest"
    }

    /// Whether this roster shows that the user used another client since
    /// `previous` was reported, which makes that client tmux's latest one.
    ///
    /// Counts what tmux itself counts: a key press or focus event (the
    /// client's activity time moved), a normal client's terminal resize, and a
    /// client attaching. Another mirror counts when it clears `ignore-size`,
    /// which is how a mirror takes the session back on its user's input. A
    /// mirror that attaches already ignoring sizes, or that starts ignoring
    /// them, does not count, and neither does a client detaching.
    public func showsUseOfAnotherClient(since previous: RemoteTmuxClientRoster) -> Bool {
        false
    }
}
