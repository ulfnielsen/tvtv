import XCTest
@testable import TVTVCore

/// Unit tests for the pure, view-independent helpers of the grid render
/// layer. The AppKit rendering itself (row recycling, per-row draw calls,
/// banding shade) is verified visually against the running app, but the two
/// testable pieces are pinned here:
///
/// 1. `GridTableView.drawWindow(...)` — the 300 pt horizontal-overscan math
///    (the visible x-range expanded by overscan, clamped to `[0, totalWidth]`).
/// 2. Its composition with `ColumnLayout.columns(intersecting:)`, which is how
///    a row decides which columns to paint, and the display-order
///    geometry accessors the renderer relies on.
final class GridTableViewTests: XCTestCase {

    // MARK: - drawWindow: 300 pt overscan + clamping

    func test_drawWindow_expandsVisibleRangeBy300OnEachSide() {
        let window = GridTableView.drawWindow(
            visibleMinX: 1000, visibleMaxX: 1500, totalWidth: 10_000
        )
        XCTAssertEqual(window.lowerBound, 700)   // 1000 - 300
        XCTAssertEqual(window.upperBound, 1800)  // 1500 + 300
    }

    func test_drawWindow_usesOverscanConstant() {
        XCTAssertEqual(GridTableView.horizontalOverscan, 300.0)
    }

    func test_drawWindow_clampsLowerBoundToZero() {
        let window = GridTableView.drawWindow(
            visibleMinX: 100, visibleMaxX: 500, totalWidth: 10_000
        )
        XCTAssertEqual(window.lowerBound, 0)     // 100 - 300 -> clamped to 0
        XCTAssertEqual(window.upperBound, 800)
    }

    func test_drawWindow_clampsUpperBoundToTotalWidth() {
        let window = GridTableView.drawWindow(
            visibleMinX: 9600, visibleMaxX: 9900, totalWidth: 10_000
        )
        XCTAssertEqual(window.lowerBound, 9300)
        XCTAssertEqual(window.upperBound, 10_000) // 9900 + 300 -> clamped to total
    }

    func test_drawWindow_visiblePastContentYieldsValidEmptyRange() {
        // Viewport scrolled entirely past the (tiny) content. By design
        // (`newMin = max(wantMinX, 0)`, `newMax = min(wantMaxX, width)`),
        // `lo` is floored only at 0 (not the total), `hi` is capped at total —
        // so `hi < lo`; the helper's `lo...max(lo, hi)` guard keeps it a valid
        // (degenerate) range that selects no columns.
        let window = GridTableView.drawWindow(
            visibleMinX: 5000, visibleMaxX: 6000, totalWidth: 200
        )
        XCTAssertEqual(window.lowerBound, 4700)         // max(0, 5000 - 300)
        XCTAssertEqual(window.upperBound, 4700)         // max(lo, min(200, 6300))
        XCTAssertLessThanOrEqual(window.lowerBound, window.upperBound)
    }

    // MARK: - composition with columns(intersecting:)

    func test_drawWindow_composedWithColumnsIntersecting_selectsOverscannedColumns() {
        // 20 columns of width 100 -> x = 0,100,...,1900; total 2000.
        let layout = ColumnLayout(
            widths: Array(repeating: 100, count: 20),
            order: Array(0..<20)
        )
        // Viewport shows x in [1000, 1400]. With ±300 overscan the window is
        // [700, 1700]. Per ColumnLayout's ClosedRange boundary-touch semantics,
        // column 6 ([600,700], right edge touches 700) and column 17
        // ([1700,1800], left edge touches 1700) count as intersecting, so the
        // selected display-index range is 6..<18.
        let window = GridTableView.drawWindow(
            visibleMinX: 1000, visibleMaxX: 1400, totalWidth: layout.totalContentWidth
        )
        let cols = layout.columns(intersecting: window)
        XCTAssertEqual(cols, 6..<18)
    }

    // MARK: - ColumnLayout display-order accessors (added for the renderer)

    func test_columnCount_matchesNumberOfColumns() {
        let layout = ColumnLayout(widths: [100, 150, 80, 200], order: [2, 0, 3, 1])
        XCTAssertEqual(layout.columnCount, 4)
    }

    func test_displayWidths_areInDisplayOrderNotSourceOrder() {
        // source widths [100,150,80,200], display order [2,0,3,1]
        let layout = ColumnLayout(widths: [100, 150, 80, 200], order: [2, 0, 3, 1])
        XCTAssertEqual(layout.displayWidths, [80, 100, 200, 150])
    }

    func test_displayWidths_prefixSumMatchesXPosition() {
        let layout = ColumnLayout(widths: [100, 150, 80, 200], order: [2, 0, 3, 1])
        var running: CGFloat = 0
        for (i, w) in layout.displayWidths.enumerated() {
            XCTAssertEqual(layout.xPosition(displayIndex: i), running, accuracy: 0.0001)
            running += w
        }
        XCTAssertEqual(running, layout.totalContentWidth, accuracy: 0.0001)
    }
}
