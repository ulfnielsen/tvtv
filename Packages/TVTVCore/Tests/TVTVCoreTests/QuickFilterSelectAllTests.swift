import XCTest
import DuckDB
@testable import TVTVCore

@MainActor
final class QuickFilterSelectAllTests: XCTestCase {
    private let null = QuickFilterPopover.nullRowValue

    func test_selectAll_includesEveryListedValueAndNull() {
        let excluded: Set<String> = ["a", "b", null]
        XCTAssertEqual(QuickFilterPopover.selectingAll(values: ["a", "b", "c"], excluded: excluded), [])
    }

    func test_selectAll_keepsExclusionsForValuesNotListed() {
        // A value excluded earlier but absent from this (possibly capped) list
        // isn't visible, so Select All must not silently re-include it.
        XCTAssertEqual(QuickFilterPopover.selectingAll(values: ["a"], excluded: ["a", "zz"]), ["zz"])
    }

    func test_selectNone_excludesEveryListedValueAndNull() {
        XCTAssertEqual(QuickFilterPopover.selectingNone(values: ["a", "b"], excluded: ["zz"]),
                       ["a", "b", null, "zz"])
    }

    func test_selectNone_thenApply_hidesAllRows() throws {
        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        try connection.execute("CREATE VIEW v AS SELECT * FROM (VALUES ('a'), ('b'), (NULL)) t(x)")
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "v", columns: [ColumnInfo(name: "x", sourceIndex: 0)])
        let values = coordinator.fetchDistinctValues(forColumn: "x")
        coordinator.setExcluded(QuickFilterPopover.selectingNone(values: values, excluded: []), forColumn: "x")
        XCTAssertEqual(coordinator.totalRowCount, 0)
        coordinator.setExcluded(QuickFilterPopover.selectingAll(values: values, excluded: coordinator.excludedValues["x"] ?? []),
                                forColumn: "x")
        XCTAssertEqual(coordinator.totalRowCount, 3)
    }
}
