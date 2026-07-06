import AppKit

/// The per-row cell view: one instance per visible row, recycled by AppKit's
/// row-view pool, drawing **all** of its columns itself inside the grid's one
/// wide `NSTableColumn`.
///
/// Key points of `draw(_:)`'s behavior:
///
/// - `isFlipped == true` (top-left origin).
/// - Holds the row's cell `values` plus copies of the display-order
///   `columnXPositions` / `columnWidths` (pushed in by `GridTableView` at bind
///   time).
/// - **Per-row horizontal draw-window:** `drawnMinX` / `drawnMaxX` bound the
///   x-range this row is allowed to paint — the visible x-range expanded by
///   300 pt of horizontal overscan, maintained by `GridTableView`. `draw(_:)`
///   intersects that window with the invalidated `dirtyRect` and only paints
///   the columns intersecting the result (via `ColumnLayout.columns(intersecting:)`).
///   Columns outside the window are never drawn. This is the horizontal half
///   of the virtualization strategy (there is **no** CALayer tile pool).
/// - Cell insets: text inset 4 pt L / 4 pt R (`w - 8`),
///   1 pt top / 1 pt bottom (`h - 2`); a 0.5 pt right grid line at
///   `cellRight - 0.5`.
///
/// `values == nil` means the row's page has not loaded yet (`RowStore.row(at:)`
/// returned `nil`): the row paints its grid lines but no text — a blank
/// placeholder — and `GridTableView` re-binds + redraws it when
/// `RowStore.onPageLoaded` fires for its range.
final class RowContentView: NSView {

    /// The row's cells in **source (stable) order** — mirroring
    /// `RowStore.row(at:)` / SQL-schema order, i.e. NOT reordered to match
    /// display order — or `nil` if the page is not yet loaded (placeholder
    /// row). `draw(_:)` maps a display index to its source index via
    /// `columnLayout.sourceIndex(displayIndex:)` before indexing into this
    /// array.
    var values: [Cell]?

    /// Column layout (value copy) — used for `columns(intersecting:)` culling.
    var columnLayout: ColumnLayout?

    /// Display-order x-positions / widths (`[displayIndex]`), pushed by
    /// `GridTableView`. Kept as flat arrays for O(1) per-column geometry.
    var columnXPositions: [CGFloat] = []
    var columnWidths: [CGFloat] = []

    /// The already-granted horizontal draw-window (row-local x). Grows
    /// monotonically as `GridTableView` reveals more on scroll; reset to the
    /// current window each time the view is bound to a (new) row.
    var drawnMinX: CGFloat = 0
    var drawnMaxX: CGFloat = 0

    // MARK: Search highlight state
    //
    // A cell whose text contains `searchTermLower` (case-insensitive
    // substring) is painted `searchHighlightBg`; the ONE cell that is the
    // coordinator's current match is painted the more prominent
    // `searchMatchBg` instead. Both colors are class-level statics,
    // initialized once, chosen to read as "current match" (stronger) vs.
    // "other matches" (subtler).

    /// Pushed in by `GridTableView.bind` from `DataGridCoordinator`'s
    /// `searchTermLower`. Empty means no active search — no highlighting.
    var searchTermLower: String = ""

    /// True when this row is the row holding the coordinator's
    /// `currentMatch`. Pushed in by `GridTableView.bind`.
    var isCurrentMatchRow: Bool = false

    /// The SOURCE column index of the current match within this row (only
    /// meaningful when `isCurrentMatchRow` is true) — compared directly
    /// against the `sourceIndex` `draw(_:)` already computes per column to
    /// read `values`, so no display->source conversion is needed here.
    var currentMatchCol: Int = -1

    override var isFlipped: Bool { true }

    // Class-level statics, initialized once on first access.
    //
    // Data-cell text is monospaced so cell values (e.g. "SITE001-S0001")
    // align in columns. Column HEADER labels
    // (`GridTableHeaderView.labelAttributes`) are deliberately left on the
    // normal UI font -- headers are NOT monospaced. Same point size as the
    // rest of the UI (`smallSystemFontSize`); only the font family changes.
    private static let cellFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private static let paragraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()
    private static let gridColor = NSColor.gridColor
    /// Current-match background. See the "Search highlight state" doc above.
    private static let searchMatchBg = NSColor.systemOrange.withAlphaComponent(0.55)
    /// Other-matches-in-row background.
    private static let searchHighlightBg = NSColor.systemYellow.withAlphaComponent(0.30)
    /// `draw(_:)` builds exactly ONE `attrs` dictionary — `.foregroundColor:
    /// NSColor.labelColor` — and applies it uniformly to every cell; there is
    /// no dimmed/secondary-color branch for anything. That rules out a
    /// dimmed "NULL" literal (which would require a second attributes set).
    /// A SQL NULL is therefore rendered as an EMPTY string in the SAME
    /// `textAttributes` as every other cell — i.e. a blank cell, not a
    /// literal "NULL" — keeping the styling uniform across every cell.
    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: cellFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let columnLayout,
              columnXPositions.count == columnWidths.count,
              !columnXPositions.isEmpty
        else { return }

        // Intersect the invalidated strip with the granted draw-window: only
        // columns inside [drawnMinX, drawnMaxX] (visible ± 300 pt) are ever
        // painted, regardless of how wide a dirtyRect AppKit hands us.
        let lo = max(dirtyRect.minX, drawnMinX)
        let hi = min(dirtyRect.maxX, drawnMaxX)
        guard lo <= hi else { return }

        let cols = columnLayout.columns(intersecting: lo...hi)
        guard !cols.isEmpty else { return }

        let h = bounds.height
        for i in cols {
            guard i < columnXPositions.count else { break }
            let x = columnXPositions[i]
            let w = columnWidths[i]
            let textRect = CGRect(x: x + 4, y: 1, width: max(0, w - 8), height: max(0, h - 2))

            // Position (x/w) is display-indexed, but cell VALUES are stored
            // in source order — map display index `i` to its source index
            // before reading `values`, or the wrong column's data paints
            // here whenever `order` isn't identity (see `values`' doc).
            let sourceIndex = columnLayout.sourceIndex(displayIndex: i)
            if let values, sourceIndex < values.count {
                let cell = values[sourceIndex]

                // Search highlight background — painted UNDER the text, so
                // backgrounds are filled before the single text-draw call.
                // Current match wins over "other match in row".
                if !searchTermLower.isEmpty {
                    let cellRect = CGRect(x: x, y: 0, width: w, height: h)
                    if isCurrentMatchRow && sourceIndex == currentMatchCol {
                        Self.searchMatchBg.setFill()
                        cellRect.fill()
                    } else if case .text(let s) = cell, s.lowercased().contains(searchTermLower) {
                        Self.searchHighlightBg.setFill()
                        cellRect.fill()
                    }
                }

                // Single draw call with ONE attributes dict for every cell,
                // built once and applied uniformly. A `.null` cell draws an
                // empty string (blank), never a "NULL" literal; see
                // `textAttributes` doc above.
                let displayString: String
                switch cell {
                case .text(let string): displayString = string
                case .null: displayString = ""
                }
                (displayString as NSString).draw(
                    with: textRect,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: Self.textAttributes,
                    context: nil
                )
            }
            // `values == nil` (page not loaded) → grid line only, no text.

            // Right grid line at cellRight - 0.5, width 0.5.
            Self.gridColor.setStroke()
            let gridX = x + w - 0.5
            let line = NSBezierPath()
            line.move(to: CGPoint(x: gridX, y: 0))
            line.line(to: CGPoint(x: gridX, y: h))
            line.lineWidth = 0.5
            line.stroke()
        }
    }
}
