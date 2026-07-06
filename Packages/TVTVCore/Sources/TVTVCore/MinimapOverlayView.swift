import AppKit

/// A small scroll-position overview shown over the bottom-right corner of
/// the grid, with a moving viewport-indicator rectangle.
///
/// ## Layer-backed, not drawRect
///
/// This view is **CALayer-backed** rather than `drawRect:`-based: it owns a
/// `viewportLayer` (the moving indicator rectangle) plus a background
/// sublayer, built in `init(frame:)` and resized to the inset bounds in
/// `layout()`.
///
/// - `wantsLayer = true`; `backgroundLayer` and `viewportLayer` are plain
///   `CALayer`s added as sublayers in that order (background behind,
///   indicator on top).
/// - `layout()` resizes `backgroundLayer` to `bounds` inset by `areaInset`,
///   the same inset the indicator area uses, so the background reads as a
///   margin around the indicator rather than filling the view edge-to-edge.
/// - `updateViewport(fx:fy:fw:fh:)` repositions `viewportLayer` (via
///   `indicatorFrame`), inside a non-animating `CATransaction` so the
///   indicator tracks scroll crisply instead of drifting through an
///   implicit layer animation.
///
/// ## Simplification: no density heatmap
///
/// `backgroundLayer` here is a plain subtle translucent fill rather than a
/// real per-row density visualization — out of scope (YAGNI) for what the
/// minimap needs to do.
///
/// ## Coordinate space
///
/// `GridTableView`'s `NSTableView` is AppKit-flipped (row 0 at the top), so
/// the visible-fraction `fy` the host computes is measured from the top of
/// the content. This view overrides `isFlipped` to match, so `fy == 0` maps
/// to the top of the minimap too — without that, the indicator would track
/// vertical scroll upside down.
public final class MinimapOverlayView: NSView {

    // MARK: Layout constants

    /// Minimap size.
    public static let size = CGSize(width: 140, height: 90)

    /// Inset from the host container's bottom-right corner.
    public static let containerMargin: CGFloat = 24

    /// Minimum indicator dimension — the `max(4.0, ...)` clamp in
    /// `updateViewport`.
    public static let minimumIndicatorDimension: CGFloat = 4

    /// Small inset applied to `bounds` to get the indicator's drawable
    /// "area" in `updateViewport`. Chosen small enough to read as a margin
    /// around the indicator.
    public static let areaInset: CGFloat = 3

    // MARK: Layer tree

    private let backgroundLayer = CALayer()
    private let viewportLayer = CALayer()

    // MARK: Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildLayerTree()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    /// Called on click/drag with the (x, y) fractions (0…1) of the drawable
    /// area the pointer is at, so the host can scroll the grid to that
    /// position both vertically AND horizontally. The minimap is interactive
    /// (click-to-jump).
    public var onJump: ((_ fx: CGFloat, _ fy: CGFloat) -> Void)?

    /// The minimap is interactive (click/drag to jump), so it must receive
    /// mouse events — return `self` for points inside. It occupies only the
    /// 140×90 bottom-right corner, so this claims a small region; scroll-wheel
    /// events over that corner are forwarded on (see `scrollWheel`).
    public override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// The (x, y) fractions (0…1) of the drawable area for a point in view
    /// coordinates (flipped: y grows downward, so y=area.minY → 0).
    /// Internal for testing.
    func fractions(at point: NSPoint) -> (x: CGFloat, y: CGFloat) {
        let area = bounds.insetBy(dx: Self.areaInset, dy: Self.areaInset)
        let fx = area.width > 0 ? min(1, max(0, (point.x - area.minX) / area.width)) : 0
        let fy = area.height > 0 ? min(1, max(0, (point.y - area.minY) / area.height)) : 0
        return (fx, fy)
    }

    public override func mouseDown(with event: NSEvent) {
        let f = fractions(at: convert(event.locationInWindow, from: nil))
        onJump?(f.x, f.y)
    }

    public override func mouseDragged(with event: NSEvent) {
        let f = fractions(at: convert(event.locationInWindow, from: nil))
        onJump?(f.x, f.y)
    }

    /// Don't swallow scroll-wheel over the corner — pass it up so the grid
    /// still scrolls when the pointer happens to be over the minimap.
    public override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    private func buildLayerTree() {
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        backgroundLayer.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        backgroundLayer.borderWidth = 1
        backgroundLayer.cornerRadius = 6
        backgroundLayer.frame = bounds.insetBy(dx: Self.areaInset, dy: Self.areaInset)
        layer?.addSublayer(backgroundLayer)

        viewportLayer.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        viewportLayer.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        viewportLayer.borderWidth = 1
        viewportLayer.cornerRadius = 2
        layer?.addSublayer(viewportLayer)
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        // Resizes the background sublayer to the (inset) bounds every time
        // the view's size changes. Reuses the same `areaInset` as
        // `updateViewport`'s indicator `area`, for consistency.
        backgroundLayer.frame = bounds.insetBy(dx: Self.areaInset, dy: Self.areaInset)
    }

    // MARK: Viewport tracking

    /// Repositions `viewportLayer` to reflect the currently-visible fraction
    /// of the grid's content.
    ///
    /// - Parameters:
    ///   - fx: origin-x fraction of the visible viewport within the total
    ///     content (0...1).
    ///   - fy: origin-y fraction of the visible viewport within the total
    ///     content (0...1).
    ///   - fw: width fraction of the visible viewport within the total
    ///     content (0...1).
    ///   - fh: height fraction of the visible viewport within the total
    ///     content (0...1).
    public func updateViewport(fx: CGFloat, fy: CGFloat, fw: CGFloat, fh: CGFloat) {
        let area = bounds.insetBy(dx: Self.areaInset, dy: Self.areaInset)
        let frame = Self.indicatorFrame(area: area, fx: fx, fy: fy, fw: fw, fh: fh)
        // Wrapped in a non-animating transaction so the indicator tracks
        // scroll crisply instead of drifting through CALayer's implicit
        // position/bounds animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewportLayer.frame = frame
        CATransaction.commit()
    }

    /// Pure, view-independent math for the viewport-indicator frame —
    /// extracted so it can be unit-tested without an `NSView`.
    ///
    /// ```
    /// let w = max(4.0, area.width  * fw)
    /// let h = max(4.0, area.height * fh)
    /// let px = min(area.minX + fx * area.width,  area.maxX - w)
    /// let py = min(area.minY + fy * area.height, area.maxY - h)
    /// ```
    public static func indicatorFrame(
        area: CGRect,
        fx: CGFloat,
        fy: CGFloat,
        fw: CGFloat,
        fh: CGFloat
    ) -> CGRect {
        let w = max(minimumIndicatorDimension, area.width * fw)
        let h = max(minimumIndicatorDimension, area.height * fh)
        let px = min(area.minX + fx * area.width, area.maxX - w)
        let py = min(area.minY + fy * area.height, area.maxY - h)
        return CGRect(x: px, y: py, width: w, height: h)
    }
}
