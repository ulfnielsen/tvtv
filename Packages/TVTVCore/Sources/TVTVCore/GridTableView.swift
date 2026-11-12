import AppKit

/// The AppKit grid view: renders visible rows and, per row, only the columns
/// inside a 300 pt-expanded horizontal draw-window.
///
/// ## Architecture — AppKit-native row recycling, NO CALayer tiler
///
/// There is deliberately **no CALayer tile pool** for grid content.
/// Virtualization is split across the two axes instead:
///
/// - **Vertical:** AppKit's native `NSTableView` row-view recycling. This
///   view hosts an `NSScrollView` + `NSTableView` (single full-width
///   `NSTableColumn`); AppKit vends/recycles one `RowContentView` per *visible*
///   row via `rowsInRect`, so scrolling a billion-row file only ever
///   instantiates a screenful of views. No manual scrollY/rowHeight math here
///   (that lives in `GridGeometry`, the coordinator's tool).
/// - **Horizontal:** a hand-rolled per-row draw-window. On every scroll the
///   window `[visibleRect.minX - 300, visibleRect.maxX + 300]` (clamped to
///   `[0, totalContentWidth]`) is grown on each visible `RowContentView`
///   (`drawnMinX` / `drawnMaxX`), and only the newly-exposed strip is
///   invalidated. `RowContentView.draw` culls its columns to that window via
///   `ColumnLayout.columns(intersecting:)`.
///
/// `GridTableView` is a self-contained `NSView` that *hosts* the table and
/// owns the render-side delegate/dataSource duties, so it renders standalone
/// before the coordinator exists. Load *scheduling* (prefetch /
/// `ensureLoaded`) is deliberately NOT done here: this view only
/// renders what is loaded and reports visible-range changes via
/// `onVisibleRowsChanged`; the coordinator drives prefetch off that callback.
/// (It does subscribe to `RowStore.onPageLoaded` purely to redraw rows whose
/// data has just arrived.)
public final class GridTableView: NSView {

    // MARK: Layout constants

    /// Fixed row height.
    public static let rowHeight: CGFloat = 20.0
    /// Fixed vertical intercell spacing.
    public static let intercellSpacingHeight: CGFloat = 2.0
    /// Horizontal overscan applied to each side of the visible x-range.
    public static let horizontalOverscan: CGFloat = 300.0

    /// Trailing-edge debounce before a scroll tick pushes an updated viewport
    /// rect into the minimap.
    public static let minimapDebounce: TimeInterval = 0.03

    // MARK: Dependencies

    private let rowStore: RowStore

    /// Column geometry. Re-assigning rebuilds the derived arrays and reloads.
    public var columnLayout: ColumnLayout {
        didSet {
            rebuildColumnGeometry()
            reloadData()
        }
    }

    /// Called (on the main thread) whenever the visible row range changes,
    /// with the inclusive `[first, last]` range. The coordinator observes
    /// this to drive `RowStore.ensureLoaded` / prefetch. Not fired
    /// when there are no visible rows.
    public var onVisibleRowsChanged: ((_ first: Int, _ last: Int) -> Void)?

    // MARK: Search highlight state

    /// Case-insensitive search term (already lowercased), pushed in by
    /// `DataGridCoordinator` and forwarded to every bound `RowContentView` so
    /// its `draw(_:)` can highlight matching cells (see `RowContentView`'s
    /// doc). Setting this alone does NOT redraw — the coordinator calls
    /// `reloadVisible()` after updating
    /// this and `currentMatch` together, matching how `columnLayout`
    /// mutations are the caller's responsibility to redraw.
    public var searchTermLower: String = ""

    /// The coordinator's current search match — `row` is an ABSOLUTE row
    /// index (`RowStore.row(at:)` space), `col` a SOURCE column index (same
    /// space `RowContentView.values` is indexed in). `nil` when there is no
    /// active match. Pushed to whichever bound `RowContentView` has that row.
    public var currentMatch: (row: Int, col: Int)?

    // MARK: Cell editing

    /// When true, double-clicking a cell opens an inline editor. Set by
    /// `DataGridCoordinator` to mirror `isEditing`.
    public var editingEnabled: Bool = false

    /// Called (main thread) when an inline edit is committed with the display
    /// `row`, the DISPLAY column index, and the new text. The coordinator maps
    /// the display column to its source index and writes it.
    public var onCommitEdit: ((_ row: Int, _ displayColumn: Int, _ newText: String) -> Void)?

