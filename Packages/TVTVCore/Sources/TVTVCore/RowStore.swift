import DuckDB
import Foundation

/// A single grid cell value.
///
/// The page-fetch query enumerates every column cast `::VARCHAR`
/// (`SELECT "c1"::VARCHAR, "c2"::VARCHAR, … FROM "<view>" … LIMIT … OFFSET
/// …`). DuckDB does the type→string formatting itself, so every cell
/// RowStore ever produces is either a formatted string or SQL NULL — there
/// is no richer typed value to preserve at this layer. Kept intentionally
/// minimal (YAGNI); a richer case can be added later if a real consumer
/// needs one.
public enum Cell: Equatable {
    case null
    case text(String)
}

/// Optional query refinement threaded through to `RowStore`'s count and page
/// SQL. Both fields are pre-built, already-escaped SQL fragments — the
/// caller owns escaping/validation; `RowStore` only concatenates them into
/// the fixed query shape. Empty string means "no clause" for that part.
public struct QuerySpec: Equatable, Sendable {
    /// `""` or a full `" WHERE …"` fragment (leading space included).
    public var whereClause: String
    /// `""` or a full `" ORDER BY …"` fragment (leading space included).
    public var orderBy: String

    public init(whereClause: String = "", orderBy: String = "") {
        self.whereClause = whereClause
        self.orderBy = orderBy
    }
}

/// A DuckDB-backed paging cache for the grid.
///
/// `RowStore` fetches rows from a DuckDB view in fixed-size pages
/// (`pageSize`, 10000) and caches loaded pages in a dictionary keyed by page
/// index. Pages can be loaded in any order — `ensureLoaded(around:)` loads
/// whichever page contains the requested row index, so jump-to-arbitrary-row
/// (including jump-to-end) works without first loading every preceding page.
/// This uses random access rather than a monotonic sequential-append model,
/// so a jump doesn't require loading everything before it.
///
/// `RowStore` holds no pixel/scroll logic: deciding *when* to call
/// `ensureLoaded(around:)` (e.g. a distance-from-bottom prefetch trigger) is
/// the scroll/coordinator layer's responsibility. RowStore is only the
/// loading mechanism.
///
/// Page loads run off the caller's thread and report completion via
/// `onPageLoaded`, which fires on a background queue — callers that need to
/// touch UI state should hop to the main thread themselves.
public final class RowStore: @unchecked Sendable {

    private let connection: Connection
    private let view: String
    private let columnNames: [String]
    private let spec: QuerySpec

    /// When true, the page query also selects DuckDB's implicit `rowid`
    /// pseudocolumn (only valid when `view` is a base TABLE — i.e. the
    /// materialized `data_edit` table used for cell editing) and stores it per
    /// row, so an edit can be applied with `UPDATE … WHERE rowid = <id>` to the
    /// exact source row regardless of the current sort/filter. `false` for
    /// read-only views (parquet/csv/query results), which have no stable
    /// editable rowid.
    private let includesRowID: Bool

    /// Number of rows fetched per page. 10000.
    public let pageSize: Int

    /// `COUNT(*)` of the view, computed once at init.
    public let totalRowCount: Int

