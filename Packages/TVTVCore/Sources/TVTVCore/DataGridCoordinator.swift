import AppKit
import DuckDB
import Foundation
import Observation
import SwiftUI

/// Minimal description of a grid column: its display name, its stable SOURCE
/// index (identity in `ColumnLayout`'s width/`setWidth` space), and its SQL
/// type (e.g. "VARCHAR", "BIGINT") -- shown in the header as "NAME (TYPE)".
///
/// `type` defaults to `""` (both existing call sites and every pre-existing
/// test construct `ColumnInfo` without it) so this stays source-compatible;
/// only the two schema probes (`DataGridCoordinator.columnInfos(forView:)`
/// and `TVTVApp/DataSource.columnInfos(forView:connection:)`) populate it for
/// real, from the duckdb-swift result's `underlyingDatabaseType`.
public struct ColumnInfo: Equatable, Sendable {
    public let name: String
    public let sourceIndex: Int
    public let type: String

    public init(name: String, sourceIndex: Int, type: String = "") {
        self.name = name
        self.sourceIndex = sourceIndex
        self.type = type
    }

    /// Maps a duckdb-swift `DatabaseType` to the uppercase SQL-ish name shown
    /// in the header (e.g. `.varchar` -> "VARCHAR", `.bigint` -> "BIGINT").
    /// Covers every case declared in `DatabaseType` as of this duckdb-swift
    /// checkout; anything else (a future DuckDB type this hasn't been
    /// updated for, or `.invalid`) falls back to `DatabaseType`'s own
    /// `CustomStringConvertible` description (`"DatabaseType.xyz"`), stripped
    /// of its type-name prefix and uppercased, so an unrecognized type still
    /// surfaces a readable label instead of silently becoming `""`.
    public static func sqlTypeName(for type: DatabaseType) -> String {
        switch type {
        case .boolean: return "BOOLEAN"
        case .tinyint: return "TINYINT"
        case .smallint: return "SMALLINT"
        case .integer: return "INTEGER"
        case .bigint: return "BIGINT"
        case .hugeint: return "HUGEINT"
        case .uhugeint: return "UHUGEINT"
        case .utinyint: return "UTINYINT"
        case .usmallint: return "USMALLINT"
        case .uinteger: return "UINTEGER"
        case .ubigint: return "UBIGINT"
        case .float: return "FLOAT"
        case .double: return "DOUBLE"
        case .timestamp: return "TIMESTAMP"
        case .timestampTz: return "TIMESTAMP WITH TIME ZONE"
        case .date: return "DATE"
        case .time: return "TIME"
        case .timeTz: return "TIME WITH TIME ZONE"
        case .interval: return "INTERVAL"
        case .varchar: return "VARCHAR"
        case .blob: return "BLOB"
        case .decimal: return "DECIMAL"
        case .timestampS: return "TIMESTAMP_S"
        case .timestampMS: return "TIMESTAMP_MS"
        case .timestampNS: return "TIMESTAMP_NS"
        case .enum: return "ENUM"
        case .list: return "LIST"
        case .struct: return "STRUCT"
        case .map: return "MAP"
        case .union: return "UNION"
        case .uuid: return "UUID"
        default:
            let description = type.description
            if let dotIndex = description.lastIndex(of: ".") {
                return String(description[description.index(after: dotIndex)...]).uppercased()
            }
            return description.uppercased()
        }
    }
}

// MARK: - Scheduler seam (injected clock)

/// A one-shot main-thread scheduler, injected so the coordinator's two timed
/// behaviors — the 0.5 s prefetch re-arm and the 0.1 s visible-rows debounce —
/// can be driven deterministically in tests instead of by real `asyncAfter`.
@MainActor
public protocol GridScheduler: AnyObject {
    /// Schedule `work` to run on the main actor after `seconds`. The returned
    /// token cancels the pending work (used to implement cancel-and-reschedule
    /// debouncing).
    @discardableResult
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> GridSchedulerToken
}

/// A handle to scheduled work; `cancel()` prevents it from running if it has
/// not fired yet.
@MainActor
public protocol GridSchedulerToken: AnyObject {
    func cancel()
}

/// Production `GridScheduler`: `DispatchQueue.main.asyncAfter`.
public final class MainQueueScheduler: GridScheduler {
    public init() {}

    public func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> GridSchedulerToken {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return WorkItemToken(item)
    }
}

private final class WorkItemToken: GridSchedulerToken {
    private let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

// MARK: - DataGridCoordinator

/// The grid engine's orchestration hub.
///
/// `DataGridCoordinator` owns a `RowStore` + `ColumnLayout` + `GridGeometry`
/// and drives a live `GridTableView` / `GridTableHeaderView`. It is the piece
/// the SwiftUI wrapper embeds; it turns a file/table selection (`switchTo`)
/// into a rebuilt, wired-up grid, and drives the two scroll-time behaviors
/// this type owns: pixel-based bottom prefetch and the debounced visible-row
/// publish.
///
/// ## `@Observable`, main-actor
///
/// Uses the Observation framework (`@Observable`), NOT
/// `ObservableObject`/`@Published`. The whole type is `@MainActor`: it drives
/// AppKit views and publishes `@Observable` state the UI reads, so all
/// mutation belongs on the main actor. The one cross-actor edge is
/// `RowStore.onPageLoaded`, which fires on a background queue — the
/// coordinator's slot closure hops back to the main actor before touching
/// any state (see `switchTo`).
///
/// ## Prefetch lives HERE, and it is pixel-based
///
/// `RowStore` deliberately has no prefetch. The coordinator triggers loading
/// the next page when the viewport bottom comes within
/// `bottomLoadThreshold` (500 pt) of the content bottom, guarded by
/// `hasTriggeredBottomLoad` and re-armed `bottomLoadRearm` (0.5 s) later. The
/// distance is computed in points; because rows have a fixed pitch, it is
/// derived here from the visible last row and `GridGeometry` (rows map to
/// pixels via a fixed row pitch), so no pixel-scroll callback has to be
/// plumbed out of `GridTableView`.
///
/// ## Generation-safe stale-load cancellation
///
/// Every file/table switch bumps `switchGeneration` and cancels/replaces
/// `activeSwitchTask`. Each `RowStore` is built for one generation; its
/// `onPageLoaded` closure captures THAT generation. When a load resolves, its
/// captured generation is compared against the current one — a load from a
/// superseded view (old generation) is discarded and never mutates state
/// (`applyPageLoaded`). This ensures that after a switch, an in-flight load
/// from the old view can never touch the new view's state.
///
/// ## `onPageLoaded` ownership (single-slot handoff)
///
/// `RowStore.onPageLoaded` is a SINGLE closure slot. `GridTableView` claims it
/// in its own init to redraw just-loaded rows — but so must the coordinator, to
/// do its bookkeeping (`dataVersion`). Rather than let both fight over the one
/// slot, the coordinator RE-CLAIMS the slot after building the grid and becomes
/// the sole owner: its handler does the background→main hop, the generation
/// check, its own bookkeeping, AND forwards the redraw to the grid via
/// `GridTableView.reloadVisible()`. One owner, multicast to both consumers.
@MainActor
@Observable
public final class DataGridCoordinator {

