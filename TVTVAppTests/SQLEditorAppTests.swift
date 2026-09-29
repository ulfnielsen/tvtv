import DuckDB
import Foundation
import TVTVCore
import XCTest

@testable import TVTV

/// App-level tests for the SQL editor's `runQuery`/return-to-file flow.
/// `DataGridCoordinator.runQuery` itself is exercised directly
/// against a real connection in `TVTVCoreTests/SQLEditorTests.swift`; these
/// tests instead cover the APP-side wiring `SQLEditorTests.swift` can't see:
/// `AppModel.runQuery()`/`closeQuery()` around a REAL opened file, proving
/// the "return to the opened file's `data` view" mechanism actually works
/// end to end (open -> run query -> close query -> back to `data`).
final class SQLEditorAppTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLEditorAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    private func writeParquetFixture(at url: URL, rowCount: Int = 50) throws {
        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let escapedPath = url.path.replacingOccurrences(of: "'", with: "''")
        try connection.execute("""
            COPY (SELECT range AS id, range * 1.5 AS v FROM range(\(rowCount)))
            TO '\(escapedPath)' (FORMAT PARQUET)
            """)
    }

    @MainActor
    func testRunQuerySwitchesGridToQueryResult() async throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture.parquet")
        try writeParquetFixture(at: fileURL, rowCount: 50)

        let model = AppModel()
        model.open(url: fileURL)
        XCTAssertTrue(model.hasData)
        XCTAssertFalse(model.coordinator.isQueryResult)

        await model.runQuery("SELECT 1 AS a, 2 AS b")

        XCTAssertNil(model.queryErrorMessage)
        XCTAssertTrue(model.coordinator.isQueryResult)
        XCTAssertEqual(model.coordinator.totalRowCount, 1)
    }

    @MainActor
    func testCloseQueryReturnsToOpenedFilesDataView() async throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture.parquet")
        try writeParquetFixture(at: fileURL, rowCount: 50)

        let model = AppModel()
        model.open(url: fileURL)
        let originalRowCount = model.coordinator.totalRowCount
        XCTAssertEqual(originalRowCount, 50)

        await model.runQuery("SELECT 1 AS a, 2 AS b")
        XCTAssertTrue(model.coordinator.isQueryResult)

        model.closeQuery()

        XCTAssertFalse(model.coordinator.isQueryResult)
        XCTAssertEqual(model.coordinator.totalRowCount, originalRowCount)
    }

    @MainActor
    func testInvalidSQLSurfacesErrorAndLeavesDataViewIntact() async throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture.parquet")
        try writeParquetFixture(at: fileURL, rowCount: 50)

        let model = AppModel()
        model.open(url: fileURL)

        await model.runQuery("SELECT * FROM no_such_table")

        XCTAssertNotNil(model.queryErrorMessage)
        XCTAssertFalse(model.coordinator.isQueryResult)
        XCTAssertEqual(model.coordinator.totalRowCount, 50)
    }

    @MainActor
    func testSaveAsConvertsCSVToParquetWithoutEditing() throws {
        let source = tempDirectory.appendingPathComponent("source.csv")
        let contents = "id,name\n1,Alice\n2,Bob\n"
        try contents.write(to: source, atomically: true, encoding: .utf8)
        let destination = tempDirectory.appendingPathComponent("copy's.parquet")
        let model = AppModel()
        model.open(url: source)

        XCTAssertTrue(model.saveAs(to: destination))
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.coordinator.isEditing)
        XCTAssertEqual(model.currentFileURL, source)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), contents)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let reopened = try DataSource.open(url: destination, connection: connection)
        XCTAssertEqual(reopened.columns.map(\.name), ["id", "name"])
        let result = try connection.query("SELECT id, name FROM data ORDER BY id")
        XCTAssertEqual(Array(result[0].cast(to: Int64.self)), [1, 2])
        XCTAssertEqual(Array(result[1].cast(to: String.self)), ["Alice", "Bob"])
    }

    @MainActor
    func testSaveAsWritesSQLResultInBothFormats() async throws {
        let source = tempDirectory.appendingPathComponent("source.parquet")
        try writeParquetFixture(at: source)
        let model = AppModel()
        model.open(url: source)
        await model.runQuery("SELECT 42::BIGINT AS answer")

        for ext in ["parquet", "csv"] {
            let destination = tempDirectory.appendingPathComponent("result.\(ext)")
            XCTAssertTrue(model.saveAs(to: destination))
            XCTAssertNil(model.errorMessage)
            let database = try Database(store: .inMemory)
            let connection = try database.connect()
            let reopened = try DataSource.open(url: destination, connection: connection)
            XCTAssertEqual(reopened.columns.map(\.name), ["answer"])
            let result = try connection.query("SELECT answer FROM data")
            XCTAssertEqual(Array(result[0].cast(to: Int64.self)), [42])
        }
        XCTAssertTrue(model.coordinator.isQueryResult)
        XCTAssertFalse(model.coordinator.isEditing)
    }

    @MainActor
    func testSaveAsRequiresDataAndProtectsUneditedSource() throws {
        let model = AppModel()
        let source = tempDirectory.appendingPathComponent("source.csv")
        XCTAssertFalse(model.saveAs(to: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        let contents = "id\n1\n2\n"
        try contents.write(to: source, atomically: true, encoding: .utf8)
        model.open(url: source)
        XCTAssertFalse(model.saveAs(to: source))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), contents)
    }

    @MainActor
    func testSaveAsUsesEditingTableInsteadOfOriginalFile() throws {
        let source = tempDirectory.appendingPathComponent("source.csv")
        try "id\n1\n2\n".write(to: source, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.open(url: source)
        model.setEditing(true)
        XCTAssertTrue(model.coordinator.isEditing)
        // Editing has a materialized snapshot; changing the backing file must
        // not change what Save As writes while editing.
        try "id\n999\n".write(to: source, atomically: true, encoding: .utf8)
        let destination = tempDirectory.appendingPathComponent("edited.parquet")

        XCTAssertTrue(model.saveAs(to: destination))
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.coordinator.isEditing)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        _ = try DataSource.open(url: destination, connection: connection)
        let result = try connection.query("SELECT id FROM data ORDER BY id")
        XCTAssertEqual(Array(result[0].cast(to: Int64.self)), [1, 2])
    }
}
