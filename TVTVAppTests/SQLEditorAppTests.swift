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
}
