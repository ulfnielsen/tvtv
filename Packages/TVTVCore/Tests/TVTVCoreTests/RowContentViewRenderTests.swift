import XCTest
import AppKit
@testable import TVTVCore

/// Headless render verification for the two drawing views. These
/// render into an offscreen bitmap in-process (no Screen Recording permission
/// needed) and inspect pixels, proving the behaviors that pure logic tests
/// can't reach:
///
/// - `RowContentView` actually paints columns **inside** the horizontal
///   draw-window and paints **nothing** for columns outside it (the marquee
///   feature: per-row horizontal culling to `[drawnMinX, drawnMaxX]`).
/// - `GrayRowView` draws a *different* background for alternate rows (banding).
///
/// The exact banding *shade* and NULL glyph rendering still benefit from
/// eyes-on comparison; banding is otherwise verified only by construction —
/// it uses the same system `alternatingContentBackgroundColors`.
@MainActor
final class RowContentViewRenderTests: XCTestCase {

    private func render(_ view: NSView) -> NSBitmapImageRep {
        view.appearance = NSAppearance(named: .aqua) // deterministic light mode
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Max alpha across a vertical strip `[xFrac0, xFrac1)` of the rep's width.
    private func maxAlpha(_ rep: NSBitmapImageRep, xFrac0: CGFloat, xFrac1: CGFloat) -> CGFloat {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let x0 = max(0, Int(CGFloat(w) * xFrac0))
        let x1 = min(w, max(x0 + 1, Int(CGFloat(w) * xFrac1)))
        var maxA: CGFloat = 0
        for x in x0..<x1 {
            for y in 0..<h {
                if let color = rep.colorAt(x: x, y: y) {
                    maxA = max(maxA, color.alphaComponent)
                }
            }
        }
        return maxA
    }

    func test_rowContentView_drawsInsideWindow_andNothingOutsideWindow() {
        // 20 columns × 100 pt → x = 0,100,…,1900; total 2000.
        let layout = ColumnLayout(widths: Array(repeating: 100, count: 20), order: Array(0..<20))
        let view = RowContentView()
        view.frame = NSRect(x: 0, y: 0, width: layout.totalContentWidth, height: 20)
        view.columnLayout = layout
        view.columnWidths = layout.displayWidths
        view.columnXPositions = (0..<layout.columnCount).map { layout.xPosition(displayIndex: $0) }
        view.values = (0..<20).map { .text("v\($0)") }
        // Draw-window covers columns ~7–9 only.
        view.drawnMinX = 700
        view.drawnMaxX = 900

        let rep = render(view)

        // Column 0 (x 0–100 → frac 0.0–0.05) is OUTSIDE the window: nothing drawn.
        let outsideAlpha = maxAlpha(rep, xFrac0: 0.0, xFrac1: 0.045)
        // Column 8 (x 800–900 → frac 0.40–0.45) is INSIDE the window: text + grid line.
        let insideAlpha = maxAlpha(rep, xFrac0: 0.40, xFrac1: 0.45)

        XCTAssertLessThan(outsideAlpha, 0.01, "columns outside the draw-window must not be painted")
        XCTAssertGreaterThan(insideAlpha, 0.1, "columns inside the draw-window must be painted")
    }

    /// Fraction of x-pixel-columns within `[xFrac0, xFrac1)` that contain at
    /// least one inked pixel (alpha above `alphaThreshold`) — a rough "how
    /// much text ink is here" density measure, used to tell a long string
    /// apart from a short one occupying the same cell rect.
    private func inkCoverage(
        _ rep: NSBitmapImageRep, xFrac0: CGFloat, xFrac1: CGFloat, alphaThreshold: CGFloat = 0.3
    ) -> CGFloat {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let x0 = max(0, Int(CGFloat(w) * xFrac0))
        let x1 = min(w, max(x0 + 1, Int(CGFloat(w) * xFrac1)))
        guard x1 > x0 else { return 0 }
        var inkedColumns = 0
        for x in x0..<x1 {
            var inked = false
            for y in 0..<h {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > alphaThreshold {
                    inked = true
                    break
                }
            }
            if inked { inkedColumns += 1 }
        }
        return CGFloat(inkedColumns) / CGFloat(x1 - x0)
    }

    /// Regression test for a display↔source column-indexing bug: `draw` used
    /// to read `values[displayIndex]` — i.e. index a SOURCE-ordered cell
    /// array (mirroring `RowStore.row(at:)` / SQL-schema order) with a
    /// DISPLAY index — so cells rendered under the wrong column whenever
    /// `order` was not identity. Every other test in this suite uses
    /// identity order, which masks the bug (display index == source index).
    /// This test uses a non-identity `order` and checks which column
    /// actually receives the ink.
    func test_rowContentView_nonIdentityOrder_paintsValueAtCorrectDisplayPosition() {
        // 3 columns, 100pt each: [0,100) [100,200) [200,300).
        // order: [2, 0, 1] -> display0 shows source col2, display1 shows
        // source col0, display2 shows source col1.
        let layout = ColumnLayout(widths: [100, 100, 100], order: [2, 0, 1])
        let view = RowContentView()
        view.frame = NSRect(x: 0, y: 0, width: layout.totalContentWidth, height: 20)
        view.columnLayout = layout
        view.columnWidths = layout.displayWidths
        view.columnXPositions = (0..<layout.columnCount).map { layout.xPosition(displayIndex: $0) }

        // `values` is SOURCE-ordered, as `RowStore.row(at:)` returns it.
        // Source col 2 gets a long, ink-dense string; source cols 0 and 1
        // get short ones, so which display column ends up ink-dense reveals
        // which source column was actually read.
        view.values = [
            .text("a"),                          // source col 0
            .text("b"),                          // source col 1
            .text("MMMMMMMMMMMMMMMMMMMM"),        // source col 2
        ]
        view.drawnMinX = 0
        view.drawnMaxX = layout.totalContentWidth

        let rep = render(view)

        // Correct behavior: display column 0 (frac 0.0..0.333) shows source
        // col 2's long string -> ink-dense.
        let display0Coverage = inkCoverage(rep, xFrac0: 0.0, xFrac1: 1.0 / 3.0)
        // Correct behavior: display column 2 (frac 0.667..1.0) shows source
        // col 1's short string -> ink-sparse.
        let display2Coverage = inkCoverage(rep, xFrac0: 2.0 / 3.0, xFrac1: 1.0)

        XCTAssertGreaterThan(
            display0Coverage, 0.3,
            "display column 0 must show source column 2's long string (order: [2,0,1])"
        )
        XCTAssertLessThan(
            display2Coverage, 0.15,
            "display column 2 must show source column 1's short string, not source column 2's long one"
        )
    }

    /// Regression coverage: the search "current match"
    /// highlight is keyed by `currentMatchCol`, a SOURCE column index (the
    /// same space `DataGridCoordinator.currentMatch.col` uses) — `draw(_:)`
    /// must map each DISPLAY column `i` to its source index
    /// (`columnLayout.sourceIndex(displayIndex: i)`) before comparing against
    /// `currentMatchCol`, exactly as it already does for `values` (see
    /// `test_rowContentView_nonIdentityOrder_paintsValueAtCorrectDisplayPosition`
    /// above). This test uses the same non-identity `order` and checks that
    /// the highlight fill lands at the DISPLAY position of the matching
    /// SOURCE column, not at the source column's own numeric index.
    func test_rowContentView_currentMatchHighlight_paintsAtCorrectDisplayColumn_nonIdentityOrder() {
        // 3 columns, 100pt each: [0,100) [100,200) [200,300).
        // order: [2, 0, 1] -> display0 shows source col2, display1 shows
        // source col0, display2 shows source col1 (same layout as the
        // non-identity value test above).
        let layout = ColumnLayout(widths: [100, 100, 100], order: [2, 0, 1])
        let view = RowContentView()
        view.frame = NSRect(x: 0, y: 0, width: layout.totalContentWidth, height: 20)
        view.columnLayout = layout
        view.columnWidths = layout.displayWidths
        view.columnXPositions = (0..<layout.columnCount).map { layout.xPosition(displayIndex: $0) }

        // Empty text in every cell -- the ONLY ink that can appear is the
        // highlight fill itself, isolating this assertion from glyph ink
        // (already covered separately by the value-mapping test above).
        view.values = [.text(""), .text(""), .text("")]
        view.drawnMinX = 0
        view.drawnMaxX = layout.totalContentWidth

        // A non-empty `searchTermLower` is required to enable highlight
        // painting at all (`draw(_:)`'s `if !searchTermLower.isEmpty` guard);
        // its actual text doesn't matter since the cells are empty.
        view.searchTermLower = "x"
        view.isCurrentMatchRow = true
        view.currentMatchCol = 2 // SOURCE column 2's match is focused.

        let rep = render(view)

        // Sample well inside each display column's interior, clear of the
        // 0.5pt grid lines at the column boundaries (x = 100, 200, 300).
        let display0 = maxAlpha(rep, xFrac0: 0.02, xFrac1: 0.30) // shows source col 2
        let display1 = maxAlpha(rep, xFrac0: 0.36, xFrac1: 0.63) // shows source col 0
        let display2 = maxAlpha(rep, xFrac0: 0.70, xFrac1: 0.97) // shows source col 1

        XCTAssertGreaterThan(display0, 0.3, "display column 0 (source col 2, the current match) must show the highlight fill")
        XCTAssertLessThan(display1, 0.05, "display column 1 (source col 0) must NOT show the highlight fill")
        XCTAssertLessThan(display2, 0.05, "display column 2 (source col 1) must NOT show the highlight fill")
    }

    func test_rowContentView_placeholderRowDrawsGridButNoCrash() {
        // values == nil (page not loaded): must render (grid lines only) safely.
        let layout = ColumnLayout(widths: Array(repeating: 100, count: 5), order: Array(0..<5))
        let view = RowContentView()
        view.frame = NSRect(x: 0, y: 0, width: layout.totalContentWidth, height: 20)
        view.columnLayout = layout
        view.columnWidths = layout.displayWidths
        view.columnXPositions = (0..<layout.columnCount).map { layout.xPosition(displayIndex: $0) }
        view.values = nil
        view.drawnMinX = 0
        view.drawnMaxX = layout.totalContentWidth

        let rep = render(view)
        // Grid lines are still drawn somewhere in the row.
        XCTAssertGreaterThan(maxAlpha(rep, xFrac0: 0.0, xFrac1: 1.0), 0.05)
    }

    /// NULL-display fidelity: `draw(_:)` builds a
    /// SINGLE `attrs` dict (`.foregroundColor: NSColor.labelColor`) applied
    /// uniformly to every cell — there is no second, dimmed attributes set
    /// for a "NULL" literal, so NULL renders as a
    /// BLANK cell (empty string), not the literal text "NULL". This test
    /// renders one `.null` cell next to one `.text(...)` cell of the same
    /// width and confirms the null cell paints no text ink (only its right
    /// grid line, which sits at the cell's far edge, outside the sampled
    /// interior strip) while the text cell clearly does.
    func test_rowContentView_nullCellPaintsBlank_textCellPaintsInk() {
        // 2 columns, 200pt each: [0,200) [200,400).
        let layout = ColumnLayout(widths: [200, 200], order: [0, 1])
        let view = RowContentView()
        view.frame = NSRect(x: 0, y: 0, width: layout.totalContentWidth, height: 20)
        view.columnLayout = layout
        view.columnWidths = layout.displayWidths
        view.columnXPositions = (0..<layout.columnCount).map { layout.xPosition(displayIndex: $0) }
        view.values = [.null, .text("hello world")]
        view.drawnMinX = 0
        view.drawnMaxX = layout.totalContentWidth

        let rep = render(view)

        // Interior of column 0 (frac 0.05..0.40 of 400pt width), well clear
        // of the 0.5pt right grid line at x=200 (frac 0.5). Use `maxAlpha`
        // (not the 0.3-alpha-threshold `inkCoverage`) because a *dimmed*
        // "NULL" literal (e.g. drawn in `tertiaryLabelColor`, alpha ~0.26)
        // would otherwise fall under a 0.3 ink threshold and be invisible to
        // this test — `maxAlpha` catches any non-zero ink at all, dim or not.
        let nullAlpha = maxAlpha(rep, xFrac0: 0.05, xFrac1: 0.40)
        // Interior of column 1 (frac 0.55..0.90), clear of the grid line at x=400.
        let textAlpha = maxAlpha(rep, xFrac0: 0.55, xFrac1: 0.90)

        XCTAssertLessThan(nullAlpha, 0.02, "a .null cell must paint NO ink at all (blank, not even a dimmed \"NULL\" literal)")
        XCTAssertGreaterThan(textAlpha, 0.1, "a .text cell must paint visible ink")
    }

    func test_grayRowView_alternateRowDiffersFromNormalRow() {
        func background(alternate: Bool) -> NSColor? {
            let view = GrayRowView()
            view.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
            view.usesAlternateColor = alternate
            let rep = render(view)
            return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        }
        let normal = background(alternate: false)
        let alternate = background(alternate: true)
        XCTAssertNotNil(normal)
        XCTAssertNotNil(alternate)
        // Standard system banding: the two shades must differ.
        let dr = abs((normal?.redComponent ?? 0) - (alternate?.redComponent ?? 0))
        let dg = abs((normal?.greenComponent ?? 0) - (alternate?.greenComponent ?? 0))
        let db = abs((normal?.blueComponent ?? 0) - (alternate?.blueComponent ?? 0))
        XCTAssertGreaterThan(dr + dg + db, 0.001, "alternate row banding must be a distinct shade")
    }
}