    // MARK: Tunable constants

    /// Prefetch trigger distance: fire the next-page load when the viewport
    /// bottom is within this many points of the content bottom.
    public static let bottomLoadThreshold: CGFloat = 500

    /// Delay before `hasTriggeredBottomLoad` is re-armed (reset to false).
    public static let bottomLoadRearm: TimeInterval = 0.5

    /// Trailing-edge debounce before a visible-row-range change is published to
    /// observers.
    public static let visibleRowsDebounce: TimeInterval = 0.1

    /// Rows fetched per page.
    public static let pageSize = 10_000

    /// The fixed view name `runQuery` creates/switches the grid to: always a
    /// view literally named `query_result`.
    public static let queryResultView = "query_result"

    // MARK: Dependencies

    private let connection: Connection
    private let scheduler: GridScheduler
    private let geometry: GridGeometry

    // MARK: Observable state

    /// Incremented on every applied page load (a load whose generation matches
    /// the current one). Observers redraw off this.
    public private(set) var dataVersion: Int = 0

    /// First visible row index, published (debounced 0.1 s) from the grid's
    /// `onVisibleRowsChanged`.
    public private(set) var visibleFirstRow: Int = 0

    /// Last visible row index, published (debounced 0.1 s) from the grid's
    /// `onVisibleRowsChanged`.
    public private(set) var visibleLastRow: Int = 0

    /// Total row count of the current view (0 before the first `switchTo`).
    public var totalRowCount: Int { rowStore?.totalRowCount ?? 0 }

    /// Row count of the current view BEFORE the quick-filter WHERE — so the
    /// status bar can show "N of M rows" while a filter is active. Captured
    /// whenever a store is built without a WHERE clause (every `switchTo`
    /// starts that way).
    public private(set) var unfilteredRowCount: Int = 0

    /// Number of rows selected in the grid (0 after every rebuild — a new
    /// sort/filter/view means new row indices, so the selection is dropped).
    public private(set) var selectedRowCount: Int = 0

    // MARK: Generation protocol state

    /// Monotonic counter bumped on every `switchTo`. A load's captured value is
    /// compared against this to detect (and discard) stale loads.
    public private(set) var switchGeneration: Int = 0

    /// The in-flight switch task, cancelled/replaced on the next switch. The
    /// current synchronous `switchTo` builds the store inline, so this is
    /// normally `nil` (a future change moving store construction onto a task
    /// would make cancelling it here matter).
    private var activeSwitchTask: Task<Void, Never>?

    // MARK: Prefetch state

    /// Guards the bottom prefetch: set true when a near-bottom load fires,
    /// re-armed to false `bottomLoadRearm` later. Internal for testability.
    private(set) var hasTriggeredBottomLoad = false

    // MARK: Owned grid pieces

    private var rowStore: RowStore?
    private var columnLayout: ColumnLayout?

    /// The view/table name and column set of the current switch, retained so
    /// a sort change (`toggleSort`) can rebuild the `RowStore` for the SAME
    /// view/columns without the caller re-supplying them.
    private var currentView: String?
    private var currentColumns: [ColumnInfo] = []

    /// True when the grid is currently showing `runQuery`'s `query_result`
    /// view rather than the caller's opened file. Derived from `switchTo`'s
    /// `view` argument rather than tracked separately, since `query_result`
    /// is exactly the view `runQuery` switches to — one source of truth, no
    /// way for the two to drift apart.
    public private(set) var isQueryResult: Bool = false

    // MARK: Cell editing

    /// Name of the materialized, mutable table the grid pages over while
    /// editing. Created lazily by `beginEditing()` from the opened file's view.
    public static let editView = "data_edit"

    /// True once the grid has been switched to the mutable `editView` (cells
    /// are editable). Also drives `RowStore(includesRowID:)` in `rebuildStore`.
    public private(set) var isEditing: Bool = false

    /// True when there are edits not yet written back to a file.
    public private(set) var isDirty: Bool = false

    /// The file view (`data`) `editView` was materialized from — retained for
    /// diagnostics / a future "revert to file".
    private var editSourceView: String?

    /// Undo history of applied edits: (rowid, source column index, prior cell).
    private var editUndoStack: [(rowID: Int64, sourceIndex: Int, old: Cell)] = []

    // MARK: Sort state

    /// The active sort, single-column (0 or 1 elements — see `SortDescriptor`
    /// doc for why this is still an array). Empty means unsorted.
    public private(set) var sortDescriptors: [SortDescriptor] = []

    // MARK: Filter state

    /// Sentinel string representing SQL NULL inside a column's exclusion
    /// set. `excludedValues[name]` is a set of "real" VARCHAR-cast values
    /// (as returned by `fetchDistinctValues`, which itself never returns
    /// NULL) optionally UNIONed with this sentinel — the pseudo-value the
    /// filter popover's "(null)" row toggles. `buildWhereClause` splits a
    /// column's set back into "real values" vs. "this sentinel" to choose
    /// among the three branches described in its own doc.
    ///
    /// Simplifying assumption (documented): a data column whose actual
    /// VARCHAR-cast value is literally the string `"(null)"` would be
    /// indistinguishable from an excluded NULL. Accepted as out of scope for
    /// this milestone.
    public static let nullSentinel = "(null)"

    /// Per-column excluded values (column name → excluded string values,
    /// optionally including `nullSentinel`). Empty means "no filter" for
    /// that column; a column with an empty set is never stored (see
    /// `setExcluded`).
    public private(set) var excludedValues: [String: Set<String>] = [:]

    /// Cache of `fetchDistinctValues` results, keyed by column name.
    /// Cleared on `switchTo` (new view ⇒ stale values); NOT invalidated by
    /// `setExcluded`, since `fetchDistinctValues`'s query only conditions on
    /// that column's own `IS NOT NULL` (see that method's doc for why it
    /// deliberately ignores other columns' current WHERE).
    private var distinctValueCache: [String: [String]] = [:]

    // MARK: Search state

    /// Cell search term, set by the toolbar search field. Setting this
    /// recomputes `searchTermLower` and re-scans currently LOADED rows for
    /// matches (`recomputeMatches`) — **never a SQL scan**: matching tests
    /// `values[i].lowercased().contains(searchTermLower)` directly against
    /// in-memory cell values, and this mirrors that at the coordinator level
    /// for `matchingColumnIndices`/`currentMatch`/next-prev navigation.
    public var searchTerm: String = "" {
        didSet {
            guard searchTerm != oldValue else { return }
            searchTermLower = searchTerm.lowercased()
            recomputeMatches()
            recomputeColumnNameMatches()
        }
    }

    /// `searchTerm.lowercased()`, recomputed by `searchTerm`'s setter.
    public private(set) var searchTermLower: String = ""

    /// The set of SOURCE column indices (`ColumnLayout.sourceIndex` space —
    /// the same order `RowStore.row(at:)` returns cells in, NOT display
    /// order) containing at least one match in any currently-loaded row.
    /// Empty when `searchTermLower` is empty or nothing loaded matches.
    public private(set) var matchingColumnIndices: Set<Int> = []

