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
    ///
    /// A host's wake behavior comes from its first stream's transport profile; every stream of
    /// one host shares its transport, since the transport is part of ``RemoteTmuxHost/connectionHash``.
    static func wakeHostGroups(for connections: [RemoteTmuxControlConnection]) -> [RemoteTmuxWakeHostGroup] {
        var order: [String] = []
        var byHost: [String: [RemoteTmuxControlConnection]] = [:]
        var seen = Set<ObjectIdentifier>()
        for connection in connections where seen.insert(ObjectIdentifier(connection)).inserted {
            let key = connection.host.connectionHash
            if byHost[key] == nil { order.append(key) }
            byHost[key, default: []].append(connection)
        }
        return order.compactMap { key in
            guard let streams = byHost[key], let first = streams.first else { return nil }
            return RemoteTmuxWakeHostGroup(
                host: first.host,
                recovery: first.transportProfile.wakeRecovery,
                streams: streams
            )
        }
    }
}
