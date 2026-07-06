import XCTest
import DuckDB
@testable import TVTVCore

/// Tests for column sort: `SortDescriptor`, `DataGridCoordinator`'s
/// `toggleSort`/`buildOrderByClause`, and the end-to-end effect on a real
/// `RowStore` fed through the coordinator.
///
/// `buildOrderByClause()`: single
/// sorted column, ` ORDER BY "<name>" ASC|DESC`, empty when unsorted.
@MainActor
final class SortTests: XCTestCase {

    private var database: Database!
    private var connection: Connection!

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW sort_fixture AS
            SELECT range AS id, ('v' || (24 - range)) AS name FROM range(25)
            """)
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    // MARK: - toggleSort cycle: none -> asc -> desc -> none

    func test_toggleSort_cyclesNoneAscDescNone() {
        let columns = [
            ColumnInfo(name: "id", sourceIndex: 0),
            ColumnInfo(name: "name", sourceIndex: 1),
        ]
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sort_fixture", columns: columns)

        XCTAssertEqual(coordinator.sortDescriptors, [])

        coordinator.toggleSort(columnSourceIndex: 0)
        XCTAssertEqual(coordinator.sortDescriptors, [
            SortDescriptor(columnSourceIndex: 0, columnName: "id", ascending: true)
        ])

        coordinator.toggleSort(columnSourceIndex: 0)
        XCTAssertEqual(coordinator.sortDescriptors, [
            SortDescriptor(columnSourceIndex: 0, columnName: "id", ascending: false)
        ])

        coordinator.toggleSort(columnSourceIndex: 0)
        XCTAssertEqual(coordinator.sortDescriptors, [])
    }

    func test_toggleSort_onNewColumn_replacesPreviousColumnsSort() {
        let columns = [
            ColumnInfo(name: "id", sourceIndex: 0),
            ColumnInfo(name: "name", sourceIndex: 1),
        ]
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sort_fixture", columns: columns)

        coordinator.toggleSort(columnSourceIndex: 0) // id -> asc
        coordinator.toggleSort(columnSourceIndex: 1) // name -> asc, replacing id's sort

        XCTAssertEqual(coordinator.sortDescriptors, [
            SortDescriptor(columnSourceIndex: 1, columnName: "name", ascending: true)
        ])
    }

    // MARK: - buildOrderByClause

    func test_buildOrderByClause_emptyWhenUnsorted() {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sort_fixture", columns: [ColumnInfo(name: "id", sourceIndex: 0)])
        XCTAssertEqual(coordinator.buildOrderByClause(), "")
    }

    func test_buildOrderByClause_ascending() {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sort_fixture", columns: [ColumnInfo(name: "id", sourceIndex: 0)])
        coordinator.toggleSort(columnSourceIndex: 0)
        XCTAssertEqual(coordinator.buildOrderByClause(), " ORDER BY \"id\" ASC")
    }

    func test_buildOrderByClause_descending() {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sort_fixture", columns: [ColumnInfo(name: "id", sourceIndex: 0)])
        coordinator.toggleSort(columnSourceIndex: 0)
        coordinator.toggleSort(columnSourceIndex: 0)
        XCTAssertEqual(coordinator.buildOrderByClause(), " ORDER BY \"id\" DESC")
    }

    func test_buildOrderByClause_quotesEmbeddedDoubleQuote() {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sort_fixture", columns: [ColumnInfo(name: "weird\"name", sourceIndex: 0)])
        coordinator.toggleSort(columnSourceIndex: 0)
        XCTAssertEqual(coordinator.buildOrderByClause(), " ORDER BY \"weird\"\"name\" ASC")
    }

    // MARK: - End-to-end: RowStore actually returns sorted rows

    // Spin the main run loop until `condition` holds or timeout — lets the
    // background→main `onPageLoaded` hop run (same pattern as
    // DataGridCoordinatorTests).
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func test_toggleSort_rebuildsStore_rowsComeBackSorted() {
        let columns = [
            ColumnInfo(name: "id", sourceIndex: 0),
            ColumnInfo(name: "name", sourceIndex: 1),
        ]
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sort_fixture", columns: columns)

        // Unsorted (view's natural order): row 0 is id=0.
        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.dataVersion >= 1 })
        XCTAssertEqual(coordinator.rowForTesting(at: 0), [.text("0"), .text("v24")])

        // Sort ascending by "id": row 0 stays id=0 (already ascending), so
        // sort DESCENDING instead to make the change observable: toggle twice
        // (asc, then desc).
        coordinator.toggleSort(columnSourceIndex: 0) // asc
        coordinator.toggleSort(columnSourceIndex: 0) // desc

        let versionBeforeSortLoad = coordinator.dataVersion
        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.dataVersion > versionBeforeSortLoad })

        // DESC by id: row 0 should now be the max id (24).
        XCTAssertEqual(coordinator.rowForTesting(at: 0), [.text("24"), .text("v0")])
    }

    // Display -> source mapping: toggling sort by SOURCE index must work
    // correctly even when the header's display order has been permuted
    // (reused non-identity-order regression class from above).
    func test_toggleSort_viaDisplayToSourceMapping_nonIdentityOrder() {
        let columns = [
            ColumnInfo(name: "id", sourceIndex: 0),
            ColumnInfo(name: "name", sourceIndex: 1),
        ]
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sort_fixture", columns: columns)

        guard let header = coordinator.headerView else {
            return XCTFail("expected a header view after switchTo")
        }

        // Reverse the display order: [name, id] -- display index 0 is now
        // source column 1 ("name"), display index 1 is source column 0 ("id").
        header.columnLayout.moveColumn(from: 0, to: 2)

        // Simulate a tap on DISPLAY index 0 (which is now "name", source 1).
        let source = header.columnLayout.sourceIndex(displayIndex: 0)
        XCTAssertEqual(source, 1, "sanity: display 0 is source 1 after the reorder")

        coordinator.toggleSort(columnSourceIndex: source)
        XCTAssertEqual(coordinator.sortDescriptors, [
            SortDescriptor(columnSourceIndex: 1, columnName: "name", ascending: true)
        ])
        XCTAssertEqual(coordinator.buildOrderByClause(), " ORDER BY \"name\" ASC")
    }
}