    /// The set of SOURCE column indices whose COLUMN NAME (case-
    /// insensitively) contains `searchTermLower` — e.g. typing "SEQ" matches
    /// an `EGSEQ` column even when no loaded CELL value contains "SEQ" (so
    /// `matchingColumnIndices` above would be empty). This is deliberately a
    /// SEPARATE affordance from cell-value search, not folded into the "N of
    /// M" count/next-prev sequence: it exists purely to make a column the
    /// user is clearly looking for discoverable — see `recomputeColumnNameMatches`'s
    /// doc for the full rationale and what it triggers (header highlight +
    /// scroll-to-column). Empty when `searchTermLower` is empty or no
    /// column name matches.
    public private(set) var matchingColumnNameIndices: Set<Int> = []

    /// The currently-focused search match, or `nil` if there are none.
    /// `row` is an ABSOLUTE row index (`RowStore.row(at:)` space); `col` is a
    /// SOURCE column index (same space as `matchingColumnIndices`).
    ///
    /// A plain tuple (`currentMatch: (row: Int, col: Int)?`) rather than a
    /// dedicated struct — the YAGNI-simplest thing satisfying the observable
    /// contract for this milestone.
    public private(set) var currentMatch: (row: Int, col: Int)?

    /// Ordered list of every match across currently-loaded rows, sorted by
    /// (row, col) ascending — the sequence `nextMatch()`/`previousMatch()`
    /// cycle through. Rebuilt by `recomputeMatches()`.
    private var matchList: [(row: Int, col: Int)] = []

    /// The live data grid. Built on `switchTo`; embedded by the SwiftUI
    /// wrapper. `nil` until the first switch (and in headless/logic-only
    /// tests).
    public private(set) var gridView: GridTableView?

    /// The live header. Built alongside `gridView`.
    public private(set) var headerView: GridTableHeaderView?

    /// Pending visible-rows debounce work (cancel-and-reschedule).
    private var visibleRowsToken: GridSchedulerToken?

    /// The currently-shown quick-filter popover, if any. Held so a
    /// second filter request replaces rather than leaks the previous one;
    /// `NSPopover` itself also auto-closes (`.transient`) on an outside click.
    private var activeFilterPopover: NSPopover?

    // MARK: Init

    public convenience init(connection: Connection) {
        self.init(connection: connection, scheduler: MainQueueScheduler())
    }

    /// Designated init with an injectable scheduler (tests pass a manual one to
    /// drive the re-arm/debounce deterministically).
    init(connection: Connection,
         scheduler: GridScheduler,
         geometry: GridGeometry = GridGeometry()) {
        self.connection = connection
        self.scheduler = scheduler
        self.geometry = geometry
    }

    // MARK: Switching views

    /// Switch to a different view/table: bumps `switchGeneration`, cancels any
    /// in-flight switch task, and rebuilds the `RowStore` / `ColumnLayout` /
    /// grid for the new view. Any page load still in flight from the previous
    /// view carries the old generation and is discarded when it resolves.
    public func switchTo(view: String, columns: [ColumnInfo]) {
        currentView = view
        currentColumns = columns
        isQueryResult = (view == Self.queryResultView)
        // Editing is active only while showing the mutable editView. Switching
        // to any other view (opening a file, running a query) exits edit mode
        // and drops the dirty/undo state.
        isEditing = (view == Self.editView)
        if !isEditing {
            isDirty = false
            editUndoStack = []
        }
        sortDescriptors = []
        excludedValues = [:]
        distinctValueCache = [:]

        // A true VIEW SWITCH — unlike `toggleSort`/`setExcluded`, which
        // intentionally preserve an active search across a sort/filter
        // change on the SAME view — must clear the search term. Without
        // this, opening a new file / running a SQL query / returning to
        // file would leave the OLD view's `searchTerm` in place;
        // `rebuildStore`'s `recomputeMatches()` (via `applyPageLoaded`)
        // would then recompute matches against the NEW view's rows,
        // showing a stale "N of M" and highlights for a term the user
        // never typed against this view (and against a possibly
        // completely different schema).
        //
        // Setting `searchTerm = ""` normally routes through its own
        // `didSet` (clearing `searchTermLower` and calling
        // `recomputeMatches()`), but that `didSet` is a no-op when
        // `searchTerm` is ALREADY "" (`guard searchTerm != oldValue`). That
        // is fine here: when there was no active search, `searchTermLower`/
        // `matchList`/`matchingColumnIndices`/`currentMatch` are already at
        // their cleared rest state, and `rebuildStore` below unconditionally
        // resets `matchList`/`matchingColumnIndices`/`currentMatch` again
        // regardless. So the end state after `switchTo` is guaranteed empty
        // either way — via the `didSet` when a search was active, or
        // because nothing needed clearing when it wasn't.
        searchTerm = ""

        // A real view switch gets a fresh layout (the new column set may
        // differ entirely) and a fresh header built against it —
        // `rebuildStore` reuses `headerView` when non-nil (the sort-change
        // path), so clear it here to force that fresh build.
        columnLayout = ColumnLayout(columnNames: columns.map(\.name))
        headerView = nil

        rebuildStore(spec: QuerySpec())
    }

    // MARK: Cell editing

    /// Enter edit mode: materialize the current file view into the mutable
    /// `editView` table and switch the grid to it (so cells carry a stable
    /// `rowid`). No-op if already editing, if there's no file view, or if the
    /// grid is showing a SQL query result (nothing to write back to). Returns
    /// whether the grid is now editable.
    @discardableResult
    public func beginEditing() -> Bool {
        if isEditing { return true }
        guard let source = currentView, source != Self.editView, !isQueryResult else { return false }
        do {
            try connection.execute(
                "CREATE OR REPLACE TABLE \"\(Self.editView)\" AS SELECT * FROM \"\(source)\"")
        } catch {
            return false
        }
        editSourceView = source
        isEditing = true
        isDirty = false
        editUndoStack = []
        // Rebuilds the store with includesRowID == true (isEditing is set).
        switchTo(view: Self.editView, columns: currentColumns)
        return true
    }

    /// Apply an edit to the cell at display `row` / `sourceColumnIndex`,
    /// writing `newValue` back to the `editView` table (by rowid, so sort/
    /// filter don't matter). Returns false if not editable or the write failed
    /// (e.g. a value that can't cast to the column's type) — the caller should
    /// then keep the old value on screen.
    @discardableResult
    public func applyEdit(row: Int, sourceColumnIndex: Int, newValue: Cell) -> Bool {
        guard isEditing, let store = rowStore, let rowID = store.rowID(at: row),
              let column = currentColumns.first(where: { $0.sourceIndex == sourceColumnIndex })
        else { return false }

        let old = store.row(at: row).flatMap { cells in
            sourceColumnIndex < cells.count ? cells[sourceColumnIndex] : nil
        } ?? .null

        guard writeCell(rowID: rowID, columnName: column.name, value: newValue) else { return false }

        editUndoStack.append((rowID, sourceColumnIndex, old))
        isDirty = true
        store.invalidatePage(containing: row)
        store.ensureLoaded(around: row)
        return true
    }

