import XCTest
@testable import TVTVCore

/// Unit tests for the minimap's pure, view-independent math
/// (`MinimapOverlayView`).
///
/// Two pieces are pinned here:
/// 1. `MinimapOverlayView.indicatorFrame(area:fx:fy:fw:fh:)` — the
///    `updateViewport(_:)` frame math (min 4×4 clamp, clamped
///    inside `area`).
/// 2. `GridTableView.minimapFraction(contentSize:visibleRect:)` — deriving
///    the origin/size fractions from the document's content size and the
///    scroll view's visible rect, which `GridTableView` feeds into (1).
final class MinimapTests: XCTestCase {

    // MARK: - indicatorFrame

    func test_indicatorFrame_clampsToMinimumSizeWhenFractionsAreTiny() {
        let area = CGRect(x: 0, y: 0, width: 140, height: 90)
        let frame = MinimapOverlayView.indicatorFrame(area: area, fx: 0, fy: 0, fw: 0.001, fh: 0.001)
        XCTAssertEqual(frame.width, 4, "width below the 4pt floor must clamp up")
        XCTAssertEqual(frame.height, 4, "height below the 4pt floor must clamp up")
        XCTAssertEqual(frame.origin, .zero)
    }

    func test_indicatorFrame_isFullAreaWhenFractionsAreOne() {
        let area = CGRect(x: 0, y: 0, width: 140, height: 90)
        let frame = MinimapOverlayView.indicatorFrame(area: area, fx: 0, fy: 0, fw: 1, fh: 1)
        XCTAssertEqual(frame, area)
    }

    func test_indicatorFrame_positionsAtHalfFractions() {
        let area = CGRect(x: 0, y: 0, width: 140, height: 90)
        let frame = MinimapOverlayView.indicatorFrame(area: area, fx: 0.5, fy: 0.5, fw: 0.2, fh: 0.2)
        // w = 140*0.2 = 28, h = 90*0.2 = 18
        // px = min(0 + 0.5*140, 140-28) = min(70, 112) = 70
        // py = min(0 + 0.5*90, 90-18)  = min(45, 72)  = 45
        XCTAssertEqual(frame, CGRect(x: 70, y: 45, width: 28, height: 18))
    }

    func test_indicatorFrame_clampsInsideAreaWhenOriginFractionIsOne() {
        let area = CGRect(x: 0, y: 0, width: 140, height: 90)
        let frame = MinimapOverlayView.indicatorFrame(area: area, fx: 1, fy: 1, fw: 0.2, fh: 0.2)
        // w = 28, h = 18. Without clamping px would be area.minX + 1*140 = 140
        // (off the right edge); clamped to area.maxX - w = 112.
        XCTAssertEqual(frame.origin.x, area.maxX - 28)
        XCTAssertEqual(frame.origin.y, area.maxY - 18)
        XCTAssertLessThanOrEqual(frame.maxX, area.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, area.maxY)
    }

    func test_indicatorFrame_respectsNonZeroOriginArea() {
        // `updateViewport` insets `bounds` to get `area`, so `area.minX`/
        // `minY` aren't necessarily 0 — the frame math must be relative to
        // area's own origin, not the view's.
        let area = CGRect(x: 3, y: 3, width: 134, height: 84)
        let frame = MinimapOverlayView.indicatorFrame(area: area, fx: 0, fy: 0, fw: 1, fh: 1)
        XCTAssertEqual(frame, area)
    }

    // MARK: - minimapFraction

    func test_minimapFraction_computesFractionsFromContentAndVisibleRect() {
        let content = CGSize(width: 1000, height: 2000)
        let visible = CGRect(x: 100, y: 200, width: 250, height: 500)
        let fraction = GridTableView.minimapFraction(contentSize: content, visibleRect: visible)
        XCTAssertEqual(fraction?.fx, 0.1)
        XCTAssertEqual(fraction?.fy, 0.1)
        XCTAssertEqual(fraction?.fw, 0.25)
        XCTAssertEqual(fraction?.fh, 0.25)
    }

    func test_minimapFraction_isNilWhenContentWidthIsZero() {
        let content = CGSize(width: 0, height: 2000)
        let visible = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(GridTableView.minimapFraction(contentSize: content, visibleRect: visible))
    }

    func test_minimapFraction_isNilWhenContentHeightIsZero() {
        let content = CGSize(width: 1000, height: 0)
        let visible = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(GridTableView.minimapFraction(contentSize: content, visibleRect: visible))
    }

