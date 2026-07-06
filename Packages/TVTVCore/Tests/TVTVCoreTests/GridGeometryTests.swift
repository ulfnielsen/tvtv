import XCTest
@testable import TVTVCore

/// `GridGeometry` design:
///
/// - Fixed `rowHeight` = 20.0, `intercellSpacing.height` = 2.0 ⇒ effective
///   row pitch = **22.0 pt**. All row math (content height, y-position,
///   visible range) uses the pitch, not bare `rowHeight`.
/// - **No vertical overscan.** This delegates to AppKit's
///   `rowsInRect(visibleRect)` semantics, which return exactly the rows whose
///   frame *geometrically intersects* the given rect — touching only at a
///   boundary line (zero-area overlap) does NOT count as intersecting.
///   `visibleRows` reproduces this as `floor(scrollY/22) ..<
///   ceil((scrollY+viewportHeight)/22)`, clamped to `0...totalRows`. There
///   is deliberately no `overscan` parameter — overscan (see `GridTableView`)
///   is horizontal-only.
final class GridGeometryTests: XCTestCase {

    // MARK: - yPosition / contentHeight (pitch = 22.0)

    func test_yPosition_isRowTimesPitch() {
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(geometry.yPosition(row: 0), 0)
        XCTAssertEqual(geometry.yPosition(row: 1), 22)
        XCTAssertEqual(geometry.yPosition(row: 10), 220)
    }

    func test_contentHeight_isTotalRowsTimesPitch() {
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(geometry.contentHeight(totalRows: 0), 0)
        XCTAssertEqual(geometry.contentHeight(totalRows: 1), 22)
        XCTAssertEqual(geometry.contentHeight(totalRows: 1000), 22000)
    }

    func test_defaultInit_usesConfiguredConstants() {
        // rowHeight: 20, intercellSpacingHeight: 2 -> pitch 22, matching
        // the standard AppKit configuration, without callers needing to
        // spell out the constants explicitly.
        let geometry = GridGeometry()
        XCTAssertEqual(geometry.yPosition(row: 1), 22)
        XCTAssertEqual(geometry.contentHeight(totalRows: 100), 2200)
    }

    // MARK: - visibleRows: basic range at 22pt pitch, no overscan

    func test_visibleRows_scrollYZero_wholeRowsFitExactly() {
        // viewport=100 -> ceil(100/22) = ceil(4.5454) = 5 -> rows 0..<5
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(
            geometry.visibleRows(scrollY: 0, viewportHeight: 100, totalRows: 1000),
            0..<5
        )
    }

    func test_visibleRows_fractionalOffBoundaryScrollY() {
        // scrollY=25 -> floor(25/22) = 1
        // scrollY+viewport = 125 -> ceil(125/22) = ceil(5.6818) = 6
        // -> rows 1..<6
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(
            geometry.visibleRows(scrollY: 25, viewportHeight: 100, totalRows: 1000),
            1..<6
        )
    }

    func test_visibleRows_exactBoundary_touchingRowIsExcluded() {
        // viewport exactly spans 2 full row-pitches (44 = 2*22): scrollY=0
        // means the viewport's bottom edge sits exactly at row 2's top
        // edge. A row whose rect only *touches* the viewport boundary (zero
        // overlap area) does not intersect it, per AppKit's
        // rowsInRect/NSIntersectsRect semantics -- so row 2 is excluded.
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(
            geometry.visibleRows(scrollY: 0, viewportHeight: 44, totalRows: 1000),
            0..<2
        )
    }

    func test_visibleRows_exactBoundary_scrollYOnRowEdge_previousRowExcluded() {
        // scrollY=22 lands exactly on row 1's top edge / row 0's bottom
        // edge. Row 0's span [0,22) does not intersect [22, 66) -- only
        // touches at the boundary -- so it must be excluded, mirroring the
        // bottom-edge exclusion above.
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(
            geometry.visibleRows(scrollY: 22, viewportHeight: 44, totalRows: 1000),
            1..<3
        )
    }

    // MARK: - jump-to-end: upper-clamped to totalRows, no out-of-range

    func test_visibleRows_jumpToEnd_clampsToTotalRows() {
        // totalRows=1000 -> contentHeight=22000. scrollY=21950 is near the
        // end: floor(21950/22) = 997; (21950+100)=22050, ceil(22050/22) =
        // 1003 (out of range) -> clamped down to totalRows=1000.
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(
            geometry.visibleRows(scrollY: 21950, viewportHeight: 100, totalRows: 1000),
            997..<1000
        )
    }

    func test_visibleRows_scrollYPastContentEnd_isEmptyNotOutOfRange() {
        // scrollY way beyond contentHeight -> both bounds clamp to
        // totalRows, yielding an empty (but valid, in-range) range.
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        let range = geometry.visibleRows(scrollY: 1_000_000, viewportHeight: 100, totalRows: 1000)
        XCTAssertEqual(range, 1000..<1000)
    }

    func test_visibleRows_negativeScrollY_clampsLowerBoundToZero() {
        // A negative scrollY (e.g. rubber-band overscroll) must not yield a
        // negative row index.
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(
            geometry.visibleRows(scrollY: -50, viewportHeight: 100, totalRows: 1000),
            0..<3
        )
    }

    // MARK: - empty grid

    func test_visibleRows_zeroTotalRows_isEmptyRange() {
        let geometry = GridGeometry(rowHeight: 20, intercellSpacingHeight: 2)
        XCTAssertEqual(
            geometry.visibleRows(scrollY: 0, viewportHeight: 500, totalRows: 0),
            0..<0
        )
    }
}
