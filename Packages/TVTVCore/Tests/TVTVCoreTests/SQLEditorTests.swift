import XCTest
import DuckDB
@testable import TVTVCore

/// Tests for `DataGridCoordinator.runQuery` — the SQL editor's `query_result`
/// flow: `DROP VIEW IF EXISTS "query_result"` + `CREATE OR REPLACE TEMP VIEW
/// "query_result" AS <sql>`, then a schema probe + `switchTo`.
///
/// All three tests run against a real in-memory DuckDB connection (no mocks):
/// 1. A valid query switches the grid to `query_result` with the right shape.
/// 2. A re-run with different SQL replaces it cleanly (DROP-first — no
///    "view already exists" error).
/// 3. Invalid SQL throws `DataGridCoordinator.QueryError` and leaves the
///    PRIOR view (`sql_fixture`, not `query_result`) fully intact — proving
///    the coordinator never calls `switchTo` on a failed `runQuery`.
@MainActor
final class SQLEditorTests: XCTestCase {

    private var database: Database!
    private var connection: Connection!

    private let columns = [
        ColumnInfo(name: "id", sourceIndex: 0),
        ColumnInfo(name: "label", sourceIndex: 1),
    ]

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW sql_fixture AS
            SELECT i AS id, ('row_' || i) AS label FROM range(10) AS t(i)
            """)
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    // Spin the main run loop until `condition` holds or timeout — lets the
    // background→main `onPageLoaded` hop run (same pattern as
    // DataGridCoordinatorTests).
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - 1. Valid query switches the grid to query_result

    func test_runQuery_switchesGridToQueryResultView() async throws {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sql_fixture", columns: columns)
        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.rowForTesting(at: 0) != nil })

        try await coordinator.runQuery("SELECT 1 AS a, 2 AS b")
        coordinator.handleVisibleRows(first: 0, last: 0)
        spin(until: { coordinator.rowForTesting(at: 0) != nil })

        XCTAssertEqual(coordinator.totalRowCount, 1)
        XCTAssertTrue(coordinator.isQueryResult)

        let schema = try connection.query("SELECT * FROM query_result LIMIT 0")
        XCTAssertEqual(Int(schema.columnCount), 2)
        XCTAssertEqual(schema.columnName(at: 0), "a")
        XCTAssertEqual(schema.columnName(at: 1), "b")

        XCTAssertNotNil(coordinator.rowForTesting(at: 0))
    }

    // MARK: - Part A: ColumnInfo.type population (schema probe -> header)

    /// `columnInfos(forView:)` (the private schema probe `runQuery` uses)
    /// must populate each `ColumnInfo.type` from the real column's
    /// `underlyingDatabaseType` -- verified end-to-end through the only
    /// public surface that exposes it: the header's `columnTypes`, which
    /// `rebuildStore` populates from `currentColumns.map(\.type)` (see
    /// `DataGridCoordinator.rebuildStore`). A real in-memory view with a
    /// VARCHAR column and a BIGINT column must yield "VARCHAR"/"BIGINT",
    /// not empty strings.
    func test_runQuery_populatesColumnTypes_varcharAndBigint() async throws {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sql_fixture", columns: columns)

        try await coordinator.runQuery("SELECT 'hello'::VARCHAR AS s, 42::BIGINT AS n")

        XCTAssertEqual(coordinator.headerView?.columnNames, ["s", "n"])
        XCTAssertEqual(coordinator.headerView?.columnTypes, ["VARCHAR", "BIGINT"])
    }

    // MARK: - 2. Re-run with different SQL replaces cleanly (DROP-first)

    func test_runQuery_rerunWithDifferentSQLReplacesCleanly() async throws {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sql_fixture", columns: columns)
        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.rowForTesting(at: 0) != nil })

        try await coordinator.runQuery("SELECT 1 AS a, 2 AS b")
        coordinator.handleVisibleRows(first: 0, last: 0)
        spin(until: { coordinator.rowForTesting(at: 0) != nil })

        // Must not throw "view already exists" -- DROP-first handles it.
        try await coordinator.runQuery("SELECT 42 AS x")
        coordinator.handleVisibleRows(first: 0, last: 0)
        spin(until: { coordinator.rowForTesting(at: 0) != nil })

        let schema = try connection.query("SELECT * FROM query_result LIMIT 0")
        XCTAssertEqual(Int(schema.columnCount), 1)
        XCTAssertEqual(schema.columnName(at: 0), "x")

        let row = coordinator.rowForTesting(at: 0)
        XCTAssertNotNil(row)
    }

    // MARK: - 3. Invalid SQL throws and leaves the prior view intact

    func test_runQuery_invalidSQLThrowsAndLeavesPriorViewIntact() async throws {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sql_fixture", columns: columns)
        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.rowForTesting(at: 0) != nil })

        do {
            try await coordinator.runQuery("SELECT * FROM no_such_table")
            XCTFail("expected runQuery to throw on invalid SQL")
        } catch is DataGridCoordinator.QueryError {
            // expected
        } catch {
            XCTFail("expected QueryError, got \(type(of: error)): \(error)")
        }

        // The grid must still show the PRIOR view, untouched.
        XCTAssertFalse(coordinator.isQueryResult)
        XCTAssertEqual(coordinator.totalRowCount, 10)
        XCTAssertNotNil(coordinator.rowForTesting(at: 0))

        // The DROP-first + CREATE means a bad CREATE leaves no half-view.
        let queryResultExists = (try? connection.query("SELECT * FROM query_result LIMIT 0")) != nil
        XCTAssertFalse(queryResultExists, "query_result should not exist after a failed CREATE")
    }

    // MARK: - 4. A subsequent valid query after a failure still works

    func test_runQuery_succeedsAfterAPriorFailure() async throws {
        let coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "sql_fixture", columns: columns)
        coordinator.handleVisibleRows(first: 0, last: 5)
        spin(until: { coordinator.rowForTesting(at: 0) != nil })

        do {
            try await coordinator.runQuery("SELECT * FROM no_such_table")
            XCTFail("expected throw")
        } catch {
            // expected
        }

        try await coordinator.runQuery("SELECT 7 AS z")
        coordinator.handleVisibleRows(first: 0, last: 0)
        spin(until: { coordinator.rowForTesting(at: 0) != nil })

        XCTAssertTrue(coordinator.isQueryResult)
        let schema = try connection.query("SELECT * FROM query_result LIMIT 0")
        XCTAssertEqual(schema.columnName(at: 0), "z")
    }
}
