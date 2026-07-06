import XCTest
import DuckDB
@testable import TVTVCore

/// Tests exercise a real in-memory DuckDB database (no mocks). The fixture
/// view has 25 000 rows (2.5 pages at pageSize=10000: page0 [0..<10000],
/// page1 [10000..<20000], page2 [20000..<25000] — a deliberately *partial*
/// last page so tests can also confirm end-of-data / non-full-page paging).
///
/// Columns:
///   - id:    BIGINT, values 0...24999
///   - label: VARCHAR, "row_<i>"
///   - note:  VARCHAR, "note_<i>" except NULL when i % 7 == 0
///
/// Every column is fetched by RowStore cast `::VARCHAR` (the page-fetch
/// query's shape), so expected cell values are always .text(String)
/// or .null — never .int/.double, matching the Cell YAGNI decision.
final class RowStoreTests: XCTestCase {

    static let fixtureRowCount = 25_000
    static let pageSize = 10_000

    var database: Database!
    var connection: Connection!

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW row_store_fixture AS
            SELECT
                i AS id,
                ('row_' || i) AS label,
                CASE WHEN i % 7 = 0 THEN NULL ELSE ('note_' || i) END AS note
            FROM range(\(Self.fixtureRowCount)) AS t(i)
            """)
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    private func expectedCells(forRow i: Int) -> [Cell] {
        let note: Cell = (i % 7 == 0) ? .null : .text("note_\(i)")
        return [.text("\(i)"), .text("row_\(i)"), note]
    }

    // (a) totalRowCount equals fixture row count.
    func testTotalRowCountMatchesFixture() {
        let store = RowStore(connection: connection, view: "row_store_fixture", pageSize: Self.pageSize)
        XCTAssertEqual(store.totalRowCount, Self.fixtureRowCount)
    }

    // Cell-editing support: with includesRowID (base TABLE), the implicit
    // DuckDB rowid is loaded per row WITHOUT appearing as a display cell, and
    // invalidatePage drops a cached page for re-fetch after an edit.
    func testIncludesRowIDLoadsRowIDsWithoutExtraDisplayColumn() throws {
        try connection.execute(
            "CREATE TABLE edit_fixture AS SELECT i AS id, ('v_' || i) AS label FROM range(30) AS t(i)")
        let store = RowStore(connection: connection, view: "edit_fixture",
                             pageSize: Self.pageSize, includesRowID: true)

        let loaded = expectation(description: "page loaded")
        store.onPageLoaded = { _ in loaded.fulfill() }
        store.ensureLoaded(around: 0)
        wait(for: [loaded], timeout: 5)

        // Display cells are exactly the two real columns — rowid is NOT one.
        XCTAssertEqual(store.row(at: 0)?.count, 2)
        XCTAssertEqual(store.row(at: 0), [.text("0"), .text("v_0")])
        // rowid is populated for loaded rows.
        XCTAssertNotNil(store.rowID(at: 0))
        XCTAssertNotNil(store.rowID(at: 29))

        // invalidatePage drops the page so the next ensureLoaded re-fetches.
        store.invalidatePage(containing: 0)
        XCTAssertNil(store.row(at: 0))
        XCTAssertNil(store.rowID(at: 0))
    }

    // Without includesRowID, rowID(at:) is always nil (read-only views).
    func testRowIDIsNilWhenNotTrackingRowIDs() {
        let store = RowStore(connection: connection, view: "row_store_fixture", pageSize: Self.pageSize)
        let loaded = expectation(description: "loaded")
        store.onPageLoaded = { _ in loaded.fulfill() }
        store.ensureLoaded(around: 0)
        wait(for: [loaded], timeout: 5)
        XCTAssertNil(store.rowID(at: 0))
    }

    // (b) row(at:) is nil before load, then correct after ensureLoaded + onPageLoaded fires.
    func testRowIsNilBeforeLoadThenCorrectAfterEnsureLoaded() {
        let store = RowStore(connection: connection, view: "row_store_fixture", pageSize: Self.pageSize)

        XCTAssertNil(store.row(at: 0))

        let expectation = expectation(description: "page 0 loaded")
        store.onPageLoaded = { range in
            XCTAssertEqual(range, 0..<10_000)
            expectation.fulfill()
        }
        store.ensureLoaded(around: 0)
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(store.row(at: 0), expectedCells(forRow: 0))
        XCTAssertEqual(store.row(at: 9_999), expectedCells(forRow: 9_999))
    }

    // (c) ensureLoaded(around: n) loads the page containing row n and fires
    // onPageLoaded for that page's range — using a middle index, not just page 0.
    func testEnsureLoadedLoadsPageContainingIndex() {
        let store = RowStore(connection: connection, view: "row_store_fixture", pageSize: Self.pageSize)

        let expectation = expectation(description: "page containing row 12345 loaded")
        store.onPageLoaded = { range in
            XCTAssertEqual(range, 10_000..<20_000)
            expectation.fulfill()
        }
        store.ensureLoaded(around: 12_345)
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(store.row(at: 12_345), expectedCells(forRow: 12_345))
        // Neighbor page must still be unloaded — ensureLoaded only loads the
        // page containing the requested index, not a range of pages.
        XCTAssertNil(store.row(at: 0))
    }

    // (d) OFFSET/LIMIT stride equals pageSize (10000): verified by checking
    // the exact row values straddling the page-1/page-2 boundary. If the
    // stride were wrong (e.g. off-by-one, or page*pageSize computed
    // incorrectly), these values would not line up.
    func testOffsetStrideEqualsPageSize() {
        let store = RowStore(connection: connection, view: "row_store_fixture", pageSize: Self.pageSize)

        let expectation = expectation(description: "page 1 loaded")
        store.onPageLoaded = { _ in expectation.fulfill() }
        store.ensureLoaded(around: 15_000)
        wait(for: [expectation], timeout: 5)

        // First and last row of page 1 (rows 10000 and 19999) must match
        // OFFSET 10000 LIMIT 10000 exactly.
        XCTAssertEqual(store.row(at: 10_000), expectedCells(forRow: 10_000))
        XCTAssertEqual(store.row(at: 19_999), expectedCells(forRow: 19_999))
    }

    // Non-sequential jump: load the LAST page directly (a grid must support
    // jump-to-end) without ever having loaded page 0 or page 1. The last
    // page is also a *partial* page (5000 rows, not 10000), exercising
    // end-of-data sizing at the same time.
    func testJumpToLastPageLoadsDirectlyWithoutSequentialPages() {
        let store = RowStore(connection: connection, view: "row_store_fixture", pageSize: Self.pageSize)

        let lastIndex = Self.fixtureRowCount - 1 // 24999

        let expectation = expectation(description: "last (partial) page loaded")
        store.onPageLoaded = { range in
            XCTAssertEqual(range, 20_000..<25_000)
            expectation.fulfill()
        }
        store.ensureLoaded(around: lastIndex)
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(store.row(at: lastIndex), expectedCells(forRow: lastIndex))
        XCTAssertEqual(store.row(at: 20_000), expectedCells(forRow: 20_000))

        // Earlier pages were never requested — confirms this was a true
        // random-access jump, not a sequential walk from page 0.
        XCTAssertNil(store.row(at: 0))
        XCTAssertNil(store.row(at: 12_345))
    }
}
