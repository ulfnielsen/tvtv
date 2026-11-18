import AppKit
import XCTest

final class WindowCommandTests: XCTestCase {
    @MainActor
    func testCommandWIsAvailableInFileMenu() throws {
        let fileMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
        let shortcut = fileMenu.items.first {
            $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command
        }
        XCTAssertNotNil(shortcut, "The File menu must retain Command-W alongside the custom save commands")
    }
}
