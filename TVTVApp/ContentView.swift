import AppKit
import DuckDB
import Observation
import os
import SwiftUI
import TVTVCore
import UniformTypeIdentifiers

private let appLog = Logger(subsystem: "com.tvtv.app", category: "open")

/// The app's single source of truth: one shared in-memory DuckDB
/// `Database`/`Connection`, and the one `DataGridCoordinator` that drives the
/// grid. Files are opened by running the open-flow SQL on this
/// connection (`DataSource`) and calling `coordinator.switchTo`.
@MainActor
@Observable
final class AppModel {

    /// The single DuckDB connection every open/query runs on.
    private let database: Database
    private let connection: Connection

    /// The grid engine's orchestration hub, embedded by `DataGrid`.
    let coordinator: DataGridCoordinator

    /// Name of the currently-open file (for the window title / status).
    private(set) var currentFileName: String?

    /// URL of the currently-open file (for Reload and Export's default name).
    private(set) var currentFileURL: URL?

    /// Alias view named after the current file (e.g. `clinical_like`), so the
    /// SQL editor can reference the current table by file name as well as by
    /// `data`. `nil` when the file name sanitizes to `data`.
    private(set) var currentTableAlias: String?

    /// True once a file has been opened and a view handed to the coordinator.
    private(set) var hasData = false

    /// The opened file's `data`-view columns, retained so `closeQuery()` can
    /// switch the coordinator back to `data` (a SQL-editor run replaces
    /// `currentColumns`/`currentView` inside the coordinator with
    /// `query_result`'s own; the app is the one place that still knows what
    /// the FILE's columns were) without re-probing the schema.
    private(set) var openedColumns: [ColumnInfo] = []

    /// Last open error, shown as a banner. Cleared on the next successful open.
    var errorMessage: String?

    /// SQL editor panel toggle.
    var showSQL = false

    /// SQL editor text buffer.
    var sqlText: String = ""

    /// Last `runQuery` error, shown in the SQL editor panel. Cleared on the
    /// next successful run.
    var queryErrorMessage: String?

    /// Bumped by the ⌘F "Find" command (`TVTVApp.swift`'s `.commands` block)
    /// to ask `ContentView` to move keyboard focus to the search field.
    /// `.commands` lives in the App scene, but the search field's
    /// `@FocusState` lives in `ContentView` — this token is the bridge:
    /// `ContentView` observes it via `.onChange` and sets its
    /// `searchFieldFocused` `@FocusState` to `true`. A monotonic counter
    /// (rather than a `Bool`) so pressing ⌘F twice in a row — e.g. after the
    /// user has since clicked focus away without changing the token's
    /// value — reliably re-fires the `.onChange` each time (`didSet`'s
    /// `Bool` toggle would need the caller to remember to reset it first).
    var focusSearchToken: Int = 0

    /// Extensions the open panel / drop flow accept.
    static let openableExtensions = ["parquet", "csv", "tsv", "duckdb", "db", "json", "ndjson"]

    /// CDISC metadata of the current file when it is Dataset-JSON — what
    /// `save`/`saveAs` re-serialize verbatim. `nil` for every other format.
    private(set) var datasetJSONMetadata: DatasetJSON.Metadata?

    /// The temp parquet backing `data` for conversion-based formats (Vortex,
    /// Dataset-JSON); deleted when the next open supersedes it.
    private var tempParquetURL: URL?

    init() {
        // In-memory DuckDB. Connecting to an in-memory store is a
        // well-exercised path; a failure here means DuckDB itself is
        // unusable, so there is nothing to recover to.
        let database = try! Database(store: .inMemory)
        let connection = try! database.connect()
        self.database = database
        self.connection = connection
        self.coordinator = DataGridCoordinator(connection: connection)
    }

