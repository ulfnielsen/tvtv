import Foundation

/// Pure vertical-geometry math for the grid: maps a scroll offset to the
/// range of visible rows, a row's y-position, and total scrollable content
/// height. No DuckDB, no AppKit — a testable value type consumed by
/// `DataGridCoordinator` and `GridTableView`.
///
/// ## Row pitch, not bare row height
///
/// Row height is fixed at 20.0 and intercell spacing at 2.0, giving an
/// effective **row pitch of 22.0 pt** (`rowHeight + intercellSpacing.height`).
/// All row math — content height, y-position, visible range — uses the
/// pitch, matching how AppKit lays out an `NSTableView` row grid.
///
/// ## No vertical overscan
///
/// Rather than hand-computing a padded visible range, `visibleRows` mirrors
/// AppKit's own `rowsInRect(visibleRect)` semantics, clamped to
/// `0..<totalCachedRows`: exactly the rows whose frame *geometrically
/// intersects* the given rect count — a row touching the rect only at a
/// boundary line (zero-area overlap) does not count as intersecting
/// (`NSIntersectsRect` semantics). `visibleRows` implements this as
/// `floor(scrollY/pitch) ..< ceil((scrollY+viewportHeight)/pitch)`, clamped
/// to `0...totalRows`. There is deliberately **no** `overscan` parameter —
/// overscan exists only on the horizontal axis (the 300pt column
/// draw-window in `GridTableView`), not here.
public struct GridGeometry {

    /// `rowHeight + intercellSpacingHeight` — the fixed vertical distance
    /// between the start of one row and the start of the next.
    private let pitch: CGFloat

    /// - Parameters:
    ///   - rowHeight: the fixed row height. Defaults to 20.0.
    ///   - intercellSpacingHeight: the fixed vertical gap between rows.
    ///     Defaults to 2.0.
    public init(rowHeight: CGFloat = 20.0, intercellSpacingHeight: CGFloat = 2.0) {
        self.pitch = rowHeight + intercellSpacingHeight
    }

    /// The y-position of `row`'s top edge: `row * pitch`.
    public func yPosition(row: Int) -> CGFloat {
        CGFloat(row) * pitch
    }

    /// Total scrollable content height for `totalRows` rows: `totalRows *
    /// pitch`.
    public func contentHeight(totalRows: Int) -> CGFloat {
        CGFloat(totalRows) * pitch
    }

    /// The range of rows intersecting `[scrollY, scrollY + viewportHeight]`
    /// at the fixed row pitch, clamped to `0..<totalRows`. No vertical
    /// overscan — see the type-level doc for the boundary convention
    /// (touching a rect edge with zero overlap area does not count as
    /// intersecting).
    public func visibleRows(scrollY: CGFloat, viewportHeight: CGFloat, totalRows: Int) -> Range<Int> {
        let firstRow = Int(floor(scrollY / pitch))
        let lastRowExclusive = Int(ceil((scrollY + viewportHeight) / pitch))

        let clampedFirst = min(max(firstRow, 0), totalRows)
        let clampedLast = min(max(lastRowExclusive, 0), totalRows)

        guard clampedFirst < clampedLast else { return clampedFirst..<clampedFirst }
        return clampedFirst..<clampedLast
    }
}
