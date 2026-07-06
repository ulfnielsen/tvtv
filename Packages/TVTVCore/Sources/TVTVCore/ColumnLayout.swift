import Foundation

/// Pure column-geometry math for the grid: widths, x-positions, total
/// content width, and horizontal culling. No DuckDB, no AppKit — a testable
/// value type consumed by `GridTableView`/`GridTableHeaderView`.
///
/// ## Index spaces
///
/// `ColumnLayout` deliberately keeps two separate index spaces distinct: a
/// name-keyed, stable-identity space for widths (`customColumnWidths`-style)
/// vs. a display-order space (`columnOrder`, a permutation of source
/// indices):
///
/// - **Source column index** (`columnIndex` in `setWidth`): a column's
///   stable identity, independent of where it's currently displayed.
///   `widths[columnIndex]` is that column's width.
/// - **Display index** (`displayIndex` in `xPosition`): the column's
///   left-to-right position on screen. `order[displayIndex]` gives the
///   source column index shown at that position.
///
/// A resize (`setWidth`) targets a column's stable identity, so it survives
/// a later reorder; a reorder (`moveColumn`) only ever touches `order`, so
/// widths are untouched by reordering.
public struct ColumnLayout {

    /// Minimum column width enforced by `setWidth`.
    public static let minimumWidth: CGFloat = 50

    /// Widths indexed by source column index (stable identity).
    private var widths: [CGFloat]

    /// Display order: `order[displayIndex]` is the source column index shown
    /// at that display position. A permutation of `widths.indices`.
    private var order: [Int]

    /// - Parameters:
    ///   - widths: column widths indexed by source column index.
    ///   - order: display order, `order[displayIndex] == sourceColumnIndex`.
    ///     Must be a permutation of `widths.indices`.
    public init(widths: [CGFloat], order: [Int]) {
        self.widths = widths
        self.order = order
    }

    /// Convenience initializer computing each column's default width from
    /// its name: `max(100.0, nameLength * 9 + 60)`. `order` defaults to
    /// identity (display order == the order `columnNames` were given in)
    /// when `nil`.
    public init(columnNames: [String], order: [Int]? = nil) {
        let widths = columnNames.map { name in
            max(100, CGFloat(name.count) * 9 + 60)
        }
        self.init(widths: widths, order: order ?? Array(columnNames.indices))
    }

    /// Sum of all column widths.
    public var totalContentWidth: CGFloat {
        widths.reduce(0, +)
    }

    /// The number of columns (display count == source count, since `order`
    /// is a permutation of `widths.indices`).
    public var columnCount: Int {
        widths.count
    }

    /// Column widths in DISPLAY order: `displayWidths[displayIndex]` is the
    /// width of the column shown at that position. Provided so the renderer
    /// can derive per-column geometry in a single O(n) pass instead of O(n)
    /// `xPosition` calls per column.
    public var displayWidths: [CGFloat] {
        order.map { widths[$0] }
    }

    /// Source (stable) index of the column currently shown at `displayIndex`
    /// — i.e. `order[displayIndex]`. Renderers use this to look up a
    /// display-positioned column's CELL DATA, which is stored in source
    /// order (matching SQL-schema order), while `xPosition`/`displayWidths`
    /// give that same column's on-screen geometry in display order.
    /// Read-only; `order` is only ever mutated via `moveColumn`.
    public func sourceIndex(displayIndex: Int) -> Int {
        order[displayIndex]
    }

    /// The inverse of `sourceIndex(displayIndex:)`: the DISPLAY position
    /// currently showing the column whose stable SOURCE index is
    /// `sourceIndex`, or `nil` if no column has that source index. Needed
    /// wherever a caller starts from a column's stable identity (e.g. a
    /// SOURCE-indexed search match on a column NAME) and has to drive a
    /// display-position API like `GridTableView.scrollToColumn(_:)` — mixing
    /// up a display index and a source index is an easy mistake, so this
    /// mapping is kept explicit and testable rather than computed ad hoc at
    /// call sites.
    public func displayIndex(sourceIndex: Int) -> Int? {
        order.firstIndex(of: sourceIndex)
    }

    /// The x-position of the column at `displayIndex`: the running sum of
    /// the widths of all preceding columns in display order.
    public func xPosition(displayIndex: Int) -> CGFloat {
        var x: CGFloat = 0
        for i in 0..<displayIndex {
            x += widths[order[i]]
        }
        return x
    }

    /// The display-index range of columns intersecting `xRange`.
    ///
    /// A column is excluded only if it lies *strictly* entirely to one side
    /// of the range: `if dirtyRect.minX > x + w { continue }` /
    /// `if dirtyRect.maxX < x { break }`. A column whose edge exactly
    /// touches a range boundary counts as intersecting (hence `ClosedRange`
    /// — not a half-open range — for the exclusion tests).
    ///
    /// Any horizontal overscan applied to the dirty rect before calling this
    /// is the CALLER's responsibility — this method only answers "which
    /// columns intersect this exact x-range."
    public func columns(intersecting xRange: ClosedRange<CGFloat>) -> Range<Int> {
        var x: CGFloat = 0
        var lowerBound: Int?
        var upperBound = 0
        for i in order.indices {
            let w = widths[order[i]]
            let colMinX = x
            let colMaxX = x + w
            let excluded = xRange.lowerBound > colMaxX || xRange.upperBound < colMinX
            if !excluded {
                if lowerBound == nil { lowerBound = i }
                upperBound = i + 1
            } else if lowerBound != nil {
                // Columns are sorted left-to-right by construction (x is a
                // monotonic prefix sum), so once we've entered and then left
                // the intersecting run, no later column can intersect.
                break
            }
            x += w
        }
        guard let lower = lowerBound else {
            // No column intersects: the range lies either entirely before
            // the first column (insertion point 0) or entirely after the
            // last (insertion point order.count) — columns are contiguous
            // (no gaps), so those are the only two possibilities.
            if xRange.lowerBound > x { return order.count..<order.count }
            return 0..<0
        }
        return lower..<upperBound
    }

    /// Sets the width of the column identified by its stable source index
    /// `columnIndex` (NOT its current display index — see the index-space
    /// note on the type). Clamps to `minimumWidth` (50pt).
    public mutating func setWidth(_ w: CGFloat, forColumn columnIndex: Int) {
        widths[columnIndex] = max(Self.minimumWidth, w)
    }

    /// Moves the column at display index `from` to display index `to`,
    /// mutating `order` only (widths are untouched). `to` is interpreted as
    /// an insertion index in the array *before* removal
    /// (`dest = to - (from < to ? 1 : 0)`), e.g. `moveColumn(from: 0, to: 3)`
    /// on `[A,B,C,D]` yields `[B,C,A,D]`.
    public mutating func moveColumn(from: Int, to: Int) {
        guard from >= 0, from < order.count else { return }
        let moved = order.remove(at: from)
        let dest = min(max(to - (from < to ? 1 : 0), 0), order.count)
        order.insert(moved, at: dest)
    }
}