    /// Open a file: run the open-flow SQL, then switch the coordinator to the
    /// resulting `data` view. Errors surface via `errorMessage`.
    func open(url: URL) {
        do {
            // Drop the previous file's alias view so it doesn't linger pointing
            // at the now-replaced `data` (the alias name is a sanitized
            // identifier — letters/digits/`_` — so no escaping is needed).
            if let old = currentTableAlias {
                try? connection.execute("DROP VIEW IF EXISTS \"\(old)\"")
            }
            let opened = try DataSource.open(url: url, connection: connection)
            coordinator.switchTo(view: opened.viewName, columns: opened.columns)
            // The previous open's temp parquet (if any) is now unreferenced.
            if let old = tempParquetURL {
                try? FileManager.default.removeItem(at: old)
            }
            tempParquetURL = opened.tempParquetURL
            datasetJSONMetadata = opened.datasetJSON
            currentFileName = url.lastPathComponent
            currentFileURL = url
            currentTableAlias = opened.tableAlias
            openedColumns = opened.columns
            hasData = true
            // A successful open clears the banner — unless the open itself
            // has something to warn about (e.g. records mismatch).
            errorMessage = opened.warning
            // A newly-opened file supersedes any SQL editor state from the
            // previous file.
            showSQL = false
            sqlText = ""
            queryErrorMessage = nil
            appLog.debug("Opened \(url.lastPathComponent, privacy: .public): \(opened.columns.count, privacy: .public) columns, \(self.coordinator.totalRowCount, privacy: .public) rows")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Run `sql` as the grid's data source — delegates to
    /// `DataGridCoordinator.runQuery`, which owns the shared connection and
    /// the `switchTo` call; this just
    /// surfaces the result/error as `@Observable` state the SQL editor panel
    /// binds to.
    func runQuery(_ sql: String) async {
        do {
            try await coordinator.runQuery(sql)
            queryErrorMessage = nil
        } catch {
            queryErrorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Return the grid to the opened file's `data` view (the SQL editor's
    /// "back to file" control). No-op if nothing has been opened yet.
    func closeQuery() {
        guard hasData else { return }
        coordinator.switchTo(view: DataSource.viewName, columns: openedColumns)
        queryErrorMessage = nil
    }

    /// Requests that the search field take keyboard focus (the ⌘F "Find"
    /// command's action — see `focusSearchToken`'s doc). No-op-ish when
    /// there's nothing to focus (`hasData == false`, so no search field is
    /// in the toolbar at all): bumping the token then is harmless since
    /// `ContentView`'s `.onChange` handler only exists once the toolbar (and
    /// its search field) does.
    func focusSearch() {
        focusSearchToken += 1
    }

    /// Present a File > Open panel and open the chosen file.
    func openViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.openableExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    /// Re-open the current file (toolbar Reload) — picks up on-disk changes.
    func reload() {
        guard let url = currentFileURL else { return }
        open(url: url)
    }

    /// Export the currently-shown view to a CSV via a save panel (toolbar
    /// Export). Uses DuckDB's `COPY … TO … (FORMAT CSV, HEADER)`.
    func exportCSV() {
        guard hasData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        let base = (currentFileName as NSString?)?.deletingPathExtension ?? "export"
        panel.nameFieldStringValue = "\(base).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let view = coordinator.isQueryResult ? DataGridCoordinator.queryResultView : DataSource.viewName
        let escapedPath = url.path.replacingOccurrences(of: "'", with: "''")
        do {
            try connection.execute(
                "COPY (SELECT * FROM \"\(view)\") TO '\(escapedPath)' (FORMAT CSV, HEADER)")
        } catch {
            errorMessage = "Export failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// Attach another file as an additional named view (toolbar Attach), so it
    /// can be referenced (e.g. joined) from the SQL editor. The view is
    /// named after the file's base name (sanitized); on success the SQL editor
    /// is opened so the user can query it.
    func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.openableExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let viewName = try DataSource.attach(url: url, connection: connection)
            attachedViews.append(viewName)
            showSQL = true
            sqlText = "SELECT * FROM \"\(viewName)\" LIMIT 100"
            errorMessage = nil
        } catch {
            errorMessage = "Attach failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// Names of files attached as additional views (for the SQL editor's
    /// completion context).
    private(set) var attachedViews: [String] = []

    // MARK: - Cell editing

    /// Toggle edit mode. Entering materializes the file into the mutable
    /// `data_edit` table (cells become editable); leaving reverts the grid to
    /// the file, discarding unsaved edits.
    func setEditing(_ on: Bool) {
        if on {
            _ = coordinator.beginEditing()
        } else {
            coordinator.switchTo(view: DataSource.viewName, columns: openedColumns)
        }
    }

    /// Undo the last cell edit (⌘Z while editing).
    func undoCellEdit() {
        coordinator.undoEdit()
    }

    /// Write the edited table back over the original file (⌘S). Supported for
    /// parquet/csv/tsv/Dataset-JSON; for other formats, points at Save As.
    func save() {
        guard coordinator.isEditing, let url = currentFileURL else { return }
        if writeEdited(to: url) {
            coordinator.markSaved()
        }
    }

    /// Write the edited table to a new file chosen via a save panel (⌘⇧S).
    /// Dataset-JSON targets are offered only when the open file IS
    /// Dataset-JSON (its CDISC metadata can't be synthesized for other data).
    func saveAs() {
        guard coordinator.isEditing else { return }
        let panel = NSSavePanel()
        var types = [UTType(filenameExtension: "parquet"), .commaSeparatedText]
        if datasetJSONMetadata != nil {
            types += [.json, UTType(filenameExtension: "ndjson")]
        }
        panel.allowedContentTypes = types.compactMap { $0 }
        let base = (currentFileName as NSString?)?.deletingPathExtension ?? "export"
        let defaultExtension = datasetJSONMetadata != nil
            ? (currentFileURL?.pathExtension.lowercased() ?? "parquet") : "parquet"
        panel.nameFieldStringValue = "\(base)-edited.\(defaultExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if writeEdited(to: url) {
            coordinator.markSaved()
        }
    }

    /// Format dispatch shared by `save`/`saveAs`: Dataset-JSON through
    /// `DatasetJSON.write`, everything else through DuckDB `COPY`. Returns
    /// success; failure leaves the explanation in `errorMessage` (success
    /// clears it, unless the post-save view refresh leaves a warning).
    private func writeEdited(to url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "json" || ext == "ndjson" {
            guard let metadata = datasetJSONMetadata else {
                errorMessage = "Saving as Dataset-JSON needs a file opened as Dataset-JSON — "
                    + "TVTV can't synthesize CDISC metadata. Choose .parquet or .csv instead."
                return false
            }
            do {
                try DatasetJSON.write(
                    view: DataGridCoordinator.editView, metadata: metadata,
                    connection: connection, to: url)
            } catch {
                errorMessage = "Save failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                return false
            }
            errorMessage = nil
            if url == currentFileURL {
                refreshDatasetJSONBackingSnapshot()
            }
            return true
        }
        guard let options = Self.copyOptions(forExtension: ext) else {
            errorMessage = "Saving edits back to .\(url.pathExtension) isn't supported — "
                + "use Save As to write a .parquet or .csv copy."
            return false
        }
        if writeEdits(toPath: url.path, options: options) {
            errorMessage = nil
            return true
        }
        return false
    }

    /// Rotate the temp parquet behind `data` to a snapshot of the just-saved
    /// edit table (see `DataSource.refreshTranscodedDataView`). On failure the
    /// save itself stands — surface the staleness instead of failing.
    private func refreshDatasetJSONBackingSnapshot() {
        do {
            let fresh = try DataSource.refreshTranscodedDataView(
                fromEditTable: DataGridCoordinator.editView, connection: connection)
            if let old = tempParquetURL {
                try? FileManager.default.removeItem(at: old)
            }
            tempParquetURL = fresh
        } catch {
            errorMessage = "Saved, but the on-screen copy may be stale — use Reload to re-read the file."
        }
    }

    /// `COPY (SELECT * FROM data_edit) TO 'path' <options>`. Returns success.
    private func writeEdits(toPath path: String, options: String) -> Bool {
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        do {
            try connection.execute(
                "COPY (SELECT * FROM \"\(DataGridCoordinator.editView)\") TO '\(escaped)' \(options)")
            return true
        } catch {
            errorMessage = "Save failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            return false
        }
    }

    /// DuckDB COPY options for a writable extension, or nil if unsupported.
    private static func copyOptions(forExtension ext: String) -> String? {
        switch ext {
        case "parquet": return "(FORMAT PARQUET)"
        case "csv": return "(FORMAT CSV, HEADER)"
        case "tsv": return "(FORMAT CSV, HEADER, DELIMITER '\t')"
        default: return nil
        }
    }
}

struct ContentView: View {
    let model: AppModel

    /// Backs the search `TextField`'s keyboard focus. The ⌘F command
    /// lives in the App scene's `.commands`, which can't reach
    /// this view's `@FocusState` directly — `model.focusSearchToken` bridges
    /// the two (see that property's doc); the `.onChange` below is the other
    /// half of the bridge.
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        ZStack {
            if model.hasData {
                // The SQL panel is a `.safeAreaInset` above the grid rather
                // than a VStack sibling: `DataGrid` is an AppKit `NSView` that
                // composited OVER a plain sibling and hid the panel. safeAreaInset
                // insets the grid and keeps the panel on top / visible.
                DataGrid(coordinator: model.coordinator)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if model.showSQL {
                            sqlEditorPanel
                                .frame(height: 200)
                        }
                    }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 700, minHeight: 460)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                errorBanner(message)
            }
        }
        .navigationTitle(model.currentFileName ?? "TVTV")
        // ⌘F ("Find", `TVTVApp.swift`'s `.commands`) bumps
        // `model.focusSearchToken`; react by moving focus to the search
        // field, whether or not the SQL editor panel happens to be open —
        // the field is always in the toolbar whenever `model.hasData`.
        .onChange(of: model.focusSearchToken) {
            searchFieldFocused = true
        }
        .toolbar {
            if model.hasData {
                ToolbarItemGroup(placement: .automatic) {
                    Button { model.openViaPanel() } label: {
                        Image(systemName: "folder")
                    }
                    .help("Open a file (⌘O)")
                    Button { model.attachFile() } label: {
                        Image(systemName: "plus.rectangle.on.folder")
                    }
                    .help("Attach another file as a table")
                    Button { model.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload the current file")
                    Button { model.exportCSV() } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Export to CSV")
                    Button {
                        model.setEditing(!model.coordinator.isEditing)
                    } label: {
                        Image(systemName: model.coordinator.isEditing ? "pencil.circle.fill" : "pencil")
                    }
                    .help(model.coordinator.isEditing ? "Editing — double-click a cell (click to stop & discard)" : "Edit cells")
                    if model.coordinator.isEditing {
                        Button { model.save() } label: {
                            Image(systemName: model.coordinator.isDirty
                                  ? "square.and.arrow.down.badge.checkmark" : "tray.and.arrow.down")
                        }
                        .help("Save edits to the file (⌘S)")
                        .disabled(!model.coordinator.isDirty)
                    }
                    Button {
                        model.showSQL.toggle()
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .help("SQL editor")
                    searchField
                }
            }
        }
    }

    // MARK: SQL editor
    //
    // A panel above the grid; running swaps the grid to `query_result`
    // (`AppModel.runQuery` -> `DataGridCoordinator.runQuery`), and "Back to
    // File" (shown only while `coordinator.isQueryResult`) switches back to
    // the opened file's `data` view via `AppModel.closeQuery()`.
    private var sqlEditorPanel: some View {
        SQLEditor(
            sqlText: Binding(get: { model.sqlText }, set: { model.sqlText = $0 }),
            errorMessage: model.queryErrorMessage,
            isQueryResult: model.coordinator.isQueryResult,
            tables: [DataSource.viewName, DataGridCoordinator.queryResultView]
                + [model.currentTableAlias].compactMap { $0 } + model.attachedViews,
            columns: model.openedColumns.map(\.name),
            onRun: { Task { await model.runQuery(model.sqlText) } },
            onClose: { model.closeQuery() }
        )
    }

    // MARK: Cell search
    //
    // In-memory over currently-loaded rows (`DataGridCoordinator.searchTerm`
    // / `matches(inRow:)` — never a SQL scan; see that type's "Search state"
    // doc). This toolbar just binds to the coordinator's published state and
    // calls `nextMatch`/`previousMatch`.
    private var searchField: some View {
        let coordinator = model.coordinator
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in loaded rows…", text: Binding(
                get: { coordinator.searchTerm },
                set: { coordinator.searchTerm = $0 }
            ))
            .textFieldStyle(.plain)
            .frame(minWidth: 140, maxWidth: 220)
            .focused($searchFieldFocused)
            // Return advances to the next match (⇧Return to the previous),
            // matching the ⌘G / ⇧⌘G shortcuts on the chevrons below.
            .onSubmit {
                if NSEvent.modifierFlags.contains(.shift) {
                    coordinator.previousMatch()
                } else {
                    coordinator.nextMatch()
                }
            }
            // Esc clears the search (dropping highlights/matches) and drops focus.
            .onExitCommand {
                coordinator.searchTerm = ""
                searchFieldFocused = false
            }
            if !coordinator.searchTerm.isEmpty {
                Text(matchCountLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    coordinator.previousMatch()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(coordinator.matchCount == 0)
                Button {
                    coordinator.nextMatch()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(coordinator.matchCount == 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var matchCountLabel: String {
        let coordinator = model.coordinator
        guard coordinator.matchCount > 0 else { return "0 of 0" }
        return "\(coordinator.currentMatchPosition ?? 0) of \(coordinator.matchCount)"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Open a file to view it")
                .font(.title2)
            Text("Drag a .parquet, .csv, .tsv, .duckdb, or Dataset-JSON file here — or use File ▸ Open.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open…") { model.openViaPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 4)
        }
        .padding(40)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .padding(.top, 8)
            .onTapGesture { model.errorMessage = nil }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.open(url: url) }
        }
        return true
    }
}
