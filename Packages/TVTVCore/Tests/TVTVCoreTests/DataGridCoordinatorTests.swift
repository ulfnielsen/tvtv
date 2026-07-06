import XCTest
import DuckDB
@testable import TVTVCore

/// Tests for `DataGridCoordinator` — the grid's orchestration hub.
///
/// Two subtle behaviors are the focus (both isolated as pure-ish logic so they
/// test deterministically, without real timers or sleeps):
///
/// 1. **Generation-safe stale-load discard.** A `switchTo` bumps
///    `switchGeneration`; an in-flight page load tagged with the OLD generation
///    must be discarded when it resolves after the switch (its completion must
///    not mutate `dataVersion` or redraw the — now different — view). Tested by
///    resolving the stale load EXPLICITLY after the switch (deterministic
///    ordering, no sleeps).
/// 2. **Pixel-based bottom prefetch** with a `hasTriggeredBottomLoad` flag and
///    a 0.5 s re-arm. The trigger decision is a pure function
///    (`shouldTriggerBottomLoad`) tested directly; the flag/re-arm interaction
///    is tested against an injected `ManualScheduler` (no real `asyncAfter`).
@MainActor
final class DataGridCoordinatorTests: XCTestCase {

    private var database: Database!
    private var connection: Connection!

    private let columns = [
        ColumnInfo(name: "id", sourceIndex: 0),
        ColumnInfo(name: "label", sourceIndex: 1),
        ColumnInfo(name: "note", sourceIndex: 2),
    ]

    override func setUpWithError() throws {
        database = try Database(store: .inMemory)
        connection = try database.connect()
        try connection.execute("""
            CREATE VIEW coord_fixture AS
            SELECT i AS id, ('row_' || i) AS label,
                   CASE WHEN i % 5 = 0 THEN NULL ELSE ('note_' || i) END AS note
            FROM range(500) AS t(i)
            """)
    }

    override func tearDownWithError() throws {
        connection = nil
        database = nil
    }

    // Spin the main run loop until `condition` holds or timeout — lets the
    // background→main `onPageLoaded` hop run.
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Pure prefetch decision

    func test_shouldTrigger_whenViewportBottomWithin500pt() {
        // distance = contentHeight - (scrollY + viewportHeight) = 400 (< 500)
        XCTAssertTrue(DataGridCoordinator.shouldTriggerBottomLoad(
            contentHeight: 11_000, scrollY: 10_200, viewportHeight: 400,
            hasTriggered: false))
    }

    func test_shouldNotTrigger_whenBeyond500pt() {
        // distance = 1000 (> 500)
        XCTAssertFalse(DataGridCoordinator.shouldTriggerBottomLoad(
            contentHeight: 11_000, scrollY: 9_600, viewportHeight: 400,
            hasTriggered: false))
    }

    func test_shouldNotTrigger_atExactly500pt_strictLessThan() {
        // distance == 500 exactly; uses strict `< 500.0`, so no trigger.
        XCTAssertFalse(DataGridCoordinator.shouldTriggerBottomLoad(
            contentHeight: 11_000, scrollY: 10_100, viewportHeight: 400,
            hasTriggered: false))
    }

    func test_shouldNotTrigger_whenFlagAlreadySet() {
        XCTAssertFalse(DataGridCoordinator.shouldTriggerBottomLoad(
            contentHeight: 11_000, scrollY: 10_600, viewportHeight: 400,
            hasTriggered: true))
    }

    // MARK: - Flag + re-arm (injected clock)

    func test_bottomLoad_setsFlag_gatesRetrigger_thenRearms() {
        let scheduler = ManualScheduler()
        let coordinator = DataGridCoordinator(connection: connection, scheduler: scheduler)

        XCTAssertFalse(coordinator.hasTriggeredBottomLoad)

        // First near-bottom tick: sets the flag and schedules ONE re-arm.
        coordinator.triggerBottomLoadIfNeeded(
            contentHeight: 11_000, scrollY: 10_600, viewportHeight: 400, prefetchIndex: 0)
        XCTAssertTrue(coordinator.hasTriggeredBottomLoad)
        XCTAssertEqual(scheduler.pendingCount, 1, "one re-arm scheduled")

        // While the flag is set, further ticks must NOT re-trigger (no new
        // re-arm scheduled, flag stays set).
        coordinator.triggerBottomLoadIfNeeded(
            contentHeight: 11_000, scrollY: 10_600, viewportHeight: 400, prefetchIndex: 0)
        XCTAssertEqual(scheduler.pendingCount, 1, "no additional re-arm while flag set")

        // Fire the 0.5 s re-arm: flag clears.
        scheduler.fireAll()
        XCTAssertFalse(coordinator.hasTriggeredBottomLoad)

        // Now a fresh near-bottom tick can trigger again.
        coordinator.triggerBottomLoadIfNeeded(
            contentHeight: 11_000, scrollY: 10_600, viewportHeight: 400, prefetchIndex: 0)
        XCTAssertTrue(coordinator.hasTriggeredBottomLoad)
    }

