import AppKit
import Bonsplit
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The app side of leaving a legacy scroller's gutter out of a mirror's columns (review F11):
/// the scroll view measures the gutter, and the mirror's layout metrics carry it.
@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorScrollerGutterAppTests {
    /// A pane hosted in an offscreen window, laid out with `scrollerStyle`, as in
    /// `TerminalScrollBarGutterStabilityTests`.
    private func hostedPane(scrollerStyle: NSScroller.Style) -> (NSWindow, GhosttySurfaceScrollView) {
        let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: .zero))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(hostedView)
        hostedView.frame = window.contentView?.bounds ?? .zero
        let scrollView = hostedView.subviews.compactMap { $0 as? GhosttyScrollView }.first
        let preference = scrollerStyle == .legacy ? "Always" : "WhenScrolling"
        scrollView?.showScrollBarsPreference = { preference }
        hostedView.needsLayout = true
        hostedView.layoutSubtreeIfNeeded()
        return (window, hostedView)
    }

    @Test func aLegacyScrollerReportsItsGutterAndAnOverlayScrollerNone() {
        let (legacyWindow, legacy) = hostedPane(scrollerStyle: .legacy)
        let (overlayWindow, overlay) = hostedPane(scrollerStyle: .overlay)
        defer { legacyWindow.close(); overlayWindow.close() }

        #expect(legacy.scrollerGutterWidth == NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
        #expect(overlay.scrollerGutterWidth == 0)
    }

    @Test func theMirrorsLayoutMetricsCarryTheGutter() throws {
        let workspace = Workspace()
        let outerPanelID = try #require(workspace.focusedPanelId)
        defer { workspace.teardownAllPanels() }
        let geometry = RemoteTmuxMirrorGeometry(
            cellWidthPx: 16, cellHeightPx: 34, surfacePadWidthPx: 14, surfacePadHeightPx: 0, scale: 2,
            scrollerGutterWidthPt: 15
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 3,
            panelId: outerPanelID,
            connection: RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@gutter.test"), sessionName: "work"),
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(11)),
            geometrySource: { geometry },
            controlPaneID: { _ in PaneID() },
            makePanel: { [workspace] _ in workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) }
        )
        defer { mirror.teardown() }

        let metrics = try #require(mirror.nativeLayoutMetrics())
        #expect(metrics.surfacePadding.width == 22)
    }
}
