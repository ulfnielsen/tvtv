import XCTest
import AppKit
import DuckDB
@testable import TVTVCore

/// Row selection, keyboard navigation, and copy-to-pasteboard.
@MainActor
final class RowSelectionTests: XCTestCase {

    private var database: Database!
    private var connection: Connection!

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW sel_fixture AS
            SELECT i AS id, ('row_' || i) AS label,
                   CASE WHEN i % 5 = 0 THEN NULL ELSE ('note_' || i) END AS note
            FROM range(500) AS t(i)
            """)
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    // MARK: - RowStore.rows(at:)

    func test_rowsAt_fetchesUnloadedRowsSynchronously_acrossPages() {
        // Page size 100 so the selection spans several (unloaded) pages.
        let store = RowStore(connection: connection, view: "sel_fixture", pageSize: 100)
        XCTAssertNil(store.row(at: 0), "precondition: nothing loaded")
        let rows = store.rows(at: IndexSet([3, 99, 100, 101, 450]))
        XCTAssertEqual(rows.map { $0.first }, [.text("3"), .text("99"), .text("100"), .text("101"), .text("450")])
        XCTAssertEqual(rows[2].last, .null) // 100 % 5 == 0
    }

    func test_rowsAt_respectsSortAndFilterSpec() {
        let spec = QuerySpec(whereClause: " WHERE id >= 10", orderBy: " ORDER BY id DESC")
        let store = RowStore(connection: connection, view: "sel_fixture", pageSize: 100, spec: spec)
        let rows = store.rows(at: IndexSet([0, 1, 489]))
        XCTAssertEqual(rows.map { $0.first }, [.text("499"), .text("498"), .text("10")])
    }

    func test_rowsAt_ignoresOutOfRangeIndexes() {
        let store = RowStore(connection: connection, view: "sel_fixture", pageSize: 100)
        XCTAssertEqual(store.rows(at: IndexSet([498, 499, 500, 9999])).count, 2)
    }

    func test_columnNames_exposed() {
        let store = RowStore(connection: connection, view: "sel_fixture", pageSize: 100)
        XCTAssertEqual(store.columns, ["id", "label", "note"])
    }

    // MARK: - TSV formatting

    func test_tsv_nullIsEmpty_andSpecialCharsQuoted() {
        let tsv = RowClipboard.tsv(
            header: ["a", "b"],
            rows: [[.text("x"), .null], [.text("tab\there"), .text("say \"hi\"\nbye")]]
        )
        XCTAssertEqual(tsv, "a\tb\nx\t\n\"tab\there\"\t\"say \"\"hi\"\"\nbye\"")
    }

    func test_tsv_withoutHeader() {
        XCTAssertEqual(RowClipboard.tsv(header: nil, rows: [[.text("1"), .text("2")]]), "1\t2")
    }

    // MARK: - GridTableView selection + copy

    private func hostedGrid(spec: QuerySpec = .init()) -> (GridTableView, NSWindow, RowStore) {
        let store = RowStore(connection: connection, view: "sel_fixture", pageSize: 100, spec: spec)
        // Display order reversed: note, label, id.
        let layout = ColumnLayout(columnNames: store.columns, order: [2, 1, 0])
        let grid = GridTableView(rowStore: store, columnLayout: layout)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(grid)
        grid.frame = window.contentView!.bounds
        window.layoutIfNeeded()
        grid.layoutSubtreeIfNeeded()
        return (grid, window, store)
    }

    func test_selectionIsEnabled_multiple_andReported() {
        let (grid, _, _) = hostedGrid()
        var reported: [Int] = []
        grid.onSelectionChanged = { reported.append($0) }
        grid.selectRows(IndexSet([1, 2, 3]))
        XCTAssertEqual(grid.selectedRowIndexes, IndexSet([1, 2, 3]))
        XCTAssertEqual(reported.last, 3)
    }

    func test_copyText_usesDisplayColumnOrder_withOptionalHeader() {
        let (grid, _, _) = hostedGrid()
        grid.selectRows(IndexSet([0, 2]))
        XCTAssertEqual(grid.copyText(includeHeader: false), "\trow_0\t0\nnote_2\trow_2\t2")
        XCTAssertEqual(grid.copyText(includeHeader: true), "note\tlabel\tid\n\trow_0\t0\nnote_2\trow_2\t2")
    }

    func test_copyText_isNilWithoutSelection() {
        let (grid, _, _) = hostedGrid()
        XCTAssertNil(grid.copyText(includeHeader: false))
    }

    func test_copy_writesToPasteboard() {
        let (grid, _, _) = hostedGrid()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tvtv.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        grid.selectRows(IndexSet([7]))
        XCTAssertTrue(grid.copySelection(includeHeader: false, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "note_7\trow_7\t7")
    }

    // MARK: - Keyboard navigation (pure target-row math)

    func test_navigationTarget() {
        XCTAssertEqual(GridTableView.targetRow(for: .home, current: 40, pageRows: 10, total: 500), 0)
        XCTAssertEqual(GridTableView.targetRow(for: .end, current: 40, pageRows: 10, total: 500), 499)
        XCTAssertEqual(GridTableView.targetRow(for: .pageDown, current: 40, pageRows: 10, total: 500), 50)
        XCTAssertEqual(GridTableView.targetRow(for: .pageUp, current: 5, pageRows: 10, total: 500), 0)
        XCTAssertEqual(GridTableView.targetRow(for: .pageDown, current: 495, pageRows: 10, total: 500), 499)
        // No current selection: page down starts from the top.
        XCTAssertEqual(GridTableView.targetRow(for: .pageDown, current: -1, pageRows: 10, total: 500), 10)
        XCTAssertNil(GridTableView.targetRow(for: .end, current: 0, pageRows: 10, total: 0))
    }

    func test_navigate_movesSelection_andShiftExtends() {
        let (grid, _, _) = hostedGrid()
        grid.selectRows(IndexSet([10]))
        grid.navigate(.end, extending: false)
        XCTAssertEqual(grid.selectedRowIndexes, IndexSet([499]))
        grid.navigate(.home, extending: true)
        XCTAssertEqual(grid.selectedRowIndexes, IndexSet(0...499))
    }

    // MARK: - Coordinator counts

    func test_coordinator_tracksSelection_andUnfilteredCount() throws {
        let coordinator = DataGridCoordinator(connection: connection)
        let columns = [
            ColumnInfo(name: "id", sourceIndex: 0),
            ColumnInfo(name: "label", sourceIndex: 1),
            ColumnInfo(name: "note", sourceIndex: 2),
        ]
        coordinator.switchTo(view: "sel_fixture", columns: columns)
        XCTAssertEqual(coordinator.totalRowCount, 500)
        XCTAssertEqual(coordinator.unfilteredRowCount, 500)
        XCTAssertEqual(coordinator.selectedRowCount, 0)

        coordinator.gridView?.selectRows(IndexSet([1, 2]))
        XCTAssertEqual(coordinator.selectedRowCount, 2)

        coordinator.setExcluded(["row_1", "row_2"], forColumn: "label")
        XCTAssertEqual(coordinator.totalRowCount, 498)
        XCTAssertEqual(coordinator.unfilteredRowCount, 500)
        XCTAssertEqual(coordinator.selectedRowCount, 0, "a rebuilt grid starts with no selection")
    }
}