    /// The live inline editor field + the cell it's editing, or nil.
    private var editingField: NSTextField?
    private var editingCell: (row: Int, displayColumn: Int)?

    // MARK: AppKit hierarchy

    private let scrollView = NSScrollView()
    private let tableView = GridNSTableView()

    /// The scroll-position overview, floating over the bottom-right corner
    /// of the grid (NOT inside `scrollView` — an overlay sibling, so it
    /// doesn't scroll with the content it's summarizing). See
    /// `MinimapOverlayView`'s doc for the CALayer-backed shape.
    private let minimapView = MinimapOverlayView(
        frame: NSRect(origin: .zero, size: MinimapOverlayView.size)
    )

    /// Pending minimap-update debounce work (cancel-and-reschedule), driven
    /// off scroll ticks at `minimapDebounce` (0.03 s).
    private var minimapDebounceItem: DispatchWorkItem?

    // MARK: Derived geometry (display order)

    private var columnXPositions: [CGFloat] = []
    private var columnWidths: [CGFloat] = []

    /// Latest computed draw-window, used to seed a freshly-bound row view.
    private var currentWindow: ClosedRange<CGFloat>?
    /// Last-reported visible range, to suppress duplicate callbacks.
    private var lastReportedRange: ClosedRange<Int>?

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("TVTV.RowContentView")
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("TVTV.GrayRowView")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("TVTV.dataColumn")

    // MARK: Init