    /// Undo the most recent edit (⌘Z). Re-applies the prior value by rowid and
    /// reloads the visible rows so the change shows.
    public func undoEdit() {
        guard isEditing, let store = rowStore, let last = editUndoStack.popLast(),
              let column = currentColumns.first(where: { $0.sourceIndex == last.sourceIndex })
        else { return }
        _ = writeCell(rowID: last.rowID, columnName: column.name, value: last.old)
        isDirty = !editUndoStack.isEmpty
        store.invalidatePage(containing: visibleFirstRow)
        store.ensureLoaded(around: visibleFirstRow)
    }

    /// Mark the current edits as saved (called after a successful write-back).
    public func markSaved() {
        isDirty = false
    }

    /// Bridge from `GridTableView`'s inline editor (display column) to
    /// `applyEdit` (source column). Empty text is written as an empty string,
    /// not SQL NULL (v1 keeps it simple).
    public func commitInlineEdit(row: Int, displayColumn: Int, text: String) {
        guard let layout = columnLayout else { return }
        let sourceIndex = layout.sourceIndex(displayIndex: displayColumn)
        applyEdit(row: row, sourceColumnIndex: sourceIndex, newValue: .text(text))
    }

    /// `UPDATE editView SET "col" = value WHERE rowid = …`. Values go in as
    /// string literals (or NULL) and rely on DuckDB casting to the column type;
    /// a cast failure returns false rather than throwing.
    private func writeCell(rowID: Int64, columnName: String, value: Cell) -> Bool {
        let col = columnName.replacingOccurrences(of: "\"", with: "\"\"")
        let setExpr: String
        switch value {
        case .null:
            setExpr = "NULL"
        case .text(let s):
            setExpr = "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        }
        do {
            try connection.execute(
                "UPDATE \"\(Self.editView)\" SET \"\(col)\" = \(setExpr) WHERE rowid = \(rowID)")
            return true
        } catch {
            return false
        }
    }

    /// Rebuilds the `RowStore` — and the grid that reads from it — for the
    /// CURRENT `currentView`/`columnLayout`, applying `spec` (WHERE/ORDER
    /// BY). Shared by `switchTo` (which first resets `columnLayout` and
    /// clears `headerView` so this rebuilds both fresh) and `toggleSort`
    /// (same view/layout — only the query changes, so the existing header is
    /// reused, preserving any resize/reorder the user has already made).
    ///
    /// This factoring exists so a sort change gets EXACTLY the same
    /// generation-safe reload protocol a view switch does (bump
    /// `switchGeneration`, cancel any stale task, reset scroll/prefetch
    /// state, re-claim `onPageLoaded` for this generation) — one
    /// implementation of that protocol, not two independently-maintained
    /// copies that could drift.
    private func rebuildStore(spec: QuerySpec) {
        guard let view = currentView, let layout = columnLayout else { return }

        switchGeneration += 1
        let generation = switchGeneration

        activeSwitchTask?.cancel()
        activeSwitchTask = nil

        // Reset per-view scroll/prefetch state.
        hasTriggeredBottomLoad = false
        visibleRowsToken?.cancel()
        visibleRowsToken = nil
        visibleFirstRow = 0
        visibleLastRow = 0

        // A fresh RowStore means fresh row indices — any previously-computed
        // matches referred to rows in the OLD store and are meaningless here
        // (a sort/filter change reshuffles which absolute row index holds
        // which data). The search TERM itself is preserved (the user is
        // still searching for the same text); `applyPageLoaded` calls
        // `recomputeMatches()` (gated on a non-empty `searchTermLower`) as
        // the new store's pages load, repopulating `matchList`/
        // `matchingColumnIndices`/`currentMatch` from scratch against the
        // new row indices.
        matchList = []
        matchingColumnIndices = []
        currentMatch = nil

        let store = RowStore(connection: connection, view: view, pageSize: Self.pageSize, spec: spec,
                             includesRowID: isEditing)
        self.rowStore = store
        if spec.whereClause.isEmpty { unfilteredRowCount = store.totalRowCount }
        selectedRowCount = 0

        // GridTableView holds its RowStore as a `let`, so a new query always
        // means a new grid instance. The header, though, can be reused
        // as-is when one already exists (a sort change on the same view) —
        // just repoint it at the current layout; `switchTo` clears
        // `headerView` beforehand when a fresh one is actually needed.
        let grid = GridTableView(rowStore: store, columnLayout: layout)
        grid.searchTermLower = searchTermLower
        grid.currentMatch = nil
        grid.editingEnabled = isEditing
        grid.onCommitEdit = { [weak self] row, displayColumn, text in
            self?.commitInlineEdit(row: row, displayColumn: displayColumn, text: text)
        }
        grid.onSelectionChanged = { [weak self] count in
            self?.selectedRowCount = count
        }
        let header = headerView
            ?? GridTableHeaderView(
                columnLayout: layout,
                columnNames: currentColumns.map(\.name),
                columnTypes: currentColumns.map(\.type)
            )
        header.columnLayout = layout
        self.gridView = grid
        self.headerView = header

        wire(grid: grid, header: header, store: store, generation: generation)
    }

    /// Wire the grid/header callbacks and — crucially — RE-CLAIM
    /// `RowStore.onPageLoaded` as the coordinator's own slot (the grid grabbed
    /// it in its init; the coordinator must be the single final owner and
    /// forward the redraw). See the type doc's "onPageLoaded ownership" note.
    private func wire(grid: GridTableView,
                      header: GridTableHeaderView,
                      store: RowStore,
                      generation: Int) {
        // onPageLoaded fires on a BACKGROUND queue — hop to the main actor,
        // then apply with the generation captured for THIS store.
        store.onPageLoaded = { [weak self] range in
            Task { @MainActor in
                self?.applyPageLoaded(range: range, generation: generation)
            }
        }

        // Prefetch + debounced visible-row publish are driven off the grid's
        // visible-range callback.
        grid.onVisibleRowsChanged = { [weak self] first, last in
            self?.handleVisibleRows(first: first, last: last)
        }

        // Header edits (resize/reorder) mutate the header's own ColumnLayout in
        // place before firing these callbacks, so the header holds the
        // authoritative post-edit layout — mirror it into the coordinator's
        // copy and push it to the grid. (Reading `headerView` back avoids a
        // header→closure→header retain cycle.)
        header.onColumnResized = { [weak self] _, _ in
            guard let self, let layout = self.headerView?.columnLayout else { return }
            self.columnLayout = layout
            self.gridView?.columnLayout = layout
        }
        header.onColumnsReordered = { [weak self] _ in
            guard let self, let layout = self.headerView?.columnLayout else { return }
            self.columnLayout = layout
            self.gridView?.columnLayout = layout
        }

        // A plain header click toggles that column's sort. The header only
        // knows DISPLAY positions (same convention as reorder/resize above)
        // — map to the column's stable SOURCE index via
        // `columnLayout.sourceIndex(displayIndex:)` before calling
        // `toggleSort`, which is keyed by source index (a prior bug in this
        // codebase came from passing a display index where source was
        // expected — see the type doc's "Index spaces" note).
        header.onColumnTapped = { [weak self] displayIndex in
            guard let self, let header = self.headerView else { return }
            let source = header.columnLayout.sourceIndex(displayIndex: displayIndex)
            self.toggleSort(columnSourceIndex: source)
        }

        // Secondary click on a column header opens its quick-filter popover
        // -- see `GridTableHeaderView.onColumnFilterRequested`'s doc for why
        // a right-click was chosen over a hover glyph.
        header.onColumnFilterRequested = { [weak self] displayIndex, frame in
            self?.presentFilterPopover(displayIndex: displayIndex, anchorFrame: frame)
        }
    }

    // MARK: Quick-filter popover

    /// Show the quick-filter popover for the column at header DISPLAY index
    /// `displayIndex`, anchored to `anchorFrame` (that column's on-screen
    /// header-local rect). On Done, calls `setExcluded` with the edited set.
    ///
    /// ## Perf: the popover must appear INSTANTLY, values populate after
    ///
    /// `fetchDistinctValues` runs its `SELECT DISTINCT … ORDER BY 1`
    /// synchronously — fine for a small view, but on a large loaded view a
    /// DISTINCT scan can take hundreds of ms, and running it on the main
    /// thread right here (as this method used to) blocked the UI for that
    /// long BEFORE the popover even appeared: right-click felt sluggish
    /// because nothing showed up until the query finished. Fixed by
    /// splitting "show the popover" from "load the values": the popover
    /// (with a `DistinctValuesLoader`, `@Observable`) is shown immediately —
    /// on a cache hit, already populated; on a miss, in its loading state —
    /// and `fetchDistinctValuesAsync` runs the query on a background queue,
    /// hopping back to the main actor to fill in `loader.values` (which the
    /// already-on-screen `QuickFilterPopover` observes and re-renders from)
    /// once it resolves. The synchronous `fetchDistinctValues(forColumn:)`
    /// stays as a public API (and is what `FilterTests` exercises directly)
    /// but is no longer what the popover's OPEN path calls.
    private func presentFilterPopover(displayIndex: Int, anchorFrame: NSRect) {
        guard let header = headerView else { return }
        let source = header.columnLayout.sourceIndex(displayIndex: displayIndex)
        guard let column = currentColumns.first(where: { $0.sourceIndex == source }) else { return }

        let name = column.name
        let initiallyExcluded = excludedValues[name] ?? []
        let loader = DistinctValuesLoader(values: distinctValueCache[name])

        let popover = NSPopover()
        popover.behavior = .transient
        let content = QuickFilterPopover(
            columnName: name,
            loader: loader,
            initiallyExcluded: initiallyExcluded,
            onApply: { [weak self, weak popover] newExcluded in
                self?.setExcluded(newExcluded, forColumn: name)
                popover?.performClose(nil)
            },
            onCancel: { [weak popover] in
                popover?.performClose(nil)
            }
        )
        // SwiftUI-in-NSPopover jank fix: an `NSHostingController` sizes itself
        // lazily, so with the default show animation the SwiftUI content
        // renders *during* the animation and it stutters. Drive the popover
        // size from the content's ideal size up front (`.preferredContentSize`)
        // and skip the animation so the popover appears instantly instead of
        // sliding open while still laying out.
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.animates = false

        activeFilterPopover = popover
        popover.show(relativeTo: anchorFrame, of: header, preferredEdge: .maxY)

        // Cache hit: `loader` was already constructed with a value, nothing
        // more to do. Cache miss: kick off the background fetch; `loader` is
        // held strongly by the just-presented `content`/popover, so it's
        // safe to update even though this method has already returned.
        guard loader.values == nil else { return }
        fetchDistinctValuesAsync(forColumn: name) { [weak self, weak loader] values in
            self?.distinctValueCache[name] = values
            loader?.values = values
        }
    }

    // MARK: Sort

    /// Cycles the given column's sort **none → ascending → descending →
    /// none**, replacing any other column's sort (single-column sort).
    /// Rebuilds the `RowStore` with the new `ORDER BY` (preserving any
    /// active WHERE), resets paging, and reloads — via `rebuildStore`, the
    /// same generation-safe path `switchTo` uses.
    public func toggleSort(columnSourceIndex: Int) {
        guard let column = currentColumns.first(where: { $0.sourceIndex == columnSourceIndex }) else { return }

        if let existing = sortDescriptors.first(where: { $0.columnSourceIndex == columnSourceIndex }) {
            sortDescriptors = existing.ascending
                ? [SortDescriptor(columnSourceIndex: columnSourceIndex, columnName: column.name, ascending: false)]
                : []
        } else {
            sortDescriptors = [SortDescriptor(columnSourceIndex: columnSourceIndex, columnName: column.name, ascending: true)]
        }

        rebuildStore(spec: QuerySpec(whereClause: buildWhereClause(), orderBy: buildOrderByClause()))

        headerView?.sortIndicator = sortDescriptors.first.map { (sourceIndex: $0.columnSourceIndex, ascending: $0.ascending) }
    }

    /// Builds the ` ORDER BY "<name>" ASC|DESC` fragment from
    /// `sortDescriptors` (empty when unsorted). Identifier-quotes the column
    /// name (doubling any embedded `"`), matching the escaping convention
    /// used elsewhere for SQL fragments built outside `RowStore`.
    public func buildOrderByClause() -> String {
        guard let descriptor = sortDescriptors.first else { return "" }
        let direction = descriptor.ascending ? "ASC" : "DESC"
        return " ORDER BY \(Self.quoteIdentifier(descriptor.columnName)) \(direction)"
    }

    private nonisolated static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: Filter

    /// Escape a value destined for a single-quoted SQL string literal
    /// (double the embedded `'`), matching the escaping approach in
    /// `TVTVApp/DataSource.swift`'s `escapedLiteral`.
    private static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// Fetch (and cache) the distinct string values of column `name` in the
    /// current view, for the filter popover's checklist:
    /// `SELECT DISTINCT "<col>"::VARCHAR AS v FROM "<view>" WHERE "<col>" IS
    /// NOT NULL ORDER BY 1 LIMIT <limit>`.
    ///
    /// Simplification (documented): this query conditions ONLY on
    /// `"<col>" IS NOT NULL` — it does NOT also
    /// apply other columns' current `excludedValues` WHERE. So the popover
    /// always lists every value the column can take in the unfiltered view,
    /// even if other active filters would currently hide some rows
    /// containing it. Cached in `distinctValueCache`, cleared on `switchTo`.
    public func fetchDistinctValues(forColumn name: String, limit: Int = 500) -> [String] {
        if let cached = distinctValueCache[name] { return cached }
        guard let view = currentView else { return [] }

        let sql = Self.distinctValuesSQL(view: view, column: name, limit: limit)
        guard let result = try? connection.query(sql) else { return [] }

        let values = Self.readStringColumn(result)
        distinctValueCache[name] = values
        return values
    }

    /// Async counterpart to `fetchDistinctValues`, and the one
    /// `presentFilterPopover` actually calls (see that method's "Perf" doc):
    /// runs the identical DISTINCT query on a background queue instead of
    /// blocking the caller, then hops back to the main actor to invoke
    /// `completion` with the result — `Task { @MainActor in … }`, the same
    /// background→main hop pattern `RowStore.onPageLoaded`'s wiring uses
    /// elsewhere in this type. Does NOT read or write `distinctValueCache`
    /// itself (the caller decides whether/how to cache — `presentFilterPopover`
    /// does); this is purely "run the query off-thread, deliver the result on
    /// the main actor." A cache hit should be handled by the caller checking
    /// `distinctValueCache` BEFORE calling this, since this always runs the
    /// query regardless of what's cached.
    ///
    /// Internal (not private), matching this file's existing test-seam
    /// convention (`rowForTesting`, `matchListForTesting`), so tests can
    /// verify it resolves off the main thread without blocking it and
    /// without needing a real popover/NSHostingController on screen.
    func fetchDistinctValuesAsync(
        forColumn name: String,
        limit: Int = 500,
        completion: @escaping @MainActor ([String]) -> Void
    ) {
        guard let view = currentView else {
            Task { @MainActor in completion([]) }
            return
        }

        let sql = Self.distinctValuesSQL(view: view, column: name, limit: limit)
        let connection = self.connection
        DispatchQueue.global(qos: .userInitiated).async {
            let values: [String]
            if let result = try? connection.query(sql) {
                values = Self.readStringColumn(result)
            } else {
                values = []
            }
            Task { @MainActor in completion(values) }
        }
    }

    private nonisolated static func distinctValuesSQL(view: String, column name: String, limit: Int) -> String {
        let column = quoteIdentifier(name)
        return "SELECT DISTINCT \(column)::VARCHAR AS v FROM \(quoteIdentifier(view)) "
            + "WHERE \(column) IS NOT NULL ORDER BY 1 LIMIT \(limit)"
    }

    /// Reads column 0 of a single-column DISTINCT-query result into
    /// `[String]`, skipping NULLs (the query's own `WHERE … IS NOT NULL`
    /// means there shouldn't be any, but `col[r]` is still `Optional`).
    /// Shared by the sync and async fetch paths so both build the array
    /// identically.
    private nonisolated static func readStringColumn(_ result: DuckDB.ResultSet) -> [String] {
        var values: [String] = []
        let rowCount = Int(result.rowCount)
        values.reserveCapacity(rowCount)
        let col = result[0].cast(to: String.self)
        for r in 0..<DBInt(rowCount) {
            if let v = col[r] { values.append(v) }
        }
        return values
    }

    /// Set column `name`'s excluded values (empty `values` clears the
    /// column's filter entirely) and rebuild the `RowStore` with the new
    /// `WHERE` (combined with the current `ORDER BY`, so filtering preserves
    /// the active sort) — via `rebuildStore`, the same generation-safe path
    /// `switchTo`/`toggleSort` use.
    public func setExcluded(_ values: Set<String>, forColumn name: String) {
        if values.isEmpty {
            excludedValues.removeValue(forKey: name)
        } else {
            excludedValues[name] = values
        }

        // Push the active-filter set to the header (SOURCE index space,
        // matching `sortIndicator`'s convention — see
        // `GridTableHeaderView.filteredColumns`'s doc) so its filter glyphs
        // redraw filled/highlighted for every column with a non-empty
        // `excludedValues` entry, and plain for every other column.
        headerView?.filteredColumns = Set(
            currentColumns.compactMap { column in
                (excludedValues[column.name]?.isEmpty == false) ? column.sourceIndex : nil
            }
        )

        rebuildStore(spec: QuerySpec(whereClause: buildWhereClause(), orderBy: buildOrderByClause()))
    }

    /// Builds the ` WHERE …` fragment from `excludedValues`. For each
    /// filtered column, splits its excluded set into "real" values vs.
    /// `nullSentinel` and picks one of three branches:
    ///
    /// - values only: `"<col>"::VARCHAR NOT IN ('v1','v2',…)`
    /// - NULL only: `"<col>" IS NOT NULL`
    /// - values + NULL: `("<col>"::VARCHAR NOT IN (…) AND "<col>" IS NOT NULL)`
    ///
    /// Per-column conditions are joined ` AND `, prefixed ` WHERE `; empty
    /// string if nothing is excluded anywhere. Column names are
    /// identifier-quoted and values single-quote-escaped (`Self.escapeLiteral`).
    ///
    /// Ordering: columns and values are each sorted alphabetically for a
    /// deterministic, testable result.
    public func buildWhereClause() -> String {
        let conditions = excludedValues.keys.sorted().compactMap { name -> String? in
            guard let excluded = excludedValues[name], !excluded.isEmpty else { return nil }

            let column = Self.quoteIdentifier(name)
            let excludesNull = excluded.contains(Self.nullSentinel)
            let realValues = excluded.subtracting([Self.nullSentinel]).sorted()

            let notInClause: String? = realValues.isEmpty ? nil : {
                let list = realValues.map { "'\(Self.escapeLiteral($0))'" }.joined(separator: ",")
                return "\(column)::VARCHAR NOT IN (\(list))"
            }()
            let isNotNullClause = "\(column) IS NOT NULL"

            switch (notInClause, excludesNull) {
            case (let notIn?, true):
                return "(\(notIn) AND \(isNotNullClause))"
            case (let notIn?, false):
                return notIn
            case (nil, true):
                return isNotNullClause
            case (nil, false):
                return nil // excluded set contained neither real values nor the sentinel
            }
        }

        guard !conditions.isEmpty else { return "" }
        return " WHERE " + conditions.joined(separator: " AND ")
    }

    // MARK: SQL editor

    /// Thrown by `runQuery` when the user's SQL fails to execute. Mirrors
    /// `DataSource.OpenError` (app-side) — this one lives in `TVTVCore`
    /// because `runQuery` itself lives on the coordinator (it is the piece
    /// that already owns the shared `connection` and `switchTo`).
    public enum QueryError: LocalizedError {
        case executionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .executionFailed(let message):
                return message
            }
        }
    }