    func test_beyond500pt_doesNothing() {
        let scheduler = ManualScheduler()
        let coordinator = DataGridCoordinator(connection: connection, scheduler: scheduler)
        coordinator.triggerBottomLoadIfNeeded(
            contentHeight: 11_000, scrollY: 9_600, viewportHeight: 400, prefetchIndex: 0)
        XCTAssertFalse(coordinator.hasTriggeredBottomLoad)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: - Generation protocol

    func test_switchTo_bumpsSwitchGeneration() {
        let coordinator = DataGridCoordinator(connection: connection, scheduler: ManualScheduler())
        let before = coordinator.switchGeneration
        coordinator.switchTo(view: "coord_fixture", columns: columns)
        XCTAssertEqual(coordinator.switchGeneration, before + 1)
        coordinator.switchTo(view: "coord_fixture", columns: columns)
        XCTAssertEqual(coordinator.switchGeneration, before + 2)
    }

    func test_currentGenerationLoad_incrementsDataVersion() {
        let coordinator = DataGridCoordinator(connection: connection, scheduler: ManualScheduler())
        coordinator.switchTo(view: "coord_fixture", columns: columns)
        let versionBefore = coordinator.dataVersion

        coordinator.applyPageLoaded(range: 0..<100, generation: coordinator.switchGeneration)
        XCTAssertEqual(coordinator.dataVersion, versionBefore + 1)
    }

    /// The core stale-load test — deterministic (no sleeps): a load tagged with
    /// the OLD generation resolves AFTER a `switchTo` and must be ignored.
    func test_staleLoad_fromOldGeneration_isDiscarded() {
        let coordinator = DataGridCoordinator(connection: connection, scheduler: ManualScheduler())

        // View A becomes active; a page load is kicked off (captures gen G1).
        coordinator.switchTo(view: "coord_fixture", columns: columns)
        let staleGeneration = coordinator.switchGeneration

        // The user switches to View B before A's load resolves (gen -> G2).
        coordinator.switchTo(view: "coord_fixture", columns: columns)
        let versionAfterSwitch = coordinator.dataVersion

        // Now A's slow load finally resolves, carrying the STALE generation.
        coordinator.applyPageLoaded(range: 0..<100, generation: staleGeneration)

        XCTAssertEqual(coordinator.dataVersion, versionAfterSwitch,
                       "a load from the old generation must NOT mutate state")

        // A load carrying the CURRENT generation is still applied normally.
        coordinator.applyPageLoaded(range: 0..<100, generation: coordinator.switchGeneration)
        XCTAssertEqual(coordinator.dataVersion, versionAfterSwitch + 1,
                       "a current-generation load is applied")
    }

    // MARK: - Visible-rows debounce

    func test_visibleRows_areDebouncedThenPublished() {
        let scheduler = ManualScheduler()
        let coordinator = DataGridCoordinator(connection: connection, scheduler: scheduler)
        coordinator.switchTo(view: "coord_fixture", columns: columns)

        // A visible-range change is NOT published immediately (debounced 0.1 s).
        coordinator.handleVisibleRows(first: 5, last: 20)
        XCTAssertEqual(coordinator.visibleFirstRow, 0)
        XCTAssertEqual(coordinator.visibleLastRow, 0)

        // A rapid second change supersedes the first (cancel-and-reschedule).
        coordinator.handleVisibleRows(first: 6, last: 25)

        // Fire the debounce: only the latest range is published.
        scheduler.fireAll()
        XCTAssertEqual(coordinator.visibleFirstRow, 6)
        XCTAssertEqual(coordinator.visibleLastRow, 25)
    }

    // MARK: - Integration: prefetch -> ensureLoaded -> onPageLoaded -> dataVersion

    /// End-to-end (real in-memory DuckDB): driving the visible range near the
    /// content bottom must call `RowStore.ensureLoaded`, whose completion —
    /// forwarded through the coordinator's owned `onPageLoaded` slot — bumps
    /// `dataVersion`. This proves the whole prefetch→load→forward→bookkeeping
    /// chain, including the background→main hop.
    func test_prefetch_triggersRealLoad_andForwardsToDataVersion() {
        let coordinator = DataGridCoordinator(connection: connection)  // real scheduler
        coordinator.switchTo(view: "coord_fixture", columns: columns)
        XCTAssertEqual(coordinator.totalRowCount, 500)
        XCTAssertEqual(coordinator.dataVersion, 0)

        let last = coordinator.totalRowCount - 1  // scrolled to the very bottom
        coordinator.handleVisibleRows(first: last - 10, last: last)

        spin(until: { coordinator.dataVersion >= 1 })
        XCTAssertGreaterThanOrEqual(coordinator.dataVersion, 1,
                                    "the prefetched page load forwarded a dataVersion bump")
    }

    /// Regression test: `handleVisibleRows` must load the
    /// page(s) backing the CURRENTLY VISIBLE range itself
    /// (`rowStore.ensureLoaded(around: first/last)`), not rely on the
    /// bottom-prefetch path to happen to cover it. Before the fix, a viewport
    /// at the TOP of a large view — nowhere near the content bottom — never
    /// triggered any load, so the grid rendered blank on first open.
    ///
    /// Uses a 25,000-row view (pageSize 10000, so page 0 sits far from the
    /// content bottom) and a viewport of `first: 0, last: 30` — a top
    /// viewport whose distance-to-bottom is enormous, well past the 500 pt
    /// `bottomLoadThreshold`. So if this test passes, it can only be because
    /// the visible-range `ensureLoaded` calls fired; the bottom-prefetch path
    /// is provably not in play (asserted via `hasTriggeredBottomLoad` staying
    /// false).
    ///
    /// Mutation-tested: temporarily deleting the two
    /// `rowStore?.ensureLoaded(around:)` lines in `handleVisibleRows` makes
    /// this test time out / fail (dataVersion never bumps) — confirming it
    /// actually pins the fix rather than passing vacuously.
    func test_visibleRows_atTop_loadsVisiblePage_withoutBottomPrefetch() throws {
        try connection.execute("""
            CREATE VIEW coord_fixture_large AS
            SELECT i AS id, ('row_' || i) AS label,
                   CASE WHEN i % 5 = 0 THEN NULL ELSE ('note_' || i) END AS note
            FROM range(25000) AS t(i)
            """)

        let coordinator = DataGridCoordinator(connection: connection)  // real scheduler
        coordinator.switchTo(view: "coord_fixture_large", columns: columns)
        XCTAssertEqual(coordinator.totalRowCount, 25_000)
        XCTAssertEqual(coordinator.dataVersion, 0)

        // A top viewport: nowhere near the content bottom.
        coordinator.handleVisibleRows(first: 0, last: 30)

        spin(until: { coordinator.dataVersion >= 1 })
        XCTAssertGreaterThanOrEqual(coordinator.dataVersion, 1,
                                    "the visible top page must load without relying on bottom prefetch")
        XCTAssertFalse(coordinator.hasTriggeredBottomLoad,
                        "sanity: a top viewport this far from the bottom must not trigger bottom prefetch")
    }
}

// MARK: - Test double: a manually-driven scheduler

/// A `GridScheduler` that records scheduled work instead of dispatching it, so
/// tests fire the 0.5 s re-arm / 0.1 s debounce deterministically via
/// `fireAll()` — no real timers, no flakiness.
@MainActor
private final class ManualScheduler: GridScheduler {
    private var pending: [Int: () -> Void] = [:]
    private var nextID = 0

    var pendingCount: Int { pending.count }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> GridSchedulerToken {
        let id = nextID
        nextID += 1
        pending[id] = work
        return ManualToken { [weak self] in self?.pending[id] = nil }
    }

    func fireAll() {
        let work = pending
        pending = [:]
        for closure in work.values { closure() }
    }
}

@MainActor
private final class ManualToken: GridSchedulerToken {
    private let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}
