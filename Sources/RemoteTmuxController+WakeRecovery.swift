import Foundation

extension RemoteTmuxController {
    /// Starts wake recovery for every mirrored stream, grouped by host.
    ///
    /// - Returns: the recoveries started, so a caller can await them.
    @discardableResult
    func recoverMirrorsAfterSystemWake() -> [Task<Void, Never>] {
        wakeRecovery.recover(Self.wakeHostGroups(for: liveControlConnections()))
    }

    /// Every live control stream: per-session connections and each host's shared view connection.
    func liveControlConnections() -> [RemoteTmuxControlConnection] {
        Array(connectionsByHostSession.values) + multiplexedViewsByHost.values.compactMap(\.connection)
    }

    /// Groups streams by host, in order of first appearance, with each object listed once.
    static func wakeHostGroups(for connections: [RemoteTmuxControlConnection]) -> [RemoteTmuxWakeHostGroup] {
        []
    }
}
