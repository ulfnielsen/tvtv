import AppKit

/// The grid's header: column drag-reorder and edge-resize, implemented by
/// hand (AppKit's own column reorder/resize are switched off on the data
/// grid's `NSTableView` -- see `GridTableView.configure()`).
///
/// This view is a plain `NSView` driven by the standard `mouseDown(with:)` /
/// `mouseDragged(with:)` / `mouseUp(with:)` override triple, which keeps the
/// pure hit-test math separate from event plumbing.
///
/// ## Scope
///
/// Reorder + resize, plus a plain sub-threshold click dispatching `onSort`
/// (`onColumnTapped` here) and the minimal label drawing needed to see
/// columns (now including a sort indicator glyph). Cmd-click column
/// selection is deliberately NOT implemented here -- a later milestone.
///
/// ## Index spaces (get this right)
///
/// - `onColumnsReordered([Int])` emits the new DISPLAY order:
///   `result[displayIndex] == sourceColumnIndex`, i.e. exactly
///   `ColumnLayout`'s `order` array after the move. Computed via
///   `sourceIndex(displayIndex:)` over `0..<columnCount` after
///   `moveColumn(from:to:)` commits.
/// - `onColumnResized(Int, CGFloat)` emits the resized column's **SOURCE**
///   index (its stable identity, matching `ColumnLayout.setWidth`'s
///   `forColumn:` parameter) and the new (already-clamped) width. SOURCE was
///   chosen -- not the display edge that was grabbed -- because it's the
///   stable identity that survives a later reorder; a consumer (2.6/2.7)
///   that caches per-column state keyed by source index doesn't need to
///   remap it. The grab itself is always resolved from a DISPLAY edge (hit
///   zones are computed over `displayWidths`/`xPosition`, since that's what
///   the mouse coordinate space is in) and converted to source via
///   `columnLayout.sourceIndex(displayIndex:)` before either calling
///   `setWidth(_:forColumn:)` or firing the callback.
/// - Reorder (`moveColumn(from:to:)`) uses DISPLAY indices throughout --
///   both the dragged column and the insertion index are display positions,
///   matching `ColumnLayout.moveColumn`'s own contract.
public final class GridTableHeaderView: NSView {

    // MARK: Layout constants

    /// Horizontal travel (pt) before a header press is treated as a
    /// column-move rather than a click. STRICT inequality (`> 3.0`), so a
    /// delta of exactly 3.0pt does NOT start a drag.
    public static let dragThreshold: CGFloat = 3.0

    /// Grab tolerance (pt) on EACH side of a column's right edge for a
    /// resize hit -- a 10pt-wide zone straddling the edge.
    public static let resizeHitZone: CGFloat = 5.0

    /// Width (pt) reserved at the LEADING edge of every column header cell
    /// for its control-glyph cluster: each header shows a left-aligned
    /// cluster -- sort glyph, THEN filter glyph, THEN the column name -- not
    /// glyphs at the trailing edge. Both glyphs are now implemented, each
    /// occupying `sortGlyphZoneWidth`/`filterGlyphZoneWidth` back-to-back
    /// inside this gutter (sort first/leftmost, filter second, immediately
    /// before the label) -- see `sortGlyphZoneX`/`filterGlyphZoneX`.
    public static let leadingGutterWidth: CGFloat = sortGlyphZoneWidth + filterGlyphZoneWidth

    /// Width (pt) of the sort glyph's clickable/drawn zone, positioned at the
    /// very FRONT of `leadingGutterWidth` (leftmost: sort glyph, then filter
    /// glyph, then name).
    public static let sortGlyphZoneWidth: CGFloat = 14.0

