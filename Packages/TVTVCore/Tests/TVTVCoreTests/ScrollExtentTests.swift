import XCTest
import AppKit
import SwiftUI
import DuckDB
@testable import TVTVCore

/// The scrollable area must end at the last row / last column. The grid is
/// built at zero size and laid out later (and the window resizes), so any
/// autoresizing of the table onto the clip view's growth shows up here as
/// empty space past the data.
@MainActor
final class ScrollExtentTests: XCTestCase {

    private func makeGrid(rows: Int, columns: Int) throws -> (GridTableView, NSTableView, NSWindow, ColumnLayout, Connection) {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()
        let cols = (0..<columns).map { "i AS c\($0)" }.joined(separator: ", ")
        try conn.execute("CREATE VIEW v AS SELECT \(cols) FROM range(\(rows)) t(i)")
        let layout = ColumnLayout(columnNames: (0..<columns).map { "c\($0)" })
        let grid = GridTableView(rowStore: RowStore(connection: conn, view: "v", pageSize: 10_000), columnLayout: layout)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView!.addSubview(grid)
        grid.frame = window.contentView!.bounds
        grid.autoresizingMask = [.width, .height]
        window.layoutIfNeeded()
        func find(_ v: NSView) -> NSTableView? { (v as? NSTableView) ?? v.subviews.lazy.compactMap(find).first }
        return (grid, find(grid)!, window, layout, conn)
    }

    private let pitch = GridTableView.rowHeight + GridTableView.intercellSpacingHeight

    func test_heightEndsAtLastRow_afterLayoutAndResize() throws {
        let (_, table, window, _, _) = try makeGrid(rows: 1000, columns: 3)
        XCTAssertEqual(table.frame.height, 1000 * pitch, "after first layout")
        window.setContentSize(NSSize(width: 600, height: 500))
        window.layoutIfNeeded()
        XCTAssertEqual(table.frame.height, 1000 * pitch, "after growing the window")
        window.setContentSize(NSSize(width: 300, height: 200))
        window.layoutIfNeeded()
        XCTAssertEqual(table.frame.height, 1000 * pitch, "after shrinking the window")
    }

    func test_widthEndsAtLastColumn_afterLayoutAndResize() throws {
        let (_, table, window, layout, _) = try makeGrid(rows: 50, columns: 40)
        XCTAssertGreaterThan(layout.totalContentWidth, 600, "precondition: wider than the window")
        XCTAssertEqual(table.frame.width, layout.totalContentWidth, accuracy: 1, "after first layout")
        window.setContentSize(NSSize(width: 600, height: 500))
        window.layoutIfNeeded()
        XCTAssertEqual(table.frame.width, layout.totalContentWidth, accuracy: 1, "after growing the window")
    }

    func test_fewRows_stillFillTheViewport() throws {
        // Fewer rows than fit: the table may fill the viewport, but no more.
        let (_, table, window, _, _) = try makeGrid(rows: 3, columns: 2)
        let clip = table.enclosingScrollView!.contentView.bounds.height
        XCTAssertLessThanOrEqual(table.frame.height, max(clip, 3 * pitch))
        window.setContentSize(NSSize(width: 600, height: 500))
        window.layoutIfNeeded()
        XCTAssertLessThanOrEqual(table.frame.height, max(table.enclosingScrollView!.contentView.bounds.height, 3 * pitch))
    }

    func test_swiftUIHostedWithStatusBar_endsAtLastRow() throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()
        try conn.execute("CREATE VIEW v AS SELECT i AS id FROM range(1000) t(i)")
        let coordinator = DataGridCoordinator(connection: conn)
        coordinator.switchTo(view: "v", columns: [ColumnInfo(name: "id", sourceIndex: 0)])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DataGrid(coordinator: coordinator)
            .safeAreaInset(edge: .bottom, spacing: 0) { Text("status").frame(height: 24) })
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        func find(_ v: NSView) -> NSTableView? { (v as? NSTableView) ?? v.subviews.lazy.compactMap(find).first }
        let table = try XCTUnwrap(find(window.contentView!))
        XCTAssertEqual(table.frame.height, 1000 * pitch)
        window.setContentSize(NSSize(width: 700, height: 600))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(table.frame.height, 1000 * pitch, "after resizing the window")
    }
}