    /// Called on completion of an async page load with the half-open row
    /// range `[offset, offset + rowsReturned)` that was just loaded. Fires
    /// off the main thread.
    public var onPageLoaded: ((_ pageRange: Range<Int>) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.tvtv.RowStore.state")
    private var pages: [Int: [[Cell]]] = [:]
    /// Per-page DuckDB `rowid`s, parallel to `pages` (only populated when
    /// `includesRowID` is true).
    private var pageRowIDs: [Int: [Int64?]] = [:]
    private var loadingPages: Set<Int> = []

    /// - Parameters:
    ///   - connection: an open DuckDB connection.
    ///   - view: the name of the view/table to page over (already-quoted
    ///     identifiers are not expected; RowStore quotes it itself).
    ///   - pageSize: rows per page (10000).
    ///   - spec: optional pre-built WHERE/ORDER BY fragments. Defaults to
    ///     `.init()` (no clauses), which keeps the fixed-query behavior.
    public init(connection: Connection, view: String, pageSize: Int, spec: QuerySpec = .init(),
                includesRowID: Bool = false) {
        self.connection = connection
        self.view = view
        self.pageSize = pageSize
        self.spec = spec
        self.includesRowID = includesRowID

        let countSQL = "SELECT COUNT(*) FROM \"\(view)\"\(spec.whereClause)"
        if let countResult = try? connection.query(countSQL),
           let count = countResult[0].cast(to: Int64.self)[0] {
            self.totalRowCount = Int(count)
        } else {
            self.totalRowCount = 0
        }

        let schemaSQL = "SELECT * FROM \"\(view)\" LIMIT 0"
        if let schemaResult = try? connection.query(schemaSQL) {
            self.columnNames = (0..<schemaResult.columnCount).map { schemaResult.columnName(at: $0) }
        } else {
            self.columnNames = []
        }
    }

    /// The cells for row `index`, or `nil` if the page containing it has not
    /// been loaded yet (call `ensureLoaded(around:)` to trigger a load).
    public func row(at index: Int) -> [Cell]? {
        guard index >= 0, index < totalRowCount, pageSize > 0 else { return nil }
        let page = index / pageSize
        let local = index % pageSize
        return stateQueue.sync {
            pages[page]?[local]
        }
    }

    /// The absolute row ranges of all currently-loaded pages, ascending.
    ///
    /// Cell search is deliberately **in-memory over loaded rows only** (never
    /// a SQL scan — see `DataGridCoordinator`'s `matches(inRow:)`/
    /// `recomputeMatches`), so the caller needs to iterate exactly the loaded
    /// rows without walking every index up to `totalRowCount` (which would be
    /// an O(100,000,000) loop on a huge file even though only a handful of
    /// pages are actually loaded). This is cheap: it only touches the loaded
    /// PAGE keys (typically 1-3), not every row.
    public func loadedRowRanges() -> [Range<Int>] {
        stateQueue.sync {
            pages.keys.sorted().map { page in
                let start = page * pageSize
                let end = min(start + (pages[page]?.count ?? 0), totalRowCount)
                return start..<end
            }
        }
    }

    /// Ensures the page containing `index` is loaded, kicking off an async
    /// DuckDB query if it is not already loaded or in flight. This is purely
    /// the loading *mechanism* — deciding when to call it (prefetch
    /// distance, etc.) belongs to the caller.
    public func ensureLoaded(around index: Int) {
        guard index >= 0, index < totalRowCount, pageSize > 0 else { return }
        let page = index / pageSize

        let shouldLoad: Bool = stateQueue.sync {
            if pages[page] != nil || loadingPages.contains(page) {
                return false
            }
            loadingPages.insert(page)
            return true
        }
        guard shouldLoad else { return }

        let offset = page * pageSize
        let limit = pageSize
        var projection = columnNames.map { "\"\($0)\"::VARCHAR" }.joined(separator: ", ")
        // When editing, tack the implicit rowid on as the LAST result column
        // (uncast — kept as BIGINT), so it never appears in the displayed
        // `columnNames`/cells but is available for `UPDATE … WHERE rowid = …`.
        if includesRowID {
            projection += ", rowid"
        }
        let sql = "SELECT \(projection) FROM \"\(view)\"\(spec.whereClause)\(spec.orderBy) LIMIT \(limit) OFFSET \(offset)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let result = try? self.connection.query(sql) else {
                self.stateQueue.sync { _ = self.loadingPages.remove(page) }
                return
            }

            let rowCount = Int(result.rowCount)
            let cellColumnCount = self.includesRowID ? Int(result.columnCount) - 1 : Int(result.columnCount)
            let stringColumns = (0..<cellColumnCount).map { result[DBInt($0)].cast(to: String.self) }
            let rowIDColumn = self.includesRowID ? result[DBInt(cellColumnCount)].cast(to: Int64.self) : nil

            var rows = [[Cell]]()
            rows.reserveCapacity(rowCount)
            var rowIDs = [Int64?]()
            rowIDs.reserveCapacity(rowCount)
            for r in 0..<DBInt(rowCount) {
                let cells: [Cell] = stringColumns.map { column in
                    if let value = column[r] {
                        return .text(value)
                    } else {
                        return .null
                    }
                }
                rows.append(cells)
                rowIDs.append(rowIDColumn?[r] ?? nil)
            }

            let range = offset..<(offset + rowCount)
            self.stateQueue.sync {
                self.pages[page] = rows
                if self.includesRowID { self.pageRowIDs[page] = rowIDs }
                self.loadingPages.remove(page)
            }
            self.onPageLoaded?(range)
        }
    }

    /// The view's column names, in SOURCE order (the order `row(at:)` cells
    /// are indexed in).
    public var columns: [String] { columnNames }

    /// The cells for every in-range index in `indexes`, ascending, fetched
    /// SYNCHRONOUSLY — rows on already-loaded pages come from the cache, the
    /// rest are queried directly (one `LIMIT/OFFSET` per contiguous run,
    /// honoring the store's WHERE/ORDER BY) without being cached. Used by
    /// copy, where a selection can span pages the grid never loaded.
    /// Out-of-range indexes are skipped; a failed query drops its run.
    public func rows(at indexes: IndexSet) -> [[Cell]] {
        guard pageSize > 0, totalRowCount > 0 else { return [] }
        let clamped = indexes.intersection(IndexSet(integersIn: 0..<totalRowCount))
        var result: [[Cell]] = []
        result.reserveCapacity(clamped.count)
        for run in clamped.rangeView {
            // Split each run at page boundaries so cached pages are reused.
            var start = run.lowerBound
            while start < run.upperBound {
                let page = start / pageSize
                let end = min(run.upperBound, (page + 1) * pageSize)
                let cached: [[Cell]]? = stateQueue.sync {
                    guard let rows = pages[page] else { return nil }
                    let lo = start - page * pageSize, hi = end - page * pageSize
                    return hi <= rows.count ? Array(rows[lo..<hi]) : nil
                }
                result += cached ?? fetchUncached(offset: start, limit: end - start)
                start = end
            }
        }
        return result
    }

    private func fetchUncached(offset: Int, limit: Int) -> [[Cell]] {
        let projection = columnNames.map { "\"\($0)\"::VARCHAR" }.joined(separator: ", ")
        let sql = "SELECT \(projection) FROM \"\(view)\"\(spec.whereClause)\(spec.orderBy) LIMIT \(limit) OFFSET \(offset)"
        guard let result = try? connection.query(sql) else { return [] }
        let columns = (0..<Int(result.columnCount)).map { result[DBInt($0)].cast(to: String.self) }
        return (0..<DBInt(result.rowCount)).map { r in
            columns.map { column in column[r].map(Cell.text) ?? .null }
        }
    }

    /// The DuckDB `rowid` for display row `index`, or `nil` if that page isn't
    /// loaded or this store isn't tracking rowids. Used by the editor to target
    /// the exact source row for an `UPDATE`.
    public func rowID(at index: Int) -> Int64? {
        guard includesRowID, index >= 0, index < totalRowCount, pageSize > 0 else { return nil }
        let page = index / pageSize
        let local = index % pageSize
        return stateQueue.sync {
            guard let ids = pageRowIDs[page], local < ids.count else { return nil }
            return ids[local]
        }
    }

    /// Drops the cached page containing `index` so the next `ensureLoaded`
    /// re-fetches it — used after an edit so the changed cell re-renders.
    public func invalidatePage(containing index: Int) {
        guard pageSize > 0 else { return }
        let page = index / pageSize
        stateQueue.sync {
            pages[page] = nil
            pageRowIDs[page] = nil
            loadingPages.remove(page)
        }
    }
}
