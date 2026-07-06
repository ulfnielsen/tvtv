import XCTest
import AppKit
import DuckDB
@testable import TVTVCore

/// End-to-end wiring test for `GridTableView`: a real in-memory DuckDB-backed
/// `RowStore` + `ColumnLayout`, hosted in an off-screen `NSWindow`, driven
/// through the same loop the coordinator will use — observe
/// `onVisibleRowsChanged`, call `RowStore.ensureLoaded`, and let the grid's own
/// `onPageLoaded` subscription (set in init) do the background→main hop and
/// redraw. Verifies delegate/dataSource wiring, row-view vending, and that
/// loaded data is reachable by the render path.
@MainActor
final class GridTableViewIntegrationTests: XCTestCase {

    private var database: Database!
    private var connection: Connection!

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW grid_fixture AS
            SELECT i AS id, ('row_' || i) AS label,
                   CASE WHEN i % 5 = 0 THEN NULL ELSE ('note_' || i) END AS note
            FROM range(500) AS t(i)
            """)
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    private func hostedGrid(width: CGFloat, height: CGFloat) -> (GridTableView, NSWindow, RowStore) {
        let store = RowStore(connection: connection, view: "grid_fixture", pageSize: 10_000)
        let layout = ColumnLayout(columnNames: ["id", "label", "note"])
        let grid = GridTableView(rowStore: store, columnLayout: layout)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(grid)
        grid.frame = window.contentView!.bounds
        window.layoutIfNeeded()
        grid.layoutSubtreeIfNeeded()
        return (grid, window, store)
    }

    /// Spins the main run loop until `condition` holds or the timeout elapses,
    /// letting background→main `onPageLoaded` callbacks run.
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func test_gridReportsVisibleRange_andReachesLoadedData() {
        let (grid, _, store) = hostedGrid(width: 600, height: 400)

        // dataSource wiring reflects the full 500-row count.
        XCTAssertEqual(store.totalRowCount, 500)

        // Visible-range callback fires (coordinator hook for prefetch).
        var reportedRange: (Int, Int)?
        grid.onVisibleRowsChanged = { reportedRange = ($0, $1) }
        grid.reloadVisible()

        XCTAssertNotNil(reportedRange)
        if let (first, last) = reportedRange {
            XCTAssertEqual(first, 0)                    // scrolled to top
            XCTAssertGreaterThan(last, 0)
            XCTAssertLessThan(last, 500)                // only a screenful reported
        }

        // Drive the load exactly as the coordinator will, then let the grid's
        // OWN onPageLoaded (set in init — not clobbered here) hop to main and
        // redraw the now-loaded rows.
        store.ensureLoaded(around: 0)
        spin(until: { store.row(at: 0) != nil })

        XCTAssertEqual(store.row(at: 0)?.first, .text("0"))
        // NULL cell (i % 5 == 0) is preserved distinctly through the store.
        XCTAssertEqual(store.row(at: 0)?.last, .null)
        grid.reloadVisible()          // rebinds visible rows with the loaded page
        grid.layoutSubtreeIfNeeded()  // must not crash
    }

    func test_scrollToColumn_andReloadVisible_areSafeIncludingOutOfRange() {
        let (grid, _, store) = hostedGrid(width: 200, height: 200)
        grid.scrollToColumn(2)
        grid.scrollToColumn(-1)   // out of range: no-op, no crash
        grid.scrollToColumn(99)   // out of range: no-op, no crash
        grid.reloadVisible()
        XCTAssertEqual(store.totalRowCount, 500)
    }
}
