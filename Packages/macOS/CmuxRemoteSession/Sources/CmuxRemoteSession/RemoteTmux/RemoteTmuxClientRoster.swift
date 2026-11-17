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
        /// Whether tmux has the client marked focused.
        public let isFocused: Bool

        public init(
            name: String,
            isControlClient: Bool,
            activity: Int,
            columns: Int,
            rows: Int?,
            ignoresSize: Bool,
            isFocused: Bool = true
        ) {
            self.isFocused = isFocused
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
    /// The session's current window (`@id`), when tmux reported one.
    public let currentWindowId: Int?

    public init(windowSize: String, currentWindowId: Int? = nil, peers: [Peer]) {
        self.windowSize = windowSize
        self.currentWindowId = currentWindowId
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
        let fields = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let selfName = String(fields[0])
        let windowSize = String(fields[1])
        guard !selfName.isEmpty, !windowSize.isEmpty else { return nil }
        let entries = fields[2].split(separator: ";", omittingEmptySubsequences: true)
        guard fields[2].isEmpty || fields[2].hasSuffix(";") else { return nil }
        var peers: [Peer] = []
        var sawSelf = false
        for entry in entries {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            // A client name is a tty path, which itself contains slashes, so
            // the five fixed fields are read from the end.
            guard parts.count >= 6 else { return nil }
            let tail = parts.suffix(5)
            let name = parts.dropLast(5).joined(separator: "/")
            let fields = Array(tail)
            guard !name.isEmpty,
                  let control = Int(fields[0]), control == 0 || control == 1,
                  let activity = Int(fields[1]),
                  let columns = Int(fields[2]),
                  fields[4] == "0" || fields[4] == "1" else { return nil }
            let rows: Int?
            if fields[3].isEmpty {
                rows = nil
            } else {
                guard let parsed = Int(fields[3]) else { return nil }
                rows = parsed
            }
            if name == selfName {
                sawSelf = true
                continue
            }
            peers.append(Peer(
                name: name,
                isControlClient: control == 1,
                activity: activity,
                columns: columns,
                rows: rows,
                ignoresSize: fields[4] == "1"
            ))
        }
        // The subscriber is attached to the session it subscribed on, so a
        // list without it is not a client list.
        guard sawSelf else { return nil }
        self.init(windowSize: windowSize, peers: peers)
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
        var before: [String: Peer] = [:]
        for peer in previous.peers { before[peer.name] = peer }
        for peer in peers {
            guard let old = before[peer.name] else {
                if peer.isControlClient && peer.ignoresSize { continue }
                return true
            }
            if peer.activity > old.activity { return true }
            if !peer.isControlClient, peer.columns != old.columns || peer.rows != old.rows {
                return true
            }
            if peer.isControlClient, old.ignoresSize, !peer.ignoresSize { return true }
        }
        return false
    }
}
