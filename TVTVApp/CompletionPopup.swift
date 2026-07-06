import SwiftUI

/// The small list popup shown under the caret in the SQL editor as the user
/// types.
///
/// Deliberately dumb/presentational: `SQLTextEditor.Coordinator` (in
/// `SQLEditor.swift`) owns all the state that matters — which suggestions
/// are current, which index is keyboard-selected, and all Up/Down/Tab/
/// Return/Esc handling (via `NSTextView`'s `doCommand(by:)`, since a floating
/// popup window must never steal first responder from the text view the
/// user is typing into). This view only renders that state and reports a
/// mouse click back via `onSelect` — it does not run its own key handling.
struct CompletionPopup: View {
    let suggestions: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Text(suggestion)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        index == selectedIndex ? Color.accentColor.opacity(0.25) : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(index) }
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 140, maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }
}