    /// Width (pt) of the filter glyph's clickable/drawn zone, positioned
    /// immediately after `sortGlyphZoneWidth` -- i.e. at the trailing end of
    /// `leadingGutterWidth` (see its doc). Comfortably clears
    /// `resizeHitZone` even at `ColumnLayout.minimumWidth` (50pt): the zone
    /// spans `[left + 14, left + 28)` while that column's OWN trailing
    /// resize zone only starts at `left + width - 5` (>= `left + 45` at the
    /// 50pt minimum) -- a 17pt margin, verified by
    /// `test_hitTest_resizeZoneStillWinsOverFilterGlyph_atTrailingEdge` and
    /// friends. The zone's right edge (`left + 28`) lands exactly AT
    /// `leadingGutterWidth`'s end, i.e. exactly where the label `textRect`
    /// starts (see `labelTextX(columnLeft:)`) -- glyph and text never
    /// overlap, pinned by `test_filterGlyphZone_neverOverlapsLabelText_*`.
    public static let filterGlyphZoneWidth: CGFloat = 14.0

    // MARK: Pure hit-test result

    public enum HitTestResult: Equatable {
        /// Mouse-down landed within `resizeHitZone` of the trailing edge of
        /// the column at DISPLAY index `displayEdge`.
        case resize(displayEdge: Int)
        /// Mouse-down landed within the filter-glyph zone (see
        /// `leadingGutterWidth`/`filterGlyphZoneWidth`) at the LEADING edge
        /// of the column at DISPLAY index `displayColumn`.
        case filterGlyph(displayColumn: Int)
        /// Mouse-down landed within the sort-glyph zone (see
        /// `sortGlyphZoneWidth`), the FRONT-most slot of the leading gutter,
        /// at the LEADING edge of the column at DISPLAY index
        /// `displayColumn`.
        case sortGlyph(displayColumn: Int)
        /// Mouse-down landed inside the body of the column at DISPLAY index
        /// `displayColumn` (candidate for drag-reorder once past
        /// `dragThreshold`).
        case body(displayColumn: Int)
    }

    // MARK: Dependencies

    /// Column geometry. Mutated in place by resize (`setWidth`) and reorder
    /// (`moveColumn`) as the user drags.
    public var columnLayout: ColumnLayout {
        didSet { needsDisplay = true }
    }

    /// Column display labels, indexed by SOURCE column index (same
    /// convention as `ColumnLayout`'s `widths`/`setWidth`) -- purely for the
    /// minimal label drawing; not used by any hit-test math.
    public var columnNames: [String]

    /// Column SQL types (e.g. "VARCHAR", "BIGINT"), indexed by SOURCE column
    /// index -- same convention/parallel array as `columnNames`. Drawn after
    /// the name in a lighter/secondary color (e.g. "STUDYNAME (VARCHAR)").
    /// An empty string (the default, and what an out-of-range index falls
    /// back to) draws no "(TYPE)" suffix at all.
    public var columnTypes: [String]

    /// Fires once a reorder commits (mouse-up past `dragThreshold`), with
    /// the new DISPLAY order (`result[displayIndex] == sourceColumnIndex`).
    public var onColumnsReordered: (([Int]) -> Void)?

    /// Fires on every drag tick while resizing, with the resized column's
    /// SOURCE index and its new (clamped) width. See the type-level doc for
    /// why SOURCE, not display.
    public var onColumnResized: ((Int, CGFloat) -> Void)?

    /// Fires on a plain sub-threshold click (mouse down + up with no drag
    /// past `dragThreshold`, and not a resize grab), with the clicked
    /// column's DISPLAY index -- matching `onColumnsReordered`'s convention
    /// (the header only ever knows display positions; the coordinator maps
    /// display -> source via `columnLayout.sourceIndex(displayIndex:)`, same
    /// as it does for reorder/resize). Dispatches the sort toggle.
    public var onColumnTapped: ((_ displayIndex: Int) -> Void)?

    /// Fires on a secondary (right) click anywhere on a column — its body OR
    /// its resize zone — with the column's DISPLAY index and its current
    /// on-screen frame (header-local coordinates), so the caller can anchor
    /// a popover to it. A secondary click is the chosen trigger for the
    /// quick-filter popover -- a discoverable, conventional affordance for
    /// it (see `DataGridCoordinator`'s filter popover wiring).
    public var onColumnFilterRequested: ((_ displayIndex: Int, _ frame: NSRect) -> Void)?