    func test_minimapFraction_isFullWhenVisibleMatchesContent() {
        let content = CGSize(width: 500, height: 500)
        let visible = CGRect(x: 0, y: 0, width: 500, height: 500)
        let fraction = GridTableView.minimapFraction(contentSize: content, visibleRect: visible)
        XCTAssertEqual(fraction?.fw, 1)
        XCTAssertEqual(fraction?.fh, 1)
    }

    // MARK: - hitTest pass-through

    /// The minimap is a non-interactive indicator that sits frontmost over
    /// the grid's bottom-right corner, which is also where both scrollbars
    /// terminate. Pins the `hitTest(_:)` override that makes every point
    /// return `nil` so mouse-down/scroll-wheel events fall through to the
    /// scrollView/scrollers/grid underneath instead of being captured by the
    /// overlay. Regression coverage for review finding: without this
    /// override AppKit's default `hitTest(_:)` returns `self`, silently
    /// breaking scroll and scrollbar-dragging over that corner.
    func test_hitTest_interactiveInsideBounds_passesThroughOutside() {
        let view = MinimapOverlayView(
            frame: CGRect(x: 0, y: 0, width: MinimapOverlayView.size.width, height: MinimapOverlayView.size.height)
        )
        // The minimap is interactive (click-to-jump), so points inside its
        // bounds hit it.
        XCTAssertEqual(view.hitTest(NSPoint(x: 70, y: 45)), view)
        // A point outside its bounds passes through (returns nil).
        XCTAssertNil(view.hitTest(NSPoint(x: -10, y: -10)))
        XCTAssertNil(view.hitTest(NSPoint(x: 500, y: 500)))
    }

    /// Click-to-jump: the vertical fraction is 0 at the top of the drawable
    /// area, 1 at the bottom, clamped outside, and the view is flipped (y
    /// grows downward) so a low y maps to a low fraction (top).
    func test_fraction_mapsVerticalPositionToZeroOneClamped() {
        let view = MinimapOverlayView(
            frame: CGRect(x: 0, y: 0, width: MinimapOverlayView.size.width, height: MinimapOverlayView.size.height)
        )
        let inset = MinimapOverlayView.areaInset
        let height = MinimapOverlayView.size.height - inset * 2
        // Top of the drawable area → 0.
        XCTAssertEqual(view.fractions(at: NSPoint(x: 70, y: inset)).y, 0, accuracy: 0.001)
        // Middle → 0.5.
        XCTAssertEqual(view.fractions(at: NSPoint(x: 70, y: inset + height / 2)).y, 0.5, accuracy: 0.001)
        // Bottom → 1.
        XCTAssertEqual(view.fractions(at: NSPoint(x: 70, y: inset + height)).y, 1, accuracy: 0.001)
        // Above the top / below the bottom clamp to 0 / 1.
        XCTAssertEqual(view.fractions(at: NSPoint(x: 70, y: -50)).y, 0, accuracy: 0.001)
        XCTAssertEqual(view.fractions(at: NSPoint(x: 70, y: 999)).y, 1, accuracy: 0.001)
    }

    /// Click-to-jump also maps the horizontal position (for horizontal scroll):
    /// 0 at the left of the drawable area, 1 at the right, clamped.
    func test_fraction_mapsHorizontalPositionToZeroOneClamped() {
        let view = MinimapOverlayView(
            frame: CGRect(x: 0, y: 0, width: MinimapOverlayView.size.width, height: MinimapOverlayView.size.height)
        )
        let inset = MinimapOverlayView.areaInset
        let width = MinimapOverlayView.size.width - inset * 2
        XCTAssertEqual(view.fractions(at: NSPoint(x: inset, y: 45)).x, 0, accuracy: 0.001)
        XCTAssertEqual(view.fractions(at: NSPoint(x: inset + width / 2, y: 45)).x, 0.5, accuracy: 0.001)
        XCTAssertEqual(view.fractions(at: NSPoint(x: inset + width, y: 45)).x, 1, accuracy: 0.001)
        XCTAssertEqual(view.fractions(at: NSPoint(x: -50, y: 45)).x, 0, accuracy: 0.001)
        XCTAssertEqual(view.fractions(at: NSPoint(x: 999, y: 45)).x, 1, accuracy: 0.001)
    }
}
