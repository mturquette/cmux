import CmuxRemoteSession
import Testing

/// Requirements L1, L5 and L6 of the latest-client sizing fix, at the level of
/// the roster value tmux pushes: which changes mean the user used another
/// client, and which do not.
@Suite struct RemoteTmuxClientRosterTests {
    private static let me = "/dev/ttys008"
    private static let iterm = "/dev/ttys000"
    private static let otherMirror = "/dev/ttys012"

    /// One roster value as tmux 3.6a prints it for ``RemoteTmuxClientRoster/subscriptionFormat``.
    private static func value(
        windowSize: String = "latest",
        selfIgnores: Bool = false,
        entries: [String]
    ) -> String {
        let selfEntry = "\(me)/1/1794863536/204//\(selfIgnores ? 1 : 0);"
        return "\(me)|\(windowSize)|" + selfEntry + entries.joined()
    }

    private static func normal(_ name: String = iterm, activity: Int, columns: Int = 264, rows: Int = 47) -> String {
        "\(name)/0/\(activity)/\(columns)/\(rows)/0;"
    }

    private static func mirror(_ name: String = otherMirror, activity: Int = 1794860000, ignores: Bool) -> String {
        "\(name)/1/\(activity)/160//\(ignores ? 1 : 0);"
    }

    private static func roster(_ value: String) throws -> RemoteTmuxClientRoster {
        try #require(RemoteTmuxClientRoster(subscriptionValue: value))
    }

    // MARK: - Reading the value

    @Test func readsTheOwnerObservedRosterAndLeavesTheSubscriberOut() throws {
        let roster = try Self.roster(Self.value(entries: [
            Self.normal("/dev/ttys002", activity: 1794783788, columns: 180, rows: 40),
            Self.normal(activity: 1794863912),
        ]))
        #expect(roster.followsLatestClient)
        #expect(roster.peers.map(\.name) == ["/dev/ttys002", Self.iterm])
        #expect(roster.peers[1] == RemoteTmuxClientRoster.Peer(
            name: Self.iterm, isControlClient: false, activity: 1794863912,
            columns: 264, rows: 47, ignoresSize: false
        ))
    }

    @Test func readsAControlPeerWithNoHeightAndItsIgnoreSizeFlag() throws {
        let roster = try Self.roster(Self.value(entries: [Self.mirror(ignores: true)]))
        let peer = try #require(roster.peers.first)
        #expect(peer.isControlClient)
        #expect(peer.rows == nil)
        #expect(peer.ignoresSize)
    }

    @Test func aSessionWithOnlyTheMirrorHasNoPeers() throws {
        #expect(try Self.roster(Self.value(entries: [])).peers.isEmpty)
    }

    @Test func otherWindowSizeSettingsDoNotFollowTheLatestClient() throws {
        for setting in ["smallest", "largest", "manual"] {
            #expect(try !Self.roster(Self.value(windowSize: setting, entries: [])).followsLatestClient)
        }
    }

    /// tmux before 3.4 has no `L:` loop, and anything else malformed must not
    /// be mistaken for a client list.
    @Test func rejectsValuesWithoutAUsableClientList() {
        let rejected = [
            "",
            "\(Self.me)|latest|",
            "\(Self.me)|latest",
            "|latest|\(Self.me)/1/1/204//0;",
            "\(Self.me)||\(Self.me)/1/1/204//0;",
            "\(Self.me)|latest|\(Self.me)/1/1/204//0",
            "\(Self.me)|latest|\(Self.me)/1/1/204//2;",
            "\(Self.me)|latest|\(Self.me)/x/1/204//0;",
            "\(Self.me)|latest|\(Self.me)/1/1/204/;",
            "\(Self.me)|latest|\(Self.iterm)/0/1/264/47/0;",
        ]
        for value in rejected {
            #expect(RemoteTmuxClientRoster(subscriptionValue: value) == nil, "accepted \(value)")
        }
    }

    // MARK: - What counts as using another client

    @Test func aKeyPressInAnotherClientCounts() throws {
        let before = try Self.roster(Self.value(entries: [Self.normal(activity: 100)]))
        let after = try Self.roster(Self.value(entries: [Self.normal(activity: 101)]))
        #expect(after.showsUseOfAnotherClient(since: before))
    }

    @Test func resizingAnotherClientsTerminalCounts() throws {
        let before = try Self.roster(Self.value(entries: [Self.normal(activity: 100, columns: 264, rows: 47)]))
        let wider = try Self.roster(Self.value(entries: [Self.normal(activity: 100, columns: 300, rows: 47)]))
        let taller = try Self.roster(Self.value(entries: [Self.normal(activity: 100, columns: 264, rows: 60)]))
        #expect(wider.showsUseOfAnotherClient(since: before))
        #expect(taller.showsUseOfAnotherClient(since: before))
    }

    @Test func aClientAttachingCounts() throws {
        let before = try Self.roster(Self.value(entries: []))
        let after = try Self.roster(Self.value(entries: [Self.normal(activity: 100)]))
        #expect(after.showsUseOfAnotherClient(since: before))
    }

    @Test func anotherMirrorTakingTheSessionBackCounts() throws {
        let before = try Self.roster(Self.value(entries: [Self.mirror(ignores: true)]))
        let after = try Self.roster(Self.value(entries: [Self.mirror(ignores: false)]))
        #expect(after.showsUseOfAnotherClient(since: before))
    }

    @Test func aFreshMirrorAttachingCounts() throws {
        let before = try Self.roster(Self.value(entries: []))
        let after = try Self.roster(Self.value(entries: [Self.mirror(ignores: false)]))
        #expect(after.showsUseOfAnotherClient(since: before))
    }

    @Test func aMirrorThatAttachesAlreadyStandingAsideDoesNotCount() throws {
        let before = try Self.roster(Self.value(entries: []))
        let after = try Self.roster(Self.value(entries: [Self.mirror(ignores: true)]))
        #expect(!after.showsUseOfAnotherClient(since: before))
    }

    @Test func anotherMirrorStandingAsideDoesNotCount() throws {
        let before = try Self.roster(Self.value(entries: [Self.mirror(ignores: false)]))
        let after = try Self.roster(Self.value(entries: [Self.mirror(ignores: true)]))
        #expect(!after.showsUseOfAnotherClient(since: before))
    }

    @Test func aClientDetachingDoesNotCount() throws {
        let before = try Self.roster(Self.value(entries: [Self.normal(activity: 100)]))
        let after = try Self.roster(Self.value(entries: []))
        #expect(!after.showsUseOfAnotherClient(since: before))
    }

    /// The subscriber's own flag changes (standing aside, taking the session
    /// back) are the mirror's own doing and must never read as someone else's use.
    @Test func theMirrorsOwnChangesNeverCount() throws {
        let entries = [Self.normal(activity: 100)]
        let before = try Self.roster(Self.value(selfIgnores: false, entries: entries))
        let after = try Self.roster(Self.value(selfIgnores: true, entries: entries))
        #expect(!after.showsUseOfAnotherClient(since: before))
        #expect(!before.showsUseOfAnotherClient(since: after))
    }

    @Test func anUnchangedRosterDoesNotCount() throws {
        let roster = try Self.roster(Self.value(entries: [Self.normal(activity: 100), Self.mirror(ignores: true)]))
        #expect(!roster.showsUseOfAnotherClient(since: roster))
    }
}