    public init(rowStore: RowStore, columnLayout: ColumnLayout) {
        self.rowStore = rowStore
        self.columnLayout = columnLayout
        super.init(frame: .zero)
        configure()
        rebuildColumnGeometry()
        subscribeToPageLoads()
        tableView.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Public API

    /// Re-binds and redraws the currently visible rows from `RowStore`
    /// (e.g. after data has changed). Also re-reports the visible range.
    public func reloadVisible() {
        for row in visibleRowIndices() {
            if let cell = contentView(atRow: row) {
                bind(cell, row: row)
            }
        }
        reportVisibleRows(force: true)
    }

    /// Horizontally scrolls so the column at `displayIndex` is brought into
    /// view (aligned to the left edge of the viewport where possible).
    public func scrollToColumn(_ displayIndex: Int) {
        guard displayIndex >= 0, displayIndex < columnXPositions.count else { return }
        let x = columnXPositions[displayIndex]
        let width = columnWidths[displayIndex]
        let visible = tableView.visibleRect
        let target = NSRect(x: x, y: visible.minY, width: width, height: max(1, visible.height))
        tableView.scrollToVisible(target)
    }

    /// Scrolls (the minimum distance) so row `row` is visible — used by
    /// `DataGridCoordinator.nextMatch()`/`previousMatch()` to bring
    /// an off-screen search match into view. AppKit's standard
    /// `scrollRowToVisible` no-ops if the row is already visible.
    public func scrollToRow(_ row: Int) {
        guard row >= 0, row < rowStore.totalRowCount else { return }
        tableView.scrollRowToVisible(row)
    }

    // MARK: Row selection

    /// Called (main thread) whenever the selected-row set changes, with the
    /// number of selected rows.
    public var onSelectionChanged: ((_ count: Int) -> Void)?

    /// The selected display-row indexes.
    public var selectedRowIndexes: IndexSet { tableView.selectedRowIndexes }

    /// Replace the selection with `rows` (out-of-range indexes are dropped)
    /// and scroll the last one into view.
    public func selectRows(_ rows: IndexSet) {
        let valid = rows.intersection(IndexSet(integersIn: 0..<rowStore.totalRowCount))
        tableView.selectRowIndexes(valid, byExtendingSelection: false)
        if let last = valid.last { tableView.scrollRowToVisible(last) }
    }

    // MARK: Keyboard navigation

    /// Selection moves the table doesn't do natively (it already handles
    /// ↑/↓ and ⇧↑/⇧↓).
    public enum Navigation { case home, end, pageUp, pageDown }

    /// Anchor/cursor of a keyboard-extended selection; reset whenever the
    /// selection changes some other way (mouse, ↑/↓, programmatic).
    private var navigationAnchor: Int?
    private var navigationCursor: Int?
    private var isNavigating = false

    /// Pure target-row math for `navigate`. `current` is -1 when nothing is
    /// selected. `nil` when the table is empty.
    public static func targetRow(for move: Navigation, current: Int, pageRows: Int, total: Int) -> Int? {
        guard total > 0 else { return nil }
        let page = max(1, pageRows)
        let target: Int
        switch move {
        case .home: target = 0
        case .end: target = total - 1
        case .pageUp: target = max(0, current) - page
        case .pageDown: target = max(0, current) + page
        }
        return min(total - 1, max(0, target))
    }

    /// Move the selection (or, with `extending`, grow it from its anchor) and
    /// scroll the target row into view.
    public func navigate(_ move: Navigation, extending: Bool) {
        let current = navigationCursor ?? tableView.selectedRow
        let pageRows = Int(scrollView.contentView.bounds.height / (Self.rowHeight + Self.intercellSpacingHeight))
        guard let target = Self.targetRow(for: move, current: current,
                                          pageRows: pageRows, total: rowStore.totalRowCount) else { return }
        let anchor = extending ? (navigationAnchor ?? max(0, current)) : target
        isNavigating = true
        tableView.selectRowIndexes(IndexSet(integersIn: min(anchor, target)...max(anchor, target)),
                                   byExtendingSelection: false)
        isNavigating = false
        navigationAnchor = anchor
        navigationCursor = target
        tableView.scrollRowToVisible(target)
    }

    /// ←/→: scroll horizontally by one column (there is no cell cursor).
    fileprivate func scrollHorizontally(by direction: Int) {
        let clip = scrollView.contentView
        let x = clip.bounds.origin.x
        let target: CGFloat
        if direction > 0 {
            target = columnXPositions.first(where: { $0 > x + 0.5 }) ?? x
        } else {
            target = columnXPositions.last(where: { $0 < x - 0.5 }) ?? 0
        }
        let maxX = max(0, (scrollView.documentView?.bounds.width ?? 0) - clip.bounds.width)
        clip.setBoundsOrigin(NSPoint(x: min(maxX, max(0, target)), y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Copy

    /// The selected rows as TSV (display column order; NULL → empty), with an
    /// optional header line of column names. Capped at `RowClipboard.maxRows`
    /// rows. `nil` when nothing is selected.
    public func copyText(includeHeader: Bool) -> String? {
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { return nil }
        var capped = IndexSet()
        for run in selection.rangeView {
            let room = RowClipboard.maxRows - capped.count
            if room <= 0 { break }
            capped.insert(integersIn: run.lowerBound..<min(run.upperBound, run.lowerBound + room))
        }
        let order = (0..<columnLayout.columnCount).map { columnLayout.sourceIndex(displayIndex: $0) }
        let names = rowStore.columns
        let header = includeHeader ? order.map { $0 < names.count ? names[$0] : "" } : nil
        let rows = rowStore.rows(at: capped).map { cells in
            order.map { $0 < cells.count ? cells[$0] : .null }
        }
        return RowClipboard.tsv(header: header, rows: rows)
    }

    /// Write `copyText` to `pasteboard`. Beeps when the selection was larger
    /// than `RowClipboard.maxRows` (only that many rows were copied).
    @discardableResult
    public func copySelection(includeHeader: Bool, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = copyText(includeHeader: includeHeader) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if tableView.selectedRowIndexes.count > RowClipboard.maxRows { NSSound.beep() }
        return true
    }

    /// Edit ▸ Copy (⌘C) — reached via the responder chain when the table is
    /// first responder.
    @objc public func copy(_ sender: Any?) {
        copySelection(includeHeader: false)
    }

    /// Edit ▸ Copy with Headers (⌥⌘C).
    @objc public func copyWithHeaders(_ sender: Any?) {
        copySelection(includeHeader: true)
    }

    // MARK: Inline cell editing

    @objc private func handleDoubleClick() {
        guard editingEnabled, let event = NSApp.currentEvent else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < rowStore.totalRowCount else { return }
        let point = tableView.convert(event.locationInWindow, from: nil)
        // Find the display column whose x-span contains the click.
        guard let displayColumn = (0..<columnXPositions.count).first(where: { i in
            point.x >= columnXPositions[i] && point.x < columnXPositions[i] + columnWidths[i]
        }) else { return }

        let sourceIndex = columnLayout.sourceIndex(displayIndex: displayColumn)
        let currentText: String
        if let cells = rowStore.row(at: row), sourceIndex < cells.count,
           case .text(let s) = cells[sourceIndex] {
            currentText = s
        } else {
            currentText = ""
        }
        beginInlineEdit(row: row, displayColumn: displayColumn, text: currentText)
    }

    private func beginInlineEdit(row: Int, displayColumn: Int, text: String) {
        endInlineEdit(commit: false)
        guard displayColumn < columnXPositions.count else { return }
        let rowRect = tableView.rect(ofRow: row)
        let frame = NSRect(x: columnXPositions[displayColumn], y: rowRect.minY,
                           width: columnWidths[displayColumn], height: rowRect.height)

        let field = NSTextField(frame: frame)
        field.stringValue = text
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.focusRingType = .none
        field.delegate = self
        field.lineBreakMode = .byClipping
        tableView.addSubview(field)
        window?.makeFirstResponder(field)
        // Select all so typing replaces; the field editor exists after focus.
        (field.currentEditor() as? NSTextView)?.selectAll(nil)

        editingField = field
        editingCell = (row, displayColumn)
    }

    /// Close the inline editor, optionally committing its text.
    func endInlineEdit(commit: Bool) {
        guard let field = editingField, let cell = editingCell else { return }
        let text = field.stringValue
        editingField = nil
        editingCell = nil
        field.delegate = nil
        field.removeFromSuperview()
        if commit {
            onCommitEdit?(cell.row, cell.displayColumn, text)
        }
    }

    // MARK: Setup

    private func configure() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Self.intercellSpacingHeight)
        if #available(macOS 11.0, *) {
            tableView.style = .plain
        }
        // Banding is drawn by GrayRowView; keep AppKit from double-drawing it.
        tableView.usesAlternatingRowBackgroundColors = false
        // Native column reorder/resize are disabled (done in GridTableHeaderView).
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.headerView = nil // header is GridTableHeaderView, hosted separately
        tableView.gridStyleMask = []
        // Row selection: click, ⇧/⌘-click, ↑/↓ (⇧ extends), ⌘A. The tint is
        // drawn by GrayRowView.drawSelection.
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.owner = self

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = []
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Overlay, not a scrollView subview — floats above the grid, pinned
        // to the container's bottom-right corner (140x90, inset -24 on
        // trailing & bottom).
        minimapView.translatesAutoresizingMaskIntoConstraints = false
        // Click/drag on the minimap jumps the grid to that position — both
        // vertically (to that fraction of the rows) and horizontally (centering
        // the clicked x-fraction of the total content width).
        minimapView.onJump = { [weak self] fx, fy in
            guard let self else { return }
            let total = self.rowStore.totalRowCount
            if total > 0 {
                let row = min(total - 1, max(0, Int(fy * CGFloat(total))))
                self.scrollToRow(row)
            }
            let clip = self.scrollView.contentView
            let contentWidth = self.scrollView.documentView?.bounds.width ?? 0
            let viewportWidth = clip.bounds.width
            let maxX = max(0, contentWidth - viewportWidth)
            let targetX = min(maxX, max(0, fx * contentWidth - viewportWidth / 2))
            clip.setBoundsOrigin(NSPoint(x: targetX, y: clip.bounds.origin.y))
            self.scrollView.reflectScrolledClipView(clip)
        }
        addSubview(minimapView)
        NSLayoutConstraint.activate([
            minimapView.widthAnchor.constraint(equalToConstant: MinimapOverlayView.size.width),
            minimapView.heightAnchor.constraint(equalToConstant: MinimapOverlayView.size.height),
            minimapView.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -MinimapOverlayView.containerMargin
            ),
            minimapView.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -MinimapOverlayView.containerMargin
            ),
        ])

