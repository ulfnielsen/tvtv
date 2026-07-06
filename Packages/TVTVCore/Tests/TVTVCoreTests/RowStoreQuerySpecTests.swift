import XCTest
import DuckDB
@testable import TVTVCore

/// Tests for `RowStore`'s `QuerySpec` (WHERE + ORDER BY) plumbing.
///
/// Fixture: an in-memory 25-row view (`id` 0...24, `name` "v<id>"). Small
/// and odd-sized deliberately, so a `WHERE id % 2 = 0` filter produces a
/// non-trivial, easily hand-verified row count (13: ids 0,2,4,...,24) and an
/// `ORDER BY id DESC` reorders the *filtered* set in a way that's obviously
/// wrong if WHERE/ORDER BY were mishandled (e.g. applied in the wrong place,
/// or ORDER BY leaking into the count query).
final class RowStoreQuerySpecTests: XCTestCase {

    static let pageSize = 10

    var database: Database!
    var connection: Connection!

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW query_spec_fixture AS
            SELECT range AS id, ('v' || range) AS name FROM range(25)
            """)
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    private func load(_ store: RowStore, around index: Int) {
        let expectation = expectation(description: "page containing \(index) loaded")
        store.onPageLoaded = { _ in expectation.fulfill() }
        store.ensureLoaded(around: index)
        wait(for: [expectation], timeout: 5)
    }

    // A QuerySpec with both WHERE and ORDER BY: totalRowCount reflects the
    // filtered count, and row(at:0) reflects the DESC-first filtered row.
    func testQuerySpecWithWhereAndOrderBy() {
        let spec = QuerySpec(whereClause: " WHERE id % 2 = 0", orderBy: " ORDER BY id DESC")
        let store = RowStore(connection: connection, view: "query_spec_fixture", pageSize: Self.pageSize, spec: spec)

        // 13 even ids in 0...24 (0,2,...,24).
        XCTAssertEqual(store.totalRowCount, 13)

        load(store, around: 0)

        // DESC order over evens: 24, 22, 20, ...
        XCTAssertEqual(store.row(at: 0), [.text("24"), .text("v24")])
        XCTAssertEqual(store.row(at: 1), [.text("22"), .text("v22")])
    }

    // OFFSET stride must still equal pageSize even with a spec applied —
    // verify by loading a page boundary (pageSize=10, so index 10 is the
    // start of page 1) and checking the value lines up with OFFSET 10.
    func testQuerySpecOffsetStrideEqualsPageSize() {
        let spec = QuerySpec(whereClause: " WHERE id % 2 = 0", orderBy: " ORDER BY id DESC")
        let store = RowStore(connection: connection, view: "query_spec_fixture", pageSize: Self.pageSize, spec: spec)

        load(store, around: 10)

        // Filtered+ordered sequence (DESC evens): 24,22,20,18,16,14,12,10,8,6 (page0, 10 rows),
        // then page1 starts at OFFSET 10: 4,2,0.
        XCTAssertEqual(store.row(at: 10), [.text("4"), .text("v4")])
    }

    // Regression guard: a default QuerySpec() must behave exactly as an
    // unfiltered, unsorted RowStore did before this change.
    func testDefaultQuerySpecBehavesAsBefore() {
        let plain = RowStore(connection: connection, view: "query_spec_fixture", pageSize: Self.pageSize)
        let defaulted = RowStore(connection: connection, view: "query_spec_fixture", pageSize: Self.pageSize, spec: QuerySpec())

        XCTAssertEqual(plain.totalRowCount, 25)
        XCTAssertEqual(defaulted.totalRowCount, 25)

        load(plain, around: 0)
        load(defaulted, around: 0)

        for i in 0..<Self.pageSize {
            XCTAssertEqual(plain.row(at: i), defaulted.row(at: i))
        }
    }
}
