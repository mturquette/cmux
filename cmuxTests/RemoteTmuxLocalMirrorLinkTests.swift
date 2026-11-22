import Bonsplit
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A path or `file://` link printed in a local mirror pane names a file on this Mac, so
/// Command-click opens it the way it would in an ordinary local terminal (a Markdown file
/// opens in cmux's Markdown viewer). In an ssh or et mirror the pane runs on another
/// machine, and its links are still never opened against this Mac's files.
@MainActor
@Suite(.serialized) struct RemoteTmuxLocalMirrorLinkTests {
    @MainActor
    private struct Mirrored {
        let workspace: Workspace
        let outerPanelID: UUID
        let mirror: RemoteTmuxWindowMirror
        let paneSurfaceID: UUID
        /// Held here because a window mirror keeps its connection weakly.
        let connection: RemoteTmuxControlConnection

        func tearDown() {
            workspace.setRemoteTmuxWindowMirror(nil, forPanelId: outerPanelID)
            workspace.isRemoteTmuxMirror = false
            mirror.teardown()
            workspace.teardownAllPanels()
        }
    }

    private func mirrored(host: RemoteTmuxHost) throws -> Mirrored {
        let workspace = Workspace()
        let outerPanelID = try #require(workspace.focusedPanelId)
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let paneIDs = [11: PaneID()]
        let geometry = RemoteTmuxMirrorGeometry(
            cellWidthPx: 16, cellHeightPx: 34, surfacePadWidthPx: 8, surfacePadHeightPx: 8, scale: 2
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 3,
            panelId: outerPanelID,
            connection: connection,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(11)),
            geometrySource: { geometry },
            controlPaneID: { paneIDs[$0] },
            makePanel: { [workspace] _ in workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) }
        )
        workspace.isRemoteTmuxMirror = true
        workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: outerPanelID)
        let paneSurfaceID = try #require(mirror.controlPanes().first?.panel.id)
        return Mirrored(
            workspace: workspace, outerPanelID: outerPanelID, mirror: mirror,
            paneSurfaceID: paneSurfaceID, connection: connection
        )
    }

    @Test func aLocalMirrorPanesLinksOpenOnThisMac() throws {
        let local = try mirrored(host: RemoteTmuxHost(
            destination: "local", transport: .local, serverSocketPath: "/tmp/tmux-501/default"
        ))
        defer { local.tearDown() }

        #expect(local.workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: local.paneSurfaceID))
        #expect(!local.workspace.terminalLinkIsRemoteTerminal(local.paneSurfaceID))
    }

    @Test(arguments: [RemoteTmuxTransportKind.ssh, .et])
    func aRemoteMirrorPanesLinksStayRemote(transport: RemoteTmuxTransportKind) throws {
        let remote = try mirrored(host: RemoteTmuxHost(destination: "user@petit", transport: transport))
        defer { remote.tearDown() }

        #expect(!remote.workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: remote.paneSurfaceID))
        #expect(remote.workspace.terminalLinkIsRemoteTerminal(remote.paneSurfaceID))
    }
}
