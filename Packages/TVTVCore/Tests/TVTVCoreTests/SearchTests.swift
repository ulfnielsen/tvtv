import XCTest
import DuckDB
@testable import TVTVCore

/// Tests for cell search: `DataGridCoordinator`'s
/// `searchTerm`/`searchTermLower`/`matchingColumnIndices`/`currentMatch`,
/// the pure `matches(inRow:)` helper, and `nextMatch`/`previousMatch`.
///
/// `draw(_:)`'s cell-rendering match test is
/// `values[i].lowercased().contains(searchTermLower)`, a plain
/// case-insensitive substring test. Search is **in-memory over currently
/// LOADED rows** — never a SQL scan — so several tests here deliberately load
/// only PART of a fixture (via `handleVisibleRows` + `spin`, the same pattern
/// `SortTests`/`FilterTests` use to let the background→main page-load hop
/// run) and assert that rows outside the loaded range are NOT matched.
///
/// Index-space note: `matches(inRow:)`,
/// `matchingColumnIndices`, and `currentMatch.col` are all **SOURCE** column
/// indices — the same order `RowStore.row(at:)` returns cells in — not
/// display indices. `currentMatch.row` is an **absolute** row index (the same
/// space `RowStore.row(at:)`/`GridTableView`'s `row` parameter use).
@MainActor
final class SearchTests: XCTestCase {