    /// The currently-sorted column (SOURCE index) and its direction, for
    /// drawing the sort-glyph gutter zone's ▲/▼ (see `drawSortGlyph`) --
    /// every OTHER column draws that same zone as a neutral "≡" affordance
    /// instead. `nil` when unsorted (every column's sort glyph draws
    /// neutral). The coordinator is the sole writer (mirrors `sortIndicator`
    /// off its own `sortDescriptors` after `toggleSort`).
    public var sortIndicator: (sourceIndex: Int, ascending: Bool)? {
        didSet { needsDisplay = true }
    }

    /// SOURCE indices (same index space as `sortIndicator.sourceIndex` --
    /// NOT display indices) of columns that currently have a non-empty
    /// `DataGridCoordinator.excludedValues` entry, i.e. an active quick
    /// filter. Drawn as a FILLED/accented filter glyph; empty (the default)
    /// draws every column's glyph as a plain outline. The coordinator is the
    /// sole writer, recomputing this set from `excludedValues` each time
    /// `setExcluded` runs (mirrors how `sortIndicator` is pushed after
    /// `toggleSort`). SOURCE, not display, was chosen for the same reason
    /// `sortIndicator` and `onColumnResized` use it: it's the stable
    /// identity that survives a later reorder, so the coordinator never has
    /// to remap this set when the user drags columns around.
    public var filteredColumns: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    /// SOURCE indices (same convention as `filteredColumns`/`sortIndicator`)
    /// of columns whose NAME currently matches the active cell-search term
    /// (Task: search-UX). Drawn as a subtle tinted background behind the
    /// column's label so a "SEQ" search that matches the `EGSEQ` column name
    /// (but no cell value) still gives a visible cue on the header, distinct
    /// from — and much quieter than — the filter/sort glyphs. The
    /// coordinator is the sole writer, recomputed alongside
    /// `matchingColumnNameIndices` whenever `searchTerm` changes.
    public var searchedColumns: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    public init(columnLayout: ColumnLayout, columnNames: [String] = [], columnTypes: [String] = []) {
        self.columnLayout = columnLayout
        self.columnNames = columnNames
        self.columnTypes = columnTypes
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    // MARK: Interaction state

    private enum InteractionState {
        case idle
        /// Mouse is down inside a column's body, sub-threshold so far.
        case pendingDrag(startX: CGFloat, displayColumn: Int)
        /// Actively resizing the column at SOURCE index `sourceColumn`;
        /// `startWidth`/`startX` are the values at the moment the resize
        /// grab began (deltas are computed against these throughout, not
        /// accumulated tick-to-tick):
        /// `newWidth = max(50.0, startWidth + (curX - startX))`.
        case resizing(sourceColumn: Int, startWidth: CGFloat, startX: CGFloat)
        /// Actively dragging column `displayColumn` (its DISPLAY index at
        /// drag-start) for reorder. `originX`/`width` are that column's
        /// geometry at drag-start; `startX` is the initial mouse-down x,
        /// `currentX` the latest drag x -- together they place the drag
        /// ghost. `insertionIndex` is recomputed every tick (`-1`/sentinel
        /// represented here as `columnLayout.columnCount`, matching
        /// `insertionIndex(forX:)`'s own "past everything" sentinel).
        case reordering(
            displayColumn: Int, originX: CGFloat, width: CGFloat,
            startX: CGFloat, currentX: CGFloat, insertionIndex: Int
        )
    }

    private var state: InteractionState = .idle

    // MARK: Pure hit-test math (unit-tested)

    /// Hit-tests a header-local x coordinate against `columnLayout`'s
    /// current DISPLAY geometry. Checked in order -- resize, THEN filter
    /// glyph, THEN sort glyph, THEN body -- checking resize across ALL
    /// column edges before falling through to containment, extended with the
    /// two leading glyphs as narrower carve-outs at each column's leading
    /// edge: a resize
    /// zone always wins over the others where they'd overlap (a narrow
    /// column's whole body can sit inside its own trailing resize zone), and
    /// the glyph zones -- which sit at the OPPOSITE (leading) end of the
    /// column from the resize zone, see `leadingGutterWidth`'s doc -- win
    /// over plain body containment within their own narrow ranges. The
    /// filter/sort zones themselves never overlap each other (contiguous,
    /// back-to-back inside the gutter -- see `sortGlyphZoneX`/
    /// `filterGlyphZoneX`), so checking filter before sort here doesn't
    /// actually pick a winner between them in practice; it just follows the
    /// spec's stated check order.
    public nonisolated static func hitTest(x: CGFloat, columnLayout: ColumnLayout) -> HitTestResult? {
        let widths = columnLayout.displayWidths
        guard !widths.isEmpty else { return nil }

        var positions: [CGFloat] = []
        positions.reserveCapacity(widths.count)
        var pos: CGFloat = 0
        for w in widths {
            positions.append(pos)
            pos += w
        }

        for i in widths.indices {
            let edge = positions[i] + widths[i]
            if abs(x - edge) <= resizeHitZone {
                return .resize(displayEdge: i)
            }
        }

        for i in widths.indices {
            let (zoneLeft, zoneRight) = filterGlyphZoneX(columnLeft: positions[i])
            if x >= zoneLeft && x < zoneRight {
                return .filterGlyph(displayColumn: i)
            }
        }

        for i in widths.indices {
            let (zoneLeft, zoneRight) = sortGlyphZoneX(columnLeft: positions[i])
            if x >= zoneLeft && x < zoneRight {
                return .sortGlyph(displayColumn: i)
            }
        }

        for i in widths.indices {
            let left = positions[i]
            let right = left + widths[i]
            if x >= left && x < right {
                return .body(displayColumn: i)
            }
        }

        return nil
    }

    /// The sort glyph's hit-test/draw x-range for a column whose DISPLAY
    /// left edge is at `columnLeft`: the FRONT-most `sortGlyphZoneWidth`pt of
    /// the `leadingGutterWidth`pt gutter -- i.e. `[columnLeft, columnLeft +
    /// sortGlyphZoneWidth)`, immediately followed (contiguous, no gap) by
    /// `filterGlyphZoneX`'s zone. Shared by `hitTest` and `draw(_:)` so the
    /// clickable zone and the drawn glyph never drift apart.
    nonisolated static func sortGlyphZoneX(columnLeft: CGFloat) -> (left: CGFloat, right: CGFloat) {
        (columnLeft, columnLeft + sortGlyphZoneWidth)
    }

    /// The filter glyph's hit-test/draw x-range for a column whose DISPLAY
    /// left edge is at `columnLeft`: the trailing `filterGlyphZoneWidth`pt
    /// of the `leadingGutterWidth`pt gutter reserved at that column's start
    /// (see both constants' docs) -- i.e. immediately after
    /// `sortGlyphZoneX`'s zone, with no gap between them. Shared by
    /// `hitTest` and `draw(_:)` so the clickable zone and the drawn glyph
    /// never drift apart.
    ///
    /// (Review fix pass -- this used to also add `resizeHitZone`, a stray
    /// term left over from an earlier trailing-edge design that was never
    /// reconciled when the glyph moved to the leading edge. That pushed the
    /// zone's right edge 5pt PAST `labelTextX(columnLeft:)` -- so the glyph,
    /// drawn after the label text in `draw(_:)`, painted over the label's
    /// first ~5pt on every column. Dropping it puts the whole zone inside
    /// `[columnLeft, columnLeft + leadingGutterWidth)`, with its right edge
    /// landing exactly at the text start -- see
    /// `test_filterGlyphZone_neverOverlapsLabelText_atNormalWidth` /
    /// `_atMinimumColumnWidth`, which caught this bug (they failed against
    /// the buggy formula and pass against this one).
    nonisolated static func filterGlyphZoneX(columnLeft: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let left = columnLeft + (leadingGutterWidth - filterGlyphZoneWidth)
        return (left, left + filterGlyphZoneWidth)
    }

    /// The x-coordinate where a column's label text begins, for a column
    /// whose DISPLAY left edge is at `columnLeft`: right after the
    /// `leadingGutterWidth`pt glyph gutter (see its doc). Extracted from
    /// `draw(_:)`'s `textRect` computation so the non-overlap invariant
    /// against `filterGlyphZoneX` (`filterGlyphZoneX(...).right <=
    /// labelTextX(...)`) can be pinned by a unit test rather than only
    /// inspected visually.
    nonisolated static func labelTextX(columnLeft: CGFloat) -> CGFloat {
        columnLeft + leadingGutterWidth + labelLeadingGap
    }

    /// Breathing room between the trailing (filter) glyph and the start of the
    /// column-name text, so the funnel doesn't crowd the label.
    nonisolated static let labelLeadingGap: CGFloat = 8.0

    /// Whether horizontal travel from `startX` to `currentX` exceeds
    /// `dragThreshold`. STRICT `>` -- see `dragThreshold`'s doc.
    public nonisolated static func isDrag(from startX: CGFloat, to currentX: CGFloat) -> Bool {
        abs(currentX - startX) > dragThreshold
    }

    /// The insertion DISPLAY index for a drag currently at x `x`: the first
    /// column whose midpoint lies STRICTLY to the right of `x`, or
    /// `columnLayout.columnCount` if none do (drop at the end):
    /// `insertionIndex = firstIndex { columnXPositions[$0] + columnWidths[$0]*0.5 > curX } ?? columnXPositions.count`.
    public nonisolated static func insertionIndex(forX x: CGFloat, columnLayout: ColumnLayout) -> Int {
        let widths = columnLayout.displayWidths
        var pos: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let mid = pos + w * 0.5
            if mid > x { return i }
            pos += w
        }
        return widths.count
    }

