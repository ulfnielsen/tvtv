import DuckDB
import Foundation
import TVTVCore
import XCTest

@testable import TVTV

/// Tests for CDISC Dataset-JSON v1.1 support (both serializations: `.json`,
/// single object with a `rows` array, and `.ndjson`, metadata line + one row
/// array per line). Reading follows the Vortex pattern — transcode to a temp
/// parquet, page over that — but implemented in TVTVCore's `DatasetJSON` with
/// DuckDB's JSON extension, no Rust. Fixtures are hand-written JSON strings —
/// real files, no mocks — following this suite's convention.
final class DatasetJSONTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatasetJSONTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    // MARK: - Fixtures

    /// Dataset-JSON v1.1 metadata for a demographics-like dataset whose seven
    /// columns exercise every dataType mapping: string, integer, double,
    /// decimal, date, boolean.
    private let metadataJSON =
        #"{"datasetJSONCreationDateTime":"2026-08-28T12:00:00","datasetJSONVersion":"1.1.0","#
        + #""fileOID":"www.tvtv.test/DM","dbLastModifiedDateTime":"2026-08-27T09:00:00","#
        + #""originator":"TVTV Tests","sourceSystem":{"name":"tvtv-tests","version":"1.0"},"#
        + #""studyOID":"cdisc.com/CDISCPILOT01","metaDataVersionOID":"MDV.MSGv2.0","#
        + #""itemGroupOID":"IG.DM","records":3,"name":"DM","label":"Demographics","#
        + #""columns":["#
        + #"{"itemOID":"IT.DM.STUDYID","name":"STUDYID","label":"Study Identifier","dataType":"string","length":8,"keySequence":1},"#
        + #"{"itemOID":"IT.DM.USUBJID","name":"USUBJID","label":"Unique Subject Identifier","dataType":"string","length":20,"keySequence":2},"#
        + #"{"itemOID":"IT.DM.AGE","name":"AGE","label":"Age","dataType":"integer"},"#
        + #"{"itemOID":"IT.DM.WEIGHT","name":"WEIGHT","label":"Weight","dataType":"double","displayFormat":"8.1"},"#
        + #"{"itemOID":"IT.DM.BMI","name":"BMI","label":"Body Mass Index","dataType":"decimal","targetDataType":"decimal"},"#
        + #"{"itemOID":"IT.DM.VISITDT","name":"VISITDT","label":"Visit Date","dataType":"date"},"#
        + #"{"itemOID":"IT.DM.ACTIVE","name":"ACTIVE","label":"Active Flag","dataType":"boolean"}"#
        + #"]}"#

    private let rowsJSON = [
        #"["CDISC01","001",34,66.7,"23.4567890123456789012345","2023-06-15",true]"#,
        #"["CDISC01","002",null,null,null,null,false]"#,
        #"["CDISC01","003",45,80.25,"26.1","2023-07-01",null]"#,
    ]

    private func writeNDJSONFixture(at url: URL) throws {
        let contents = ([metadataJSON] + rowsJSON).joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Same dataset in the single-object flavor: metadata attributes first,
    /// `rows` last (the spec-recommended attribute order).
    private func writeJSONFixture(at url: URL) throws {
        let contents = String(metadataJSON.dropLast())
            + #","rows":["# + rowsJSON.joined(separator: ",") + "]}"
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func queryCount(_ sql: String, connection: Connection) throws -> Int64 {
        let result = try connection.query(sql)
        return result[0].cast(to: Int64.self)[0]!
    }

    /// First cell of `sql`'s result as a string (the grid's `::VARCHAR` lens);
    /// `nil` for SQL NULL.
    private func varcharCell(_ sql: String, connection: Connection) throws -> String? {
        let result = try connection.query(sql)
        return result[0].cast(to: String.self)[0]
    }

    // MARK: - 1. Open NDJSON

    func testOpenNDJSONCreatesTypedDataView() throws {
        let fileURL = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: fileURL)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.viewName, "data")
        XCTAssertEqual(
            opened.columns.map(\.name),
            ["STUDYID", "USUBJID", "AGE", "WEIGHT", "BMI", "VISITDT", "ACTIVE"])
        XCTAssertEqual(opened.columns.map(\.sourceIndex), [0, 1, 2, 3, 4, 5, 6])
        // Fidelity-first type mapping: integer→BIGINT, double→DOUBLE,
        // boolean→BOOLEAN; string/decimal/date stay VARCHAR (write-back
        // re-serializes every row, so no cast may be lossy — a decimal
        // routed through DOUBLE would corrupt saved files).
        XCTAssertEqual(
            opened.columns.map(\.type),
            ["VARCHAR", "VARCHAR", "BIGINT", "DOUBLE", "VARCHAR", "VARCHAR", "BOOLEAN"])

        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection), 3)
        // File order is preserved: the first row is subject 001.
        XCTAssertEqual(
            try varcharCell("SELECT USUBJID FROM data LIMIT 1", connection: connection), "001")
        // Decimal survives with full precision (a DOUBLE would mangle this).
        XCTAssertEqual(
            try varcharCell("SELECT BMI FROM data WHERE USUBJID = '001'", connection: connection),
            "23.4567890123456789012345")
        // JSON null → SQL NULL (not the string "null"), for every type.
        XCTAssertNil(
            try varcharCell("SELECT AGE::VARCHAR FROM data WHERE USUBJID = '002'", connection: connection))
        XCTAssertNil(
            try varcharCell("SELECT VISITDT FROM data WHERE USUBJID = '002'", connection: connection))
        XCTAssertNil(
            try varcharCell("SELECT ACTIVE::VARCHAR FROM data WHERE USUBJID = '003'", connection: connection))
        XCTAssertEqual(
            try varcharCell("SELECT ACTIVE::VARCHAR FROM data WHERE USUBJID = '002'", connection: connection),
            "false")
    }

    // MARK: - 2. Open single-object .json

    func testOpenJSONSingleObjectFlavorMatchesNDJSON() throws {
        let fileURL = tempDirectory.appendingPathComponent("dm.json")
        try writeJSONFixture(at: fileURL)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(
            opened.columns.map(\.name),
            ["STUDYID", "USUBJID", "AGE", "WEIGHT", "BMI", "VISITDT", "ACTIVE"])
        XCTAssertEqual(
            opened.columns.map(\.type),
            ["VARCHAR", "VARCHAR", "BIGINT", "DOUBLE", "VARCHAR", "VARCHAR", "BOOLEAN"])
        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection), 3)
        XCTAssertEqual(
            try varcharCell("SELECT BMI FROM data WHERE USUBJID = '001'", connection: connection),
            "23.4567890123456789012345")
        XCTAssertNil(
            try varcharCell("SELECT AGE::VARCHAR FROM data WHERE USUBJID = '002'", connection: connection))
    }

    // MARK: - 3. Metadata-only datasets (records 0, no rows)

    func testOpenMetadataOnlyDatasetsShowEmptyTypedGrid() throws {
        let emptyMetadata = metadataJSON.replacingOccurrences(of: #""records":3"#, with: #""records":0"#)

        // .json flavor: metadata object with no `rows` attribute at all.
        let jsonURL = tempDirectory.appendingPathComponent("empty.json")
        try emptyMetadata.write(to: jsonURL, atomically: true, encoding: .utf8)
        // .ndjson flavor: just the metadata line.
        let ndjsonURL = tempDirectory.appendingPathComponent("empty.ndjson")
        try (emptyMetadata + "\n").write(to: ndjsonURL, atomically: true, encoding: .utf8)

        for url in [jsonURL, ndjsonURL] {
            let database = try Database(store: .inMemory)
            let connection = try database.connect()
            let opened = try DataSource.open(url: url, connection: connection)
            XCTAssertEqual(opened.columns.count, 7, "for \(url.lastPathComponent)")
            XCTAssertEqual(
                opened.columns.map(\.type),
                ["VARCHAR", "VARCHAR", "BIGINT", "DOUBLE", "VARCHAR", "VARCHAR", "BOOLEAN"],
                "for \(url.lastPathComponent)")
            XCTAssertEqual(
                try queryCount("SELECT count(*) FROM data", connection: connection), 0,
                "for \(url.lastPathComponent)")
        }
    }

    // MARK: - 4. Opened carries what save/cleanup need

    /// The app needs the parsed CDISC metadata (to write edits back) and the
    /// temp parquet's location (to delete it on the next open) — `Opened` is
    /// how `DataSource` hands both to `AppModel`.
    func testOpenedCarriesDatasetJSONMetadataAndTempParquetURL() throws {
        let fileURL = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: fileURL)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.datasetJSON?.name, "DM")
        XCTAssertEqual(opened.datasetJSON?.itemGroupOID, "IG.DM")
        XCTAssertEqual(opened.datasetJSON?.records, 3)
        XCTAssertEqual(
            opened.datasetJSON?.columns.map(\.dataType),
            ["string", "string", "integer", "double", "decimal", "date", "boolean"])
        let temp = try XCTUnwrap(opened.tempParquetURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
    }

    func testOpenedForParquetHasNoDatasetJSONMetadataOrTempFile() throws {
        let fileURL = tempDirectory.appendingPathComponent("plain.parquet")
        let fixture = try Database(store: .inMemory).connect()
        try fixture.execute(
            "COPY (SELECT range AS id FROM range(3)) TO '\(fileURL.path)' (FORMAT PARQUET)")

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertNil(opened.datasetJSON)
        XCTAssertNil(opened.tempParquetURL)
    }

    // MARK: - 5. Attach as an additional named view

    func testAttachDatasetJSONRegistersQueryableNamedView() throws {
        let fileURL = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: fileURL)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let name = try DataSource.attach(url: fileURL, connection: connection)

        XCTAssertEqual(name, "dm")
        XCTAssertEqual(try queryCount("SELECT count(*) FROM dm", connection: connection), 3)
        XCTAssertEqual(
            try varcharCell("SELECT BMI FROM dm WHERE USUBJID = '001'", connection: connection),
            "23.4567890123456789012345")
    }

    // MARK: - 6. Write-back

    /// The full save flow the app runs: open, materialize `data_edit`, UPDATE
    /// a cell by rowid, write back to Dataset-JSON, reopen. The edit must
    /// land; every untouched value and all CDISC metadata must survive
    /// byte-for-byte.
    func testWriteBackRoundTripAppliesEditAndPreservesEverythingElse() throws {
        let src = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: src)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)
        let metadata = try XCTUnwrap(opened.datasetJSON)

        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")
        try connection.execute("UPDATE data_edit SET \"AGE\" = '99' WHERE rowid = 0")

        let dest = tempDirectory.appendingPathComponent("dm-out.ndjson")
        try DatasetJSON.write(
            view: "data_edit", metadata: metadata, connection: connection, to: dest,
            creationDateTime: "2026-08-28T12:00:00")  // fixture's, for byte-compare

        // The written NDJSON is exactly the fixture with one cell changed:
        // metadata line byte-identical, integers as JSON numbers, decimal
        // still a JSON string with full precision, nulls as JSON null.
        let lines = try String(contentsOf: dest, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], metadataJSON)
        XCTAssertEqual(
            lines[1],
            #"["CDISC01","001",99,66.7,"23.4567890123456789012345","2023-06-15",true]"#)
        XCTAssertEqual(lines[2], #"["CDISC01","002",null,null,null,null,false]"#)
        XCTAssertEqual(lines[3], #"["CDISC01","003",45,80.25,"26.1","2023-07-01",null]"#)

        // And it reopens as the same dataset (fresh connection), edit applied.
        let database2 = try Database(store: .inMemory)
        let connection2 = try database2.connect()
        let reopened = try DataSource.open(url: dest, connection: connection2)
        XCTAssertEqual(reopened.datasetJSON, metadata)
        XCTAssertEqual(
            try varcharCell("SELECT AGE::VARCHAR FROM data WHERE USUBJID = '001'", connection: connection2),
            "99")
    }

    /// Save As can convert between the two serializations: data opened from
    /// `.ndjson` written out as a single-object `.json`.
    func testWriteJSONFlavorFromNDJSONOpenedData() throws {
        let src = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: src)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)
        let metadata = try XCTUnwrap(opened.datasetJSON)
        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")

        let dest = tempDirectory.appendingPathComponent("dm-out.json")
        try DatasetJSON.write(
            view: "data_edit", metadata: metadata, connection: connection, to: dest,
            creationDateTime: "2026-08-28T12:00:00")  // fixture's, so metadata compares equal

        // Single object, metadata attributes first, rows last.
        let contents = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix(#"{"datasetJSONCreationDateTime":"#))
        XCTAssertTrue(contents.hasSuffix("]}"))

        let database2 = try Database(store: .inMemory)
        let connection2 = try database2.connect()
        let reopened = try DataSource.open(url: dest, connection: connection2)
        XCTAssertEqual(reopened.datasetJSON, metadata)
        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection2), 3)
        XCTAssertEqual(
            try varcharCell("SELECT BMI FROM data WHERE USUBJID = '001'", connection: connection2),
            "23.4567890123456789012345")
    }

    /// A written file is a NEW file: its required `datasetJSONCreationDateTime`
    /// must describe this write, not be copied from the source (the spec
    /// defines it as the file's own creation time; downstream systems dedupe
    /// on it). Injectable for deterministic tests; defaults to now.
    func testWriteStampsFreshCreationDateTime() throws {
        let src = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: src)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)
        let metadata = try XCTUnwrap(opened.datasetJSON)
        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")

        // Injected timestamp lands verbatim.
        let dest = tempDirectory.appendingPathComponent("dm-out.ndjson")
        try DatasetJSON.write(
            view: "data_edit", metadata: metadata, connection: connection, to: dest,
            creationDateTime: "2026-12-31T23:59:59")
        let stamped = try String(contentsOf: dest, encoding: .utf8)
            .split(separator: "\n").map(String.init)[0]
        XCTAssertEqual(
            stamped,
            metadataJSON.replacingOccurrences(
                of: "2026-08-28T12:00:00", with: "2026-12-31T23:59:59"))

        // Default: stamped with the current date, not the source's.
        let dest2 = tempDirectory.appendingPathComponent("dm-out2.ndjson")
        try DatasetJSON.write(view: "data_edit", metadata: metadata, connection: connection, to: dest2)
        let database2 = try Database(store: .inMemory)
        let connection2 = try database2.connect()
        let reopened = try DataSource.open(url: dest2, connection: connection2)
        let written = try XCTUnwrap(reopened.datasetJSON?.datasetJSONCreationDateTime)
        XCTAssertNotEqual(written, metadata.datasetJSONCreationDateTime)
        XCTAssertTrue(written.hasPrefix("20"), "expected an ISO 8601 timestamp, got \(written)")
    }

    /// Deleting rows in SQL then saving must update `records` — the writer
    /// counts what it writes rather than parroting the opened metadata.
    func testWriteUpdatesRecordsCountWhenRowsChanged() throws {
        let src = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: src)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)
        let metadata = try XCTUnwrap(opened.datasetJSON)
        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")
        try connection.execute("DELETE FROM data_edit WHERE \"USUBJID\" = '003'")

        let dest = tempDirectory.appendingPathComponent("dm-out.ndjson")
        try DatasetJSON.write(view: "data_edit", metadata: metadata, connection: connection, to: dest)

        let database2 = try Database(store: .inMemory)
        let connection2 = try database2.connect()
        let reopened = try DataSource.open(url: dest, connection: connection2)
        XCTAssertEqual(reopened.datasetJSON?.records, 2)
        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection2), 2)
    }

    /// The writer pages in 10,000-row chunks — this dataset crosses that
    /// boundary, and mid-table deletes leave rowid gaps the paging must
    /// tolerate without dropping, duplicating, or reordering rows.
    func testWriteBackPagesAcrossPageBoundaryWithRowidGaps() throws {
        var lines = [
            metadataJSON.replacingOccurrences(of: #""records":3"#, with: #""records":12003"#)
        ]
        for i in 0..<12_003 {
            lines.append("[\"CDISC01\",\"S\(i)\",\(i),null,null,null,null]")
        }
        let src = tempDirectory.appendingPathComponent("big.ndjson")
        try (lines.joined(separator: "\n") + "\n").write(to: src, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)
        let metadata = try XCTUnwrap(opened.datasetJSON)
        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")
        try connection.execute("DELETE FROM data_edit WHERE \"AGE\" % 1000 = 500")  // 12 gaps

        let dest = tempDirectory.appendingPathComponent("big-out.ndjson")
        try DatasetJSON.write(view: "data_edit", metadata: metadata, connection: connection, to: dest)

        let database2 = try Database(store: .inMemory)
        let connection2 = try database2.connect()
        _ = try DataSource.open(url: dest, connection: connection2)
        XCTAssertEqual(
            try queryCount("SELECT count(*) FROM data", connection: connection2), 12_003 - 12)
        // Strictly increasing AGE == original order, no duplicates, no drops
        // beyond the deleted rows.
        let ages = try connection2.query("SELECT \"AGE\" FROM data")
        let values = (0..<Int(ages.rowCount)).compactMap { ages[0].cast(to: Int64.self)[DBInt($0)] }
        XCTAssertEqual(values.count, 12_003 - 12)
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 12_002)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "rows out of order")
        XCTAssertFalse(values.contains(500))
    }

    // MARK: - 6b. Backing-store refresh after save

    /// After saving, the `data` view must show the SAVED state, not the
    /// open-time transcode — otherwise leaving edit mode visibly reverts the
    /// edit, and a later save (data_edit is re-materialized from `data`)
    /// silently writes pre-save data back over the file.
    func testRefreshTranscodedDataViewShowsSavedEdits() throws {
        let src = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: src)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        _ = try DataSource.open(url: src, connection: connection)
        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")
        try connection.execute("UPDATE data_edit SET \"AGE\" = '99' WHERE rowid = 0")

        let fresh = try DataSource.refreshTranscodedDataView(
            fromEditTable: "data_edit", connection: connection)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(
            try varcharCell("SELECT AGE::VARCHAR FROM data WHERE USUBJID = '001'", connection: connection),
            "99")
        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection), 3)
    }

    /// ⌘S must rotate the temp parquet backing `data` (fresh snapshot in, old
    /// snapshot deleted) so the grid reflects the saved file.
    @MainActor
    func testSaveRotatesTempParquetToSavedState() throws {
        let fileURL = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: fileURL)

        func datasetTempFiles() -> Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path)) ?? []
            return Set(names.filter { $0.hasPrefix("tvtv-datasetjson-") })
        }

        let before = datasetTempFiles()
        let model = AppModel()
        model.open(url: fileURL)
        model.setEditing(true)
        let afterOpen = datasetTempFiles().subtracting(before)
        XCTAssertEqual(afterOpen.count, 1)

        model.save()

        XCTAssertNil(model.errorMessage)
        let afterSave = datasetTempFiles().subtracting(before)
        XCTAssertEqual(afterSave.count, 1, "old snapshot deleted, fresh one in its place")
        XCTAssertTrue(afterOpen.isDisjoint(with: afterSave), "the snapshot must be rotated on save")
    }

    // MARK: - 7. App-level wiring

    /// Both NSOpenPanels (Open, Attach) filter by this list — without these
    /// entries the format would be Finder/drag-openable but invisible in the
    /// panels (the existing Vortex trap).
    func testOpenableExtensionsIncludeDatasetJSON() {
        XCTAssertTrue(AppModel.openableExtensions.contains("json"))
        XCTAssertTrue(AppModel.openableExtensions.contains("ndjson"))
    }

    /// ⌘S on an opened Dataset-JSON must write through `DatasetJSON.write`
    /// (not fail with the "use Save As" banner), leaving a valid file.
    @MainActor
    func testAppModelSaveWritesDatasetJSONBackToFile() throws {
        let fileURL = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: fileURL)

        let model = AppModel()
        model.open(url: fileURL)
        XCTAssertTrue(model.hasData)
        XCTAssertNil(model.errorMessage)
        model.setEditing(true)
        XCTAssertTrue(model.coordinator.isEditing)

        model.save()

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.coordinator.isDirty)

        // The saved file reopens as the same dataset, metadata intact.
        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let reopened = try DataSource.open(url: fileURL, connection: connection)
        XCTAssertEqual(reopened.datasetJSON?.records, 3)
        XCTAssertEqual(reopened.datasetJSON?.label, "Demographics")
        XCTAssertEqual(
            try varcharCell("SELECT BMI FROM data WHERE USUBJID = '001'", connection: connection),
            "23.4567890123456789012345")
    }

    /// Opening another file must delete the previous open's temp parquet —
    /// the transcode-based flow otherwise leaks one file per open.
    @MainActor
    func testReopeningDeletesPreviousTempParquet() throws {
        let first = tempDirectory.appendingPathComponent("a.ndjson")
        try writeNDJSONFixture(at: first)
        let second = tempDirectory.appendingPathComponent("b.ndjson")
        try writeNDJSONFixture(at: second)

        func datasetTempFiles() -> Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path)) ?? []
            return Set(names.filter { $0.hasPrefix("tvtv-datasetjson-") })
        }

        let model = AppModel()
        let before = datasetTempFiles()
        model.open(url: first)
        XCTAssertNil(model.errorMessage)
        let afterFirst = datasetTempFiles().subtracting(before)
        XCTAssertEqual(afterFirst.count, 1, "one temp parquet per open")

        model.open(url: second)
        XCTAssertNil(model.errorMessage)
        let afterSecond = datasetTempFiles().subtracting(before)
        XCTAssertEqual(afterSecond.count, 1, "the first open's temp parquet should be deleted")
        XCTAssertTrue(afterFirst.isDisjoint(with: afterSecond))
    }

    // MARK: - 8. Metadata validation guards the writer's assumptions

    /// Duplicate column names (exact or case-only difference — DuckDB
    /// identifiers are case-insensitive) open apparently fine but corrupt the
    /// duplicated column on save (both projections resolve to the first
    /// physical column). Refuse at open.
    func testOpeningDuplicateColumnNamesIsRejected() throws {
        let duplicated = metadataJSON.replacingOccurrences(
            of: #""name":"USUBJID""#, with: #""name":"studyid""#)
        let fileURL = tempDirectory.appendingPathComponent("dup.ndjson")
        try (duplicated + "\n" + rowsJSON.joined(separator: "\n") + "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        XCTAssertThrowsError(try DataSource.open(url: fileURL, connection: connection)) { error in
            guard case DataSource.OpenError.underlying(let message) = error else {
                return XCTFail("expected OpenError.underlying, got \(error)")
            }
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("studyid"),
                "should name the colliding column: \(message)")
        }
    }

    /// A variable named ROWID (any case) shadows DuckDB's rowid pseudo-column,
    /// silently reordering saved rows and breaking cell edits. Refuse at open.
    func testOpeningColumnNamedRowidIsRejected() throws {
        let shadowed = metadataJSON.replacingOccurrences(
            of: #""name":"USUBJID""#, with: #""name":"ROWID""#)
        let fileURL = tempDirectory.appendingPathComponent("rowid.ndjson")
        try (shadowed + "\n" + rowsJSON.joined(separator: "\n") + "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        XCTAssertThrowsError(try DataSource.open(url: fileURL, connection: connection)) { error in
            guard case DataSource.OpenError.underlying(let message) = error else {
                return XCTFail("expected OpenError.underlying, got \(error)")
            }
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("rowid"),
                "should name the conflicting column: \(message)")
        }
    }

    /// A missing/unreadable file must say so — not claim the (perfectly
    /// valid, just absent) file "is not valid JSON".
    func testOpeningMissingDatasetJSONSaysFileNotFoundNotInvalidJSON() throws {
        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        for name in ["gone.json", "gone.ndjson"] {
            let fileURL = tempDirectory.appendingPathComponent(name)
            XCTAssertThrowsError(
                try DataSource.open(url: fileURL, connection: connection), "for \(name)"
            ) { error in
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                XCTAssertFalse(
                    message.contains("Not a Dataset-JSON"),
                    "for \(name): misdiagnosis — \(message)")
                XCTAssertTrue(
                    message.localizedCaseInsensitiveContains("file"),
                    "for \(name): should mention the file problem — \(message)")
            }
        }
    }

    // MARK: - 8b. records mismatch surfaces a warning

    /// Reading is tolerant — actual rows win over the declared `records` — but
    /// a mismatch means row loss (a corrupted line NDJSON silently drops) or
    /// a sloppy writer, so it must surface as a warning rather than pass
    /// silently.
    func testRecordsMismatchOpensButWarns() throws {
        let inflated = metadataJSON.replacingOccurrences(of: #""records":3"#, with: #""records":99"#)
        let fileURL = tempDirectory.appendingPathComponent("mismatch.ndjson")
        try (inflated + "\n" + rowsJSON.joined(separator: "\n") + "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection), 3)
        let warning = try XCTUnwrap(opened.warning)
        XCTAssertTrue(warning.contains("99") && warning.contains("3"), "uninformative: \(warning)")
    }

    /// A corrupted row line (valid JSON, not an array) is dropped by the
    /// transcode — the records cross-check is what makes that visible.
    func testCorruptedNDJSONRowLineWarnsInsteadOfSilentLoss() throws {
        var lines = [metadataJSON.replacingOccurrences(of: #""records":3"#, with: #""records":4"#)]
        lines += rowsJSON
        lines.insert(#"{"CDISC01":"004"}"#, at: 3)  // row rewritten as an object
        let fileURL = tempDirectory.appendingPathComponent("corrupt.ndjson")
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection), 3)
        XCTAssertNotNil(opened.warning)
    }

    /// And a clean open carries no warning.
    func testCleanOpenHasNoWarning() throws {
        let fileURL = tempDirectory.appendingPathComponent("dm.ndjson")
        try writeNDJSONFixture(at: fileURL)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        XCTAssertNil(try DataSource.open(url: fileURL, connection: connection).warning)
    }

    /// The warning must reach the user: AppModel surfaces it in the banner.
    @MainActor
    func testAppModelSurfacesRecordsMismatchWarning() throws {
        let inflated = metadataJSON.replacingOccurrences(of: #""records":3"#, with: #""records":99"#)
        let fileURL = tempDirectory.appendingPathComponent("mismatch.ndjson")
        try (inflated + "\n" + rowsJSON.joined(separator: "\n") + "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let model = AppModel()
        model.open(url: fileURL)

        XCTAssertTrue(model.hasData)
        XCTAssertTrue(model.errorMessage?.contains("99") ?? false, "warning not surfaced")
    }

    // MARK: - 8c. Serialization edge cases

    /// Metadata for the "exotic" cases: float/datetime/time/URI dataTypes and
    /// a label full of JSON-hostile characters (quotes, backslash, newline,
    /// tab, non-ASCII).
    private let exoticMetadataJSON =
        #"{"datasetJSONCreationDateTime":"2026-08-28T12:00:00","datasetJSONVersion":"1.1.0","#
        + #""itemGroupOID":"IG.XX","records":2,"name":"XX","#
        + #""label":"Lab \"quoted\" \\ line\nbreak\ttab — é 日本語 🚀","#
        + #""columns":["#
        + #"{"itemOID":"IT.XX.ID","name":"ID","label":"Identifier","dataType":"string"},"#
        + #"{"itemOID":"IT.XX.FLT","name":"FLT","label":"Float value","dataType":"float"},"#
        + #"{"itemOID":"IT.XX.DTM","name":"DTM","label":"Datetime","dataType":"datetime"},"#
        + #"{"itemOID":"IT.XX.TM","name":"TM","label":"Time","dataType":"time"},"#
        + #"{"itemOID":"IT.XX.LINK","name":"LINK","label":"Reference","dataType":"URI"}"#
        + #"]}"#

    private let exoticRowsJSON = [
        #"["say \"hi\"\n\tté 🚀",1e20,"2023-06-15T10:30:00","23:59:59","https://example.org/a?b=1"]"#,
        #"["plain",0.00001,null,null,null]"#,
    ]

    /// float→DOUBLE; datetime/time/URI stay VARCHAR (ISO 8601 fidelity);
    /// JSON-escaped strings and non-ASCII survive open→save→reopen; doubles
    /// re-serialize as JSON numbers even in scientific notation.
    func testExoticTypesAndEscapingRoundTrip() throws {
        let src = tempDirectory.appendingPathComponent("xx.ndjson")
        try (([exoticMetadataJSON] + exoticRowsJSON).joined(separator: "\n") + "\n")
            .write(to: src, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)
        let metadata = try XCTUnwrap(opened.datasetJSON)

        XCTAssertEqual(
            opened.columns.map(\.type), ["VARCHAR", "DOUBLE", "VARCHAR", "VARCHAR", "VARCHAR"])
        XCTAssertEqual(metadata.label, "Lab \"quoted\" \\ line\nbreak\ttab — é 日本語 🚀")
        XCTAssertEqual(
            try varcharCell("SELECT ID FROM data LIMIT 1", connection: connection),
            "say \"hi\"\n\tté 🚀")

        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")
        let dest = tempDirectory.appendingPathComponent("xx-out.ndjson")
        try DatasetJSON.write(
            view: "data_edit", metadata: metadata, connection: connection, to: dest,
            creationDateTime: "2026-08-28T12:00:00")

        // Every written line is standalone valid JSON.
        let lines = try String(contentsOf: dest, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed),
                "not valid JSON: \(line)")
        }
        // Doubles stay JSON numbers, including scientific notation.
        XCTAssertEqual(
            lines[1], #"["say \"hi\"\n\tté 🚀",1e+20,"2023-06-15T10:30:00","23:59:59","https://example.org/a?b=1"]"#)
        XCTAssertEqual(lines[2], #"["plain",1e-05,null,null,null]"#)

        // And the whole thing reopens equal.
        let database2 = try Database(store: .inMemory)
        let connection2 = try database2.connect()
        let reopened = try DataSource.open(url: dest, connection: connection2)
        XCTAssertEqual(reopened.datasetJSON, metadata)
        XCTAssertEqual(
            try varcharCell("SELECT ID FROM data LIMIT 1", connection: connection2),
            "say \"hi\"\n\tté 🚀")
    }

    /// Windows-authored NDJSON uses CRLF; the spec allows it.
    func testOpenNDJSONWithCRLFLineEndings() throws {
        let fileURL = tempDirectory.appendingPathComponent("crlf.ndjson")
        try (([metadataJSON] + rowsJSON).joined(separator: "\r\n") + "\r\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.datasetJSON?.name, "DM")
        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection), 3)
        XCTAssertEqual(
            try varcharCell("SELECT BMI FROM data WHERE USUBJID = '001'", connection: connection),
            "23.4567890123456789012345")
    }

    /// The spec recommends metadata-first but does not require it — a `.json`
    /// with `rows` FIRST must open identically.
    func testOpenJSONWithRowsBeforeMetadata() throws {
        let contents = #"{"rows":["# + rowsJSON.joined(separator: ",") + "],"
            + metadataJSON.dropFirst()
        let fileURL = tempDirectory.appendingPathComponent("rows-first.json")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: fileURL, connection: connection)

        XCTAssertEqual(opened.datasetJSON?.name, "DM")
        XCTAssertEqual(try queryCount("SELECT count(*) FROM data", connection: connection), 3)
    }

    /// Column names that are SQL keywords or contain quotes must survive the
    /// whole open→edit→save pipeline (everything goes through
    /// quotedIdentifier).
    func testSQLKeywordAndQuoteColumnNamesSurvive() throws {
        let metadata =
            #"{"datasetJSONCreationDateTime":"2026-08-28T12:00:00","datasetJSONVersion":"1.1.0","#
            + #""itemGroupOID":"IG.KW","records":1,"name":"KW","label":"Keywords","#
            + #""columns":["#
            + #"{"itemOID":"IT.KW.1","name":"SELECT","label":"A","dataType":"string"},"#
            + #"{"itemOID":"IT.KW.2","name":"ORDER","label":"B","dataType":"integer"},"#
            + #"{"itemOID":"IT.KW.3","name":"A\"B","label":"C","dataType":"string"}"#
            + #"]}"#
        let fileURL = tempDirectory.appendingPathComponent("kw.ndjson")
        try (metadata + "\n" + #"["x",7,"y"]"# + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: fileURL, connection: connection)
        XCTAssertEqual(opened.columns.map(\.name), ["SELECT", "ORDER", "A\"B"])

        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")
        let dest = tempDirectory.appendingPathComponent("kw-out.ndjson")
        try DatasetJSON.write(
            view: "data_edit", metadata: try XCTUnwrap(opened.datasetJSON),
            connection: connection, to: dest)

        let database2 = try Database(store: .inMemory)
        let connection2 = try database2.connect()
        let reopened = try DataSource.open(url: dest, connection: connection2)
        XCTAssertEqual(reopened.columns.map(\.name), ["SELECT", "ORDER", "A\"B"])
        XCTAssertEqual(
            try varcharCell("SELECT \"A\"\"B\" FROM data", connection: connection2), "y")
    }

    /// PINS A BOUNDARY, not an aspiration: attributes outside the v1.1 spec
    /// (vendor extensions) survive open but are DROPPED on save — the
    /// "metadata verbatim" guarantee covers spec attributes only.
    func testUnknownMetadataAttributesAreDroppedOnSave() throws {
        let extended = metadataJSON.replacingOccurrences(
            of: #""itemGroupOID":"IG.DM""#,
            with: #""x-vendor":"custom","itemGroupOID":"IG.DM""#)
        let src = tempDirectory.appendingPathComponent("ext.ndjson")
        try (extended + "\n" + rowsJSON.joined(separator: "\n") + "\n")
            .write(to: src, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)  // opens fine
        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")

        let dest = tempDirectory.appendingPathComponent("ext-out.ndjson")
        try DatasetJSON.write(
            view: "data_edit", metadata: try XCTUnwrap(opened.datasetJSON),
            connection: connection, to: dest)

        let written = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertFalse(written.contains("x-vendor"), "unknown attributes are (by design) not kept")
    }

    /// A failing write must leave an existing destination byte-identical and
    /// no temp litter behind (the atomic temp+replace contract).
    func testFailedWriteLeavesDestinationUntouched() throws {
        let dest = tempDirectory.appendingPathComponent("precious.ndjson")
        try writeNDJSONFixture(at: dest)
        let before = try Data(contentsOf: dest)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: dest, connection: connection)

        XCTAssertThrowsError(
            try DatasetJSON.write(
                view: "no_such_table", metadata: try XCTUnwrap(opened.datasetJSON),
                connection: connection, to: dest))

        XCTAssertEqual(try Data(contentsOf: dest), before, "destination must be untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
            .filter { $0.contains(".tvtv-") }
        XCTAssertEqual(leftovers, [], "no temp litter after a failed write")
    }

    // MARK: - 8c'. Type-mismatch fallback (CDISC's own examples need it)

    /// CDISC's official ADaM examples declare columns as `integer` whose rows
    /// hold fractional values — a strict CAST silently ROUNDS them (verified:
    /// DuckDB '-33.3333333333'::BIGINT is -33). Such columns must fall back
    /// to text, preserving every value exactly, with a warning naming them.
    func testIntegerColumnWithNonIntegerValuesFallsBackToTextAndWarns() throws {
        let metadata =
            #"{"datasetJSONCreationDateTime":"2026-08-28T12:00:00","datasetJSONVersion":"1.1.0","#
            + #""itemGroupOID":"IG.AD","records":4,"name":"AD","label":"ADaM-like","#
            + #""columns":["#
            + #"{"itemOID":"IT.AD.ID","name":"ID","label":"ID","dataType":"string"},"#
            + #"{"itemOID":"IT.AD.PCHG","name":"PCHG","label":"Percent Change","dataType":"integer"},"#
            + #"{"itemOID":"IT.AD.AGE","name":"AGE","label":"Age","dataType":"integer"}"#
            + #"]}"#
        let rows = [
            #"["a",3,34]"#,
            #"["b",-33.3333333333,35]"#,
            #"["c","na",36]"#,
            #"["d",null,null]"#,
        ]
        let src = tempDirectory.appendingPathComponent("ad.ndjson")
        try (([metadata] + rows).joined(separator: "\n") + "\n")
            .write(to: src, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)

        // PCHG falls back to VARCHAR; the clean integer column stays BIGINT.
        XCTAssertEqual(opened.columns.map(\.type), ["VARCHAR", "VARCHAR", "BIGINT"])
        let warning = try XCTUnwrap(opened.warning)
        XCTAssertTrue(warning.contains("PCHG"), "warning should name the column: \(warning)")
        XCTAssertFalse(warning.contains("AGE"), "clean column wrongly flagged: \(warning)")
        XCTAssertEqual(
            try varcharCell("SELECT PCHG FROM data WHERE ID = 'b'", connection: connection),
            "-33.3333333333")
        XCTAssertEqual(
            try varcharCell("SELECT PCHG FROM data WHERE ID = 'c'", connection: connection), "na")
        XCTAssertNil(try varcharCell("SELECT PCHG FROM data WHERE ID = 'd'", connection: connection))

        // Write-back reproduces the source rows byte-for-byte: numbers stay
        // numbers, the stray "na" stays a string, null stays null.
        try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")
        let dest = tempDirectory.appendingPathComponent("ad-out.ndjson")
        try DatasetJSON.write(
            view: "data_edit", metadata: try XCTUnwrap(opened.datasetJSON),
            connection: connection, to: dest, creationDateTime: "2026-08-28T12:00:00")
        let lines = try String(contentsOf: dest, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines[1...]), rows)
    }

    /// Same guard for double and boolean columns with unrepresentable values.
    func testDoubleAndBooleanColumnsWithBadValuesFallBackToText() throws {
        let metadata =
            #"{"datasetJSONCreationDateTime":"2026-08-28T12:00:00","datasetJSONVersion":"1.1.0","#
            + #""itemGroupOID":"IG.XY","records":2,"name":"XY","label":"Mixed","#
            + #""columns":["#
            + #"{"itemOID":"IT.XY.W","name":"W","label":"Weight","dataType":"double"},"#
            + #"{"itemOID":"IT.XY.F","name":"F","label":"Flag","dataType":"boolean"}"#
            + #"]}"#
        let rows = [
            #"[66.7,true]"#,
            #"["heavy","Y"]"#,
        ]
        let src = tempDirectory.appendingPathComponent("xy.ndjson")
        try (([metadata] + rows).joined(separator: "\n") + "\n")
            .write(to: src, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let opened = try DataSource.open(url: src, connection: connection)

        XCTAssertEqual(opened.columns.map(\.type), ["VARCHAR", "VARCHAR"])
        XCTAssertNotNil(opened.warning)
        XCTAssertEqual(try varcharCell("SELECT W FROM data LIMIT 1", connection: connection), "66.7")
        XCTAssertEqual(
            try varcharCell("SELECT F FROM data WHERE W = 'heavy'", connection: connection), "Y")
    }

    // MARK: - 8d. Official CDISC example corpus

    /// The official CDISC example corpus (SDTM/ADaM/SEND/i18n/extensions from
    /// github.com/cdisc-org/DataExchange-DatasetJson), local-only like
    /// `data/bench` — skipped when absent.
    private var cdiscExamplesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TVTVAppTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("data/cdisc-examples")
    }

    /// Every official example must open, and every `.json` must survive an
    /// open → write → reopen round trip with metadata and row count intact.
    /// The deliberately non-conformant extensions example must open with a
    /// records-mismatch warning rather than fail.
    func testOfficialCDISCExampleCorpusOpensAndRoundTrips() throws {
        let root = cdiscExamplesURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("official CDISC examples not present at data/cdisc-examples")
        }
        let files = FileManager.default
            .enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { ["json", "ndjson"].contains($0.pathExtension.lowercased()) }
            .filter { !$0.lastPathComponent.hasSuffix(".schema.json") }  // JSON Schemas, not datasets
            .sorted { $0.path < $1.path }
        XCTAssertGreaterThan(files.count, 100, "corpus looks incomplete")
        // Opening and round-tripping the multi-MB ADaM files takes minutes in
        // a Debug build (DuckDB at -O0); the default run skips files over the
        // cap and the exhaustive pass runs with TVTV_CORPUS_FULL=1 (via
        // xcodebuild's TEST_RUNNER_ env prefix), ideally against Release.
        let fullCorpus = ProcessInfo.processInfo.environment["TVTV_CORPUS_FULL"] != nil
        let byteLimit = 2_000_000
        func fileSize(_ url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
                .flatMap { $0 } ?? 0
        }

        // Writer outputs persist here so an external schema validator can
        // check them after the run.
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvtv-cdisc-roundtrip")
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        var failures: [String] = []

        for url in files {
            guard fullCorpus || fileSize(url) <= byteLimit else { continue }
            let name = url.pathComponents.suffix(2).joined(separator: "/")
            let isExtended = url.lastPathComponent == "extended_dataset.json"
            do {
                let opened = try DataSource.open(url: url, connection: connection)
                let metadata = try XCTUnwrap(opened.datasetJSON)
                let count = try queryCount("SELECT count(*) FROM data", connection: connection)
                if isExtended {
                    // records=72 vs 2 rows AND an integer column holding "na",
                    // both on purpose — must open with warnings, not fail.
                    if opened.warning == nil { failures.append("\(name): expected mismatch warning") }
                } else if name.hasPrefix("adam/") {
                    // CDISC's own ADaM examples declare integer columns with
                    // fractional values — the text fallback warns there; row
                    // count must still match.
                    if count != Int64(metadata.records) {
                        failures.append("\(name): \(count) rows vs records=\(metadata.records)")
                    }
                } else {
                    if opened.warning != nil { failures.append("\(name): unexpected warning \(opened.warning!)") }
                    if count != Int64(metadata.records) {
                        failures.append("\(name): \(count) rows vs records=\(metadata.records)")
                    }
                }
                guard url.pathExtension.lowercased() == "json" else { continue }

                // Round trip through the writer (as .ndjson, the other flavor).
                try connection.execute("CREATE OR REPLACE TABLE data_edit AS SELECT * FROM data")
                let out = outDir.appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + "-"
                    + url.deletingLastPathComponent().lastPathComponent + ".ndjson")
                try DatasetJSON.write(
                    view: "data_edit", metadata: metadata, connection: connection, to: out,
                    creationDateTime: metadata.datasetJSONCreationDateTime)
                let reopened = try DataSource.open(url: out, connection: connection)
                let reopenedCount = try queryCount("SELECT count(*) FROM data", connection: connection)
                if reopenedCount != count { failures.append("\(name): round-trip row count \(reopenedCount) != \(count)") }
                if !isExtended, reopened.datasetJSON != metadata {
                    failures.append("\(name): metadata changed in round trip")
                }
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        XCTAssertEqual(failures, [], "corpus failures:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 9. Errors surface as OpenError with actionable messages

    func testOpeningNonDatasetJSONThrowsOpenErrorMentioningDatasetJSON() throws {
        let fileURL = tempDirectory.appendingPathComponent("plain.json")
        try #"{"hello": [1, 2, 3]}"#.write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        XCTAssertThrowsError(try DataSource.open(url: fileURL, connection: connection)) { error in
            guard case DataSource.OpenError.underlying(let message) = error else {
                return XCTFail("expected OpenError.underlying, got \(error)")
            }
            XCTAssertTrue(message.contains("Dataset-JSON"), "unhelpful message: \(message)")
        }
    }

    func testOpeningDatasetJSONv1LegacyFileThrowsVersionError() throws {
        let fileURL = tempDirectory.appendingPathComponent("legacy.json")
        try #"{"clinicalData":{"studyOID":"S","metaDataVersionOID":"M","itemGroupData":"#
            .appending(#"{"IG.DM":{"records":1,"name":"DM","label":"Demographics","#)
            .appending(#""items":[{"OID":"IT.X","name":"X","label":"X","type":"integer"}],"#)
            .appending(#""itemData":[[1]]}}}}"#)
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()

        XCTAssertThrowsError(try DataSource.open(url: fileURL, connection: connection)) { error in
            guard case DataSource.OpenError.underlying(let message) = error else {
                return XCTFail("expected OpenError.underlying, got \(error)")
            }
            XCTAssertTrue(message.contains("1.0"), "should name the legacy version: \(message)")
            XCTAssertTrue(message.contains("1.1"), "should name the supported version: \(message)")
        }
    }

    func testOpeningGarbageJSONFileThrowsOpenError() throws {
        for name in ["garbage.json", "garbage.ndjson"] {
            let fileURL = tempDirectory.appendingPathComponent(name)
            try "this is not json at all".write(to: fileURL, atomically: true, encoding: .utf8)

            let database = try Database(store: .inMemory)
            let connection = try database.connect()

            XCTAssertThrowsError(
                try DataSource.open(url: fileURL, connection: connection), "for \(name)"
            ) { error in
                XCTAssertTrue(error is DataSource.OpenError, "for \(name): got \(type(of: error))")
            }
        }
    }
}
