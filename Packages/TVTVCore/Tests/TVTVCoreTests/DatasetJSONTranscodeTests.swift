import Darwin
import DuckDB
import Foundation
import XCTest
@testable import TVTVCore

/// Transcode behaviour that only shows at scale: row order across Parquet
/// row groups and the peak-memory ceiling (the reason the transcode runs
/// single-threaded on its own database).
final class DatasetJSONTranscodeTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvtv-transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: Fixtures

    private static let columns = [
        ("SEQ", "integer"), ("USUBJID", "string"), ("VISIT", "string"), ("AVAL", "double"),
        ("AVALC", "string"), ("PARAMCD", "string"), ("ADT", "date"), ("FLAG", "boolean"),
        ("NOTE", "string"), ("SCORE", "float"),
    ]

    private static func metadataJSON(records: Int) -> String {
        let columns = Self.columns.map {
            #"{"itemOID":"IT.BIG.\#($0.0)","name":"\#($0.0)","label":"\#($0.0)","dataType":"\#($0.1)"}"#
        }.joined(separator: ",")
        return #"{"datasetJSONCreationDateTime":"2026-09-02T00:00:00","datasetJSONVersion":"1.1.0","#
            + #""itemGroupOID":"IG.BIG","records":\#(records),"name":"BIG","label":"Big","columns":[\#(columns)]}"#
    }

    private static func row(_ i: Int) -> String {
        #"[\#(i),"01-701-\#(i % 1200)","VISIT \#(i % 13)",\#(Double(i % 997) / 7.0),"value \#(i)","PARAM\#(i % 40)","#
            + #""2024-\#(i % 12 + 1)-\#(i % 28 + 1)",\#(i % 3 == 0),"some free text note number \#(i) with padding",\#(Double(i % 100) / 100.0)]"#
    }

    /// Writes `rows` rows in both flavors; returns (ndjson, json) URLs.
    private func writeFixtures(rows: Int, name: String) throws -> (ndjson: URL, json: URL) {
        let ndjson = tempDirectory.appendingPathComponent("\(name).ndjson")
        let json = tempDirectory.appendingPathComponent("\(name).json")
        let metadata = Self.metadataJSON(records: rows)
        FileManager.default.createFile(atPath: ndjson.path, contents: nil)
        FileManager.default.createFile(atPath: json.path, contents: nil)
        let n = try FileHandle(forWritingTo: ndjson), j = try FileHandle(forWritingTo: json)
        defer { try? n.close(); try? j.close() }
        try n.write(contentsOf: Data((metadata + "\n").utf8))
        try j.write(contentsOf: Data((String(metadata.dropLast()) + #","rows":["#).utf8))
        var nBuf = "", jBuf = ""
        for i in 0..<rows {
            let r = Self.row(i)
            nBuf += r + "\n"
            jBuf += (i == 0 ? "" : ",") + r
            if nBuf.utf8.count > 1 << 20 {
                try n.write(contentsOf: Data(nBuf.utf8)); try j.write(contentsOf: Data(jBuf.utf8))
                nBuf = ""; jBuf = ""
            }
        }
        try n.write(contentsOf: Data(nBuf.utf8))
        try j.write(contentsOf: Data((jBuf + "]}").utf8))
        return (ndjson, json)
    }

    private func misorderedRows(in parquet: URL) throws -> (misordered: Int64, total: Int64) {
        let connection = try Database(store: .inMemory).connect()
        let result = try connection.query(
            "SELECT count(*) FILTER (WHERE SEQ <> file_row_number), count(*) "
            + "FROM read_parquet('\(parquet.path)', file_row_number=true)")
        return (result[0].cast(to: Int64.self)[0] ?? -1, result[1].cast(to: Int64.self)[0] ?? -1)
    }

    private func rowGroupCount(in parquet: URL) throws -> Int64 {
        let connection = try Database(store: .inMemory).connect()
        let result = try connection.query(
            "SELECT count(DISTINCT row_group_id) FROM parquet_metadata('\(parquet.path)')")
        return result[0].cast(to: Int64.self)[0] ?? -1
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Peak physical footprint growth (bytes) while `work` runs, sampled every ~2ms.
    private func peakFootprintGrowth(during work: () throws -> Void) throws -> UInt64 {
        final class Peak: @unchecked Sendable { var value: UInt64 = 0; var stop = false }
        let peak = Peak()
        let base = Self.physicalFootprint()
        DispatchQueue.global().async {
            while !peak.stop { peak.value = max(peak.value, Self.physicalFootprint()); usleep(2000) }
        }
        defer { peak.stop = true }
        try work()
        peak.value = max(peak.value, Self.physicalFootprint())
        return peak.value > base ? peak.value - base : 0
    }

    // MARK: Tests

    func testLowMemoryPathKeepsRowOrderAcrossItsSmallRowGroupsInBothFlavors() throws {
        let files = try writeFixtures(rows: 60_000, name: "order")  // 3 row groups of 20k
        for url in [files.ndjson, files.json] {
            let conversion = try DatasetJSON.convertToParquet(url: url, lowMemoryThreshold: 0)
            defer { try? FileManager.default.removeItem(at: conversion.parquetURL) }
            let (misordered, total) = try misorderedRows(in: conversion.parquetURL)
            XCTAssertEqual(total, 60_000, url.lastPathComponent)
            XCTAssertEqual(misordered, 0, "\(url.lastPathComponent): rows came out of file order")
            XCTAssertNil(conversion.warning, url.lastPathComponent)
            XCTAssertGreaterThanOrEqual(try rowGroupCount(in: conversion.parquetURL), 3, url.lastPathComponent)
        }
    }

    func testFilesUnderTheThresholdTakeTheParallelPathWithDefaultRowGroups() throws {
        // ~8MB, far under the 128MB default threshold: DuckDB's default row
        // group (122,880 rows) holds all 60k rows in one group.
        let files = try writeFixtures(rows: 60_000, name: "fast")
        for url in [files.ndjson, files.json] {
            let conversion = try DatasetJSON.convertToParquet(url: url)
            defer { try? FileManager.default.removeItem(at: conversion.parquetURL) }
            XCTAssertEqual(try rowGroupCount(in: conversion.parquetURL), 1, url.lastPathComponent)
            let (misordered, total) = try misorderedRows(in: conversion.parquetURL)
            XCTAssertEqual(total, 60_000, url.lastPathComponent)
            XCTAssertEqual(misordered, 0, "\(url.lastPathComponent): rows came out of file order")
        }
    }

    func testThresholdIsInclusiveOfFileSize() throws {
        let files = try writeFixtures(rows: 60_000, name: "edge")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: files.ndjson.path)[.size] as? Int)
        let atSize = try DatasetJSON.convertToParquet(url: files.ndjson, lowMemoryThreshold: size)
        defer { try? FileManager.default.removeItem(at: atSize.parquetURL) }
        XCTAssertEqual(try rowGroupCount(in: atSize.parquetURL), 3, "a file AT the threshold is treated as large")
        let justUnder = try DatasetJSON.convertToParquet(url: files.ndjson, lowMemoryThreshold: size + 1)
        defer { try? FileManager.default.removeItem(at: justUnder.parquetURL) }
        XCTAssertEqual(try rowGroupCount(in: justUnder.parquetURL), 1, "a file just under the threshold takes the fast path")
    }

    func testJSONFlavorLeavesNoSplitTempFileBehind() throws {
        let files = try writeFixtures(rows: 10, name: "cleanup")
        let before = try leftoverSplitFiles()
        let conversion = try DatasetJSON.convertToParquet(url: files.json)
        try? FileManager.default.removeItem(at: conversion.parquetURL)
        XCTAssertEqual(try leftoverSplitFiles(), before, "split temp .ndjson must be deleted after the transcode")
    }

    private func leftoverSplitFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("tvtv-datasetjson-") && $0.hasSuffix(".ndjson") })
    }

    func testPeakMemoryStaysNearTheFileSizeInBothFlavors() throws {
        // ~27MB per flavor, forced onto the low-memory path (in production
        // it starts at 128MB). Debug DuckDB takes ~30s per transcode.
        let files = try writeFixtures(rows: 200_000, name: "mem")
        for url in [files.ndjson, files.json] {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
            var conversion: DatasetJSON.Conversion?
            let growth = try peakFootprintGrowth {
                conversion = try DatasetJSON.convertToParquet(url: url, lowMemoryThreshold: 0)
            }
            if let parquet = conversion?.parquetURL { try? FileManager.default.removeItem(at: parquet) }
            // Measured (duckdb-swift 1.1.3): the old multi-threaded transcode
            // grew ~3.6-3.8× the file size; the single-threaded one ~1.1× at
            // 200MB and ~1.5× at 40MB, on top of a fixed ~25-30MB for DuckDB
            // itself (buffer pool, JSON extension). Hence a ratio plus a
            // fixed allowance.
            let ceiling = UInt64(1.5 * Double(size)) + 32 * 1_048_576
            XCTAssertLessThan(
                growth, ceiling,
                "\(url.lastPathComponent): peak footprint grew \(growth / 1_048_576)MB for a \(size / 1_048_576)MB file")
        }
    }
}