    /// Run user-provided SQL as the grid's data source:
    ///
    /// 1. `DROP VIEW IF EXISTS "query_result"` — so a re-run (or a previously
    ///    failed run) never trips a "view already exists" error.
    /// 2. `CREATE OR REPLACE TEMP VIEW "query_result" AS <sql>` — `sql` is
    ///    spliced in VERBATIM as the view body (it is a query, not a string
    ///    literal, so it is never escaped/quoted).
    /// 3. A `SELECT * FROM query_result LIMIT 0` schema probe (the same
    ///    pattern `DataSource.columnInfos` uses for the `data` view) builds
    ///    `[ColumnInfo]`.
    /// 4. `switchTo(view: "query_result", columns:)` swaps the grid over.
    ///
    /// On any failure (bad SQL, unreadable schema), throws `QueryError` and
    /// returns WITHOUT calling `switchTo` — the grid keeps showing whatever
    /// view it showed before this call. The DROP-first step means a failed
    /// `CREATE` never leaves a half-built `query_result` view lying around
    /// either.
    public func runQuery(_ sql: String) async throws {
        do {
            try connection.execute("DROP VIEW IF EXISTS \(Self.quoteIdentifier(Self.queryResultView))")
            try connection.execute(
                "CREATE OR REPLACE TEMP VIEW \(Self.quoteIdentifier(Self.queryResultView)) AS \(sql)")
        } catch {
            throw QueryError.executionFailed("\(error)")
        }

        let columns: [ColumnInfo]
        do {
            columns = try columnInfos(forView: Self.queryResultView)
        } catch {
            throw QueryError.executionFailed("Could not read result schema: \(error)")
        }

        switchTo(view: Self.queryResultView, columns: columns)
    }

