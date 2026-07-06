import DuckDB
import Foundation
import TVTVCore

/// App-side file-open flow: turns a file URL into a queryable DuckDB view named
/// `data` and the `[ColumnInfo]` the `DataGridCoordinator` needs.
///
/// The SQL templates used for each supported format:
///
/// - parquet → `CREATE VIEW data AS SELECT * FROM read_parquet('<path>')`
/// - csv/tsv → `CREATE VIEW data AS SELECT * FROM read_csv('<path>', auto_detect=true)`
/// - .duckdb/.db → `ATTACH '<path>' AS <alias> (READ_ONLY)`, then expose the
///   first user table as `data`.
///
/// `DROP VIEW IF EXISTS data` precedes each `CREATE VIEW` so a second open on the
/// shared connection replaces the previous view (`CREATE VIEW` alone would fail
/// on re-open; the drop keeps it usable across repeated opens).
///
/// Vortex (`.vtx`/`.vortex`) is transcoded to a temporary Parquet via the Rust
/// reader (`VortexReader`) — DuckDB can't read Vortex natively — then paged
/// like any other Parquet.
enum DataSource {

    /// The result of opening a file: the view name to page over, its columns,
    /// and a friendly alias view named after the file (so the SQL editor can
    /// reference the current table by its file name, e.g. `SELECT * FROM
    /// clinical_like`, in addition to the fixed `data`). `nil` if the file's
    /// name sanitizes to `data` itself.
    struct Opened {
        let viewName: String
        let columns: [ColumnInfo]
        let tableAlias: String?
    }

