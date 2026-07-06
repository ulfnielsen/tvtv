import DuckDB
import Foundation

/// A lightweight, read-only preview of a data file's first rows — used by the
/// QuickLook extension (and available to anything else that wants a quick
/// look without standing up the full grid engine). Reads parquet/csv/tsv/
/// duckdb via a throwaway in-memory DuckDB connection, mirroring the grid's
/// own `"col"::VARCHAR` projection so the formatting matches the main app.
///
/// Vortex (`.vtx`/`.vortex`) is handled separately by `VortexReader` (the
/// Rust FFI), since DuckDB cannot read Vortex natively.
public struct FilePreview: Sendable {
    public struct Column: Sendable {
        public let name: String
        public let type: String
        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    /// Column headers (name + DuckDB type name).
    public let columns: [Column]
    /// Row values as display strings; SQL NULL is represented as `nil`.
    public let rows: [[String?]]
    /// Total rows in the file (may exceed `rows.count`).
    public let totalRowCount: Int
    /// True when `rows` is a truncated prefix of the file (`totalRowCount >
    /// rows.count`).
    public let truncated: Bool

    public enum PreviewError: LocalizedError {
        case unsupportedExtension(String)
        case noTablesInDatabase
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedExtension(let ext): return "Unsupported file type: .\(ext)"
            case .noTablesInDatabase: return "The database contains no tables to preview."
            case .underlying(let message): return message
            }
        }
    }

    /// Open `url` and materialize up to `rowCap` rows for preview.
    public static func load(url: URL, rowCap: Int = 200) throws -> FilePreview {
        let database: Database
        let connection: Connection
        do {
            database = try Database(store: .inMemory)
            connection = try database.connect()
        } catch {
            throw PreviewError.underlying("Could not open DuckDB: \(error)")
        }

        let ext = url.pathExtension.lowercased()
        let path = url.path.replacingOccurrences(of: "'", with: "''")
        do {
            switch ext {
            case "parquet":
                try connection.execute("CREATE VIEW data AS SELECT * FROM read_parquet('\(path)')")
            case "csv", "tsv":
                try connection.execute("CREATE VIEW data AS SELECT * FROM read_csv('\(path)', auto_detect=true)")
            case "duckdb", "db":
                try connection.execute("ATTACH '\(path)' AS src (READ_ONLY)")
                let tables = try connection.query(
                    "SELECT table_name FROM information_schema.tables "
                    + "WHERE table_catalog = 'src' ORDER BY table_name LIMIT 1")
                guard tables.rowCount > 0,
                      let table = tables[0].cast(to: String.self)[0] else {
                    throw PreviewError.noTablesInDatabase
                }
                let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
                try connection.execute("CREATE VIEW data AS SELECT * FROM src.\"\(quoted)\"")
            default:
                throw PreviewError.unsupportedExtension(ext)
            }
        } catch let error as PreviewError {
            throw error
        } catch {
            throw PreviewError.underlying("Could not read file: \(error)")
        }

        // Column names + types from a zero-row probe.
        guard let schema = try? connection.query("SELECT * FROM data LIMIT 0") else {
            throw PreviewError.underlying("Could not read schema.")
        }
        let columns: [Column] = (0..<Int(schema.columnCount)).map { index in
            Column(
                name: schema.columnName(at: DBInt(index)),
                type: ColumnInfo.sqlTypeName(for: schema[DBInt(index)].underlyingDatabaseType))
        }

        let totalRowCount: Int
        if let countResult = try? connection.query("SELECT count(*) FROM data"),
           let value = countResult[0].cast(to: Int64.self)[0] {
            totalRowCount = Int(value)
        } else {
            totalRowCount = 0
        }

        // Rows: same `"col"::VARCHAR` projection the grid pages use, so the
        // preview's formatting matches the main app.
        let projection = columns.map { "\"\($0.name.replacingOccurrences(of: "\"", with: "\"\""))\"::VARCHAR" }
            .joined(separator: ", ")
        var rows: [[String?]] = []
        if !columns.isEmpty,
           let result = try? connection.query("SELECT \(projection) FROM data LIMIT \(max(0, rowCap))") {
            let stringColumns = (0..<result.columnCount).map { result[$0].cast(to: String.self) }
            let rowCount = Int(result.rowCount)
            rows.reserveCapacity(rowCount)
            for r in 0..<DBInt(rowCount) {
                rows.append(stringColumns.map { $0[r] })
            }
        }

        return FilePreview(
            columns: columns,
            rows: rows,
            totalRowCount: totalRowCount,
            truncated: totalRowCount > rows.count)
    }
}
