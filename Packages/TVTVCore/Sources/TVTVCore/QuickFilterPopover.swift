import AppKit
import Observation
import SwiftUI

/// Holds a column's distinct-values fetch as it progresses from "loading" to
/// "loaded", shared by reference between `DataGridCoordinator` (the writer,
/// once the background query resolves) and the already-presented
/// `QuickFilterPopover` (the reader) — a plain `[String]` snapshot handed to
/// the view's `init` can't be updated after the popover is already on
/// screen, which is the whole point of showing the popover immediately and
/// populating it once the async fetch resolves (see
/// `DataGridCoordinator.presentFilterPopover`'s doc). `nil` means "still
/// loading"; a non-nil (possibly empty) array means the query resolved.
@MainActor
@Observable
final class DistinctValuesLoader {
    var values: [String]?

    init(values: [String]? = nil) {
        self.values = values
    }
}

/// The per-column quick-filter popover's SwiftUI content: a scrollable
/// checklist of a column's distinct values (from
/// `DataGridCoordinator.fetchDistinctValues`) plus a synthetic "(null)" row,
/// each with a checkbox — checked means INCLUDED, unchecked means EXCLUDED.
/// This type is the popover's content view.
/// `DataGridCoordinator.presentFilterPopover(...)` hosts it in an
/// `NSPopover` shown from the header's secondary-click affordance (see
/// `GridTableHeaderView.onColumnFilterRequested`).
///
/// Deliberately minimal (YAGNI): no search-within-popover, no "select all"/
/// "select none" shortcuts — a plain checklist plus Cancel/Done.
struct QuickFilterPopover: View {
    /// The column this popover is filtering (for the title and the callback).
    let columnName: String

    /// The column's distinct non-null string values, once the (async, off-
    /// main-thread — see `DataGridCoordinator.fetchDistinctValuesAsync`)
    /// DISTINCT query resolves. `loader.values == nil` means the query is
    /// still running: the popover is shown immediately (so it never feels
    /// slow to APPEAR) with a lightweight loading row in place of the
    /// checklist, which is replaced by the real checklist the moment
    /// `loader.values` is set — `@Observable`, so this view just re-renders,
    /// no re-presenting the popover needed.
    @Bindable var loader: DistinctValuesLoader

    /// The set the checklist starts pre-checked/unchecked against — mirrors
    /// `DataGridCoordinator.excludedValues[columnName]` at popover-open time.
    @State private var excluded: Set<String>

    /// Called with the final excluded set when the user commits (Done).
    let onApply: (Set<String>) -> Void

    /// Called when the user dismisses without committing (Cancel).
    let onCancel: () -> Void

    init(
        columnName: String,
        loader: DistinctValuesLoader,
        initiallyExcluded: Set<String>,
        onApply: @escaping (Set<String>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.columnName = columnName
        self.loader = loader
        self._excluded = State(initialValue: initiallyExcluded)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    /// The pseudo-value the "(null)" row toggles — matches
    /// `DataGridCoordinator.nullSentinel` (kept as a separate constant here
    /// so this view has no compile-time dependency direction issue; the two
    /// are asserted equal in tests).
    static let nullRowValue = DataGridCoordinator.nullSentinel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(columnName)
                .font(.headline)
                .lineLimit(1)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))

            Divider()

            // A `List` (NSScrollView-backed) rather than a `ScrollView`+`VStack`:
            // it gives a proper native, correctly-inset scroller inside the
            // NSPopover (the plain ScrollView's overlay scroller mis-rendered
            // over the row content).
            Group {
                if let values = loader.values {
                    List {
                        checkRow(label: "(null)", value: Self.nullRowValue)
                        ForEach(values, id: \.self) { value in
                            checkRow(label: value, value: value)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading values…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .frame(minHeight: 220, maxHeight: 380)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Done") { onApply(excluded) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 260)
    }

    private func checkRow(label: String, value: String) -> some View {
        Toggle(isOn: Binding(
            get: { !excluded.contains(value) },
            set: { isIncluded in
                if isIncluded {
                    excluded.remove(value)
                } else {
                    excluded.insert(value)
                }
            }
        )) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.checkbox)
    }
}
