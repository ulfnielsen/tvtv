import XCTest
import AppKit
import SwiftUI
import DuckDB
@testable import TVTVCore

/// Keyboard row navigation driven end-to-end: the real `DataGrid` SwiftUI
/// wrapper in an `NSHostingView`, a real multi-page DuckDB view, and real
/// `NSEvent`s delivered through `NSWindow.sendEvent` (the same path AppKit
/// uses), so focus/first-responder behavior is exercised, not just the
/// selection math.
@MainActor
final class KeyboardNavigationTests: XCTestCase {

    private var database: Database!
    private var connection: Connection!
    private var coordinator: DataGridCoordinator!
    private var window: NSWindow!

    /// Built per test (not in setUp, which is nonisolated under Swift 6).
    private func host() throws {
        _ = NSApplication.shared
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW nav_fixture AS
            SELECT i AS id, ('row_' || i) AS label FROM range(25000) AS t(i)
            """)
        coordinator = DataGridCoordinator(connection: connection)
        coordinator.switchTo(view: "nav_fixture",
                             columns: [ColumnInfo(name: "id", sourceIndex: 0),
                                       ColumnInfo(name: "label", sourceIndex: 1)])
        let host = NSHostingView(rootView: GridHost(coordinator: coordinator))
        window = KeyTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        spin(until: { self.table != nil })
    }

    /// A headless test process is never the active app, so its windows never
    /// become key and AppKit drops clicks on them. Claim key status so mouse
    /// events take the normal path (hit-test → first responder → mouseDown).
    private final class KeyTestWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// Mirrors how ContentView embeds the grid (reads observable state the
    /// same way, so selection changes re-render the hosting body).
    private struct GridHost: View {
        let coordinator: DataGridCoordinator
        var body: some View {
            DataGrid(coordinator: coordinator)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Text("\(coordinator.totalRowCount) rows · \(coordinator.selectedRowCount) selected")
                }
        }
    }

    /// Like ContentView: a @FocusState search field beside the grid, with a
    /// status line that re-renders on every selection change.
    private struct FocusHost: View {
        let coordinator: DataGridCoordinator
        @FocusState private var searchFocused: Bool
        @State private var text = ""
        var body: some View {
            VStack(spacing: 0) {
                TextField("Find", text: $text).focused($searchFocused)
                DataGrid(coordinator: coordinator)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Text("\(coordinator.totalRowCount) rows · \(coordinator.selectedRowCount) selected")
                    }
            }
            .onAppear { DispatchQueue.main.async { searchFocused = true } }
        }
    }

    private func hostWithSearchField() throws {
        try host()
        window.contentView = NSHostingView(rootView: FocusHost(coordinator: coordinator))
        window.layoutIfNeeded()
        spin(until: { self.table != nil && self.window.firstResponder is NSTextView })
    }

    // MARK: Helpers

    private var table: NSTableView? {
        func find(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Wait until SwiftUI has installed the coordinator's CURRENT grid (a
    /// sort/filter builds a new one; the swap lands on a later run-loop turn).
    private func waitForCurrentGrid() {
        spin(until: {
            guard let grid = self.coordinator.gridView else { return false }
            return grid.window === self.window
        })
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func click(row: Int) {
        guard let table else { return XCTFail("no table") }
        let rect = table.rect(ofRow: row)
        let p = table.convert(NSPoint(x: 30, y: rect.midY), to: nil)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 0, clickCount: 1, pressure: 0)!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(up, atStart: false) // consumed by the table's tracking loop
        // Not window.sendEvent: an inactive (headless) app's windows swallow the
        // first click. Deliver to the hit view, as NSWindow does after its
        // first-responder step (RowContentView refuses focus, so that step is
        // a no-op here anyway; the table takes focus in its own mouseDown).
        let hit = window.contentView!.hitTest(window.contentView!.convert(p, from: nil))!
        hit.mouseDown(with: down)
        settle(0.1)
    }

    private func key(_ code: UInt16, _ scalar: Int, flags: NSEvent.ModifierFlags = []) {
        let chars = String(UnicodeScalar(scalar)!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: flags.union([.function, .numericPad]),
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    private func down(_ flags: NSEvent.ModifierFlags = []) { key(125, NSDownArrowFunctionKey, flags: flags) }
    private func up(_ flags: NSEvent.ModifierFlags = []) { key(126, NSUpArrowFunctionKey, flags: flags) }
    private func pageDown() { key(121, NSPageDownFunctionKey) }
    private func pageUp() { key(116, NSPageUpFunctionKey) }
    private func end() { key(119, NSEndFunctionKey) }
    private func home() { key(115, NSHomeFunctionKey) }

    private var state: String {
        let fr = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "firstResponder=\(fr) selected=\(Array(table?.selectedRowIndexes ?? []).prefix(5))"
    }

    // MARK: Tests

    /// The selected row's position on screen, in rows from the top edge.
    private func selectedRowOnScreen() -> CGFloat {
        guard let table, let clip = table.enclosingScrollView?.contentView else { return .nan }
        return (table.rect(ofRow: table.selectedRow).minY - clip.bounds.minY) / 22
    }

    func test_pageKeys_scrollByAPage_andKeepSelectedRowInPlace() throws {
        try host()
        defer { window.orderOut(nil) }
        guard let table, let clip = table.enclosingScrollView?.contentView else { return XCTFail("no table") }
        let pageRows = Int(clip.bounds.height / 22)
        click(row: 0)
        for _ in 0..<3 { down() }                     // selection 3 rows below the top edge
        let onScreen = selectedRowOnScreen()
        XCTAssertEqual(onScreen, 3, accuracy: 0.01)

        pageDown()
        XCTAssertEqual(table.selectedRow, 3 + pageRows, state)
        XCTAssertEqual(clip.bounds.minY / 22, CGFloat(pageRows), accuracy: 0.01, "view scrolled exactly one page")
        XCTAssertEqual(selectedRowOnScreen(), onScreen, accuracy: 0.01, "selected row kept its place")

        pageDown()
        XCTAssertEqual(table.selectedRow, 3 + 2 * pageRows, state)
        XCTAssertEqual(selectedRowOnScreen(), onScreen, accuracy: 0.01)

        pageUp()
        XCTAssertEqual(table.selectedRow, 3 + pageRows, state)
        XCTAssertEqual(selectedRowOnScreen(), onScreen, accuracy: 0.01, "Page Up doesn't flip the row to the top edge")

        pageUp()
        XCTAssertEqual(table.selectedRow, 3, state)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.01)

        pageUp()                                       // at the top: view can't move, selection goes to row 0
        XCTAssertEqual(table.selectedRow, 0, state)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.01)
    }

    func test_pageDownAtEnd_clampsToLastRow_andStaysVisible() throws {
        try host()
        defer { window.orderOut(nil) }
        guard let table, let clip = table.enclosingScrollView?.contentView else { return XCTFail("no table") }
        click(row: 0)
        end()
        settle(0.1)
        pageUp()
        let afterUp = table.selectedRow
        pageDown()
        XCTAssertEqual(table.selectedRow, 24_999, state)
        let row = table.rect(ofRow: 24_999)
        XCTAssertTrue(clip.bounds.contains(NSPoint(x: 1, y: row.midY)), "last row visible after Page Down at the end")
        XCTAssertLessThan(afterUp, 24_999)
    }

    func test_pageDown_whenSelectionScrolledOffScreen_bringsItBack() throws {
        try host()
        defer { window.orderOut(nil) }
        guard let table, let clip = table.enclosingScrollView?.contentView else { return XCTFail("no table") }
        click(row: 2)
        clip.scroll(to: NSPoint(x: 0, y: 5000 * 22))     // trackpad-scroll far away
        table.enclosingScrollView?.reflectScrolledClipView(clip)
        pageDown()
        let row = table.rect(ofRow: table.selectedRow)
        XCTAssertTrue(clip.bounds.intersects(row), "selected row \(table.selectedRow) is on screen after Page Down — \(state)")
    }


    func test_afterUsingSearchField_clickedGridKeepsFocusWhileArrowing() throws {
        try hostWithSearchField()
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.firstResponder is NSTextView, "precondition: search field focused — \(state)")
        click(row: 3)
        XCTAssertTrue(window.firstResponder === table, state)
        for i in 1...8 {
            down()
            settle(0.1) // let SwiftUI re-render the status line between keys
            XCTAssertTrue(window.firstResponder === table, "after ↓ #\(i): \(state)")
            XCTAssertEqual(table?.selectedRow, 3 + i, "after ↓ #\(i): \(state)")
        }
    }

    func test_newGridTakesFocusWhenNothingElseHasIt() throws {
        try host() // fresh open: the window holds focus, no click yet
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.firstResponder === table, state)
        down()
        XCTAssertEqual(table?.selectedRow, 0, "↓ right after opening selects the first row: \(state)")
    }

    func test_newGridDoesNotStealFocusFromSearchField() throws {
        try hostWithSearchField()
        defer { window.orderOut(nil) }
        coordinator.toggleSort(columnSourceIndex: 0)
        waitForCurrentGrid()
        XCTAssertTrue(window.firstResponder is NSTextView, "search field keeps focus: \(state)")
    }

    func test_selectedRowStaysAboveStatusBar() throws {
        try host()
        defer { window.orderOut(nil) }
        guard let table, let scroll = table.enclosingScrollView else { return XCTFail("no table") }
        click(row: 0)
        for _ in 0..<40 { down() }
        settle(0.2)
        let row = table.convert(table.rect(ofRow: table.selectedRow), to: nil)
        let viewport = scroll.convert(scroll.bounds, to: nil)
        XCTAssertTrue(viewport.contains(row), "selected row \(row) inside visible grid \(viewport)")
    }

    func test_gridKeepsKeyboardFocusAcrossSortAndFilter() throws {
        try host()
        defer { window.orderOut(nil) }
        click(row: 3)
        XCTAssertTrue(window.firstResponder === table, state)

        coordinator.toggleSort(columnSourceIndex: 0)
        waitForCurrentGrid()
        XCTAssertTrue(window.firstResponder === table, "after sort: \(state)")
        down()
        XCTAssertEqual(table?.selectedRow, 0, "↓ after sort starts at the top: \(state)")

        coordinator.setExcluded(["row_1"], forColumn: "label")
        waitForCurrentGrid()
        XCTAssertTrue(window.firstResponder === table, "after filter: \(state)")
    }

    func test_clickMakesGridFirstResponder_thenArrowsMoveSelection() throws {
        try host()
        defer { window.orderOut(nil) }
        click(row: 3)
        XCTAssertTrue(window.firstResponder === table, state)
        XCTAssertEqual(table?.selectedRow, 3, state)

        for _ in 0..<5 { down() }
        XCTAssertEqual(table?.selectedRow, 8, state)
        up()
        XCTAssertEqual(table?.selectedRow, 7, state)
    }

    func test_focusAndSelectionSurvivePageLoadsAndRedraws() throws {
        try host()
        defer { window.orderOut(nil) }
        click(row: 0)
        for i in 0..<60 {
            down()
            if i % 10 == 0 { settle(0.15) } // let page loads + SwiftUI updates land mid-run
        }
        settle(0.5)
        XCTAssertTrue(window.firstResponder === table, state)
        XCTAssertEqual(table?.selectedRow, 60, state)
    }

    func test_pageDownEndHome_acrossPageBoundaries() throws {
        try host()
        defer { window.orderOut(nil) }
        click(row: 0)
        end()
        settle()
        XCTAssertEqual(table?.selectedRow, 24_999, state)
        XCTAssertTrue(window.firstResponder === table, state)
        up()
        XCTAssertEqual(table?.selectedRow, 24_998, state)
        home()
        settle()
        XCTAssertEqual(table?.selectedRow, 0, state)
        pageDown()
        XCTAssertGreaterThan(table?.selectedRow ?? 0, 5, state)
        let afterPage = table?.selectedRow ?? -1
        down()
        XCTAssertEqual(table?.selectedRow, afterPage + 1, "↓ after Page Down continues from the new row — \(state)")
    }

    func test_shiftArrowAfterPageDown_extendsFromCurrentRow() throws {
        try host()
        defer { window.orderOut(nil) }
        click(row: 10)
        pageDown()
        let row = table?.selectedRow ?? -1
        down(.shift)
        XCTAssertEqual(table?.selectedRowIndexes, IndexSet([row, row + 1]), state)
    }
}
