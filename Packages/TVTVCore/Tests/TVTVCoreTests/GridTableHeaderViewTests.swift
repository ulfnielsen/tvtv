import AppKit
import XCTest
@testable import TVTVCore

/// Unit tests for `GridTableHeaderView`'s pure hit-testing math, plus
/// integration tests that drive the REAL
/// `mouseDown(with:)`/`mouseDragged(with:)`/`mouseUp(with:)` event-handling
/// triple with synthetic `NSEvent`s, exercising the composed
/// resize/reorder callback path end-to-end.
///
/// What IS pure and unit-testable is pinned here:
///
/// 1. `GridTableHeaderView.hitTest(x:columnLayout:)` -- resize-zone vs. body
///    dispatch, including the resize zone's priority over body containment.
/// 2. `GridTableHeaderView.isDrag(from:to:)` -- the 3.0pt drag threshold,
///    including its exact boundary (`abs(delta) > 3.0`, STRICT).
/// 3. `GridTableHeaderView.insertionIndex(forX:columnLayout:)` -- the
///    midpoint-based insertion-index scan used while dragging.
///
/// All three are tested against a NON-IDENTITY display order, since a
/// display/source indexing bug is exactly the kind of thing that could
/// recur here (resize must map a DISPLAY edge back to a SOURCE column
/// index).
///
/// The "Integration: real mouse events" section below closes a coverage gap
/// flagged in review: the pure helpers above are tested directly, but the
/// `state` machine in `mouseDown`/`mouseDragged`/`mouseUp` that CAPTURES a
/// source column and later fires the callbacks was untested -- a refactor
/// could swap `displayEdge` for `sourceColumn` in that composition, compile
/// fine, and pass every test above while silently reintroducing a
/// display/source indexing bug. Those tests synthesize real `NSEvent`s (mouse down /
/// dragged / up) and call the view's actual override methods, hosting the
/// view as an offscreen `NSWindow`'s content view so `convert(_:from:)`
/// resolves without requiring an interactive display session.
final class GridTableHeaderViewTests: XCTestCase {

    // MARK: - hitTest: resize zone (±5.0pt straddling a column's right edge)