    /// Schema probe shared by `runQuery`: `SELECT * FROM "<view>" LIMIT 0`,
    /// mirroring `DataSource.columnInfos(forView:connection:)` (the app-side
    /// equivalent used when opening a file) so both paths build `ColumnInfo`
    /// the same way.
    private func columnInfos(forView view: String) throws -> [ColumnInfo] {
        let sql = "SELECT * FROM \(Self.quoteIdentifier(view)) LIMIT 0"
        guard let result = try? connection.query(sql) else {
            throw QueryError.executionFailed("Could not read schema for view \"\(view)\".")
        }
        return (0..<Int(result.columnCount)).map { index in
            ColumnInfo(
                name: result.columnName(at: DBInt(index)),
                sourceIndex: index,
                type: ColumnInfo.sqlTypeName(for: result[DBInt(index)].underlyingDatabaseType)
            )
        }
    }

    // MARK: Search

    /// Pure helper: the SOURCE column indices in `values` whose text (case-
    /// insensitively) contains `searchTermLower`
    /// (`values[i].lowercased().contains(searchTermLower)`) — a `.null` cell
    /// never matches (there is no text to test), and an empty
    /// `searchTermLower` matches nothing (an empty search box highlights no
    /// cells, matching "empty means no active search" throughout this type).
    func matches(inRow values: [Cell]) -> [Int] {
        guard !searchTermLower.isEmpty else { return [] }
        var result: [Int] = []
        for (index, cell) in values.enumerated() {
            guard case .text(let string) = cell, string.lowercased().contains(searchTermLower) else { continue }
            result.append(index)
        }
        return result
    }

