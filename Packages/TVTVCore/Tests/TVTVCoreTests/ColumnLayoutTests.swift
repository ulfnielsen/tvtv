import XCTest
@testable import TVTVCore

/// `ColumnLayout` design:
///
/// - `widths` is indexed by **source column index** — a stable identity that
///   survives reordering, keyed by column *name* rather than display
///   position.
/// - `order[displayIndex] = sourceColumnIndex` is the display-order
///   permutation.
/// - `xPosition(displayIndex:)` / `totalContentWidth` are prefix sums over
///   `widths[order[i]]`.
/// - `columns(intersecting:)` reproduces `RowContentView.draw`'s exact
///   per-column culling test:
///   `if dirtyRect.minX > x + w { continue }` / `if dirtyRect.maxX < x { break }`
///   — i.e. a column is EXCLUDED only if it is strictly, entirely left of
///   the range, or strictly, entirely right of it. A column whose edge
///   exactly touches a range boundary (e.g. `x + w == xRange.lowerBound`)
///   IS included — this is why the interface takes a `ClosedRange`.
final class ColumnLayoutTests: XCTestCase {

    // MARK: - xPosition / totalContentWidth

    func test_xPosition_isRunningSumOfPrecedingWidthsInDisplayOrder() {
        // widths indexed by source column; order = identity (display == source)
        let layout = ColumnLayout(widths: [100, 150, 80, 200], order: [0, 1, 2, 3])

        XCTAssertEqual(layout.xPosition(displayIndex: 0), 0)
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 100)
        XCTAssertEqual(layout.xPosition(displayIndex: 2), 250)
        XCTAssertEqual(layout.xPosition(displayIndex: 3), 330)
    }

    func test_xPosition_respectsNonIdentityDisplayOrder() {
        // source column 2 (width 80) is shown first, then 0 (100), then 3 (200), then 1 (150)
        let layout = ColumnLayout(widths: [100, 150, 80, 200], order: [2, 0, 3, 1])

        XCTAssertEqual(layout.xPosition(displayIndex: 0), 0)     // before col 2
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 80)    // after col 2
        XCTAssertEqual(layout.xPosition(displayIndex: 2), 180)   // after col 2, col 0
        XCTAssertEqual(layout.xPosition(displayIndex: 3), 380)   // after col 2, col 0, col 3
    }

    func test_totalContentWidth_isSumOfAllColumnWidths() {
        let layout = ColumnLayout(widths: [100, 150, 80, 200], order: [0, 1, 2, 3])
        XCTAssertEqual(layout.totalContentWidth, 530)
    }

    func test_totalContentWidth_isOrderIndependent() {
        // total is a sum, so any permutation of `order` yields the same total
        let layout = ColumnLayout(widths: [100, 150, 80, 200], order: [3, 1, 0, 2])
        XCTAssertEqual(layout.totalContentWidth, 530)
    }

    // MARK: - default-width convenience initializer

    func test_defaultWidthInit_usesNameLengthFormula() {
        // max(100, nameLen*9 + 60): "id" (len 2) -> max(100, 78) = 100
        // "description" (len 11) -> max(100, 159) = 159
        // "x" (len 1) -> max(100, 69) = 100
        let layout = ColumnLayout(columnNames: ["id", "description", "x"])

        XCTAssertEqual(layout.xPosition(displayIndex: 0), 0)
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 100)   // after "id"
        XCTAssertEqual(layout.xPosition(displayIndex: 2), 259)   // after "id" + "description"
        XCTAssertEqual(layout.totalContentWidth, 359)
    }

    func test_defaultWidthInit_defaultsOrderToIdentity() {
        let layout = ColumnLayout(columnNames: ["aaa", "bbbbbbbbbb"])
        // identity order means displayIndex 0 == source column 0 ("aaa", width 100)
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 100)
    }

    // MARK: - sourceIndex(displayIndex:)

    func test_sourceIndex_mapsDisplayIndexToSourceColumnIndex() {
        // source col 2 shown first, then col 0, then col 1.
        let layout = ColumnLayout(widths: [100, 100, 100], order: [2, 0, 1])
        XCTAssertEqual(layout.sourceIndex(displayIndex: 0), 2)
        XCTAssertEqual(layout.sourceIndex(displayIndex: 1), 0)
        XCTAssertEqual(layout.sourceIndex(displayIndex: 2), 1)
    }

    func test_sourceIndex_isIdentityWhenOrderIsIdentity() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(layout.sourceIndex(displayIndex: 0), 0)
        XCTAssertEqual(layout.sourceIndex(displayIndex: 1), 1)
        XCTAssertEqual(layout.sourceIndex(displayIndex: 2), 2)
    }

    // MARK: - displayIndex(sourceIndex:): the inverse of sourceIndex(displayIndex:)

    /// Under a non-identity display order, `displayIndex(sourceIndex:)` must
    /// find the DISPLAY position that currently shows a given SOURCE column
    /// — the exact inverse of `sourceIndex(displayIndex:)`. This is the
    /// mapping `DataGridCoordinator.recomputeColumnNameMatches` relies on to
    /// turn a column-NAME match (known only by its stable source index) into
    /// a `GridTableView.scrollToColumn(_:)` call (which wants a display
    /// index) — the codebase previously had a bug from conflating these two
    /// index spaces, so this is pinned directly against a shuffled order.
    func test_displayIndex_isInverseOfSourceIndex_underNonIdentityOrder() {
        // source col 2 shown first, then col 0, then col 1.
        let layout = ColumnLayout(widths: [100, 100, 100], order: [2, 0, 1])
        XCTAssertEqual(layout.displayIndex(sourceIndex: 2), 0)
        XCTAssertEqual(layout.displayIndex(sourceIndex: 0), 1)
        XCTAssertEqual(layout.displayIndex(sourceIndex: 1), 2)

        // Round-trips with sourceIndex(displayIndex:) at every position.
        for displayIndex in 0..<3 {
            let sourceIndex = layout.sourceIndex(displayIndex: displayIndex)
            XCTAssertEqual(layout.displayIndex(sourceIndex: sourceIndex), displayIndex)
        }
    }

    func test_displayIndex_isIdentityWhenOrderIsIdentity() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(layout.displayIndex(sourceIndex: 0), 0)
        XCTAssertEqual(layout.displayIndex(sourceIndex: 1), 1)
        XCTAssertEqual(layout.displayIndex(sourceIndex: 2), 2)
    }

    func test_displayIndex_nilForUnknownSourceIndex() {
        let layout = ColumnLayout(widths: [100, 100, 100], order: [2, 0, 1])
        XCTAssertNil(layout.displayIndex(sourceIndex: 99))
    }

    // MARK: - columns(intersecting:) horizontal culling

    func test_columnsIntersecting_returnsOnlyOverlappingColumns() {
        // 4 columns of width 100 each: [0,100) [100,200) [200,300) [300,400)
        let layout = ColumnLayout(widths: [100, 100, 100, 100], order: [0, 1, 2, 3])

        // range squarely inside columns 1 and 2
        XCTAssertEqual(layout.columns(intersecting: 120...250), 1..<3)
    }

    func test_columnsIntersecting_fullRangeReturnsAllColumns() {
        let layout = ColumnLayout(widths: [100, 100, 100, 100], order: [0, 1, 2, 3])
        XCTAssertEqual(layout.columns(intersecting: 0...400), 0..<4)
    }

    func test_columnsIntersecting_rangeEntirelyBeforeAllColumnsIsEmpty() {
        let layout = ColumnLayout(widths: [100, 100], order: [0, 1])
        XCTAssertEqual(layout.columns(intersecting: (-100)...(-1)), 0..<0)
    }

    func test_columnsIntersecting_rangeEntirelyAfterAllColumnsIsEmpty() {
        let layout = ColumnLayout(widths: [100, 100], order: [0, 1])
        XCTAssertEqual(layout.columns(intersecting: 500...600), 2..<2)
    }

    func test_columnsIntersecting_outerLeftEdgeOfFirstColumnIsIncluded() {
        // columns: [0,100) [100,200) [200,300). A range ending exactly at
        // the first column's left edge (x=0), with no column further left
        // to also match, isolates the "touching left edge is included"
        // rule: `if dirtyRect.maxX < x { break }` -- maxX(0) == x(0)
        // is NOT < x, so column 0 is included (not culled).
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(layout.columns(intersecting: (-50)...0), 0..<1)
    }

    func test_columnsIntersecting_outerRightEdgeOfLastColumnIsIncluded() {
        // A range starting exactly at the last column's right edge
        // (x+w=300), with no column further right to also match, isolates
        // the "touching right edge is included" rule:
        // `if dirtyRect.minX > x + w { continue }` -- minX(300) == x+w(300)
        // is NOT >, so the last column is included (not culled).
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(layout.columns(intersecting: 300...350), 2..<3)
    }

    func test_columnsIntersecting_pointAtInternalBoundaryIncludesBothAdjacentColumns() {
        // A zero-width point range sitting exactly on the boundary shared by
        // two adjacent columns (col0's right edge == col1's left edge = 100)
        // satisfies both edge-touch rules simultaneously, so BOTH columns
        // are included -- a direct consequence of the two rules above
        // each using strict `<`/`>` (not `<=`/`>=`).
        let layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        XCTAssertEqual(layout.columns(intersecting: 100...100), 0..<2)
    }

    func test_columnsIntersecting_respectsDisplayOrderNotSourceOrder() {
        // source widths: col0=100, col1=50; displayed as [col1, col0] -> [0,50) [50,150)
        let layout = ColumnLayout(widths: [100, 50], order: [1, 0])
        XCTAssertEqual(layout.columns(intersecting: 60...70), 1..<2)  // hits displayed col0 (source idx 0)
        XCTAssertEqual(layout.columns(intersecting: 10...20), 0..<1)  // hits displayed col1 (source idx 1)
    }

    // MARK: - setWidth

    func test_setWidth_updatesTotalContentWidth() {
        var layout = ColumnLayout(widths: [100, 100], order: [0, 1])
        layout.setWidth(250, forColumn: 0)
        XCTAssertEqual(layout.totalContentWidth, 350)
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 250)
    }

    func test_setWidth_isKeyedBySourceColumnIndexNotDisplayIndex() {
        // source col1 (width 100) displayed first; setWidth(forColumn: 1) must
        // resize the source column, and its NEW width must appear at
        // displayIndex 0 (where it's shown), not at source index 1's old slot.
        var layout = ColumnLayout(widths: [100, 100], order: [1, 0])
        layout.setWidth(300, forColumn: 1)
        XCTAssertEqual(layout.xPosition(displayIndex: 0), 0)
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 300)  // after the resized column
        XCTAssertEqual(layout.totalContentWidth, 400)
    }

    func test_setWidth_clampsToMinimum50() {
        var layout = ColumnLayout(widths: [100], order: [0])
        layout.setWidth(10, forColumn: 0)
        XCTAssertEqual(layout.totalContentWidth, 50)

        layout.setWidth(-40, forColumn: 0)
        XCTAssertEqual(layout.totalContentWidth, 50)
    }

    func test_setWidth_exactlyMinimumIsUnclamped() {
        var layout = ColumnLayout(widths: [100], order: [0])
        layout.setWidth(50, forColumn: 0)
        XCTAssertEqual(layout.totalContentWidth, 50)
    }

    // MARK: - moveColumn

    func test_moveColumn_reordersAndShiftsXPositions() {
        // A(100) B(100) C(100) D(100), source order == display order initially
        var layout = ColumnLayout(widths: [100, 100, 100, 100], order: [0, 1, 2, 3])

        // move A (display 0) to insertion index 3 (i.e. after C, using the
        // drag-insertion-index convention: `to` is a position in
        // the array *before* removal, so this lands A between C and D)
        layout.moveColumn(from: 0, to: 3)

        // expected resulting order: [1, 2, 0, 3]  (B, C, A, D)
        XCTAssertEqual(layout.xPosition(displayIndex: 0), 0)     // B
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 100)   // C
        XCTAssertEqual(layout.xPosition(displayIndex: 2), 200)   // A (moved here)
        XCTAssertEqual(layout.xPosition(displayIndex: 3), 300)   // D
        XCTAssertEqual(layout.totalContentWidth, 400)
    }

    func test_moveColumn_toFront() {
        var layout = ColumnLayout(widths: [100, 100, 100], order: [0, 1, 2])
        // move last column (display 2) to the very front
        layout.moveColumn(from: 2, to: 0)
        // expected order: [2, 0, 1]
        XCTAssertEqual(layout.xPosition(displayIndex: 0), 0)
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 100)
        XCTAssertEqual(layout.xPosition(displayIndex: 2), 200)
        // confirm identity: the moved column (source idx 2) is now first,
        // verified indirectly via setWidth targeting source idx 2 affecting displayIndex 0
        layout.setWidth(50, forColumn: 2)
        XCTAssertEqual(layout.xPosition(displayIndex: 0), 0)
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 50)   // shifted left by the resize
    }

    func test_moveColumn_toSamePositionIsNoOp() {
        var layout = ColumnLayout(widths: [100, 150, 80], order: [0, 1, 2])
        layout.moveColumn(from: 1, to: 1)
        XCTAssertEqual(layout.xPosition(displayIndex: 0), 0)
        XCTAssertEqual(layout.xPosition(displayIndex: 1), 100)
        XCTAssertEqual(layout.xPosition(displayIndex: 2), 250)
    }
}
