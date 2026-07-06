import XCTest
import DuckDB
@testable import TVTVCore

/// Tests for per-column quick-filter: `DataGridCoordinator`'s
/// `excludedValues`/`setExcluded`/`fetchDistinctValues`/`buildWhereClause`,
/// and its composition with sort (`buildOrderByClause`).
///
/// `buildWhereClause()`'s three branches: values-only
/// exclusion → `"<col>"::VARCHAR NOT IN (...)`; NULL-only → `"<col>" IS NOT
/// NULL`; values+NULL → `("<col>"::VARCHAR NOT IN (...) AND "<col>" IS NOT
/// NULL)`; conditions for multiple columns joined ` AND `, prefixed ` WHERE `;
/// empty when nothing is excluded. NULL exclusion is represented by the
/// sentinel `DataGridCoordinator.nullSentinel` inside a column's
/// `excludedValues` set (see that constant's doc for the representation and
/// its one documented simplifying assumption).
///
/// Multi-column/multi-value ordering: this implementation sorts column names
/// and values alphabetically for determinism, and these tests pin that choice.
@MainActor
final class FilterTests: XCTestCase {

    private var database: Database!
    private var connection: Connection!

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW filter_fixture AS
            SELECT range AS id, ('v' || range) AS name FROM range(25)
            """)
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    private func makeCoordinator(columns: [ColumnInfo] = [
        ColumnInfo(name: "id", sourceIndex: 0),
        ColumnInfo(name: "name", sourceIndex: 1),
    ]) -> DataGridCoordinator {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "filter_fixture", columns: columns)
        return coordinator
    }

    // MARK: - buildWhereClause: three branches

    func test_buildWhereClause_emptyWhenNothingExcluded() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.buildWhereClause(), "")
    }

    func test_buildWhereClause_valuesOnly_escapesEmbeddedQuote() {
        let coordinator = makeCoordinator()
        coordinator.setExcluded(["it's", "plain"], forColumn: "name")
        XCTAssertEqual(
            coordinator.buildWhereClause(),
            " WHERE \"name\"::VARCHAR NOT IN ('it''s','plain')"
        )
    }

    func test_buildWhereClause_nullOnly() {
        let coordinator = makeCoordinator()
        coordinator.setExcluded([DataGridCoordinator.nullSentinel], forColumn: "name")
        XCTAssertEqual(coordinator.buildWhereClause(), " WHERE \"name\" IS NOT NULL")
    }

    func test_buildWhereClause_valuesAndNull() {
        let coordinator = makeCoordinator()
        coordinator.setExcluded(["b", "a", DataGridCoordinator.nullSentinel], forColumn: "name")
        XCTAssertEqual(
            coordinator.buildWhereClause(),
            " WHERE (\"name\"::VARCHAR NOT IN ('a','b') AND \"name\" IS NOT NULL)"
        )
    }

    func test_buildWhereClause_multipleColumns_joinedByAnd() {
        let coordinator = makeCoordinator()
        coordinator.setExcluded(["x"], forColumn: "name")
        coordinator.setExcluded(["1"], forColumn: "id")
        XCTAssertEqual(
            coordinator.buildWhereClause(),
            " WHERE \"id\"::VARCHAR NOT IN ('1') AND \"name\"::VARCHAR NOT IN ('x')"
        )
    }

    func test_buildWhereClause_clearingExclusionRemovesColumn() {
        let coordinator = makeCoordinator()
        coordinator.setExcluded(["x"], forColumn: "name")
        coordinator.setExcluded([], forColumn: "name")
        XCTAssertEqual(coordinator.buildWhereClause(), "")
    }

    // MARK: - fetchDistinctValues

    func test_fetchDistinctValues_returnsSortedDistinctSet_excludingNull() throws {
        try connection.execute("""
            CREATE VIEW distinct_fixture AS
            SELECT * FROM (VALUES ('b'), ('a'), ('b'), (NULL)) AS t(name)
            """)
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "distinct_fixture", columns: [ColumnInfo(name: "name", sourceIndex: 0)])

        XCTAssertEqual(coordinator.fetchDistinctValues(forColumn: "name"), ["a", "b"])
    }

    func test_fetchDistinctValues_isCached() throws {
        // A real table (not a VALUES-backed view) so it can be mutated with
        // INSERT after the view is created over it.
        try connection.execute("CREATE TABLE distinct_table2 (name VARCHAR)")
        try connection.execute("INSERT INTO distinct_table2 VALUES ('a'), ('b')")
        try connection.execute("CREATE VIEW distinct_fixture2 AS SELECT * FROM distinct_table2")

        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "distinct_fixture2", columns: [ColumnInfo(name: "name", sourceIndex: 0)])

        let first = coordinator.fetchDistinctValues(forColumn: "name")
        // Mutate the underlying data; a cached call must still return the
        // unchanged snapshot (proves it didn't re-query).
        try connection.execute("INSERT INTO distinct_table2 VALUES ('c')")
        let second = coordinator.fetchDistinctValues(forColumn: "name")
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, ["a", "b"])
    }

    // MARK: - fetchDistinctValuesAsync (popover perf)
    //
    // The filter popover used to call the SYNCHRONOUS `fetchDistinctValues`
    // right as it opened, running the DISTINCT query on the main thread
    // before the popover could even appear -- sluggish on a large loaded
    // view. `fetchDistinctValuesAsync` is the fix `presentFilterPopover` now
    // calls instead: it must deliver the identical result set, but via a
    // completion callback on the main actor rather than a blocking return,
    // so the caller (here, the test's `await`) is never blocked on the
    // query itself.

    func test_fetchDistinctValuesAsync_deliversSameResultAsSyncVersion() async throws {
        try connection.execute("""
            CREATE VIEW distinct_async_fixture AS
            SELECT * FROM (VALUES ('b'), ('a'), ('b'), (NULL)) AS t(name)
            """)
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "distinct_async_fixture", columns: [ColumnInfo(name: "name", sourceIndex: 0)])

        let values = await withCheckedContinuation { continuation in
            coordinator.fetchDistinctValuesAsync(forColumn: "name") { values in
                continuation.resume(returning: values)
            }
        }

        XCTAssertEqual(values, ["a", "b"])
    }

    func test_fetchDistinctValuesAsync_emptyForUnknownView() async throws {
        // No `switchTo` call -- `currentView` is nil, matching
        // `fetchDistinctValues`'s own `guard let view = currentView else {
        // return [] }` early-out.
        let coordinator = DataGridCoordinator(connection: connection)

        let values = await withCheckedContinuation { continuation in
            coordinator.fetchDistinctValuesAsync(forColumn: "name") { values in
                continuation.resume(returning: values)
            }
        }

        XCTAssertEqual(values, [])
    }

    func test_fetchDistinctValuesAsync_completionDeliveredOnMainActor() async throws {
        // The completion is typed `@MainActor ([String]) -> Void` precisely
        // so callers (in particular `DistinctValuesLoader.values`'s writer
        // in `presentFilterPopover`) can safely touch main-actor-isolated
        // state from inside it with no further hop. `MainActor.assertIsolated`
        // is the empirical check that this promise actually holds at
        // runtime, not just at the type level.
        let coordinator = makeCoordinator()

        await withCheckedContinuation { continuation in
            coordinator.fetchDistinctValuesAsync(forColumn: "name") { _ in
                MainActor.assertIsolated("completion must run on the main actor")
                continuation.resume()
            }
        }
    }

    // MARK: - setExcluded changes totalRowCount

    func test_setExcluded_changesTotalRowCount() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.totalRowCount, 25)

        coordinator.setExcluded(["0", "1", "2"], forColumn: "id")
        XCTAssertEqual(coordinator.totalRowCount, 22)

        coordinator.setExcluded([], forColumn: "id")
        XCTAssertEqual(coordinator.totalRowCount, 25)
    }

    func test_setExcluded_updatesExcludedValues() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.excludedValues["id"], nil)

        coordinator.setExcluded(["0"], forColumn: "id")
        XCTAssertEqual(coordinator.excludedValues["id"], ["0"])

        coordinator.setExcluded([], forColumn: "id")
        XCTAssertNil(coordinator.excludedValues["id"])
    }

    // MARK: - setExcluded pushes filteredColumns (SOURCE index space) to the header

    /// `setExcluded` must push the active-filter set to
    /// `headerView.filteredColumns`, in SOURCE index space (`ColumnInfo.sourceIndex`,
    /// NOT display index) -- so the header's filter glyph can draw
    /// filled/highlighted for exactly the columns with a non-empty
    /// `excludedValues` entry. `id` is `sourceIndex: 0`, `name` is
    /// `sourceIndex: 1` in the default fixture.
    func test_setExcluded_pushesFilteredColumnsToHeader_inSourceIndexSpace() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.headerView?.filteredColumns, [])

        coordinator.setExcluded(["v1"], forColumn: "name")
        XCTAssertEqual(coordinator.headerView?.filteredColumns, [1]) // name's sourceIndex

        coordinator.setExcluded(["0"], forColumn: "id")
        XCTAssertEqual(coordinator.headerView?.filteredColumns, [0, 1])

        coordinator.setExcluded([], forColumn: "name")
        XCTAssertEqual(coordinator.headerView?.filteredColumns, [0]) // only id remains excluded

        coordinator.setExcluded([], forColumn: "id")
        XCTAssertEqual(coordinator.headerView?.filteredColumns, [])
    }

    /// Non-identity source-index fixture: `filteredColumns` must key off each
    /// column's stable `sourceIndex`, not its position in `currentColumns` or
    /// any display ordering -- proven by giving `name` a non-trivial source
    /// index (2, with a gap at 1) unrelated to its array position (0).
    func test_setExcluded_filteredColumns_nonIdentitySourceIndex() {
        let coordinator = makeCoordinator(columns: [
            ColumnInfo(name: "name", sourceIndex: 2),
            ColumnInfo(name: "id", sourceIndex: 0),
        ])

        coordinator.setExcluded(["v1"], forColumn: "name")
        XCTAssertEqual(coordinator.headerView?.filteredColumns, [2])
    }

    // MARK: - switchTo resets filter state

    func test_switchTo_resetsExcludedValues() {
        let coordinator = makeCoordinator()
        coordinator.setExcluded(["0"], forColumn: "id")
        XCTAssertFalse(coordinator.excludedValues.isEmpty)

        coordinator.switchTo(view: "filter_fixture", columns: [
            ColumnInfo(name: "id", sourceIndex: 0),
            ColumnInfo(name: "name", sourceIndex: 1),
        ])
        XCTAssertTrue(coordinator.excludedValues.isEmpty)
        XCTAssertEqual(coordinator.buildWhereClause(), "")
    }

    // MARK: - Sort + filter compose

    // Spin the main run loop until `condition` holds or timeout — lets the
    // background→main `onPageLoaded` hop run (same pattern as SortTests).
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func test_filterThenSort_composesBothClauses() {
        let coordinator = makeCoordinator()

        // Exclude ids 0 and 1, then sort ascending by id: row 0 should be id=2.
        coordinator.setExcluded(["0", "1"], forColumn: "id")
        coordinator.toggleSort(columnSourceIndex: 0) // ascending

        XCTAssertEqual(coordinator.buildOrderByClause(), " ORDER BY \"id\" ASC")
        XCTAssertEqual(coordinator.buildWhereClause(), " WHERE \"id\"::VARCHAR NOT IN ('0','1')")
        XCTAssertEqual(coordinator.totalRowCount, 23)

        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.dataVersion >= 1 })
        XCTAssertEqual(coordinator.rowForTesting(at: 0), [.text("2"), .text("v2")])
    }

    func test_sortThenFilter_composesBothClauses() {
        let coordinator = makeCoordinator()

        // Sort descending by id, then exclude id 24 (the current top row):
        // the new top row should be id=23, proving the filter rebuild kept
        // the sort's ORDER BY.
        coordinator.toggleSort(columnSourceIndex: 0) // ascending
        coordinator.toggleSort(columnSourceIndex: 0) // descending
        coordinator.setExcluded(["24"], forColumn: "id")

        XCTAssertEqual(coordinator.buildOrderByClause(), " ORDER BY \"id\" DESC")
        XCTAssertEqual(coordinator.buildWhereClause(), " WHERE \"id\"::VARCHAR NOT IN ('24')")

        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.dataVersion >= 1 })
        XCTAssertEqual(coordinator.rowForTesting(at: 0), [.text("23"), .text("v23")])
    }
}