        // Observe scroll (clip-view bounds changes) to maintain the draw-window
        // and report visible-range changes.
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
    }

    private func subscribeToPageLoads() {
        // onPageLoaded fires on a BACKGROUND queue (RowStore contract) — hop to
        // main before touching any AppKit state, then redraw the just-loaded
        // rows that are currently visible.
        rowStore.onPageLoaded = { [weak self] range in
            DispatchQueue.main.async {
                guard let self else { return }
                for row in self.visibleRowIndices() where range.contains(row) {
                    if let cell = self.contentView(atRow: row) {
                        cell.values = self.rowStore.row(at: row)
                        cell.needsDisplay = true
                    }
                }
            }
        }
    }

    // MARK: Geometry

    private func rebuildColumnGeometry() {
        columnWidths = columnLayout.displayWidths
        columnXPositions = []
        columnXPositions.reserveCapacity(columnWidths.count)
        var x: CGFloat = 0
        for w in columnWidths {
            columnXPositions.append(x)
            x += w
        }
        // Single wide column spanning all data.
        let total = columnLayout.totalContentWidth
        if let column = tableView.tableColumns.first {
            column.minWidth = total
            column.width = total
            column.maxWidth = max(100_000, total)
        }
    }

    private func reloadData() {
        tableView.reloadData()
        currentWindow = nil
        lastReportedRange = nil
        updateDrawWindow()
        reportVisibleRows(force: true)
        updateMinimapNow()
    }

    // MARK: Scroll handling

    @objc private func clipViewBoundsChanged(_ note: Notification) {
        updateDrawWindow()
        reportVisibleRows(force: false)
        scheduleMinimapUpdate()
    }

    public override func layout() {
        super.layout()
        updateDrawWindow()
        reportVisibleRows(force: false)
        updateMinimapNow()
    }

    // MARK: Minimap

    /// Debounced (0.03 s, cancel-and-reschedule) push of the current viewport
    /// into the minimap.
    private func scheduleMinimapUpdate() {
        minimapDebounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.updateMinimapNow() }
        minimapDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.minimapDebounce, execute: item)
    }

    /// Computes the visible-content fraction from the table's full content
    /// size vs. the scroll view's visible rect, and pushes it into the
    /// minimap. Hides the minimap when there's no content to summarize (zero
    /// content size) or the content fits entirely on screen (nothing to
    /// scroll).
    private func updateMinimapNow() {
        guard let fraction = Self.minimapFraction(
            contentSize: tableView.bounds.size,
            visibleRect: scrollView.contentView.documentVisibleRect
        ) else {
            minimapView.isHidden = true
            return
        }
        if fraction.fw >= 1 && fraction.fh >= 1 {
            // Content fits entirely — nothing to navigate, so nothing to
            // summarize.
            minimapView.isHidden = true
            return
        }
        minimapView.isHidden = false
        minimapView.updateViewport(fx: fraction.fx, fy: fraction.fy, fw: fraction.fw, fh: fraction.fh)
    }

    /// Pure, view-independent fraction math: given the document's full
    /// content size and the currently-visible rect within it, returns the
    /// origin/size fractions (0...1) `MinimapOverlayView.updateViewport`
    /// expects — or `nil` when there's no content to summarize (zero-size
    /// content, e.g. before the first layout pass). Extracted for unit
    /// testing.
    public static func minimapFraction(
        contentSize: CGSize,
        visibleRect: CGRect
    ) -> (fx: CGFloat, fy: CGFloat, fw: CGFloat, fh: CGFloat)? {
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        return (
            fx: visibleRect.minX / contentSize.width,
            fy: visibleRect.minY / contentSize.height,
            fw: visibleRect.width / contentSize.width,
            fh: visibleRect.height / contentSize.height
        )
    }

    /// Computes the current draw-window and grows it on each visible row,
    /// invalidating only the newly-exposed strips (monotonic grow per
    /// row-view lifetime via `drawnMinX`/`drawnMaxX`).
    private func updateDrawWindow() {
        let visible = tableView.visibleRect
        guard visible.width > 0 else { return }
        let total = columnLayout.totalContentWidth
        let window = Self.drawWindow(
            visibleMinX: visible.minX,
            visibleMaxX: visible.maxX,
            totalWidth: total
        )
        currentWindow = window
        let lo = window.lowerBound
        let hi = window.upperBound

        for row in visibleRowIndices() {
            guard let cell = contentView(atRow: row) else { continue }
            let height = cell.bounds.height
            if lo < cell.drawnMinX {
                cell.setNeedsDisplay(NSRect(x: lo, y: 0, width: cell.drawnMinX - lo, height: height))
                cell.drawnMinX = lo
            }
            if hi > cell.drawnMaxX {
                cell.setNeedsDisplay(NSRect(x: cell.drawnMaxX, y: 0, width: hi - cell.drawnMaxX, height: height))
                cell.drawnMaxX = hi
            }
        }
    }

    /// Pure draw-window math: the visible x-range expanded by `overscan` on
    /// each side, clamped to `[0, totalWidth]`. Extracted for unit testing.
    public static func drawWindow(
        visibleMinX: CGFloat,
        visibleMaxX: CGFloat,
        totalWidth: CGFloat,
        overscan: CGFloat = horizontalOverscan
    ) -> ClosedRange<CGFloat> {
        let lo = max(0, visibleMinX - overscan)
        let hi = min(totalWidth, visibleMaxX + overscan)
        return lo...max(lo, hi)
    }

    private func reportVisibleRows(force: Bool) {
        let rows = visibleRowIndices()
        guard let first = rows.first, let last = rows.last else { return }
        let range = first...last
        if !force, range == lastReportedRange { return }
        lastReportedRange = range
        onVisibleRowsChanged?(first, last)
    }

    // MARK: Row/cell access

    private func visibleRowIndices() -> Range<Int> {
        let nsRange = tableView.rows(in: tableView.visibleRect)
        guard nsRange.length > 0 else { return 0..<0 }
        let lower = max(0, nsRange.location)
        let upper = min(rowStore.totalRowCount, nsRange.location + nsRange.length)
        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }

    private func contentView(atRow row: Int) -> RowContentView? {
        tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowContentView
    }

    private func bind(_ cell: RowContentView, row: Int) {
        cell.columnLayout = columnLayout
        cell.columnXPositions = columnXPositions
        cell.columnWidths = columnWidths
        cell.values = rowStore.row(at: row)
        cell.searchTermLower = searchTermLower
        if let match = currentMatch, match.row == row {
            cell.isCurrentMatchRow = true
            cell.currentMatchCol = match.col
        } else {
            cell.isCurrentMatchRow = false
            cell.currentMatchCol = -1
        }
        let window = currentWindow ?? {
            let visible = tableView.visibleRect
            return Self.drawWindow(
                visibleMinX: visible.minX,
                visibleMaxX: visible.maxX,
                totalWidth: columnLayout.totalContentWidth
            )
        }()
        cell.drawnMinX = window.lowerBound
        cell.drawnMaxX = window.upperBound
        cell.needsDisplay = true
    }
}

