import AppKit

/// The grid's row-background view — provides the alternating-row banding.
///
/// This implements *standard* system alternating-row banding and nothing
/// more — no invented behavior. The two shades come straight from
/// `NSColor.alternatingContentBackgroundColors`, which is exactly what
/// AppKit's own `usesAlternatingRowBackgroundColors` draws, so the banding
/// adapts to light/dark automatically.
///
/// It is vended per visible row by `GridTableView`'s
/// `tableView(_:rowViewForRow:)` and recycled by AppKit's row-view pool; the
/// even/odd parity is pushed in via `usesAlternateColor` at bind time (a
/// reused instance may serve a row of the opposite parity).
final class GrayRowView: NSTableRowView {

    /// Whether this row draws the *alternate* (second) banding color. Set by
    /// `GridTableView` from the row index's parity when the view is bound.
    var usesAlternateColor: Bool = false {
        didSet {
            if usesAlternateColor != oldValue { needsDisplay = true }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let colors = NSColor.alternatingContentBackgroundColors
        let color = (usesAlternateColor && colors.count > 1) ? colors[1] : colors[0]
        color.setFill()
        dirtyRect.fill()
    }
}
