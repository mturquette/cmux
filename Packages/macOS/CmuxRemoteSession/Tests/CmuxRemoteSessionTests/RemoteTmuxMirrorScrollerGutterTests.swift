import Foundation
import Testing
@testable import CmuxRemoteSession

/// A mirror's client size leaves room for a legacy scroller.
///
/// With "Show scroll bars: Always" (or a mouse without a trackpad), the terminal's
/// vertical scroller is a legacy one that takes a gutter from the visible width. The
/// mirror sized tmux from the full pane width, so the rightmost column was drawn under
/// the gutter and could not be seen. Reported on a 1680-point pane with 8-point cells:
/// cmux claimed 209 columns, and the 209th was hidden.
@Suite struct RemoteTmuxMirrorScrollerGutterTests {
    private let pane = RemoteTmuxLayoutNode(width: 10, height: 10, x: 0, y: 0, content: .pane(1))

    private func geometry(gutter: CGFloat) -> RemoteTmuxMirrorGeometry {
        RemoteTmuxMirrorGeometry(
            cellWidthPx: 16,
            cellHeightPx: 34,
            surfacePadWidthPx: 14,
            surfacePadHeightPx: 0,
            scale: 2,
            scrollerGutterWidthPt: gutter
        )
    }

    private func columns(_ geometry: RemoteTmuxMirrorGeometry, paneWidth: CGFloat) -> Int? {
        RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(
                width: CGFloat(geometry.cellWidthPx) / geometry.scale,
                height: CGFloat(geometry.cellHeightPx) / geometry.scale
            ),
            surfacePadding: geometry.surfacePaddingPt,
            tabBarHeight: 0,
            dividerThickness: 1
        ).clientGrid(layout: pane, contentSize: CGSize(width: paneWidth, height: 1024))?.columns
    }

    @Test func aLegacyScrollerGutterIsPartOfEachPanesChrome() {
        #expect(geometry(gutter: 15).surfacePaddingPt == CGSize(width: 22, height: 0))
    }

    // The reported case: every claimed column must fit beside the 15-point gutter.
    @Test func theClaimLeavesTheRightmostColumnVisibleBesideTheGutter() throws {
        let claimed = try #require(columns(geometry(gutter: 15), paneWidth: 1680))
        #expect(claimed == 207)
        let visibleWidth: CGFloat = 1680 - 15
        #expect(CGFloat(claimed) * 8 + 7 <= visibleWidth)
    }

    // Review F10: the one points-to-cells model, which the debug parity check uses, agrees with
    // the claim beside a gutter.
    @Test func theRenderedCellsModelLeavesTheGutterOut() {
        let g = geometry(gutter: 15)
        let rendered = RemoteTmuxNativeLayoutMetrics.renderedCells(
            outer: CGSize(width: 1680, height: 1024),
            tabBarHeight: 0,
            scale: g.scale,
            surfacePadPx: (width: g.surfacePadWidthPx, height: g.surfacePadHeightPx),
            cellPx: (width: g.cellWidthPx, height: g.cellHeightPx),
            scrollerGutterPt: g.scrollerGutterWidthPt
        )
        #expect(rendered.columns == 207)
    }

    // An overlay scroller takes no width, so the claim is what it was.
    @Test func anOverlayScrollerChangesNothing() {
        #expect(geometry(gutter: 0).surfacePaddingPt == CGSize(width: 7, height: 0))
        #expect(columns(geometry(gutter: 0), paneWidth: 1680) == 209)
    }
}