    /// Rebuilds `matchList`/`matchingColumnIndices`/`currentMatch` by
    /// scanning every currently-LOADED row (`RowStore.loadedRowRanges()` —
    /// never the whole file) with `matches(inRow:)`, then pushes the result
    /// to `gridView` and redraws the visible rows. Called from `searchTerm`'s
    /// setter, and from `applyPageLoaded` whenever `searchTermLower` is
    /// non-empty (so matches keep expanding as more of the file loads while a
    /// search is active — verified by `SearchTests`'
    /// `test_matchList_growsWhenNewPageLoadsWhileSearchActive`, which fails
    /// without that `applyPageLoaded` wiring).
    ///
    /// If the previously-focused match is still present in the new list, it
    /// stays focused (recomputing after a page load shouldn't yank focus
    /// away from where the user is looking); otherwise focus moves to the
    /// first match, or `nil` if there are none.
    private func recomputeMatches() {
        let previousMatch = currentMatch
        var newMatchList: [(row: Int, col: Int)] = []
        var newMatchingColumns: Set<Int> = []

        if !searchTermLower.isEmpty, let rowStore {
            for range in rowStore.loadedRowRanges() {
                for row in range {
                    guard let cells = rowStore.row(at: row) else { continue }
                    for col in matches(inRow: cells) {
                        newMatchList.append((row: row, col: col))
                        newMatchingColumns.insert(col)
                    }
                }
            }
        }

        matchList = newMatchList
        matchingColumnIndices = newMatchingColumns
        if let previousMatch, newMatchList.contains(where: { $0.row == previousMatch.row && $0.col == previousMatch.col }) {
            currentMatch = previousMatch
        } else {
            currentMatch = newMatchList.first
        }

        gridView?.searchTermLower = searchTermLower
        gridView?.currentMatch = currentMatch
        gridView?.reloadVisible()
    }

    /// Recomputes `matchingColumnNameIndices` from `currentColumns` (a case-
    /// insensitive substring test of each column's NAME against
    /// `searchTermLower` — no row data involved, so this never has to wait on
    /// anything loading), pushes it to the header as a subtle highlight
    /// (`GridTableHeaderView.searchedColumns`), and scrolls the leftmost
    /// currently-DISPLAYED matching column into view.
    ///
    /// ## Why this is a separate affordance from cell-value search
    ///
    /// The toolbar's "N of M" count and next/prev (⌘G/⇧⌘G) navigation stay
    /// keyed EXCLUSIVELY to `matchList`/`matchingColumnIndices` (cell-value
    /// matches) — deliberately not extended to include column-name matches.
    /// Folding a column-name "match" into that same count/sequence would mean
    /// inventing a fake row/cell position for something that isn't a cell at
    /// all, and would make "0 of 0" lie about there being zero matches when a
    /// column-name match (and its scroll-into-view) just happened. Simpler
    /// and honest: cell search keeps its existing count/navigation contract
    /// untouched; matching a column NAME is purely an additional "scroll to
    /// that column" cue layered on top — so searching "SEQ" scrolls to
    /// `EGSEQ` and highlights its header even though the cell count reads
    /// "0 of 0" (no cell contains "SEQ").
    ///
    /// ## Source → display mapping
    ///
    /// `currentColumns`/`ColumnInfo.sourceIndex` are in SOURCE index space,
    /// but `GridTableView.scrollToColumn(_:)` takes a DISPLAY index. This
    /// maps every matching column's source index through
    /// `columnLayout.displayIndex(sourceIndex:)` — the inverse of
    /// `sourceIndex(displayIndex:)` used everywhere else in this type — and
    /// scrolls to the SMALLEST resulting display index (i.e. the match
    /// closest to the left edge as currently arranged on screen), rather than
    /// whichever happened to be first in `currentColumns`' own (source-index)
    /// order.
    private func recomputeColumnNameMatches() {
        guard !searchTermLower.isEmpty else {
            matchingColumnNameIndices = []
            headerView?.searchedColumns = []
            return
        }

        let matchingSourceIndices = currentColumns
            .filter { $0.name.lowercased().contains(searchTermLower) }
            .map(\.sourceIndex)
        matchingColumnNameIndices = Set(matchingSourceIndices)
        headerView?.searchedColumns = matchingColumnNameIndices

        guard let layout = columnLayout else { return }
        let displayIndices = matchingSourceIndices.compactMap { layout.displayIndex(sourceIndex: $0) }
        if let leftmostDisplayIndex = displayIndices.min() {
            gridView?.scrollToColumn(leftmostDisplayIndex)
        }
    }

