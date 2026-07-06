import Foundation

/// A single column sort: which column (by its stable SOURCE index — the same
/// identity `ColumnLayout.setWidth`/`ColumnInfo` use — and its display name,
/// needed to build the `ORDER BY` SQL) and direction.
///
/// Kept as an array in `DataGridCoordinator` even though this milestone is
/// single-column sort (0 or 1 elements): a later multi-column sort would only
/// need to grow the array, not change the type. YAGNI: no multi-sort UI yet.
public struct SortDescriptor: Equatable, Sendable {
    public var columnSourceIndex: Int
    public var columnName: String
    public var ascending: Bool

    public init(columnSourceIndex: Int, columnName: String, ascending: Bool) {
        self.columnSourceIndex = columnSourceIndex
        self.columnName = columnName
        self.ascending = ascending
    }
}