    // MARK: Cursor rects

    public override func resetCursorRects() {
        super.resetCursorRects()
        let widths = columnLayout.displayWidths
        var x: CGFloat = 0
        for w in widths {
            let right = x + w
            let rect = NSRect(
                x: right - Self.resizeHitZone, y: 0,
                width: Self.resizeHitZone * 2, height: bounds.height
            )
            addCursorRect(rect, cursor: .resizeLeftRight)

            let (zoneLeft, zoneRight) = Self.filterGlyphZoneX(columnLeft: x)
            let glyphRect = NSRect(x: zoneLeft, y: 0, width: zoneRight - zoneLeft, height: bounds.height)
            addCursorRect(glyphRect, cursor: .pointingHand)

            let (sortZoneLeft, sortZoneRight) = Self.sortGlyphZoneX(columnLeft: x)
            let sortGlyphRect = NSRect(
                x: sortZoneLeft, y: 0, width: sortZoneRight - sortZoneLeft, height: bounds.height
            )
            addCursorRect(sortGlyphRect, cursor: .pointingHand)

            x += w
        }
    }

    // MARK: Mouse handling

    public override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        switch Self.hitTest(x: x, columnLayout: columnLayout) {
        case .resize(let displayEdge)?:
            let sourceColumn = columnLayout.sourceIndex(displayIndex: displayEdge)
            let startWidth = columnLayout.displayWidths[displayEdge]
            state = .resizing(sourceColumn: sourceColumn, startWidth: startWidth, startX: x)
        case .filterGlyph(let displayColumn)?:
            // No drag/threshold ambiguity to resolve here (unlike a plain
            // body click, which waits for mouse-up to distinguish a sort
            // click from a drag-reorder) -- the glyph is a direct button-like
            // affordance, so it fires immediately on mouse-down and leaves
            // `state` at `.idle` so the paired `mouseUp` is a no-op (does NOT
            // also dispatch `onColumnTapped`/sort).
            state = .idle
            onColumnFilterRequested?(displayColumn, filterGlyphFrame(displayColumn: displayColumn))
        case .sortGlyph(let displayColumn)?:
            // Same immediate-fire, no-drag-ambiguity treatment as the filter
            // glyph above: a direct button-like affordance that fires on
            // mouse-down and leaves `state` at `.idle`. Dispatches through
            // the SAME `onColumnTapped` callback a plain body click uses --
            // the coordinator's sort-toggle wiring doesn't care which of the
            // two triggered it.
            state = .idle
            onColumnTapped?(displayColumn)
        case .body(let displayColumn)?:
            state = .pendingDrag(startX: x, displayColumn: displayColumn)
        case nil:
            state = .idle
        }
    }

    /// The on-screen (header-local) frame of the filter glyph at DISPLAY
    /// index `displayColumn`, used to anchor the quick-filter popover close
    /// to the glyph that opened it (rather than the whole column, which is
    /// what a right-click passes -- see `onColumnFilterRequested`'s doc).
    private func filterGlyphFrame(displayColumn: Int) -> NSRect {
        let left = columnLayout.xPosition(displayIndex: displayColumn)
        let (zoneLeft, zoneRight) = Self.filterGlyphZoneX(columnLeft: left)
        let size = zoneRight - zoneLeft
        return NSRect(x: zoneLeft, y: (bounds.height - size) / 2, width: size, height: size)
    }

    public override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        switch state {
        case .resizing(let sourceColumn, let startWidth, let startX):
            let newWidth = max(ColumnLayout.minimumWidth, startWidth + (x - startX))
            columnLayout.setWidth(newWidth, forColumn: sourceColumn)
            onColumnResized?(sourceColumn, newWidth)

        case .pendingDrag(let startX, let displayColumn):
            guard Self.isDrag(from: startX, to: x) else { return }
            let originX = columnLayout.xPosition(displayIndex: displayColumn)
            let width = columnLayout.displayWidths[displayColumn]
            let insertion = Self.insertionIndex(forX: x, columnLayout: columnLayout)
            state = .reordering(
                displayColumn: displayColumn, originX: originX, width: width,
                startX: startX, currentX: x, insertionIndex: insertion
            )
            needsDisplay = true

        case .reordering(let displayColumn, let originX, let width, let startX, _, _):
            let insertion = Self.insertionIndex(forX: x, columnLayout: columnLayout)
            state = .reordering(
                displayColumn: displayColumn, originX: originX, width: width,
                startX: startX, currentX: x, insertionIndex: insertion
            )
            needsDisplay = true

        case .idle:
            break
        }
    }

    public override func mouseUp(with event: NSEvent) {
        switch state {
        case .resizing:
            state = .idle

        case .reordering(let displayColumn, _, _, _, _, let insertionIndex):
            columnLayout.moveColumn(from: displayColumn, to: insertionIndex)
            let newOrder = (0..<columnLayout.columnCount).map { columnLayout.sourceIndex(displayIndex: $0) }
            onColumnsReordered?(newOrder)
            state = .idle
            needsDisplay = true

        case .pendingDrag(_, let displayColumn):
            // Sub-threshold click inside a column's body: dispatch the sort
            // toggle, keyed by DISPLAY index -- the coordinator maps it to a
            // source index before calling `toggleSort`, same convention as
            // `onColumnsReordered`.
            onColumnTapped?(displayColumn)
            state = .idle

        case .idle:
            // Mouse-down landed on neither a resize zone nor a column body
            // (or mouse-down never happened) -- nothing to dispatch.
            state = .idle
        }
    }

    /// Secondary click: identify which column was clicked (its body OR its
    /// resize zone both count -- either landing counts as "clicked this
    /// column", since a filter request has no drag/resize ambiguity to
    /// resolve) and fire `onColumnFilterRequested` with that column's
    /// DISPLAY index and on-screen frame. Does not touch `state` -- a
    /// right-click never starts a drag/resize/sort gesture.
    public override func rightMouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let displayColumn: Int
        switch Self.hitTest(x: x, columnLayout: columnLayout) {
        case .resize(let displayEdge)?:
            displayColumn = displayEdge
        case .filterGlyph(let column)?:
            displayColumn = column
        case .sortGlyph(let column)?:
            displayColumn = column
        case .body(let column)?:
            displayColumn = column
        case nil:
            return
        }

        let widths = columnLayout.displayWidths
        guard displayColumn >= 0, displayColumn < widths.count else { return }
        var originX: CGFloat = 0
        for i in 0..<displayColumn { originX += widths[i] }
        let frame = NSRect(x: originX, y: 0, width: widths[displayColumn], height: bounds.height)

        onColumnFilterRequested?(displayColumn, frame)
    }

    // MARK: Drawing (minimal -- labels + drag ghost/insertion indicator)

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
    ]

    /// Attributes for the " (TYPE)" suffix appended after the column name --
    /// lighter weight and `secondaryLabelColor` so the name stays the
    /// prominent element and the type reads as de-emphasized, e.g.
    /// "STUDYNAME (VARCHAR)".
    private static let typeLabelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let widths = columnLayout.displayWidths
        var x: CGFloat = 0
        for i in widths.indices {
            let w = widths[i]
            let sourceIndex = columnLayout.sourceIndex(displayIndex: i)
            let name = sourceIndex < columnNames.count ? columnNames[sourceIndex] : ""
            let type = sourceIndex < columnTypes.count ? columnTypes[sourceIndex] : ""

            // A quiet tinted background for a column whose NAME matches the
            // active search term (`searchedColumns`, SOURCE index space).
            // Drawn first so the label/glyphs above still read normally.
            if searchedColumns.contains(sourceIndex) {
                NSColor.findHighlightColor.withAlphaComponent(0.25).setFill()
                NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
            }

            // Direction/sort-state is no longer appended to the label text --
            // it moved entirely into the sort-glyph gutter zone (drawn
            // below) so there's a single, consistent presentation of "is
            // this column sorted, and which way" instead of two (a corner
            // ▲/▼ AND a gutter glyph).
            let text = NSMutableAttributedString(string: name, attributes: Self.labelAttributes)
            if !type.isEmpty {
                text.append(NSAttributedString(string: " (\(type))", attributes: Self.typeLabelAttributes))
            }

            // Label text starts after `leadingGutterWidth` -- the reserved
            // gutter the sort/filter glyphs (drawn below) live in, giving a
            // left-aligned glyph-cluster-then-name layout.
            // `labelTextX` is the SAME helper the non-overlap invariant test
            // checks `filterGlyphZoneX(...).right` against, so this can't
            // silently drift back out of sync with the glyph zone.
            let textStartX = Self.labelTextX(columnLeft: x)
            let textRect = CGRect(
                x: textStartX, y: 0,
                width: max(0, w - Self.leadingGutterWidth - 4), height: bounds.height
            )
            text.draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                context: nil
            )

            // Sort glyph: front-most slot of the leading gutter. Neutral "≡"
            // for every column except the currently-sorted one (per
            // `sortIndicator`, SOURCE index space -- same convention as
            // `filteredColumns` below), which draws a solid ▲/▼ instead.
            let (sortZoneLeft, sortZoneRight) = Self.sortGlyphZoneX(columnLeft: x)
            let sortGlyphSize = sortZoneRight - sortZoneLeft
            let sortGlyphRect = NSRect(
                x: sortZoneLeft, y: (bounds.height - sortGlyphSize) / 2,
                width: sortGlyphSize, height: sortGlyphSize
            )
            let ascending = (sortIndicator?.sourceIndex == sourceIndex) ? sortIndicator?.ascending : nil
            Self.drawSortGlyph(in: sortGlyphRect, ascending: ascending)

            // `filteredColumns` is in SOURCE index space (matching
            // `sortIndicator.sourceIndex`'s convention) -- see that
            // property's doc for why.
            let (zoneLeft, zoneRight) = Self.filterGlyphZoneX(columnLeft: x)
            let glyphSize = zoneRight - zoneLeft
            let glyphRect = NSRect(x: zoneLeft, y: (bounds.height - glyphSize) / 2, width: glyphSize, height: glyphSize)
            Self.drawFilterGlyph(in: glyphRect, active: filteredColumns.contains(sourceIndex))

            NSColor.separatorColor.setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x + w - 0.5, y: 0))
            line.line(to: CGPoint(x: x + w - 0.5, y: bounds.height))
            line.lineWidth = 0.5
            line.stroke()

            x += w
        }

        if case .reordering(_, let originX, let width, let startX, let currentX, let insertionIndex) = state {
            let ghostX = originX + (currentX - startX)
            NSColor.selectedControlColor.withAlphaComponent(0.5).setFill()
            NSRect(x: ghostX, y: 0, width: width, height: bounds.height).fill()

            let clampedInsertion = min(insertionIndex, widths.count)
            let insertX = columnLayout.xPosition(displayIndex: clampedInsertion)
            NSColor.controlAccentColor.setFill()
            NSRect(x: insertX - 1, y: 0, width: 2, height: bounds.height).fill()
        }
    }

    /// Draws a hand-drawn funnel/filter pictograph in `rect` -- a wide
    /// trapezoid top tapering to a narrow rectangular stem, the standard
    /// "filter" glyph. Hand-drawn via `NSBezierPath` rather than an SF
    /// Symbol image: there's no live GUI in this environment to visually
    /// confirm an `NSImage(systemSymbolName:)` actually rendered (a typo'd
    /// or unavailable symbol name fails silently, producing a blank glyph
    /// with no compile-time signal), whereas this shape's geometry is
    /// trivially correct by inspection and has no such failure mode.
    ///
    /// `active` (this column's `filteredColumns` membership -- i.e. it has a
    /// non-empty `excludedValues` entry) draws it FILLED with the accent
    /// color; inactive draws just a subtle stroked outline in secondary
    /// label color, so filtered columns read as visually distinct at a
    /// glance without needing two separate glyph assets.
    ///
    /// Coordinates account for `isFlipped == true`: `rect.minY` is the
    /// VISUAL TOP (where the funnel is wide) and `rect.maxY` is the visual
    /// bottom (the narrow stem), the opposite of an unflipped view.
    private static func drawFilterGlyph(in rect: NSRect, active: Bool) {
        guard rect.width > 0, rect.height > 0 else { return }

        let stemHalfWidth = rect.width * 0.12
        let topInset = rect.width * 0.08
        let neckY = rect.minY + rect.height * 0.55

        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + topInset, y: rect.minY))       // top-left (visual top)
        path.line(to: NSPoint(x: rect.maxX - topInset, y: rect.minY))       // top-right
        path.line(to: NSPoint(x: rect.midX + stemHalfWidth, y: neckY))      // taper to the neck
        path.line(to: NSPoint(x: rect.midX + stemHalfWidth, y: rect.maxY))  // stem right side
        path.line(to: NSPoint(x: rect.midX - stemHalfWidth, y: rect.maxY)) // stem bottom (visual bottom)
        path.line(to: NSPoint(x: rect.midX - stemHalfWidth, y: neckY))      // stem left side
        path.close()

        if active {
            NSColor.controlAccentColor.setFill()
            path.fill()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    /// Draws the sort-glyph pictograph in `rect`: a neutral three-horizontal-
    /// line "≡" affordance (`ascending == nil`, i.e. this column isn't the
    /// active `sortIndicator`), or a solid ▲/▼ triangle in the accent color
    /// pointing in the sort direction (`ascending == true`/`false`) when it
    /// is. This single glyph is now the ONLY place sort direction is drawn --
    /// folding in what used to be a separate " ▲"/" ▼" suffix appended to the
    /// label text (see `draw(_:)`'s doc), so there's one consistent
    /// presentation instead of two redundant ones.
    ///
    /// Coordinates account for `isFlipped == true` (see the type doc):
    /// `rect.minY` is the visual TOP, `rect.maxY` the visual BOTTOM. An
    /// ascending (▲, "smallest first") triangle points UP, so its apex sits
    /// at the visual top (`rect.minY`); descending (▼) points down, apex at
    /// `rect.maxY`.
    private static func drawSortGlyph(in rect: NSRect, ascending: Bool?) {
        guard rect.width > 0, rect.height > 0 else { return }

        guard let ascending else {
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.2
            let inset = rect.width * 0.15
            for step in 1...3 {
                let y = rect.minY + rect.height * (CGFloat(step) / 4)
                path.move(to: NSPoint(x: rect.minX + inset, y: y))
                path.line(to: NSPoint(x: rect.maxX - inset, y: y))
            }
            path.stroke()
            return
        }

        let apexY = ascending ? rect.minY : rect.maxY
        let baseY = ascending ? rect.maxY : rect.minY
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: apexY))
        path.line(to: NSPoint(x: rect.minX, y: baseY))
        path.line(to: NSPoint(x: rect.maxX, y: baseY))
        path.close()

        NSColor.controlAccentColor.setFill()
        path.fill()
    }
}