    /// Moves `currentMatch` forward (`delta == 1`) or backward (`delta ==
    /// -1`) through `matchList`, wrapping around at either end. No-ops when
    /// there are no matches. Scrolls the new match's row into view (best
    /// effort — column-level scroll-into-view is not implemented; see the
    /// report's "scroll-to-match" note).
    private func advanceMatch(by delta: Int) {
        guard !matchList.isEmpty else { return }
        let count = matchList.count
        let baseIndex: Int
        if let current = currentMatch,
           let index = matchList.firstIndex(where: { $0.row == current.row && $0.col == current.col }) {
            baseIndex = index
        } else {
            baseIndex = delta > 0 ? -1 : 0
        }
        let newIndex = ((baseIndex + delta) % count + count) % count
        currentMatch = matchList[newIndex]

        gridView?.currentMatch = currentMatch
        gridView?.scrollToRow(currentMatch!.row)
        gridView?.reloadVisible()
    }

    /// Moves focus to the next match in `matchList`, wrapping to the first
    /// after the last. No-op when there are no matches.
    public func nextMatch() {
        advanceMatch(by: 1)
    }

    /// Moves focus to the previous match in `matchList`, wrapping to the
    /// last before the first. No-op when there are no matches.
    public func previousMatch() {
        advanceMatch(by: -1)
    }

    /// The number of matches across currently-loaded rows — for the
    /// toolbar's "N of M" label.
    public var matchCount: Int { matchList.count }

    /// 1-based position of `currentMatch` within `matchList` (for the
    /// toolbar's "N of M" label), or `nil` when there is no current match.
    public var currentMatchPosition: Int? {
        guard let current = currentMatch else { return nil }
        return matchList.firstIndex(where: { $0.row == current.row && $0.col == current.col }).map { $0 + 1 }
    }

    // MARK: Test seam

    /// The row at `index` in the current `RowStore`, or `nil` if unloaded.
    /// Internal (not private) so tests can assert on loaded row data
    /// directly — mirrors the existing `applyPageLoaded`/`handleVisibleRows`
    /// testability seams — without driving a real AppKit table-view render.
    func rowForTesting(at index: Int) -> [Cell]? {
        rowStore?.row(at: index)
    }

    /// The ordered list of every match across currently-loaded rows (see
    /// `matchList`'s doc). Internal so tests can assert directly on which
    /// rows/columns were found, in particular to prove search never reaches
    /// beyond loaded rows into a SQL scan of the whole file.
    func matchListForTesting() -> [(row: Int, col: Int)] {
        matchList
    }

    // MARK: Page-load application (generation-checked)

    /// Apply a completed page load. Discards the result if its `generation`
    /// does not match the current `switchGeneration` (a stale load from a view
    /// the user has since switched away from). On a match: bump `dataVersion`
    /// and forward the redraw to the grid.
    ///
    /// When a search is active (`searchTermLower` non-empty), also calls
    /// `recomputeMatches()` so `matchList`/`matchingColumnIndices`/
    /// `currentMatch` (and the toolbar's "N of M" count) expand to include
    /// the rows this page just loaded — without this, a match in a
    /// newly-loaded row highlights (the grid's `searchTermLower` is applied
    /// per-cell at draw time) but never enters the count/next-prev
    /// navigation. Gated on a non-empty term so a page load outside any
    /// search does zero extra work. `recomputeMatches` already forwards its
    /// own redraw to `gridView`, so the plain `reloadVisible()` below only
    /// runs when it did NOT (no active search) — never both, to avoid a
    /// redundant redraw.
    ///
    /// Internal (not private) so the generation protocol can be tested
    /// deterministically — resolving a stale load explicitly after a switch,
    /// with no sleeps or real async.
    func applyPageLoaded(range: Range<Int>, generation: Int) {
        guard generation == switchGeneration else { return }  // stale → discard
        dataVersion += 1
        if !searchTermLower.isEmpty {
            recomputeMatches()
        } else {
            gridView?.reloadVisible()
        }
    }

    // MARK: Scroll handling — prefetch + visible-row publish

    /// Handle a visible-row-range change from the grid: run the (immediate)
    /// bottom prefetch check and schedule the (debounced) visible-row publish.
    func handleVisibleRows(first: Int, last: Int) {
        // Ensure the page(s) backing the currently-visible rows are loaded.
        // `RowStore` has no prefetch of its own and the grid only renders what
        // is loaded, so without this the visible rows would stay blank until a
        // near-bottom prefetch happened to cover them. `ensureLoaded` is
        // idempotent (no-op for an already-loaded/in-flight page), so calling it
        // on every visible-range change is cheap. Cover both edges in case the
        // viewport straddles a page boundary.
        rowStore?.ensureLoaded(around: first)
        rowStore?.ensureLoaded(around: last)

        // Bottom prefetch is NOT debounced — it fires directly from the
        // scroll callback. Derive the point distance from the fixed row
        // pitch: the bottom edge of the last visible row is
        // `yPosition(last + 1)`, and the content bottom is `contentHeight`.
        let total = totalRowCount
        let contentHeight = geometry.contentHeight(totalRows: total)
        let viewportBottom = geometry.yPosition(row: last + 1)
        triggerBottomLoadIfNeeded(
            contentHeight: contentHeight,
            scrollY: viewportBottom,
            viewportHeight: 0,
            prefetchIndex: min(max(total - 1, 0), last + 1))

        scheduleVisibleRowsPublish(first: first, last: last)
    }

    /// Pure trigger decision:
    /// `documentHeight - (scrollY + visibleHeight) < 500.0 && !hasTriggered`.
    /// Strict `<`, so exactly `threshold` does not trigger.
    public static func shouldTriggerBottomLoad(
        contentHeight: CGFloat,
        scrollY: CGFloat,
        viewportHeight: CGFloat,
        hasTriggered: Bool,
        threshold: CGFloat = bottomLoadThreshold
    ) -> Bool {
        guard !hasTriggered else { return false }
        return contentHeight - (scrollY + viewportHeight) < threshold
    }

    /// Apply the prefetch decision: if it fires, set the guard flag, kick the
    /// load, and schedule the 0.5 s re-arm that clears the flag. Internal so
    /// the flag/re-arm interaction is testable against an injected scheduler.
    func triggerBottomLoadIfNeeded(
        contentHeight: CGFloat,
        scrollY: CGFloat,
        viewportHeight: CGFloat,
        prefetchIndex: Int
    ) {
        guard Self.shouldTriggerBottomLoad(
            contentHeight: contentHeight,
            scrollY: scrollY,
            viewportHeight: viewportHeight,
            hasTriggered: hasTriggeredBottomLoad
        ) else { return }

        hasTriggeredBottomLoad = true
        rowStore?.ensureLoaded(around: prefetchIndex)
        scheduler.schedule(after: Self.bottomLoadRearm) { [weak self] in
            self?.hasTriggeredBottomLoad = false
        }
    }

    /// Debounced (0.1 s, cancel-and-reschedule) publish of the visible range.
    private func scheduleVisibleRowsPublish(first: Int, last: Int) {
        visibleRowsToken?.cancel()
        visibleRowsToken = scheduler.schedule(after: Self.visibleRowsDebounce) { [weak self] in
            guard let self else { return }
            self.visibleFirstRow = first
            self.visibleLastRow = last
            self.visibleRowsToken = nil
        }
    }
}