    enum OpenError: LocalizedError {
        case unsupportedExtension(String)
        case noTablesInDatabase
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedExtension(let ext):
                return "Unsupported file type: .\(ext)"
            case .noTablesInDatabase:
                return "The database contains no tables to display."
            case .underlying(let message):
                return message
            }
        }
    }

    /// The fixed view name the app pages over.
    static let viewName = "data"

    /// Catalog alias used for `.duckdb`/`.db` files ATTACHed onto the shared
    /// connection. Named here (rather than only locally in
    /// `attachDatabaseAsDataView`) so `open` can detach a stale attachment
    /// before handling ANY new file, not just another `.duckdb`/`.db`.
    private static let attachedDBAlias = "attached_db"

    /// Open `url` on `connection`, creating/replacing the `data` view and
    /// returning its columns. Runs synchronously (the SQL is DDL + a schema
    /// probe; the row pages load lazily via `RowStore`).
    static func open(url: URL, connection: Connection) throws -> Opened {
        let ext = url.pathExtension.lowercased()
        let path = escapedLiteral(url.path)

        // Detach any database attached by a previous `.duckdb`/`.db` open,
        // regardless of what this file turns out to be — otherwise opening a
        // `.duckdb` and then a `.parquet`/`.csv` leaves the old attachment
        // lingering on the shared connection even though `data` no longer
        // references it. Best-effort: a no-op if nothing is attached.
        try? connection.execute("DETACH \(quotedIdentifier(attachedDBAlias))")

        switch ext {
        case "parquet":
            try createDataView(from: "read_parquet('\(path)')", connection: connection)
        case "csv", "tsv":
            try createDataView(from: "read_csv('\(path)', auto_detect=true)", connection: connection)
        case "duckdb", "db":
            try attachDatabaseAsDataView(path: path, connection: connection)
        case "vtx", "vortex":
            // DuckDB can't read Vortex natively, so transcode to a temporary
            // Parquet (via the Rust reader) and page over that — real types,
            // full paging. The temp file lives in the OS temp dir.
            let parquet = try VortexReader.convertToParquet(url)
            try createDataView(from: "read_parquet('\(escapedLiteral(parquet.path))')", connection: connection)
        default:
            throw OpenError.unsupportedExtension(ext)
        }

        let columns = try columnInfos(forView: viewName, connection: connection)

        // Friendly alias view named after the file, so the SQL editor can say
        // `SELECT * FROM clinical_like` as well as `FROM data`. Skip if the
        // name sanitizes to `data` itself.
        let alias = sanitizedViewName(url.deletingPathExtension().lastPathComponent)
        var tableAlias: String? = nil
        if alias != viewName {
            try? connection.execute(
                "CREATE OR REPLACE VIEW \(quotedIdentifier(alias)) AS SELECT * FROM \(quotedIdentifier(viewName))")
            tableAlias = alias
        }
        return Opened(viewName: viewName, columns: columns, tableAlias: tableAlias)
    }

    /// Attach `url` as an ADDITIONAL named view (distinct from the main `data`
    /// view), so it can be referenced — e.g. joined — from the SQL editor.
    /// Returns the created view name (the file's base name, sanitized to a
    /// valid identifier). Parquet/CSV/TSV only.
    static func attach(url: URL, connection: Connection) throws -> String {
        let ext = url.pathExtension.lowercased()
        let path = escapedLiteral(url.path)
        let source: String
        switch ext {
        case "parquet": source = "read_parquet('\(path)')"
        case "csv", "tsv": source = "read_csv('\(path)', auto_detect=true)"
        default: throw OpenError.unsupportedExtension(ext)
        }
        let name = sanitizedViewName(url.deletingPathExtension().lastPathComponent)
        do {
            try connection.execute(
                "CREATE OR REPLACE VIEW \(quotedIdentifier(name)) AS SELECT * FROM \(source)")
        } catch {
            throw OpenError.underlying("Could not attach file: \(error)")
        }
        return name
    }

    /// Turn a file base-name into a safe SQL identifier (letters/digits/`_`,
    /// leading letter), avoiding a clash with the primary `data` view.
    private static func sanitizedViewName(_ base: String) -> String {
        var s = String(base.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if s.isEmpty || !(s.first?.isLetter ?? false) { s = "t_" + s }
        if s == viewName { s = "t_" + s }
        return s
    }

    // MARK: - View creation

    private static func createDataView(from source: String, connection: Connection) throws {
        do {
            try connection.execute("DROP VIEW IF EXISTS \(quotedIdentifier(viewName))")
            try connection.execute(
                "CREATE VIEW \(quotedIdentifier(viewName)) AS SELECT * FROM \(source)")
        } catch {
            throw OpenError.underlying("Could not open file: \(error)")
        }
    }

    /// ATTACH the database read-only, then point `data` at its first user table.
    ///
    /// The stale-attachment detach itself now happens once, up front, in
    /// `open(url:connection:)` (so it also runs on a `.duckdb` → `.parquet`/
    /// `.csv` switch) — this only attaches the new file.
    private static func attachDatabaseAsDataView(path: String, connection: Connection) throws {
        do {
            try connection.execute("ATTACH '\(path)' AS \(quotedIdentifier(attachedDBAlias)) (READ_ONLY)")
        } catch {
            throw OpenError.underlying("Could not attach database: \(error)")
        }

        guard let table = try firstTableName(inCatalog: attachedDBAlias, connection: connection) else {
            throw OpenError.noTablesInDatabase
        }

        do {
            try connection.execute("DROP VIEW IF EXISTS \(quotedIdentifier(viewName))")
            try connection.execute(
                "CREATE VIEW \(quotedIdentifier(viewName)) AS SELECT * FROM "
                + "\(quotedIdentifier(attachedDBAlias)).\(quotedIdentifier(table))")
        } catch {
            throw OpenError.underlying("Could not open table \"\(table)\": \(error)")
        }
    }

    private static func firstTableName(inCatalog catalog: String, connection: Connection) throws -> String? {
        let sql = "SELECT table_name FROM information_schema.tables "
            + "WHERE table_catalog = '\(escapedLiteral(catalog))' "
            + "ORDER BY table_name LIMIT 1"
        guard let result = try? connection.query(sql), result.rowCount > 0 else { return nil }
        return result[0].cast(to: String.self)[0]
    }

    // MARK: - Schema → ColumnInfo

    private static func columnInfos(forView view: String, connection: Connection) throws -> [ColumnInfo] {
        let sql = "SELECT * FROM \(quotedIdentifier(view)) LIMIT 0"
        guard let result = try? connection.query(sql) else {
            throw OpenError.underlying("Could not read schema for view \"\(view)\".")
        }
        return (0..<Int(result.columnCount)).map { index in
            ColumnInfo(
                name: result.columnName(at: DBInt(index)),
                sourceIndex: index,
                type: ColumnInfo.sqlTypeName(for: result[DBInt(index)].underlyingDatabaseType)
            )
        }
    }

    // MARK: - Escaping

    /// Escape a value destined for a single-quoted SQL string literal.
    private static func escapedLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// Quote a SQL identifier (double-quote, doubling any embedded quotes).
    private static func quotedIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