    private var database: Database!
    private var connection: Connection!

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    // Spin the main run loop until `condition` holds or timeout — lets the
    // background→main `onPageLoaded` hop run (same pattern as
    // SortTests/FilterTests).
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func makeCoordinator(view: String, columns: [ColumnInfo]) -> DataGridCoordinator {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: view, columns: columns)
        return coordinator
    }

    // MARK: - matches(inRow:): pure helper

    func test_matchesInRow_caseInsensitiveSubstring() throws {
        try connection.execute("CREATE VIEW search_pure AS SELECT range AS id FROM range(1)")
        let coordinator = makeCoordinator(view: "search_pure", columns: [ColumnInfo(name: "id", sourceIndex: 0)])
        coordinator.searchTerm = "ELL"

        let row: [Cell] = [.text("Hello"), .text("world"), .text("shell")]
        XCTAssertEqual(coordinator.matches(inRow: row), [0, 2])
    }

    func test_matchesInRow_emptyWhenNoMatch() throws {
        try connection.execute("CREATE VIEW search_pure AS SELECT range AS id FROM range(1)")
        let coordinator = makeCoordinator(view: "search_pure", columns: [ColumnInfo(name: "id", sourceIndex: 0)])
        coordinator.searchTerm = "zzz"

        let row: [Cell] = [.text("Hello"), .text("world")]
        XCTAssertEqual(coordinator.matches(inRow: row), [])
    }

    func test_matchesInRow_emptyWhenSearchTermEmpty() throws {
        try connection.execute("CREATE VIEW search_pure AS SELECT range AS id FROM range(1)")
        let coordinator = makeCoordinator(view: "search_pure", columns: [ColumnInfo(name: "id", sourceIndex: 0)])
        XCTAssertEqual(coordinator.searchTerm, "")

        let row: [Cell] = [.text("anything"), .text("matches nothing when term is empty")]
        XCTAssertEqual(coordinator.matches(inRow: row), [])
    }

    func test_matchesInRow_nullCellNeverMatches() throws {
        try connection.execute("CREATE VIEW search_pure AS SELECT range AS id FROM range(1)")
        let coordinator = makeCoordinator(view: "search_pure", columns: [ColumnInfo(name: "id", sourceIndex: 0)])
        coordinator.searchTerm = "null"

        // A literal ".null" cell (SQL NULL) must never match, even though the
        // string "null" is the search term itself.
        let row: [Cell] = [.null, .text("this has null in it")]
        XCTAssertEqual(coordinator.matches(inRow: row), [1])
    }

    // MARK: - matchingColumnIndices: aggregation over loaded rows

    func test_matchingColumnIndices_aggregatesAcrossLoadedRows() throws {
        try connection.execute("""
            CREATE VIEW search_agg AS
            SELECT range AS id,
                   CASE WHEN range = 1 THEN 'apple' ELSE 'x' || range END AS a,
                   CASE WHEN range = 3 THEN 'apple pie' ELSE 'y' || range END AS b
            FROM range(10)
            """)
        let columns = [
            ColumnInfo(name: "id", sourceIndex: 0),
            ColumnInfo(name: "a", sourceIndex: 1),
            ColumnInfo(name: "b", sourceIndex: 2),
        ]
        let coordinator = makeCoordinator(view: "search_agg", columns: columns)

        coordinator.handleVisibleRows(first: 0, last: 9)
        spin(until: { coordinator.dataVersion >= 1 })

        coordinator.searchTerm = "apple"

        // Column "a" (source 1) matches at row 1, column "b" (source 2)
        // matches at row 3 -- both source indices must be aggregated.
        XCTAssertEqual(coordinator.matchingColumnIndices, [1, 2])
    }

    func test_matchingColumnIndices_emptyWhenNoLoadedRowsMatch() throws {
        try connection.execute("CREATE VIEW search_none AS SELECT range AS id, ('v' || range) AS name FROM range(5)")
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "name", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "search_none", columns: columns)

        coordinator.handleVisibleRows(first: 0, last: 4)
        spin(until: { coordinator.dataVersion >= 1 })

        coordinator.searchTerm = "zzz-not-present"
        XCTAssertEqual(coordinator.matchingColumnIndices, [])
        XCTAssertNil(coordinator.currentMatch)
    }

    // MARK: - matchingColumnNameIndices: column-NAME search
    //
    // Typing "SEQ" finds nothing via `matchingColumnIndices` (cell-value
    // search) when no loaded CELL contains "SEQ" -- but should still surface
    // an `EGSEQ` COLUMN as a match via `matchingColumnNameIndices`, a
    // case-insensitive substring test over `currentColumns.name` (no row
    // data involved, so it doesn't depend on anything being loaded).

    func test_matchingColumnNameIndices_caseInsensitiveSubstring_overColumnNames() throws {
        try connection.execute("CREATE VIEW colname_fixture AS SELECT range AS id, ('v' || range) AS egseq FROM range(5)")
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "EGSEQ", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "colname_fixture", columns: columns)

        // No loaded row's cell VALUE contains "seq" -- cell-value search
        // finds zero matches -- but the column NAME "EGSEQ" does.
        coordinator.searchTerm = "seq"
        XCTAssertEqual(coordinator.matchingColumnNameIndices, [1])
        XCTAssertEqual(coordinator.matchCount, 0, "column-name matches must NOT be folded into the cell-value match count")
    }

    func test_matchingColumnNameIndices_emptyWhenNoColumnNameMatches() throws {
        try connection.execute("CREATE VIEW colname_none AS SELECT range AS id FROM range(1)")
        let coordinator = makeCoordinator(view: "colname_none", columns: [ColumnInfo(name: "id", sourceIndex: 0)])

        coordinator.searchTerm = "zzz-not-a-column"
        XCTAssertEqual(coordinator.matchingColumnNameIndices, [])
    }

    func test_matchingColumnNameIndices_clearedWhenSearchTermCleared() throws {
        try connection.execute("CREATE VIEW colname_clear AS SELECT range AS id, ('v' || range) AS egseq FROM range(1)")
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "EGSEQ", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "colname_clear", columns: columns)

        coordinator.searchTerm = "seq"
        XCTAssertEqual(coordinator.matchingColumnNameIndices, [1])

        coordinator.searchTerm = ""
        XCTAssertEqual(coordinator.matchingColumnNameIndices, [])
    }

    /// Multiple columns can match a column-name search; every one of their
    /// SOURCE indices must be present, regardless of `currentColumns`' own
    /// (source-index) ordering.
    func test_matchingColumnNameIndices_multipleMatches_nonIdentitySourceIndex() throws {
        try connection.execute("""
            CREATE VIEW colname_multi AS
            SELECT range AS id, ('a' || range) AS egseq, ('b' || range) AS otherseq
            FROM range(1)
            """)
        // Deliberately non-identity / gapped source indices, matching this
        // file's existing convention for proving SOURCE (not array position)
        // is what's keyed off of.
        let columns = [
            ColumnInfo(name: "otherseq", sourceIndex: 5),
            ColumnInfo(name: "id", sourceIndex: 0),
            ColumnInfo(name: "egseq", sourceIndex: 2),
        ]
        let coordinator = makeCoordinator(view: "colname_multi", columns: columns)

        coordinator.searchTerm = "seq"
        XCTAssertEqual(coordinator.matchingColumnNameIndices, [5, 2])
    }

    /// `matchingColumnNameIndices` (and the header push it drives) must
    /// re-key correctly when columns are displayed in a non-identity order --
    /// proving the SOURCE index space (what `matchingColumnNameIndices`/
    /// `GridTableHeaderView.searchedColumns` use) is never confused with the
    /// DISPLAY index space `GridTableView.scrollToColumn(_:)` wants. The
    /// actual source→display inverse arithmetic is pinned directly in
    /// `ColumnLayoutTests.test_displayIndex_isInverseOfSourceIndex_underNonIdentityOrder`;
    /// this test proves the coordinator drives that mapping end-to-end
    /// without crashing and without corrupting the SOURCE-space state it
    /// publishes.
    func test_matchingColumnNameIndices_andHeaderHighlight_surviveNonIdentityDisplayOrder() throws {
        try connection.execute("CREATE VIEW colname_reorder AS SELECT range AS id, ('v' || range) AS egseq FROM range(3)")
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "EGSEQ", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "colname_reorder", columns: columns)

        // Reorder so EGSEQ (source 1) now displays FIRST -- the header is
        // the authoritative post-reorder layout (mirrors the convention
        // `header.onColumnResized`/`onColumnsReordered` wiring documents).
        guard let header = coordinator.headerView else { return XCTFail("expected a headerView after switchTo") }
        header.columnLayout = ColumnLayout(widths: [100, 100], order: [1, 0])
        header.onColumnsReordered?([1, 0])

        coordinator.searchTerm = "seq"

        // SOURCE-space state is unaffected by display order.
        XCTAssertEqual(coordinator.matchingColumnNameIndices, [1])
        XCTAssertEqual(coordinator.headerView?.searchedColumns, [1])
    }

    // MARK: - Search is over LOADED rows only, not the whole file

    func test_search_onlyConsidersLoadedRows_notWholeFile() throws {
        // Bigger than one page (pageSize == 10_000) so only page 0 loads when
        // we ask for rows within it; page 1 (>= 10_000) stays unloaded.
        let totalRows = DataGridCoordinator.pageSize + 50
        try connection.execute("""
            CREATE VIEW search_paged AS
            SELECT range AS id, 'needle_' || range AS label FROM range(\(totalRows))
            """)
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "label", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "search_paged", columns: columns)

        // Load only page 0 (rows within the first page).
        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.dataVersion >= 1 })
        XCTAssertNil(coordinator.rowForTesting(at: DataGridCoordinator.pageSize + 1), "page 1 must still be unloaded")

        // Every row's label contains "needle_", including unloaded rows in
        // page 1 -- but ONLY loaded (page 0) rows may show up as matches.
        coordinator.searchTerm = "needle_"

        XCTAssertFalse(coordinator.matchListForTesting().isEmpty)
        for match in coordinator.matchListForTesting() {
            XCTAssertLessThan(match.row, DataGridCoordinator.pageSize, "a match must come from a LOADED row, not a SQL scan of the whole file")
        }
    }

    // MARK: - currentMatch: set to first match, cleared when term is cleared

    func test_currentMatch_setToFirstMatch_andClearedWithTerm() throws {
        try connection.execute("""
            CREATE VIEW search_first AS
            SELECT range AS id, CASE WHEN range IN (2, 5, 8) THEN 'target' ELSE 'other' END AS label
            FROM range(10)
            """)
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "label", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "search_first", columns: columns)

        coordinator.handleVisibleRows(first: 0, last: 9)
        spin(until: { coordinator.dataVersion >= 1 })

        coordinator.searchTerm = "target"
        XCTAssertEqual(coordinator.currentMatch?.row, 2)
        XCTAssertEqual(coordinator.currentMatch?.col, 1)

        coordinator.searchTerm = ""
        XCTAssertNil(coordinator.currentMatch)
        XCTAssertEqual(coordinator.matchingColumnIndices, [])
        XCTAssertEqual(coordinator.searchTermLower, "")
    }

    // MARK: - nextMatch / previousMatch: cycle with wrap-around

    func test_nextMatch_and_previousMatch_cycleWithWrapAround() throws {
        try connection.execute("""
            CREATE VIEW search_cycle AS
            SELECT range AS id, CASE WHEN range IN (1, 4, 7) THEN 'hit' ELSE 'miss' END AS label
            FROM range(10)
            """)
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "label", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "search_cycle", columns: columns)

        coordinator.handleVisibleRows(first: 0, last: 9)
        spin(until: { coordinator.dataVersion >= 1 })

        coordinator.searchTerm = "hit"
        XCTAssertEqual(coordinator.currentMatch?.row, 1)

        coordinator.nextMatch()
        XCTAssertEqual(coordinator.currentMatch?.row, 4)

        coordinator.nextMatch()
        XCTAssertEqual(coordinator.currentMatch?.row, 7)

        // Wrap forward past the last match back to the first.
        coordinator.nextMatch()
        XCTAssertEqual(coordinator.currentMatch?.row, 1)

        // Wrap backward past the first match back to the last.
        coordinator.previousMatch()
        XCTAssertEqual(coordinator.currentMatch?.row, 7)

        coordinator.previousMatch()
        XCTAssertEqual(coordinator.currentMatch?.row, 4)
    }

    // MARK: - Regression: matches must grow as more pages load during an active search

    /// Regression test for the review finding: `recomputeMatches()` used to
    /// be wired ONLY to `searchTerm`'s `didSet`, never to `applyPageLoaded` —
    /// so once a search was active, matches in rows loaded by a LATER page
    /// load (scrolling further into the file) never entered `matchList`/
    /// `matchingColumnIndices`, and the toolbar's "N of M" count went stale
    /// (even though those cells still visually highlighted, since the grid
    /// applies `searchTermLower` per-cell independent of `matchList`).
    ///
    /// This must FAIL without the `applyPageLoaded` → `recomputeMatches()`
    /// wiring and PASS with it (verified by temporarily reverting the fix).
    func test_matchList_growsWhenNewPageLoadsWhileSearchActive() throws {
        // Bigger than one page so page 0 and page 1 are distinct loads.
        let totalRows = DataGridCoordinator.pageSize + 50
        try connection.execute("""
            CREATE VIEW search_growing AS
            SELECT range AS id, 'needle_' || range AS label FROM range(\(totalRows))
            """)
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "label", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "search_growing", columns: columns)

        // Load only page 0.
        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.dataVersion >= 1 })
        XCTAssertNil(coordinator.rowForTesting(at: DataGridCoordinator.pageSize + 1), "page 1 must still be unloaded")

        coordinator.searchTerm = "needle_"

        // Every row's "label" matches -- but with only page 0 loaded, the
        // initial count/list must cover ONLY page-0 rows.
        XCTAssertEqual(coordinator.matchCount, DataGridCoordinator.pageSize)
        for match in coordinator.matchListForTesting() {
            XCTAssertLessThan(match.row, DataGridCoordinator.pageSize, "initial matches must come only from the loaded page-0 rows")
        }

        // Now load page 1 -- WITHOUT touching searchTerm again. If matches
        // are recomputed on page load, the count/list must grow to cover the
        // newly-loaded page-1 rows too.
        let versionBeforePage1 = coordinator.dataVersion
        coordinator.handleVisibleRows(first: DataGridCoordinator.pageSize + 10, last: DataGridCoordinator.pageSize + 15)
        spin(until: { coordinator.dataVersion > versionBeforePage1 })
        XCTAssertNotNil(coordinator.rowForTesting(at: DataGridCoordinator.pageSize + 1), "page 1 must now be loaded")

        XCTAssertEqual(coordinator.matchCount, totalRows, "match count must grow to include page-1 matches once that page loads")
        XCTAssertEqual(coordinator.matchingColumnIndices, [1])
        XCTAssertTrue(
            coordinator.matchListForTesting().contains(where: { $0.row >= DataGridCoordinator.pageSize }),
            "matchList must include at least one page-1 row after the page-load recompute"
        )
    }

    // MARK: - Regression: searchTerm must not leak across a view switch

    /// Regression test for the whole-branch review finding: `switchTo` reset
    /// `sortDescriptors`/`excludedValues`/`distinctValueCache` for the new
    /// view but left `searchTerm` untouched. So opening a new file / running
    /// a SQL query / returning to file (all routed through `switchTo`) while
    /// a search was active carried the OLD view's search term into the NEW
    /// view — `rebuildStore`'s `recomputeMatches()` would then recompute
    /// matches against the new view's (possibly totally different-schema)
    /// rows, showing a stale "N of M" and highlights for a term the user
    /// never typed there.
    ///
    /// This must FAIL without the `searchTerm = ""` reset in `switchTo` and
    /// PASS with it (verified by temporarily reverting the fix).
    func test_switchTo_resetsSearchTerm_notLeakedFromPreviousView() throws {
        try connection.execute("""
            CREATE VIEW search_view_a AS
            SELECT range AS id, 'needle_' || range AS label FROM range(10)
            """)
        try connection.execute("""
            CREATE VIEW search_view_b AS
            SELECT range AS other_id, 'row_' || range AS description FROM range(10)
            """)
        let columnsA = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "label", sourceIndex: 1)]
        let columnsB = [ColumnInfo(name: "other_id", sourceIndex: 0), ColumnInfo(name: "description", sourceIndex: 1)]

        let coordinator = makeCoordinator(view: "search_view_a", columns: columnsA)
        coordinator.handleVisibleRows(first: 0, last: 9)
        spin(until: { coordinator.dataVersion >= 1 })

        coordinator.searchTerm = "needle_"
        XCTAssertFalse(coordinator.matchListForTesting().isEmpty, "sanity check: search must match something in view A")
        XCTAssertNotNil(coordinator.currentMatch)

        // Switch to a different, unrelated view -- a real view switch, not a
        // sort/filter change on the same view.
        coordinator.switchTo(view: "search_view_b", columns: columnsB)

        XCTAssertEqual(coordinator.searchTerm, "", "searchTerm must be cleared on a real view switch")
        XCTAssertEqual(coordinator.searchTermLower, "", "searchTermLower must be cleared on a real view switch")
        XCTAssertEqual(coordinator.matchingColumnIndices, [], "matchingColumnIndices must be cleared on a real view switch")
        XCTAssertEqual(coordinator.matchingColumnNameIndices, [], "matchingColumnNameIndices must be cleared on a real view switch")
        XCTAssertNil(coordinator.currentMatch, "currentMatch must be cleared on a real view switch")
        XCTAssertTrue(coordinator.matchListForTesting().isEmpty, "matchList must be cleared on a real view switch")

        // Load view B's rows too, to prove no stale match resurfaces once
        // rows load (an active-but-empty search term must stay inert).
        coordinator.handleVisibleRows(first: 0, last: 9)
        spin(until: { coordinator.dataVersion >= 1 })
        XCTAssertTrue(coordinator.matchListForTesting().isEmpty, "no matches should reappear after view B's rows load")
    }

    // MARK: - Contrast: toggleSort/setExcluded must NOT clear an active search

    /// The flip side of the above: `toggleSort`/`setExcluded` intentionally
    /// preserve `searchTerm` across a sort/filter change on the SAME view
    /// (only a true `switchTo` view switch should clear it). This guards
    /// against an over-eager fix that clears the term anywhere `rebuildStore`
    /// runs, rather than only in `switchTo`.
    func test_toggleSortAndSetExcluded_preserveActiveSearchTerm() throws {
        try connection.execute("""
            CREATE VIEW search_preserve AS
            SELECT range AS id, CASE WHEN range IN (2, 5, 8) THEN 'target' ELSE 'other' END AS label
            FROM range(10)
            """)
        let columns = [ColumnInfo(name: "id", sourceIndex: 0), ColumnInfo(name: "label", sourceIndex: 1)]
        let coordinator = makeCoordinator(view: "search_preserve", columns: columns)

        coordinator.handleVisibleRows(first: 0, last: 9)
        spin(until: { coordinator.dataVersion >= 1 })

        coordinator.searchTerm = "target"
        XCTAssertNotNil(coordinator.currentMatch)

        let versionBeforeSort = coordinator.dataVersion
        coordinator.toggleSort(columnSourceIndex: 0)
        coordinator.handleVisibleRows(first: 0, last: 9)
        spin(until: { coordinator.dataVersion > versionBeforeSort })
        XCTAssertEqual(coordinator.searchTerm, "target", "toggleSort must NOT reset an active search term")

        let versionBeforeFilter = coordinator.dataVersion
        coordinator.setExcluded(["other"], forColumn: "label")
        coordinator.handleVisibleRows(first: 0, last: 9)
        spin(until: { coordinator.dataVersion > versionBeforeFilter })
        XCTAssertEqual(coordinator.searchTerm, "target", "setExcluded must NOT reset an active search term")
    }

    func test_nextMatch_and_previousMatch_noOpWhenNoMatches() throws {
        try connection.execute("CREATE VIEW search_empty AS SELECT range AS id FROM range(5)")
        let coordinator = makeCoordinator(view: "search_empty", columns: [ColumnInfo(name: "id", sourceIndex: 0)])

        coordinator.handleVisibleRows(first: 0, last: 4)
        spin(until: { coordinator.dataVersion >= 1 })

        coordinator.searchTerm = "no-such-value"
        XCTAssertNil(coordinator.currentMatch)

        coordinator.nextMatch()
        XCTAssertNil(coordinator.currentMatch)

        coordinator.previousMatch()
        XCTAssertNil(coordinator.currentMatch)
    }
}
