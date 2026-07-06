import XCTest
@testable import TVTVCore

final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(TVTVCore.moduleName, "TVTVCore")
    }
}
