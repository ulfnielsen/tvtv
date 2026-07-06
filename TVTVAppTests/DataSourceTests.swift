import DuckDB
import Foundation
import TVTVCore
import XCTest

@testable import TVTV

/// Integration tests for `DataSource.open(url:connection:)` — the app's file-open
/// flow. This is the "critical, visually-unverifiable" user path: a Finder
/// double-click, an `open(1)` call, or the File > Open… panel all funnel
/// through here to turn a URL into the `data` view + `[ColumnInfo]` the grid
/// renders. Before this test file, DataSource had zero test coverage.
///
/// All fixtures are real files (parquet/csv/duckdb) written with a real
/// DuckDB engine — no mocks. Every test opens fixtures on a *fresh*
/// in-memory `Connection` unless explicitly testing the reopen/DETACH
/// behavior, which requires reusing one connection across two opens.
final class DataSourceTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    // MARK: - Helpers

    /// Writes a parquet fixture with `rowCount` rows, columns `id BIGINT` and
    /// `v DOUBLE`, using a throwaway DuckDB engine (independent of the
    /// connection under test).
    private func writeParquetFixture(at url: URL, rowCount: Int = 50) throws {
        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        // Escape single quotes the same way DataSource does — this fixture
        // writer needs to handle quote-containing paths too (used by the
        // single-quote test below).
        let escapedPath = url.path.replacingOccurrences(of: "'", with: "''")
        try connection.execute("""
            COPY (SELECT range AS id, range * 1.5 AS v FROM range(\(rowCount)))
            TO '\(escapedPath)' (FORMAT PARQUET)
            """)
    }

    /// Writes a plain-text CSV fixture with a header row, columns `id,name`.
    private func writeCSVFixture(at url: URL, rowCount: Int = 20) throws {
        var lines = ["id,name"]
        for i in 0..<rowCount {
            lines.append("\(i),row_\(i)")
        }
        let contents = lines.joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes a `.duckdb` fixture file containing a single table `t` with
    /// `rowCount` rows and one column `id`.
    private func writeDuckDBFixture(at url: URL, rowCount: Int = 10) throws {
        let database = try Database(store: .file(at: url))
        let connection = try database.connect()
        try connection.execute("CREATE TABLE t AS SELECT range AS id FROM range(\(rowCount))")
        // Explicitly drop references so the file is fully closed/flushed
        // before DataSource ATTACHes it from a different connection.
        _ = connection
        _ = database
    }

    private func queryCount(_ sql: String, connection: Connection) throws -> Int64 {
        let result = try connection.query(sql)
        return result[0].cast(to: Int64.self)[0]!
    }

    // MARK: - 1. Parquet open

    func testOpenParquetCreatesDataViewWithExpectedColumnsAndRowCount() throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture.parquet")
        try writeParquetFixture(at: fileURL, rowCount: 50)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.viewName, "data")
        XCTAssertEqual(opened.columns.map(\.name), ["id", "v"])
        XCTAssertEqual(opened.columns.map(\.sourceIndex), [0, 1])

        let rowCount = try queryCount("SELECT count(*) FROM data", connection: connection)
        XCTAssertEqual(rowCount, 50)

        // Spot-check actual data, not just row count.
        let firstID = try connection.query("SELECT id FROM data ORDER BY id LIMIT 1")
        XCTAssertEqual(firstID[0].cast(to: Int64.self)[0], 0)
    }

    /// Path to the checked-in Vortex fixture (`data/bench/clinical_like.vtx`),
    /// derived from this source file's location so it's machine-independent.
    private var vortexFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TVTVAppTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("data/bench/clinical_like.vtx")
    }

    func testOpenVortexTranscodesToParquetAndPagesRows() throws {
        let url = vortexFixtureURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing: \(url.path)")

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: url, connection: connection)

        XCTAssertEqual(opened.viewName, "data")
        XCTAssertEqual(opened.columns.count, 8)
        let rowCount = try queryCount("SELECT count(*) FROM data", connection: connection)
        XCTAssertEqual(rowCount, 46)
    }

    func testVortexReaderPreviewReportsColumnsAndTotal() throws {
        let url = vortexFixtureURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing: \(url.path)")

        let preview = try VortexReader.loadPreview(url: url, rowCap: 20)
        XCTAssertEqual(preview.columns.count, 8)
        XCTAssertEqual(preview.totalRowCount, 46)
        XCTAssertEqual(preview.rows.count, 20)     // capped
        XCTAssertTrue(preview.truncated)
    }

    /// The cell-edit round trip at the SQL level the app runs: materialize the
    /// file view into `data_edit`, UPDATE a cell by rowid, COPY back over the
    /// original parquet, then reopen and confirm the edit persisted and other
    /// rows are untouched.
    func testCellEditMaterializeUpdateByRowidSaveAndReload() throws {
        let src = tempDirectory.appendingPathComponent("edit.parquet")
        try writeParquetFixture(at: src, rowCount: 10)  // id BIGINT, v DOUBLE (v = id*1.5)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        _ = try DataSource.open(url: src, connection: connection)

        // beginEditing(): materialize into the mutable table.
        try connection.execute(
            "CREATE OR REPLACE TABLE \(DataGridCoordinator.editView) AS SELECT * FROM data")
        // applyEdit(): UPDATE by rowid (row 0 → id 0), value as a string literal cast by DuckDB.
        try connection.execute(
            "UPDATE \(DataGridCoordinator.editView) SET \"v\" = '999.5' WHERE rowid = 0")
        // save(): COPY the edited table out to a file.
        let dest = tempDirectory.appendingPathComponent("edit-out.parquet")
        let escaped = dest.path.replacingOccurrences(of: "'", with: "''")
        try connection.execute(
            "COPY (SELECT * FROM \(DataGridCoordinator.editView)) TO '\(escaped)' (FORMAT PARQUET)")

        // Reopen the edited file on a fresh connection and verify.
        let database2 = try Database(store: .inMemory)
        let connection2 = try database2.connect()
        _ = try DataSource.open(url: dest, connection: connection2)
        // Compare via ::VARCHAR (exactly how the grid reads cells).
        let edited = try connection2.query("SELECT v::VARCHAR FROM data WHERE id = 0")
        XCTAssertEqual(edited[0].cast(to: String.self)[0], "999.5")
        let untouched = try connection2.query("SELECT v::VARCHAR FROM data WHERE id = 1")
        XCTAssertEqual(untouched[0].cast(to: String.self)[0], "1.5")
    }

    func testFilePreviewReadsCappedFirstRowsWithColumnsAndTotal() throws {
        let fileURL = tempDirectory.appendingPathComponent("preview.parquet")
        try writeParquetFixture(at: fileURL, rowCount: 500)

        let preview = try FilePreview.load(url: fileURL, rowCap: 100)

        XCTAssertEqual(preview.columns.map(\.name), ["id", "v"])
        XCTAssertEqual(preview.rows.count, 100)          // capped at rowCap
        XCTAssertEqual(preview.totalRowCount, 500)
        XCTAssertTrue(preview.truncated)
        // Cells are formatted strings (same `::VARCHAR` projection as the grid).
        XCTAssertEqual(preview.rows.first?.first, "0")
    }

    func testOpenCreatesFileNamedAliasViewQueryableAlongsideData() throws {
        let fileURL = tempDirectory.appendingPathComponent("sales_2025.parquet")
        try writeParquetFixture(at: fileURL, rowCount: 12)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        // The friendly alias is the sanitized file base name...
        XCTAssertEqual(opened.tableAlias, "sales_2025")
        // ...and it is queryable, returning the same rows as `data`.
        let aliasCount = try queryCount("SELECT count(*) FROM sales_2025", connection: connection)
        XCTAssertEqual(aliasCount, 12)
    }

    // MARK: - 2. CSV open

    func testOpenCSVCreatesDataViewWithExpectedColumnsAndRowCount() throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture.csv")
        try writeCSVFixture(at: fileURL, rowCount: 20)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.viewName, "data")
        XCTAssertEqual(opened.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(opened.columns.map(\.sourceIndex), [0, 1])

        let rowCount = try queryCount("SELECT count(*) FROM data", connection: connection)
        XCTAssertEqual(rowCount, 20)
    }

    /// Part A (header shows each column's TYPE): `DataSource.columnInfos`
    /// must populate `ColumnInfo.type` from the real column's
    /// `underlyingDatabaseType`, not leave it at the `""` default. This CSV
    /// fixture's `auto_detect` schema gives a real BIGINT + VARCHAR pair
    /// (`id` is all-numeric, `name` is `row_<n>` text) -- exactly the
    /// "a VARCHAR column and a BIGINT column" case called for.
    func testOpenCSVPopulatesColumnTypesAsBigintAndVarchar() throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture.csv")
        try writeCSVFixture(at: fileURL, rowCount: 20)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(opened.columns.map(\.type), ["BIGINT", "VARCHAR"])
    }

    // MARK: - 3. .duckdb ATTACH

    func testOpenDuckDBAttachesAndSurfacesFirstTableAsDataView() throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture.duckdb")
        try writeDuckDBFixture(at: fileURL, rowCount: 10)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.viewName, "data")
        XCTAssertEqual(opened.columns.map(\.name), ["id"])

        let rowCount = try queryCount("SELECT count(*) FROM data", connection: connection)
        XCTAssertEqual(rowCount, 10)
    }

    // MARK: - 4. DETACH on reopen (duckdb -> parquet on same connection)

    func testOpeningParquetAfterDuckDBDetachesThePriorAttachment() throws {
        let duckdbURL = tempDirectory.appendingPathComponent("first.duckdb")
        try writeDuckDBFixture(at: duckdbURL, rowCount: 10)

        let parquetURL = tempDirectory.appendingPathComponent("second.parquet")
        try writeParquetFixture(at: parquetURL, rowCount: 50)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        _ = try DataSource.open(url: duckdbURL, connection: connection)
        // Second open, same connection: must not throw (a lingering ATTACH
        // with a re-used alias would make this ATTACH fail).
        let opened = try DataSource.open(url: parquetURL, connection: connection)

        XCTAssertEqual(opened.columns.map(\.name), ["id", "v"])
        let rowCount = try queryCount("SELECT count(*) FROM data", connection: connection)
        XCTAssertEqual(rowCount, 50)

        // The attached_db catalog must actually be gone, not just unreferenced.
        let databaseList = try connection.query("PRAGMA database_list")
        let nameColumnIndex = databaseList.index(forColumnName: "name")!
        let names = (0..<databaseList.rowCount).compactMap {
            databaseList[nameColumnIndex].cast(to: String.self)[$0]
        }
        XCTAssertFalse(names.contains("attached_db"), "attached_db should have been DETACHed, found in: \(names)")
    }

    // MARK: - 5. Bad file -> error surfaced

    func testOpeningNonexistentParquetThrowsOpenError() throws {
        let fileURL = tempDirectory.appendingPathComponent("does-not-exist.parquet")

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        XCTAssertThrowsError(try DataSource.open(url: fileURL, connection: connection)) { error in
            XCTAssertTrue(error is DataSource.OpenError, "expected OpenError, got \(type(of: error))")
        }
    }

    func testOpeningGarbageDuckDBFileThrowsOpenError() throws {
        let fileURL = tempDirectory.appendingPathComponent("garbage.duckdb")
        try "this is not a duckdb file".write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        XCTAssertThrowsError(try DataSource.open(url: fileURL, connection: connection)) { error in
            XCTAssertTrue(error is DataSource.OpenError, "expected OpenError, got \(type(of: error))")
        }
    }

    func testOpeningUnsupportedExtensionThrowsOpenError() throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        XCTAssertThrowsError(try DataSource.open(url: fileURL, connection: connection)) { error in
            guard case DataSource.OpenError.unsupportedExtension(let ext) = error else {
                return XCTFail("expected .unsupportedExtension, got \(error)")
            }
            XCTAssertEqual(ext, "txt")
        }
    }

    // MARK: - 6. Path containing a single quote

    func testOpeningParquetWhoseFileNameContainsASingleQuoteWorks() throws {
        // APFS (this test machine's filesystem) permits apostrophes in file
        // names, so this exercises the real escaping path end-to-end rather
        // than just the escaping helper in isolation.
        let fileURL = tempDirectory.appendingPathComponent("O'Brien's data.parquet")
        try writeParquetFixture(at: fileURL, rowCount: 5)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.columns.map(\.name), ["id", "v"])
        let rowCount = try queryCount("SELECT count(*) FROM data", connection: connection)
        XCTAssertEqual(rowCount, 5)
    }
}