// MARK: - NSTableViewDataSource

extension GridTableView: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        rowStore.totalRowCount
    }
}

// MARK: - NSTableViewDelegate

extension GridTableView: NSTableViewDelegate {

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if !isNavigating {
            navigationAnchor = nil
            navigationCursor = nil
        }
        onSelectionChanged?(tableView.selectedRowIndexes.count)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? RowContentView)
            ?? {
                let view = RowContentView()
                view.identifier = Self.cellIdentifier
                return view
            }()
        bind(cell, row: row)
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = (tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self) as? GrayRowView)
            ?? {
                let view = GrayRowView()
                view.identifier = Self.rowIdentifier
                return view
            }()
        rowView.usesAlternateColor = (row % 2 == 1)
        return rowView
    }
}

// MARK: - Inline editor field delegate

extension GridTableView: NSTextFieldDelegate {
    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            endInlineEdit(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endInlineEdit(commit: false)
            return true
        default:
            return false
        }
    }

    /// Commit on focus loss (e.g. clicking another cell). No-op if the editor
    /// was already closed by Enter/Esc (those clear `editingField` first).
    public func controlTextDidEndEditing(_ obj: Notification) {
        endInlineEdit(commit: true)
    }
}

// MARK: - Menu validation

extension GridTableView: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(copyWithHeaders(_:)):
            return !tableView.selectedRowIndexes.isEmpty
        default:
            return true
        }
    }
}

// MARK: - Table subclass (keyboard)

/// The grid's `NSTableView`: adds the keyboard moves AppKit's table lacks —
/// Home/End and ⌘↑/⌘↓ (first/last row), Page Up/Down (by a screenful),
/// ⇧ with any of those to extend, ←/→ to scroll a column, Esc to deselect.
/// ↑/↓, ⇧↑/⇧↓ and ⌘A are native.
final class GridNSTableView: NSTableView {
    weak var owner: GridTableView?

    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        let extending = flags.contains(.shift)
        let command = flags.contains(.command)
        switch event.specialKey {
        case .home?: owner.navigate(.home, extending: extending)
        case .end?: owner.navigate(.end, extending: extending)
        case .pageUp?: owner.navigate(.pageUp, extending: extending)
        case .pageDown?: owner.navigate(.pageDown, extending: extending)
        case .upArrow? where command: owner.navigate(.home, extending: extending)
        case .downArrow? where command: owner.navigate(.end, extending: extending)
        case .leftArrow? where flags.isEmpty: owner.scrollHorizontally(by: -1)
        case .rightArrow? where flags.isEmpty: owner.scrollHorizontally(by: 1)
        default:
            if event.keyCode == 53, flags.isEmpty { // Esc
                deselectAll(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
