import DuckDB
import Foundation
import TVTVCore
import XCTest

/// Round-trips the official CDISC example corpus (SDTM/ADaM/SEND/i18n from
/// github.com/cdisc-org/DataExchange-DatasetJson) through TVTVCore's
/// `DatasetJSON` reader and writer. The corpus is local-only
/// (`data/cdisc-examples`, git-ignored) — skipped when absent.
///
/// Debug builds take minutes on the multi-MB ADaM files (DuckDB at -O0);
/// prefer `swift test -c release --filter DatasetJSONCorpus`. Writer outputs
/// persist in `<tmp>/tvtv-cdisc-roundtrip` so an external validator can check
/// them against CDISC's JSON Schema afterwards.
final class DatasetJSONCorpusTests: XCTestCase {

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // -> TVTVCoreTests/
            .deletingLastPathComponent()  // -> Tests/
            .deletingLastPathComponent()  // -> TVTVCore/
            .deletingLastPathComponent()  // -> Packages/
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("data/cdisc-examples")
    }

    func testOfficialCorpusConvertWriteReconvert() throws {
        // Opt-in: the uncapped corpus takes ~15 minutes at Debug optimization
        // (the app-side corpus test covers the size-capped subset on every
        // run). NOTE: `swift test -c release` currently segfaults on ANY
        // DuckDB query on this toolchain (xctest + optimized duckdb-swift
        // 1.1.3) — the optimized pipeline is verified via the Release app
        // instead.
        guard ProcessInfo.processInfo.environment["TVTV_CORPUS_FULL"] != nil else {
            throw XCTSkip("exhaustive corpus pass — run with TVTV_CORPUS_FULL=1")
        }
        let root = corpusURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("official CDISC examples not present at data/cdisc-examples")
        }
        let files = FileManager.default
            .enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { ["json", "ndjson"].contains($0.pathExtension.lowercased()) }
            .filter { !$0.lastPathComponent.hasSuffix(".schema.json") }
            .sorted { $0.path < $1.path }
        XCTAssertGreaterThan(files.count, 100, "corpus looks incomplete")

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvtv-cdisc-roundtrip")
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        var failures: [String] = []

        func rowCount(ofParquet url: URL) throws -> Int64 {
            let escaped = url.path.replacingOccurrences(of: "'", with: "''")
            let result = try connection.query("SELECT count(*) FROM read_parquet('\(escaped)')")
            return result[0].cast(to: Int64.self)[0] ?? -1
        }

        for url in files {
            let name = url.pathComponents.suffix(2).joined(separator: "/")
            let isExtended = url.lastPathComponent == "extended_dataset.json"
            do {
                let conversion = try DatasetJSON.convertToParquet(url: url)
                defer { try? FileManager.default.removeItem(at: conversion.parquetURL) }
                let count = try rowCount(ofParquet: conversion.parquetURL)
                if !isExtended, count != Int64(conversion.metadata.records) {
                    failures.append("\(name): \(count) rows vs records=\(conversion.metadata.records)")
                }
                guard url.pathExtension.lowercased() == "json" else { continue }

                let escaped = conversion.parquetURL.path.replacingOccurrences(of: "'", with: "''")
                try connection.execute(
                    "CREATE OR REPLACE TABLE corpus_edit AS SELECT * FROM read_parquet('\(escaped)')")
                let out = outDir.appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + "-"
                    + url.deletingLastPathComponent().lastPathComponent + ".ndjson")
                try DatasetJSON.write(
                    view: "corpus_edit", metadata: conversion.metadata, connection: connection,
                    to: out, creationDateTime: conversion.metadata.datasetJSONCreationDateTime)

                let back = try DatasetJSON.convertToParquet(url: out)
                defer { try? FileManager.default.removeItem(at: back.parquetURL) }
                if try rowCount(ofParquet: back.parquetURL) != count {
                    failures.append("\(name): round-trip row count changed")
                }
                if !isExtended, back.metadata != conversion.metadata {
                    failures.append("\(name): metadata changed in round trip")
                }
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        XCTAssertEqual(failures, [], "corpus failures:\n" + failures.joined(separator: "\n"))
    }
}