    func test_hitTest_atColumnRightEdge_isResize() {
        // 3 columns of width 100: edges at x=100, x=200, x=300.
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 100, columnLayout: layout), .resize(displayEdge: 0))
    }

    func test_hitTest_5ptBeforeEdge_isResize() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 95, columnLayout: layout), .resize(displayEdge: 0))
    }

    func test_hitTest_5ptAfterEdge_isResize() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 105, columnLayout: layout), .resize(displayEdge: 0))
    }

    func test_hitTest_justOutsideResizeZone_5point1pt_isBodyNotResize() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        // 105.1 is > 5.0pt from edge (100) -> outside the resize zone -> falls
        // into column 1's leading gutter -- specifically its sort-glyph zone
        // ([100, 114)), the front-most slot of that gutter (see
        // `sortGlyphZoneWidth`'s doc). The point of this test is that
        // resize does NOT spuriously claim it; which glyph/body zone it
        // resolves to instead is column 1's own leading-edge layout.
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 105.1, columnLayout: layout), .sortGlyph(displayColumn: 1))
    }

    func test_hitTest_justOutsideResizeZoneOnLeftSide_94point9pt_isBodyNotResize() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        // 94.9 is > 5.0pt from edge (100) on the left -> column 0's body.
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 94.9, columnLayout: layout), .body(displayColumn: 0))
    }

    func test_hitTest_resizeZoneTakesPriorityOverBody() {
        // x=95 is both inside column 0's body ([0,100)) AND within 5pt of its
        // right edge (100). mouseDown tests ALL edges for a resize
        // hit BEFORE falling through to the column-containment dispatch --
        // resize wins.
        let layout = ColumnLayout(widths: [100, 100], order: [0, 1])
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 95, columnLayout: layout), .resize(displayEdge: 0))
    }

    // MARK: - hitTest: body (column containment, elsewhere)

    func test_hitTest_middleOfColumn_isBody() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 50, columnLayout: layout), .body(displayColumn: 0))
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 150, columnLayout: layout), .body(displayColumn: 1))
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 250, columnLayout: layout), .body(displayColumn: 2))
    }

    func test_hitTest_pastLastColumn_isNil() {
        let layout = ColumnLayout(widths: [100, 100], order: [0, 1])
        // 300 is > 5pt past the last edge (200) -> no resize, no containing column.
        XCTAssertNil(GridTableHeaderView.hitTest(x: 300, columnLayout: layout))
    }

    func test_hitTest_emptyLayout_isNil() {
        let layout = ColumnLayout(widths: [], order: [])
        XCTAssertNil(GridTableHeaderView.hitTest(x: 10, columnLayout: layout))
    }

    // MARK: - hitTest: display -> source mapping for resize (non-identity order)

    func test_hitTest_resizeDisplayEdge_mapsToCorrectSourceColumn_nonIdentityOrder() {
        // source widths: col0=100(A), col1=150(B), col2=80(C); displayed as
        // [C, A, B] -> display x-ranges: C=[0,80) A=[80,180) B=[180,330).
        // display edge 0 (C|A boundary) is at x=80; resizing it must target
        // SOURCE column 2 (C), not display index 0 or source index 0.
        let layout = ColumnLayout(widths: [100, 150, 80], order: [2, 0, 1])

        guard case .resize(let displayEdge)? = GridTableHeaderView.hitTest(x: 80, columnLayout: layout) else {
            return XCTFail("expected a resize hit at the C|A boundary")
        }
        XCTAssertEqual(displayEdge, 0)
        XCTAssertEqual(layout.sourceIndex(displayIndex: displayEdge), 2) // C is source column 2

        // Second edge (A|B boundary) at x=180 must map to source column 0 (A).
        guard case .resize(let displayEdge2)? = GridTableHeaderView.hitTest(x: 180, columnLayout: layout) else {
            return XCTFail("expected a resize hit at the A|B boundary")
        }
        XCTAssertEqual(displayEdge2, 1)
        XCTAssertEqual(layout.sourceIndex(displayIndex: displayEdge2), 0) // A is source column 0
    }

    func test_hitTest_bodyDisplayColumn_isDisplayIndexNotSourceIndex_nonIdentityOrder() {
        // Same non-identity layout: clicking inside "A" (displayed 2nd, at
        // x in [80,180)) must report display index 1 (A's display position),
        // not its source index 0.
        let layout = ColumnLayout(widths: [100, 150, 80], order: [2, 0, 1])
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 120, columnLayout: layout), .body(displayColumn: 1))
    }

    // MARK: - isDrag: 3.0pt threshold (STRICT `>`, not `>=`)

    func test_isDrag_belowThreshold_2point9pt_isFalse() {
        XCTAssertFalse(GridTableHeaderView.isDrag(from: 100, to: 102.9))
    }

    func test_isDrag_exactlyAtThreshold_3point0pt_isFalse() {
        // `if 3.0 < abs(currentX - startX)` -- STRICT
        // inequality, so a delta of EXACTLY 3.0 does NOT cross the threshold
        // (the loop's `else { continue }` keeps waiting).
        XCTAssertFalse(GridTableHeaderView.isDrag(from: 100, to: 103.0))
    }

    func test_isDrag_justAboveThreshold_3point1pt_isTrue() {
        XCTAssertTrue(GridTableHeaderView.isDrag(from: 100, to: 103.1))
    }

    func test_isDrag_isSymmetricForLeftwardMovement() {
        XCTAssertFalse(GridTableHeaderView.isDrag(from: 100, to: 97.0))
        XCTAssertTrue(GridTableHeaderView.isDrag(from: 100, to: 96.9))
    }

    func test_isDrag_usesDragThresholdConstant() {
        XCTAssertEqual(GridTableHeaderView.dragThreshold, 3.0)
    }

    // MARK: - resizeHitZone constant

    func test_resizeHitZone_usesResizeHitZoneConstant() {
        XCTAssertEqual(GridTableHeaderView.resizeHitZone, 5.0)
    }

    // MARK: - insertionIndex: midpoint-based scan

    func test_insertionIndex_beforeAllMidpoints_isZero() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        // midpoints at 50, 150, 250; x=10 is left of all of them.
        XCTAssertEqual(GridTableHeaderView.insertionIndex(forX: 10, columnLayout: layout), 0)
    }

    func test_insertionIndex_pastAllMidpoints_isColumnCount() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(GridTableHeaderView.insertionIndex(forX: 290, columnLayout: layout), 3)
    }

    func test_insertionIndex_betweenMidpoints_isFirstColumnWhoseMidpointExceedsX() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        // midpoints: col0=50, col1=150, col2=250. x=120 -> first midpoint > 120 is col1's (150) -> index 1.
        XCTAssertEqual(GridTableHeaderView.insertionIndex(forX: 120, columnLayout: layout), 1)
    }

    func test_insertionIndex_exactlyAtAMidpoint_isNotSelected_strictInequality() {
        // `columnXPositions[$0] + columnWidths[$0]*0.5 > curX` -- STRICT.
        // x exactly AT col0's midpoint (50) does not satisfy `50 > 50`, so the
        // scan continues past it.
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(GridTableHeaderView.insertionIndex(forX: 50, columnLayout: layout), 1)
    }

    func test_insertionIndex_respectsNonIdentityDisplayOrder() {
        // displayed as [C(80), A(100), B(150)]: C=[0,80) A=[80,180) B=[180,330)
        // -> midpoints: C=40, A=130, B=255.
        let layout = ColumnLayout(widths: [100, 150, 80], order: [2, 0, 1])
        XCTAssertEqual(GridTableHeaderView.insertionIndex(forX: 10, columnLayout: layout), 0)
        XCTAssertEqual(GridTableHeaderView.insertionIndex(forX: 100, columnLayout: layout), 1) // past C's midpoint(40), before A's(130)
        XCTAssertEqual(GridTableHeaderView.insertionIndex(forX: 300, columnLayout: layout), 3)
    }

    // MARK: - Integration: real mouse events (mouseDown/mouseDragged/mouseUp)

    /// Fixture shared by the event-driven tests below: source widths
    /// col0=100(A), col1=150(B), col2=80(C), displayed (via `order:
    /// [2,0,1]`) as [C, A, B] -- same non-identity layout as the pure
    /// `hitTest`/`insertionIndex` tests above, so display x-ranges are:
    /// C=[0,80) (source 2), A=[80,180) (source 0), B=[180,330) (source 1).
    ///
    /// Hosting the header as an offscreen `NSWindow`'s `contentView` (never
    /// `orderFront`-ed) is enough for `convert(_:from:)` inside
    /// `mouseDown(with:)` etc. to resolve real geometry without an
    /// interactive display session -- no window needs to actually be shown
    /// on screen for this.
    @MainActor
    private func makeFixture() -> (window: NSWindow, header: GridTableHeaderView) {
        let layout = ColumnLayout(widths: [100, 150, 80], order: [2, 0, 1])
        let header = GridTableHeaderView(columnLayout: layout)
        let frame = NSRect(x: 0, y: 0, width: layout.totalContentWidth, height: 24)
        header.frame = frame
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = header
        return (window, header)
    }

    /// Synthesizes a real mouse `NSEvent` at header-local x `x` (y fixed at
    /// mid-height; only x drives the hit-test/threshold math under test).
    /// `location` is in the window's base coordinate system, matching what
    /// AppKit itself would deliver to `mouseDown(with:)`; since the header
    /// is the window's entire content view at origin (0,0), base-space x
    /// equals header-local x regardless of the header's `isFlipped`
    /// (flipping affects y, not x).
    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, x: CGFloat, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: 12),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1.0 : 0.0
        )!
    }

    /// Resize path: grabbing the C|A display edge (display edge 0) must
    /// resize SOURCE column 2 (C), not display index 0 and not source
    /// column 0 (A) -- display and source deliberately disagree here. If
    /// the composition in `mouseDragged(with:)` ever emitted the display
    /// edge instead of the captured `sourceColumn`, this assertion (`2`,
    /// not `0`) would fail.
    @MainActor
    func test_mouseEvents_resizeDrag_firesOnColumnResized_withSourceIndexNotDisplayIndex() {
        let (window, header) = makeFixture()
        var received: [(source: Int, width: CGFloat)] = []
        header.onColumnResized = { source, width in received.append((source, width)) }

        // C|A edge is at x=80 (C's width). Grab within the ±5pt zone.
        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 80, in: window))
        // Drag +30pt: newWidth = startWidth(80, C's width) + 30 = 110.
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 110, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 110, in: window))

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.source, 2) // source column C -- NOT displayEdge (0), NOT source col 0 (A)
        XCTAssertEqual(received.first?.width, 110)
        // The layout itself was actually mutated for source column 2, confirming
        // the same index was used for both the callback and `setWidth(_:forColumn:)`.
        XCTAssertEqual(header.columnLayout.displayWidths[0], 110)
    }

    /// Resize path: dragging past the low end clamps to `ColumnLayout.minimumWidth`
    /// (50pt), and the clamped value -- not the raw unclamped delta -- is what
    /// reaches the callback.
    @MainActor
    func test_mouseEvents_resizeDrag_clampsToMinimumWidth() {
        let (window, header) = makeFixture()
        var receivedWidths: [CGFloat] = []
        header.onColumnResized = { _, width in receivedWidths.append(width) }

        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 80, in: window))
        // Drag far enough left that startWidth(80) + delta would go negative.
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, x: -50, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: -50, in: window))

        XCTAssertEqual(receivedWidths, [50])
    }

    /// Reorder path: dragging column A (display index 1, body x in [80,180))
    /// leftward past C's midpoint (40) must emit the new DISPLAY order
    /// `[0, 2, 1]` (A, C, B) -- i.e. `result[displayIndex] == sourceColumnIndex`
    /// after the move, exactly `ColumnLayout.moveColumn`'s contract, driven
    /// through the real event handlers rather than called directly.
    @MainActor
    func test_mouseEvents_reorderDrag_pastThreshold_firesOnColumnsReordered_withNewDisplayOrder() {
        let (window, header) = makeFixture()
        var received: [[Int]] = []
        header.onColumnsReordered = { received.append($0) }

        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 130, in: window)) // inside A's body
        // Past the 3.0pt threshold, and far enough to land before C's midpoint (40).
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 20, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 20, in: window))

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first, [0, 2, 1]) // A, C, B -- A moved ahead of C
    }

    /// Reorder path: a drag of exactly 3.0pt (the STRICT `>` boundary)
    /// must NOT be treated as a drag at all, so no reorder commits and no
    /// callback fires on mouse-up.
    @MainActor
    func test_mouseEvents_reorderDrag_exactlyAtThreshold_doesNotFireOnColumnsReordered() {
        let (window, header) = makeFixture()
        var received: [[Int]] = []
        header.onColumnsReordered = { received.append($0) }

        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 130, in: window)) // inside A's body
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 133, in: window)) // exactly +3.0pt
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 133, in: window))

        XCTAssertTrue(received.isEmpty)
    }

    // MARK: - Integration: plain click fires onColumnTapped

    /// A plain sub-threshold click (mouse down, then up with no drag) inside
    /// a column's body must fire `onColumnTapped` with that column's DISPLAY
    /// index -- the coordinator is responsible for mapping that to a source
    /// index via `columnLayout.sourceIndex(displayIndex:)`.
    @MainActor
    func test_mouseEvents_plainClick_firesOnColumnTapped_withDisplayIndex() {
        let (window, header) = makeFixture()
        var tapped: [Int] = []
        header.onColumnTapped = { tapped.append($0) }

        // Click inside A's body (displayed 2nd, x in [80,180)) with no drag.
        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 130, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 130, in: window))

        XCTAssertEqual(tapped, [1]) // A's DISPLAY index, not its source index (0)
    }

    /// A drag past the threshold must NOT fire `onColumnTapped` -- it's a
    /// reorder, not a click.
    @MainActor
    func test_mouseEvents_dragPastThreshold_doesNotFireOnColumnTapped() {
        let (window, header) = makeFixture()
        var tapped: [Int] = []
        header.onColumnTapped = { tapped.append($0) }

        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 130, in: window))
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 20, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 20, in: window))

        XCTAssertTrue(tapped.isEmpty)
    }

    /// A resize drag must NOT fire `onColumnTapped`.
    @MainActor
    func test_mouseEvents_resizeDrag_doesNotFireOnColumnTapped() {
        let (window, header) = makeFixture()
        var tapped: [Int] = []
        header.onColumnTapped = { tapped.append($0) }

        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 80, in: window))
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 110, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 110, in: window))

        XCTAssertTrue(tapped.isEmpty)
    }

    // MARK: - Sort indicator drawing state

    /// `sortIndicator` is a plain stored property the coordinator drives;
    /// pin that setting it doesn't crash and is readable back (the actual
    /// glyph placement is exercised visually, not asserted pixel-by-pixel).
    @MainActor
    func test_sortIndicator_settableAndReadable() {
        let (_, header) = makeFixture()
        XCTAssertNil(header.sortIndicator)

        header.sortIndicator = (sourceIndex: 2, ascending: true)
        XCTAssertEqual(header.sortIndicator?.sourceIndex, 2)
        XCTAssertEqual(header.sortIndicator?.ascending, true)

        header.sortIndicator = nil
        XCTAssertNil(header.sortIndicator)
    }

    // MARK: - columnTypes (Part A: header knows each column's SQL type)

    /// `columnTypes` is a plain constructor-supplied array, parallel to
    /// `columnNames` (both indexed by SOURCE column index) -- pin that the
    /// `init` param round-trips, and that omitting it (matching every
    /// pre-existing call site/test) defaults to empty.
    @MainActor
    func test_columnTypes_defaultsToEmpty_andRoundTripsThroughInit() {
        let layout = ColumnLayout(widths: [100], order: [0])
        let bareHeader = GridTableHeaderView(columnLayout: layout)
        XCTAssertEqual(bareHeader.columnTypes, [])

        let header = GridTableHeaderView(columnLayout: layout, columnNames: ["id"], columnTypes: ["BIGINT"])
        XCTAssertEqual(header.columnTypes, ["BIGINT"])
    }

    // MARK: - hitTest: filter-glyph zone (LEADING edge of each column body)

    /// The filter glyph lives in a reserved gutter (`leadingGutterWidth`) at
    /// the START of each column, right after that column's OWN left-edge
    /// resize zone (there is none for display column 0, but the gutter
    /// offset is still measured relative to `resizeHitZone` for a uniform
    /// per-column formula) -- placed leading, not trailing.
    /// `filterGlyphZoneWidth` occupies the END of that gutter (closest to
    /// the label), leaving room at the very front for a possible future sort
    /// glyph.
    func test_hitTest_leadingFilterGlyphZone_isFilterGlyph() {
        // 3 columns of width 100 each, identity order. Column 0's filter
        // zone is [0 + (leadingGutterWidth - filterGlyphZoneWidth),
        // + filterGlyphZoneWidth) = [18, 32) for the constants
        // (32, 14) -- no longer offset by `resizeHitZone`,
        // see `filterGlyphZoneX`'s doc for why that term was dropped.
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(
            GridTableHeaderView.hitTest(x: 25, columnLayout: layout),
            .filterGlyph(displayColumn: 0)
        )
    }

    func test_hitTest_filterGlyphZone_secondColumn_isFilterGlyphWithCorrectDisplayIndex() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        // Column 1 starts at x=100; its filter zone is [118, 132).
        XCTAssertEqual(
            GridTableHeaderView.hitTest(x: 125, columnLayout: layout),
            .filterGlyph(displayColumn: 1)
        )
    }

    /// Existing resize-zone tests (both directly at, and 5.1pt/94.9pt either
    /// side of, a column's TRAILING edge) must be unaffected by the new
    /// LEADING filter-glyph zone -- it lives at the opposite end of each
    /// column, with a wide margin before that column's own trailing resize
    /// zone even at the 50pt minimum column width. Pinned explicitly here
    /// (in addition to the untouched pre-existing tests above) since this is
    /// exactly the kind of adjacent-feature interaction a future glyph
    /// resize could silently break.
    func test_hitTest_resizeZoneStillWinsOverFilterGlyph_atTrailingEdge() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 100, columnLayout: layout), .resize(displayEdge: 0))
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 95, columnLayout: layout), .resize(displayEdge: 0))
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 105, columnLayout: layout), .resize(displayEdge: 0))
    }

    /// A click in the true label body (past the filter-glyph zone, before
    /// the trailing resize zone) must still resolve to `.body`, i.e. still
    /// dispatches sort on a plain click -- NOT filter.
    func test_hitTest_labelBody_betweenGlyphZoneAndResizeZone_isBodyNotFilter() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        // Column 0's leading gutter (sort + filter glyphs) ends at x=28; its
        // resize zone starts at x=95. x=60 sits squarely in the real label body.
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 60, columnLayout: layout), .body(displayColumn: 0))
    }

    /// Non-identity display order: displayed as [C(80), A(100), B(150)] --
    /// same fixture as the resize/body non-identity tests above. Clicking
    /// the filter-glyph zone of the column displayed 2nd (A, source index 0,
    /// body x-range [80,180)) must resolve to DISPLAY index 1 -- proving the
    /// glyph hit-test is keyed off display geometry, matching `hitTest`'s
    /// existing display-index convention for resize/body. The
    /// DISPLAY -> SOURCE mapping itself is exercised by the coordinator
    /// integration test below (`columnLayout.sourceIndex(displayIndex:)`).
    func test_hitTest_filterGlyphZone_nonIdentityOrder_resolvesToDisplayIndex_notSourceIndex() {
        let layout = ColumnLayout(widths: [100, 150, 80], order: [2, 0, 1])
        // A's body starts at x=80; its filter zone is [80+14, 80+28) = [94, 108).
        XCTAssertEqual(
            GridTableHeaderView.hitTest(x: 100, columnLayout: layout),
            .filterGlyph(displayColumn: 1)
        )
        XCTAssertEqual(layout.sourceIndex(displayIndex: 1), 0) // A is source column 0, not 1
    }

    /// Same non-identity fixture, but landing in the SORT glyph's zone
    /// (the front-most slot of A's leading gutter, [80, 94)) instead of the
    /// filter glyph's -- proving the two glyph zones are independently
    /// hit-testable and both map through DISPLAY index, not source.
    func test_hitTest_sortGlyphZone_nonIdentityOrder_resolvesToDisplayIndex_notSourceIndex() {
        let layout = ColumnLayout(widths: [100, 150, 80], order: [2, 0, 1])
        // A's body starts at x=80; its sort zone is [80, 80+14) = [80, 94), but
        // [80,85] also falls in the C|A resize zone (edge at 80, +-5) -- use
        // x=90, safely inside the sort zone and outside the resize zone.
        XCTAssertEqual(
            GridTableHeaderView.hitTest(x: 90, columnLayout: layout),
            .sortGlyph(displayColumn: 1)
        )
        XCTAssertEqual(layout.sourceIndex(displayIndex: 1), 0) // A is source column 0, not 1
    }

    // MARK: - hitTest: sort-glyph zone (front-most slot of the leading gutter)

    func test_hitTest_leadingSortGlyphZone_isSortGlyph() {
        // 3 columns of width 100 each, identity order. Column 0's sort zone
        // is [0, sortGlyphZoneWidth) = [0, 14) for the constant.
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(
            GridTableHeaderView.hitTest(x: 7, columnLayout: layout),
            .sortGlyph(displayColumn: 0)
        )
    }

    func test_hitTest_sortGlyphZone_secondColumn_isSortGlyphWithCorrectDisplayIndex() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        // Column 1 starts at x=100; its sort zone is [100, 114), but
        // [100,105] also falls in the col0|col1 resize zone (edge at 100,
        // +-5) -- use x=108, safely inside the sort zone and outside it.
        XCTAssertEqual(
            GridTableHeaderView.hitTest(x: 108, columnLayout: layout),
            .sortGlyph(displayColumn: 1)
        )
    }

    // MARK: - Integration: leading filter-glyph click fires onColumnFilterRequested

    /// A plain click landing in a column's filter-glyph zone must fire
    /// `onColumnFilterRequested` with that column's DISPLAY index -- and must
    /// NOT also fire `onColumnTapped` (sort). This is the same callback
    /// right-click already uses; the glyph is a second, discoverable
    /// trigger for the same popover.
    @MainActor
    func test_mouseEvents_filterGlyphClick_firesOnColumnFilterRequested_notOnColumnTapped() {
        let (window, header) = makeFixture()
        var filterRequests: [(displayIndex: Int, frame: NSRect)] = []
        var tapped: [Int] = []
        header.onColumnFilterRequested = { displayIndex, frame in filterRequests.append((displayIndex, frame)) }
        header.onColumnTapped = { tapped.append($0) }

        // A is displayed 2nd (body x in [80,180)); its filter zone is [94,108).
        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 100, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 100, in: window))

        XCTAssertEqual(filterRequests.count, 1)
        XCTAssertEqual(filterRequests.first?.displayIndex, 1) // A's DISPLAY index
        XCTAssertTrue(tapped.isEmpty, "a filter-glyph click must not also dispatch sort")
    }

    /// A plain click in the same column's true label body (NOT the glyph
    /// zone) must still fire `onColumnTapped` (sort) and NOT
    /// `onColumnFilterRequested` -- the two triggers must not cross-fire.
    @MainActor
    func test_mouseEvents_labelBodyClick_stillFiresOnColumnTapped_notFilterRequest() {
        let (window, header) = makeFixture()
        var filterRequests: [Int] = []
        var tapped: [Int] = []
        header.onColumnFilterRequested = { displayIndex, _ in filterRequests.append(displayIndex) }
        header.onColumnTapped = { tapped.append($0) }

        // x=130 is inside A's body but past its leading gutter (ends at 108).
        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 130, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 130, in: window))

        XCTAssertEqual(tapped, [1])
        XCTAssertTrue(filterRequests.isEmpty)
    }

    /// A resize-zone click must still resize -- unaffected by the new glyph
    /// hit-test branch inserted between resize and body.
    @MainActor
    func test_mouseEvents_resizeZoneClick_stillFiresOnColumnResized_notFilterRequest() {
        let (window, header) = makeFixture()
        var filterRequests: [Int] = []
        var resized: [Int] = []
        header.onColumnFilterRequested = { displayIndex, _ in filterRequests.append(displayIndex) }
        header.onColumnResized = { source, _ in resized.append(source) }

        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 80, in: window)) // C|A edge
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 110, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 110, in: window))

        XCTAssertEqual(resized, [2])
        XCTAssertTrue(filterRequests.isEmpty)
    }

    // MARK: - Invariant: filter glyph zone never overlaps the label text
    //
    // Review fix pass: `filterGlyphZoneX` used to add a stray
    // `+ resizeHitZone` term left over from an earlier trailing-edge design,
    // pushing the zone's right edge (`columnLeft + 37`) 5pt PAST
    // `labelTextX(columnLeft:)` (`columnLeft + 32`, matching `draw(_:)`'s
    // `textRect`). Since the glyph is drawn AFTER the label text, that 5pt
    // overlap painted over the first ~5pt of every column's label. These
    // tests pin `filterGlyphZoneX(...).right <= labelTextX(...)` so it can't
    // regress -- they FAIL against the old (buggy) formula and PASS against
    // the fixed one (dropped the `+ resizeHitZone` term).

    func test_filterGlyphZone_neverOverlapsLabelText_atNormalWidth() {
        let columnLeft: CGFloat = 40
        let width: CGFloat = 120
        let (_, zoneRight) = GridTableHeaderView.filterGlyphZoneX(columnLeft: columnLeft)
        let textStartX = GridTableHeaderView.labelTextX(columnLeft: columnLeft)
        XCTAssertLessThanOrEqual(zoneRight, textStartX)

        // Also reconfirm the (unrelated, unchanged) margin to this column's
        // OWN trailing resize zone still holds at a normal width.
        let resizeZoneStart = columnLeft + width - GridTableHeaderView.resizeHitZone
        XCTAssertLessThanOrEqual(zoneRight, resizeZoneStart)
    }

    func test_filterGlyphZone_neverOverlapsLabelText_atMinimumColumnWidth() {
        let columnLeft: CGFloat = 0
        let width = ColumnLayout.minimumWidth // 50pt -- tightest margin case.
        let (_, zoneRight) = GridTableHeaderView.filterGlyphZoneX(columnLeft: columnLeft)
        let textStartX = GridTableHeaderView.labelTextX(columnLeft: columnLeft)
        XCTAssertLessThanOrEqual(zoneRight, textStartX)

        let resizeZoneStart = columnLeft + width - GridTableHeaderView.resizeHitZone
        XCTAssertLessThanOrEqual(zoneRight, resizeZoneStart)
    }

    // MARK: - Invariant: sort glyph zone never overlaps the filter glyph zone
    //
    // The two leading glyphs (sort, then filter) sit back-to-back inside
    // `leadingGutterWidth` with no gap: `sortGlyphZoneX(...).right ==
    // filterGlyphZoneX(...).left`. Pinned here (rather than just the
    // combined `filterGlyphZoneX(...).right <= labelTextX(...)` invariant
    // above) so a future change to either zone's width can't silently
    // reintroduce an overlap between the two glyphs themselves.

    func test_sortGlyphZone_neverOverlapsFilterGlyphZone_atNormalWidth() {
        let columnLeft: CGFloat = 40
        let (_, sortZoneRight) = GridTableHeaderView.sortGlyphZoneX(columnLeft: columnLeft)
        let (filterZoneLeft, _) = GridTableHeaderView.filterGlyphZoneX(columnLeft: columnLeft)
        XCTAssertLessThanOrEqual(sortZoneRight, filterZoneLeft)
    }

    func test_sortGlyphZone_neverOverlapsFilterGlyphZone_atMinimumColumnWidth() {
        let columnLeft: CGFloat = 0
        let (_, sortZoneRight) = GridTableHeaderView.sortGlyphZoneX(columnLeft: columnLeft)
        let (filterZoneLeft, _) = GridTableHeaderView.filterGlyphZoneX(columnLeft: columnLeft)
        XCTAssertLessThanOrEqual(sortZoneRight, filterZoneLeft)

        // And the whole gutter (both glyphs) still clears this column's own
        // trailing resize zone at the 50pt minimum width, same margin the
        // filter-only invariant test above already checks.
        let width = ColumnLayout.minimumWidth
        let textStartX = GridTableHeaderView.labelTextX(columnLeft: columnLeft)
        let resizeZoneStart = columnLeft + width - GridTableHeaderView.resizeHitZone
        XCTAssertLessThanOrEqual(textStartX, resizeZoneStart)
    }

    /// Resize-zone priority extends to the new sort-glyph branch too --
    /// unaffected by its insertion into `hitTest`'s check order.
    func test_hitTest_resizeZoneStillWinsOverSortGlyph_atTrailingEdge() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 100, columnLayout: layout), .resize(displayEdge: 0))
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 95, columnLayout: layout), .resize(displayEdge: 0))
        XCTAssertEqual(GridTableHeaderView.hitTest(x: 105, columnLayout: layout), .resize(displayEdge: 0))
    }

    // MARK: - Integration: sort-glyph click fires onColumnTapped, not onColumnFilterRequested

    /// A plain click landing in a column's sort-glyph zone must fire
    /// `onColumnTapped` (the SAME callback a body click uses -- the
    /// coordinator's `toggleSort` wiring doesn't distinguish the two
    /// triggers) with that column's DISPLAY index, and must NOT fire
    /// `onColumnFilterRequested`.
    @MainActor
    func test_mouseEvents_sortGlyphClick_firesOnColumnTapped_notOnColumnFilterRequested() {
        let (window, header) = makeFixture()
        var tapped: [Int] = []
        var filterRequests: [Int] = []
        header.onColumnTapped = { tapped.append($0) }
        header.onColumnFilterRequested = { displayIndex, _ in filterRequests.append(displayIndex) }

        // A is displayed 2nd (body x in [80,180)); its sort zone is [80,94), but
        // [80,85] also falls in the C|A resize zone (edge at 80, +-5) -- use
        // x=90, safely inside the sort zone and outside the resize zone.
        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 90, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 90, in: window))

        XCTAssertEqual(tapped, [1]) // A's DISPLAY index
        XCTAssertTrue(filterRequests.isEmpty, "a sort-glyph click must not also request a filter")
    }

    /// A sort-glyph click must fire IMMEDIATELY on mouse-down (no drag/
    /// threshold ambiguity, same as the filter glyph) -- a `mouseDown` alone
    /// with no paired `mouseUp` still dispatches.
    @MainActor
    func test_mouseEvents_sortGlyphClick_firesImmediatelyOnMouseDown() {
        let (window, header) = makeFixture()
        var tapped: [Int] = []
        header.onColumnTapped = { tapped.append($0) }

        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 90, in: window))

        XCTAssertEqual(tapped, [1])
    }

    /// A drag starting from the sort-glyph zone must not also fire
    /// `onColumnTapped` a second time on `mouseUp` (the glyph click already
    /// fired on `mouseDown` and reset `state` to `.idle`).
    @MainActor
    func test_mouseEvents_sortGlyphClick_thenMouseUp_doesNotDoubleFire() {
        let (window, header) = makeFixture()
        var tapped: [Int] = []
        header.onColumnTapped = { tapped.append($0) }

        header.mouseDown(with: mouseEvent(.leftMouseDown, x: 90, in: window))
        header.mouseUp(with: mouseEvent(.leftMouseUp, x: 90, in: window))

        XCTAssertEqual(tapped, [1])
    }

    // MARK: - filteredColumns (active-filter draw state)

    /// `filteredColumns` is a plain stored property (SOURCE index space,
    /// mirroring `sortIndicator`'s `sourceIndex` convention) the coordinator
    /// drives from `excludedValues`; pin that setting it doesn't crash and
    /// is readable back.
    @MainActor
    func test_filteredColumns_settableAndReadable() {
        let (_, header) = makeFixture()
        XCTAssertTrue(header.filteredColumns.isEmpty)

        header.filteredColumns = [0, 2]
        XCTAssertEqual(header.filteredColumns, [0, 2])

        header.filteredColumns = []
        XCTAssertTrue(header.filteredColumns.isEmpty)
    }
}
