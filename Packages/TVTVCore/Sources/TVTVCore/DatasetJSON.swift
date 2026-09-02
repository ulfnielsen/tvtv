import DuckDB
import Foundation

/// CDISC Dataset-JSON v1.1 support — both serializations:
///
/// - `.json` — one object: metadata attributes plus a `rows` array of
///   row-arrays.
/// - `.ndjson` — the metadata object on line 1, then one row-array per line
///   (the streaming flavor for large datasets).
///
/// DuckDB's JSON extension reads the files, but the grid can't page the
/// columns-metadata + positional row-arrays shape directly, so — like Vortex —
/// the dataset is transcoded to a temporary Parquet and paged from there. The
/// transcode is a single `COPY (SELECT …) TO '<tmp>.parquet'` whose SELECT
/// extracts each column positionally (`json_extract_string(row, '$[i]')`)
/// from the row arrays of the `.ndjson` shape; a `.json` file is first split
/// into that shape, streaming (`DatasetJSONSplitter.swift`), so DuckDB never
/// holds the whole object.
///
/// Type mapping is fidelity-first, because save re-serializes every row (so a
/// lossy cast on open would corrupt saved files, not just displays):
/// `integer`→BIGINT, `float`/`double`→DOUBLE, `boolean`→BOOLEAN; everything
/// else — `string`, `decimal` (a string in Dataset-JSON precisely so precision
/// survives), `date`/`time`/`datetime` (ISO 8601, which sorts correctly as
/// text), `URI` — stays VARCHAR.
public enum DatasetJSON {

    // MARK: - Metadata model

    public struct SourceSystem: Codable, Equatable {
        public let name: String
        public let version: String
    }

    /// One entry of the `columns` array: CDISC variable metadata. Retained in
    /// full (OIDs, labels, formats) so saving can round-trip it verbatim.
    public struct Column: Codable, Equatable {
        public let itemOID: String
        public let name: String
        public let label: String
        public let dataType: String
        public let targetDataType: String?
        public let length: Int?
        public let displayFormat: String?
        public let keySequence: Int?
    }

    /// The dataset's top-level attributes (everything except `rows`).
    /// Required-vs-optional mirrors the v1.1 spec.
    public struct Metadata: Codable, Equatable {
        public let datasetJSONCreationDateTime: String
        public let datasetJSONVersion: String
        public let fileOID: String?
        public let dbLastModifiedDateTime: String?
        public let originator: String?
        public let sourceSystem: SourceSystem?
        public let studyOID: String?
        public let metaDataVersionOID: String?
        public let metaDataRef: String?
        public let itemGroupOID: String
        public let records: Int
        public let name: String
        public let label: String
        public let columns: [Column]
    }

    public enum Flavor: String {
        case json
        case ndjson
    }

