import AppKit
import SwiftUI

/// SwiftUI wrapper that hosts the grid engine's two AppKit views — a
/// `GridTableHeaderView` on top and a `GridTableView` below — inside a single
/// container and keeps them in sync with a `DataGridCoordinator`.
///
/// ## What it hosts
///
/// The coordinator owns and rebuilds `headerView` / `gridView` on every
/// `switchTo`. `DataGrid` does NOT create those views; it reads them off the
/// coordinator and installs them into a `GridContainerView`, swapping in the
/// new instances whenever the coordinator rebuilds them (a new file/table).
///
/// ## How it stays live (`@Observable` → `updateNSView`)
///
/// `DataGridCoordinator` is `@Observable`. This struct reads
/// `switchGeneration` and `dataVersion` at init time (during the enclosing
/// SwiftUI `body`), which registers an observation dependency on them. So when
/// the user switches views (`switchGeneration` bumps) or a page load is applied
/// (`dataVersion` bumps), the enclosing `body` re-evaluates, SwiftUI calls
/// `updateNSView`, and we reconcile the hosted views. Redraw of just-loaded rows
/// is already driven by the coordinator (`applyPageLoaded` → `reloadVisible`);
/// `updateNSView` only has to reconcile which NSViews are installed.
///
/// ## Header horizontal-scroll sync
///
/// The header is a plain full-viewport-width `NSView` that draws its columns at
/// absolute x-positions; the grid scrolls horizontally inside its own
/// `NSScrollView`. `GridContainerView` observes the grid's clip view and shifts
/// the header's `bounds` origin to match, so header labels stay aligned with the
/// columns beneath them as the grid scrolls. This is done entirely in the
/// container — no changes to the (reviewed) grid/header views.
public struct DataGrid: NSViewRepresentable {

    private let coordinator: DataGridCoordinator

    // Read from the @Observable coordinator so this view's `body` re-evaluates
    // (and `updateNSView` runs) on a view switch or an applied page load.
    private let generation: Int
    private let dataVersion: Int

    public init(coordinator: DataGridCoordinator) {
        self.coordinator = coordinator
        self.generation = coordinator.switchGeneration
        self.dataVersion = coordinator.dataVersion
    }

    public func makeNSView(context: Context) -> GridContainerView {
        let container = GridContainerView()
        container.install(header: coordinator.headerView, grid: coordinator.gridView)
        return container
    }

    public func updateNSView(_ container: GridContainerView, context: Context) {
        // `generation`/`dataVersion` are the observation triggers; reconcile the
        // hosted views (they change identity only on a switch).
        _ = (generation, dataVersion)
        container.install(header: coordinator.headerView, grid: coordinator.gridView)
    }
}

/// AppKit container that stacks a header (fixed height, top) over a grid
/// (fills the rest) and syncs the header's horizontal scroll to the grid.
public final class GridContainerView: NSView {

    /// Header strip height. Fixed for now (dynamic fit to the header labels
    /// is a later, cell-rendering-adjacent concern).
    public static let headerHeight: CGFloat = 28

    private var header: NSView?
    private var grid: NSView?
    private weak var gridClip: NSClipView?

    public override var isFlipped: Bool { true } // origin top-left: header on top

    /// Reconcile the installed header/grid with the coordinator's current
    /// instances. Idempotent: passing the same instances is a no-op beyond a
    /// relayout, so `updateNSView` can call it freely.
    public func install(header newHeader: NSView?, grid newGrid: NSView?) {
        if newHeader !== header {
            header?.removeFromSuperview()
            header = newHeader
            if let newHeader { addSubview(newHeader) }
        }
        if newGrid !== grid {
            grid?.removeFromSuperview()
            grid = newGrid
            if let newGrid { addSubview(newGrid) }
            observeGridScroll()
        }
        needsLayout = true
    }

    /// Find the grid's internal `NSScrollView` clip view and observe its bounds
    /// so we can mirror horizontal scroll onto the header.
    private func observeGridScroll() {
        if let clip = gridClip {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: clip)
            gridClip = nil
        }
        guard let scrollView = grid?.subviews.compactMap({ $0 as? NSScrollView }).first else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        gridClip = clip
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gridClipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
    }

    @objc private func gridClipBoundsChanged(_ note: Notification) {
        syncHeaderScroll()
    }

    /// Shift the header's coordinate system so its column drawing tracks the
    /// grid's horizontal scroll offset.
    private func syncHeaderScroll() {
        guard let header, let gridClip else { return }
        var b = header.bounds
        let offsetX = gridClip.bounds.origin.x
        if b.origin.x != offsetX {
            b.origin.x = offsetX
            header.bounds = b
            header.needsDisplay = true
        }
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let headerH = Self.headerHeight
        // Header keeps a viewport-width frame; its content is scrolled by
        // shifting its bounds origin (see syncHeaderScroll), so setting the
        // frame here resets only the size — re-sync afterwards.
        header?.frame = NSRect(x: 0, y: 0, width: w, height: headerH)
        grid?.frame = NSRect(x: 0, y: headerH, width: w, height: max(0, h - headerH))
        syncHeaderScroll()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