    public enum ReadError: LocalizedError {
        case notDatasetJSON(String)
        case unsupportedVersion(String)
        case invalid(String)
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .notDatasetJSON(let reason):
                return "Not a Dataset-JSON file: \(reason)"
            case .unsupportedVersion(let version):
                return "Unsupported Dataset-JSON version \(version) — TVTV reads Dataset-JSON 1.1."
            case .invalid(let reason):
                return "Can't open this Dataset-JSON file: \(reason)"
            case .underlying(let message):
                return message
            }
        }
    }

    // MARK: - Reading

    public struct Conversion {
        public let parquetURL: URL
        public let metadata: Metadata
        /// Non-fatal problem worth telling the user about — currently a
        /// mismatch between the declared `records` and the rows actually
        /// transcoded (row loss from malformed lines, or stale metadata).
        public let warning: String?
    }

    /// Files at least this large (bytes) transcode on the low-memory path.
    /// Below it the ~4× peak of the parallel path tops out around 500MB,
    /// which is harmless; above it the peak runs into gigabytes while the
    /// low-memory path costs well under a second per 100MB.
    public static let lowMemoryThreshold = 128 << 20

    /// Transcode the Dataset-JSON at `url` to a temporary Parquet, returning
    /// its location and the parsed metadata. The caller owns the temp file
    /// (delete when done).
    ///
    /// Runs on a private in-memory DuckDB. Files of `lowMemoryThreshold`
    /// bytes or more use ONE thread and small Parquet row groups: measured on
    /// duckdb-swift 1.1.3, the default multi-threaded scan +
    /// insertion-ordered COPY held ~4× the file size in RAM, while this shape
    /// holds ~1× and still emits rows in file order (CDISC row order is
    /// significant, so `preserve_insertion_order=false` is not an option),
    /// at ~1.5× the wall time. `threads` is a database-global setting, hence
    /// a private database rather than the caller's.
    ///
    /// The single-object `.json` flavor is first split, streaming, into a
    /// temporary `.ndjson` (see `splitToNDJSON`) — DuckDB's JSON reader
    /// otherwise materializes the whole object (~70× the file size).
    public static func convertToParquet(
        url: URL, lowMemoryThreshold: Int = lowMemoryThreshold
    ) throws -> Conversion {
        guard let flavor = Flavor(rawValue: url.pathExtension.lowercased()) else {
            throw ReadError.underlying("Not a .json/.ndjson file: \(url.lastPathComponent)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Without this check, DuckDB's read failure gets misreported as
            // "not valid JSON" — a wrong diagnosis of a file that is merely
            // missing (moved, deleted, or unreadable on Reload).
            throw ReadError.underlying("Could not open \(url.lastPathComponent): the file doesn't exist.")
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        let lowMemory = fileSize >= lowMemoryThreshold
        let connection: Connection
        do {
            connection = try Database(store: .inMemory).connect()
            if lowMemory { try connection.execute("SET threads = 1") }
        } catch {
            throw ReadError.underlying("Could not start the Dataset-JSON transcoder: \(error)")
        }

        let ndjson: URL
        var splitTemp: URL?
        switch flavor {
        case .ndjson:
            ndjson = url
        case .json:
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tvtv-datasetjson-\(UUID().uuidString).ndjson")
            do {
                try splitToNDJSON(source: url, destination: temp)
            } catch let error as SplitError {
                try? FileManager.default.removeItem(at: temp)
                switch error {
                case .empty:
                    throw ReadError.notDatasetJSON("empty file (\(url.lastPathComponent))")
                case .invalidJSON:
                    throw ReadError.notDatasetJSON("not valid JSON (\(url.lastPathComponent))")
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw ReadError.underlying("Could not read \(url.lastPathComponent): \(error)")
            }
            splitTemp = temp
            ndjson = temp
        }
        defer { if let splitTemp { try? FileManager.default.removeItem(at: splitTemp) } }

        let metadata = try readMetadata(ndjson: ndjson, original: url)

        // Columns whose declared dataType doesn't losslessly hold their actual
        // values open as text instead — CDISC's own ADaM examples declare
        // `integer` columns holding fractional values, which a strict CAST
        // would silently ROUND (and a stray "na" would abort the open).
        let fallback = try typedColumnsNeedingTextFallback(
            for: metadata, ndjson: ndjson, connection: connection)
        var warnings: [String] = []
        if !fallback.isEmpty {
            let names = fallback.sorted().map { metadata.columns[$0].name }
            warnings.append(
                (names.count == 1 ? "Column \(names[0]) contains" : "Columns \(names.joined(separator: ", ")) contain")
                + " values that don't fit the declared dataType — opened as text to preserve them exactly.")
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvtv-datasetjson-\(UUID().uuidString).parquet")
        let select = rowSelect(for: metadata, ndjson: ndjson, textFallback: fallback)
        do {
            // 20k-row groups (default 122,880): with one thread the writer's
            // pending row group is what bounds the peak, not the scan.
            let options = lowMemory ? "FORMAT PARQUET, ROW_GROUP_SIZE 20000" : "FORMAT PARQUET"
            try connection.execute(
                "COPY (\(select)) TO '\(escapedLiteral(dest.path))' (\(options))")
        } catch {
            throw ReadError.underlying("Could not read Dataset-JSON rows: \(error)")
        }

        // Cross-check what actually landed against the declared record count.
        // Reading stays tolerant (the rows win), but a shortfall usually means
        // malformed row lines were silently skipped — say so.
        if let result = try? connection.query(
            "SELECT count(*) FROM read_parquet('\(escapedLiteral(dest.path))')"),
            let actual = result[0].cast(to: Int64.self)[0],
            actual != Int64(metadata.records) {
            warnings.append(
                "Opened \(actual) rows, but the file's metadata declares records=\(metadata.records)"
                + " — rows may be malformed, or the metadata is out of date.")
        }
        return Conversion(
            parquetURL: dest, metadata: metadata,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    /// One aggregate scan over the row arrays: for every column with a typed
    /// mapping, count the non-null values its declared type cannot hold
    /// losslessly (fractional or overflowing text for `integer`, non-numeric
    /// for `float`/`double`, non-true/false for `boolean`). Returns the
    /// indices of columns that must stay text.
    private static func typedColumnsNeedingTextFallback(
        for metadata: Metadata, ndjson: URL, connection: Connection
    ) throws -> Set<Int> {
        let typed = metadata.columns.enumerated()
            .filter { sqlType(forDataType: $0.element.dataType) != nil }
        guard !typed.isEmpty else { return [] }
        let (source, row) = rowSource(ndjson: ndjson)
        let paths = typed.map { "'$[\($0.offset)]'" }.joined(separator: ",")
        let checks = typed.enumerated().map { position, column -> String in
            let value = "vals[\(position + 1)]"
            let bad: String
            switch column.element.dataType {
            case "integer":
                bad = "NOT regexp_matches(\(value), '^-?[0-9]+$') OR TRY_CAST(\(value) AS BIGINT) IS NULL"
            case "boolean":
                bad = "\(value) NOT IN ('true', 'false')"
            default:  // float, double
                bad = "TRY_CAST(\(value) AS DOUBLE) IS NULL"
            }
            return "count(*) FILTER (WHERE \(value) IS NOT NULL AND (\(bad))) AS c\(position)"
        }
        let sql = "SELECT \(checks.joined(separator: ", ")) FROM "
            + "(SELECT json_extract_string(\(row), [\(paths)]) AS vals FROM \(source))"
        let result: ResultSet
        do {
            result = try connection.query(sql)
        } catch {
            throw ReadError.underlying("Could not read Dataset-JSON rows: \(error)")
        }
        var fallback = Set<Int>()
        for (position, column) in typed.enumerated() {
            if let count = result[DBInt(position)].cast(to: Int64.self)[0], count > 0 {
                fallback.insert(column.offset)
            }
        }
        return fallback
    }

    /// Parse and validate the metadata: line 1 of `ndjson` (the file itself,
    /// or the split of a `.json`). `original` is the user's file, sniffed for
    /// legacy-version hints and named in errors.
    static func readMetadata(ndjson: URL, original url: URL) throws -> Metadata {
        let data = try firstLine(of: ndjson)

        let metadata: Metadata
        do {
            metadata = try JSONDecoder().decode(Metadata.self, from: data)
        } catch {
            // Sniff the RAW file head (not `data`, which for `.json` is the
            // projected metadata — all nulls for a legacy file): Dataset-JSON
            // 1.0 nested everything under `clinicalData`.
            let head = (try? FileHandle(forReadingFrom: url))
                .flatMap { handle -> String? in
                    defer { try? handle.close() }
                    return (try? handle.read(upToCount: 4096)).flatMap { String(data: $0, encoding: .utf8) }
                } ?? ""
            if head.contains("\"clinicalData\"") {
                throw ReadError.unsupportedVersion("1.0")
            }
            throw ReadError.notDatasetJSON(
                "missing or invalid Dataset-JSON 1.1 metadata (\(url.lastPathComponent))")
        }
        guard metadata.datasetJSONVersion == "1.1" || metadata.datasetJSONVersion.hasPrefix("1.1.") else {
            throw ReadError.unsupportedVersion(metadata.datasetJSONVersion)
        }
        // The transcode aliases parquet columns by NAME and the writer
        // projects them back by name; the writer and cell edits also page by
        // DuckDB's rowid pseudo-column. Names that collide (DuckDB identifiers
        // are case-insensitive) or shadow rowid would open apparently fine and
        // then silently corrupt the file on save — refuse them up front.
        var seenNames = Set<String>()
        for column in metadata.columns {
            let lowered = column.name.lowercased()
            if lowered == "rowid" {
                throw ReadError.invalid(
                    "the column \"\(column.name)\" conflicts with the rowid row identifier "
                    + "TVTV uses for editing")
            }
            if !seenNames.insert(lowered).inserted {
                throw ReadError.invalid(
                    "duplicate column name \"\(column.name)\" (column names must be unique)")
            }
        }
        return metadata
    }

    // MARK: - Writing

    public enum WriteError: LocalizedError {
        case unsupportedExtension(String)
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedExtension(let ext):
                return "Dataset-JSON can be saved as .json or .ndjson, not .\(ext)"
            case .underlying(let message):
                return message
            }
        }
    }

    /// Serialize `view` (the edited table — must have a stable `rowid`, i.e.
    /// a real table like `data_edit`) as Dataset-JSON to `url`, in the flavor
    /// its extension names. The CDISC metadata round-trips verbatim — same
    /// attributes, spec attribute order — except `records`, which is counted
    /// from what is actually written, and `datasetJSONCreationDateTime`,
    /// which describes THIS file per the spec and is stamped fresh
    /// (`creationDateTime` overrides the stamp, for deterministic tests).
    /// Cells re-serialize by the ORIGINAL column dataType:
    /// `integer`/`float`/`double` as JSON numbers, `boolean` as true/false,
    /// SQL NULL as null, everything else (including `decimal`, a string in
    /// Dataset-JSON) as strings.
    ///
    /// Written atomically: a temp file in the destination directory, then a
    /// replace — a failure mid-write cannot corrupt an existing file.
    public static func write(
        view: String, metadata: Metadata, connection: Connection, to url: URL,
        creationDateTime: String? = nil
    ) throws {
        guard let flavor = Flavor(rawValue: url.pathExtension.lowercased()) else {
            throw WriteError.unsupportedExtension(url.pathExtension)
        }
        let stamp = creationDateTime ?? ISO8601DateFormatter().string(from: Date())

        let records: Int
        do {
            let result = try connection.query("SELECT count(*) FROM \(quotedIdentifier(view))")
            records = Int(result[0].cast(to: Int64.self)[0] ?? 0)
        } catch {
            throw WriteError.underlying("Could not read edited rows: \(error)")
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tvtv-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: temporary)
        } catch {
            throw WriteError.underlying("Could not create file: \(error.localizedDescription)")
        }
        do {
            let header = metadataJSONObject(metadata, records: records, creationDateTime: stamp)
            switch flavor {
            case .ndjson:
                try handle.write(contentsOf: Data((header + "\n").utf8))
                try writeRows(view: view, metadata: metadata, connection: connection) { rows in
                    try handle.write(contentsOf: Data((rows.joined(separator: "\n") + "\n").utf8))
                }
            case .json:
                try handle.write(contentsOf: Data((String(header.dropLast()) + ",\"rows\":[").utf8))
                var first = true
                try writeRows(view: view, metadata: metadata, connection: connection) { rows in
                    let prefix = first ? "" : ","
                    first = false
                    try handle.write(contentsOf: Data((prefix + rows.joined(separator: ",")).utf8))
                }
                try handle.write(contentsOf: Data("]}".utf8))
            }
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch let error as WriteError {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw WriteError.underlying("Could not save Dataset-JSON: \(error.localizedDescription)")
        }
    }

    /// Page `view` in rowid order and hand each page's serialized row-array
    /// lines to `emit`. Pages by rowid RANGES, not LIMIT/OFFSET — each offset
    /// page is a Top-N that rescans the table, O(n²) over a large save, while
    /// a range scan prunes to its row groups. Rowid gaps from deleted rows
    /// just yield short pages, so the loop runs to max(rowid) rather than
    /// stopping at the first short page.
    private static func writeRows(
        view: String, metadata: Metadata, connection: Connection,
        emit: ([String]) throws -> Void
    ) throws {
        let pageSize: Int64 = 10_000
        let projection = metadata.columns
            .map { "\(quotedIdentifier($0.name))::VARCHAR" }
            .joined(separator: ", ")
        let maxRowID: Int64?
        do {
            let result = try connection.query("SELECT max(rowid) FROM \(quotedIdentifier(view))")
            maxRowID = result[0].cast(to: Int64.self)[0]
        } catch {
            throw WriteError.underlying("Could not read edited rows: \(error)")
        }
        guard let maxRowID else { return }  // empty table
        var low: Int64 = 0
        while low <= maxRowID {
            let sql = "SELECT \(projection) FROM \(quotedIdentifier(view)) "
                + "WHERE rowid >= \(low) AND rowid < \(low + pageSize) ORDER BY rowid"
            let result: ResultSet
            do {
                result = try connection.query(sql)
            } catch {
                throw WriteError.underlying("Could not read edited rows: \(error)")
            }
            let rowCount = Int(result.rowCount)
            if rowCount > 0 {
                let columns = (0..<metadata.columns.count).map { result[DBInt($0)].cast(to: String.self) }
                var rows: [String] = []
                rows.reserveCapacity(rowCount)
                for row in 0..<rowCount {
                    let cells = metadata.columns.indices.map { index in
                        jsonValue(columns[index][DBInt(row)], dataType: metadata.columns[index].dataType)
                    }
                    rows.append("[" + cells.joined(separator: ",") + "]")
                }
                try emit(rows)
            }
            low += pageSize
        }
    }

    /// One cell as JSON, serialized by the column's Dataset-JSON dataType. A
    /// value a numeric/boolean type can't represent (a text-fallback column's
    /// "na", a non-finite double) is emitted as a STRING — reproducing the
    /// source file rather than corrupting the value to null.
    private static func jsonValue(_ value: String?, dataType: String) -> String {
        guard let value else { return "null" }
        switch dataType {
        case "integer", "float", "double":
            return isJSONNumber(value) ? value : jsonString(value)
        case "boolean":
            return value == "true" || value == "false" ? value : jsonString(value)
        default:
            return jsonString(value)
        }
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` as a hand-rolled
    /// byte scan — this runs once per numeric CELL, where a regex (compiled
    /// per call) dominated whole-file save times.
    private static func isJSONNumber(_ value: String) -> Bool {
        var bytes = value.utf8[...]
        func digit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        func take(where test: (UInt8) -> Bool) -> Int {
            var n = 0
            while let b = bytes.first, test(b) { bytes = bytes.dropFirst(); n += 1 }
            return n
        }
        if bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
        guard let lead = bytes.first, digit(lead) else { return false }
        if lead == UInt8(ascii: "0") {
            bytes = bytes.dropFirst()  // a leading 0 stands alone
        } else if take(where: digit) == 0 {
            return false
        }
        if bytes.first == UInt8(ascii: ".") {
            bytes = bytes.dropFirst()
            guard take(where: digit) > 0 else { return false }
        }
        if bytes.first == UInt8(ascii: "e") || bytes.first == UInt8(ascii: "E") {
            bytes = bytes.dropFirst()
            if bytes.first == UInt8(ascii: "+") || bytes.first == UInt8(ascii: "-") {
                bytes = bytes.dropFirst()
            }
            guard take(where: digit) > 0 else { return false }
        }
        return bytes.isEmpty
    }

    /// The metadata object as compact JSON, attributes in the spec-recommended
    /// order (metadata first — callers append `rows` last), optional
    /// attributes emitted only when present.
    private static func metadataJSONObject(
        _ metadata: Metadata, records: Int, creationDateTime: String
    ) -> String {
        var attributes: [String] = []
        func add(_ name: String, _ value: String?) {
            if let value { attributes.append("\(jsonString(name)):\(value)") }
        }
        add("datasetJSONCreationDateTime", jsonString(creationDateTime))
        add("datasetJSONVersion", jsonString(metadata.datasetJSONVersion))
        add("fileOID", metadata.fileOID.map(jsonString))
        add("dbLastModifiedDateTime", metadata.dbLastModifiedDateTime.map(jsonString))
        add("originator", metadata.originator.map(jsonString))
        add("sourceSystem", metadata.sourceSystem.map {
            "{\(jsonString("name")):\(jsonString($0.name)),\(jsonString("version")):\(jsonString($0.version))}"
        })
        add("studyOID", metadata.studyOID.map(jsonString))
        add("metaDataVersionOID", metadata.metaDataVersionOID.map(jsonString))
        add("metaDataRef", metadata.metaDataRef.map(jsonString))
        add("itemGroupOID", jsonString(metadata.itemGroupOID))
        add("records", String(records))
        add("name", jsonString(metadata.name))
        add("label", jsonString(metadata.label))
        add("columns", "[" + metadata.columns.map(columnJSONObject).joined(separator: ",") + "]")
        return "{" + attributes.joined(separator: ",") + "}"
    }

    private static func columnJSONObject(_ column: Column) -> String {
        var attributes: [String] = []
        func add(_ name: String, _ value: String?) {
            if let value { attributes.append("\(jsonString(name)):\(value)") }
        }
        add("itemOID", jsonString(column.itemOID))
        add("name", jsonString(column.name))
        add("label", jsonString(column.label))
        add("dataType", jsonString(column.dataType))
        add("targetDataType", column.targetDataType.map(jsonString))
        add("length", column.length.map(String.init))
        add("displayFormat", column.displayFormat.map(jsonString))
        add("keySequence", column.keySequence.map(String.init))
        return "{" + attributes.joined(separator: ",") + "}"
    }

    /// JSON string literal with standard escaping. Fast path for the common
    /// cell that needs none (this runs once per string cell).
    private static func jsonString(_ value: String) -> String {
        if !value.utf8.contains(where: { $0 == 0x22 || $0 == 0x5C || $0 < 0x20 }) {
            return "\"\(value)\""
        }
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20:
                out += String(format: "\\u%04x", s.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - Transcode SQL

    /// The FROM-source of row arrays, and the expression that names one
    /// row's JSON within it. Line 1 is the metadata object; every row line
    /// is an array. The object cap bounds a single LINE, so a fixed generous
    /// cap beats a file-sized one (which measurably slows the scan); 64MB
    /// matches firstLine's own metadata-line cap.
    private static func rowSource(ndjson: URL) -> (source: String, row: String) {
        (
            "read_ndjson_objects('\(escapedLiteral(ndjson.path))', maximum_object_size=67108864) "
                + "WHERE json_type(json) = 'ARRAY'",
            "json")
    }

    /// The typed per-column SELECT over the row arrays. One
    /// `json_extract_string` call with a path LIST parses each row's JSON
    /// once for all columns (the per-column form re-parses the row per
    /// column — several times the transcode CPU on wide datasets). Columns in
    /// `textFallback` skip their type cast and stay VARCHAR.
    private static func rowSelect(
        for metadata: Metadata, ndjson: URL, textFallback: Set<Int>
    ) -> String {
        let (source, row) = rowSource(ndjson: ndjson)
        let paths = metadata.columns.indices.map { "'$[\($0)]'" }.joined(separator: ",")
        let columns = metadata.columns.enumerated().map { index, column in
            let value = "vals[\(index + 1)]"
            let expression = textFallback.contains(index)
                ? value
                : sqlType(forDataType: column.dataType).map { "CAST(\(value) AS \($0))" } ?? value
            return "\(expression) AS \(quotedIdentifier(column.name))"
        }
        return "SELECT \(columns.joined(separator: ", ")) FROM "
            + "(SELECT json_extract_string(\(row), [\(paths)]) AS vals FROM \(source))"
    }

    /// DuckDB type for a Dataset-JSON dataType, or nil to keep VARCHAR.
    private static func sqlType(forDataType dataType: String) -> String? {
        switch dataType {
        case "integer": return "BIGINT"
        case "float", "double": return "DOUBLE"
        case "boolean": return "BOOLEAN"
        default: return nil
        }
    }

    // MARK: - Metadata extraction

    /// Read up to the first newline (the `.ndjson` metadata line). Capped —
    /// a "line" this large is not a metadata object.
    private static func firstLine(of url: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ReadError.underlying("Could not open file: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(chunk[chunk.startIndex..<newline])
                return buffer
            }
            buffer.append(chunk)
            if buffer.count > 64 * 1024 * 1024 { break }
        }
        return buffer  // single-line file (metadata-only, no trailing newline)
    }

    // MARK: - Escaping

    private static func escapedLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
