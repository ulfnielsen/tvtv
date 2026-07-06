import AppKit
import SwiftUI
import TVTVCore

/// The SQL editor panel plus autocomplete: a multiline text view + Run/
/// ⌘-Return + an error line, with a `CompletionPopup` that appears under
/// the caret as the user types. Toggled show/hide from `ContentView`'s
/// toolbar.
///
/// ## Editor: `NSTextView`, not `TextEditor`
///
/// A plain SwiftUI `TextEditor` isn't enough here: autocomplete needs two
/// things `TextEditor` does not expose: the caret's on-screen rect (to
/// position the popup) and a hook to intercept Up/Down/Tab/Return/Esc
/// BEFORE they edit the text (to navigate/accept/dismiss the popup
/// instead). `SQLTextEditor` below wraps
/// `NSTextView` in an `NSViewRepresentable` for exactly that — see its own
/// doc for the mechanism (`NSTextViewDelegate.doCommand(by:)`).
struct SQLEditor: View {
    @Binding var sqlText: String
    let errorMessage: String?
    let isQueryResult: Bool

    /// Current view/table names the grid can switch to (completion
    /// context) — e.g. `["data", "query_result"]`.
    let tables: [String]

    /// The open file's column names (completion context).
    let columns: [String]

    let onRun: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SQL")
                    .font(.headline)
                Spacer()
                if isQueryResult {
                    Button("Back to File", action: onClose)
                        .help("Return the grid to the opened file")
                }
                Button("Run", action: onRun)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Run (⌘-Return)")
            }

            SQLTextEditor(text: $sqlText, tables: tables, columns: columns)
                .frame(minHeight: 70, maxHeight: 160)
                .background(.background)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(.thinMaterial)
    }
}

/// `NSTextView`-backed replacement for `TextEditor` (see `SQLEditor`'s doc
/// for why). Drives `sqlCompletions` (the pure completion provider, in
/// `TVTVCore`) off the identifier fragment ending at the caret, and shows a
/// `CompletionPopup` in a floating, NON-ACTIVATING child window positioned
/// under the caret.
///
/// ## Why a non-activating child `NSPanel`
///
/// The popup must be visible and mouse-clickable WITHOUT ever taking first
/// responder / key-window status away from the `NSTextView` the user is
/// actively typing into — stealing focus would break every keystroke after
/// the popup appears. `styleMask: [.borderless, .nonactivatingPanel]` is
/// the standard AppKit idiom for exactly this (the same class of panel
/// tooltips and system autocomplete windows use): it can still receive
/// mouse clicks, but showing/ordering it front never changes key window or
/// first responder.
struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String
    let tables: [String]
    let columns: [String]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // Correct NSTextView-in-NSScrollView setup. The previous version left
        // the text view with no frame, no min/max size, and no text-container
        // size, which made it collapse to zero height — the editor rendered
        // blank and wouldn't accept input.
        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.tables = tables
        context.coordinator.columns = columns
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismissPopup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, tables: tables, columns: columns)
    }

    /// Owns the completion state (`suggestions`, `selectedIndex`,
    /// `autocompleteAvailable`) and all popup/key-interception logic.
    ///
    /// `autocompleteAvailable` is the flag the coordinator sets when
    /// suggestions exist — it lives HERE, on this
    /// `NSViewRepresentable`'s own `Coordinator`, deliberately NOT on
    /// `DataGridCoordinator`. It is purely editor-local UI state (whether a
    /// popup is currently showing under the caret), unrelated to grid/query
    /// state (`sortDescriptors`, `excludedValues`, `searchTerm`, …) that
    /// `DataGridCoordinator` owns — adding it there would mix an editor
    /// concern into the grid engine for no benefit, since nothing outside
    /// this text view's own key handling ever needs to read it.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        var tables: [String]
        var columns: [String]
        weak var textView: NSTextView?

        private var popupPanel: NSPanel?
        private var suggestions: [String] = []
        private var selectedIndex: Int = 0
        private var prefixRange: NSRange = NSRange(location: NSNotFound, length: 0)

        /// True whenever the popup currently has suggestions to show.
        private(set) var autocompleteAvailable: Bool = false

        init(text: Binding<String>, tables: [String], columns: [String]) {
            self.text = text
            self.tables = tables
            self.columns = columns
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            updateCompletions()
        }

        func textDidEndEditing(_ notification: Notification) {
            dismissPopup()
        }

        /// Intercepts the navigation/accept/dismiss keys NORMALLY bound to
        /// text editing (`moveUp:`/`moveDown:`/`insertTab:`/`insertNewline:`/
        /// `cancelOperation:`) while the popup is showing, so they drive the
        /// popup instead of moving the caret / inserting a newline. Returns
        /// `false` (let the default binding run) whenever no popup is
        /// showing, or for any other command.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard autocompleteAvailable, !suggestions.isEmpty else { return false }

            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                selectedIndex = (selectedIndex - 1 + suggestions.count) % suggestions.count
                showPopup()
                return true
            case #selector(NSResponder.moveDown(_:)):
                selectedIndex = (selectedIndex + 1) % suggestions.count
                showPopup()
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                acceptSuggestion(at: selectedIndex)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismissPopup()
                return true
            default:
                return false
            }
        }

        // MARK: Completion (provider wiring)

        /// Recomputes the identifier-fragment prefix ending at the caret and
        /// refreshes `suggestions`/the popup from `sqlCompletions` (the pure
        /// provider in `TVTVCore/Completion.swift`).
        private func updateCompletions() {
            guard let textView else { dismissPopup(); return }
            let caret = textView.selectedRange().location
            guard caret != NSNotFound else { dismissPopup(); return }

            let ns = textView.string as NSString
            var start = caret
            while start > 0, Self.isIdentifierChar(ns.character(at: start - 1)) {
                start -= 1
            }
            let range = NSRange(location: start, length: caret - start)
            let prefix = ns.substring(with: range)

            guard !prefix.isEmpty else { dismissPopup(); return }

            let matches = sqlCompletions(prefix: prefix, tables: tables, columns: columns)
            guard !matches.isEmpty else { dismissPopup(); return }

            prefixRange = range
            suggestions = matches
            selectedIndex = 0
            autocompleteAvailable = true
            showPopup()
        }

        private static func isIdentifierChar(_ code: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(code) else { return false }
            let ch = Character(scalar)
            return ch.isLetter || ch.isNumber || ch == "_"
        }

        // MARK: Popup lifecycle

        fileprivate func showPopup() {
            guard let textView, let window = textView.window else { return }

            let panel: NSPanel
            if let existing = popupPanel {
                panel = existing
            } else {
                let created = NSPanel(
                    contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: true
                )
                created.isFloatingPanel = true
                created.level = .popUpMenu
                created.hasShadow = true
                created.isOpaque = false
                created.backgroundColor = .clear
                created.hidesOnDeactivate = false
                window.addChildWindow(created, ordered: .above)
                popupPanel = created
                panel = created
            }

            let content = CompletionPopup(
                suggestions: suggestions,
                selectedIndex: selectedIndex,
                onSelect: { [weak self] index in
                    self?.acceptSuggestion(at: index)
                }
            )
            let hosting = NSHostingView(rootView: content)
            let size = hosting.fittingSize
            panel.contentView = hosting
            panel.setContentSize(size)

            let caretRect = caretScreenRect(textView: textView)
            panel.setFrameOrigin(NSPoint(x: caretRect.minX, y: caretRect.minY - size.height))
            panel.orderFront(nil)
        }

        /// The caret's rect, already in SCREEN coordinates. `firstRect(for
        /// CharacterRange:actualRange:)` is the `NSTextInputClient` method
        /// AppKit itself uses to position input-method candidate windows —
        /// exactly this popup's use case (a floating window that must track
        /// the caret regardless of what's between the text view and the
        /// screen: scroll view, SwiftUI hosting, app window) — so it's used
        /// here directly rather than re-deriving the rect by hand through
        /// `NSLayoutManager` + manual coordinate conversion.
        private func caretScreenRect(textView: NSTextView) -> NSRect {
            textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        }

        fileprivate func dismissPopup() {
            autocompleteAvailable = false
            suggestions = []
            if let panel = popupPanel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            popupPanel = nil
        }

        /// Replaces the current prefix range with `suggestions[index]`,
        /// moves the caret to just after the inserted text, and dismisses
        /// the popup.
        private func acceptSuggestion(at index: Int) {
            guard let textView, suggestions.indices.contains(index) else { return }
            let replacement = suggestions[index]
            guard textView.shouldChangeText(in: prefixRange, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: prefixRange, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: prefixRange.location + (replacement as NSString).length, length: 0))
            text.wrappedValue = textView.string
            dismissPopup()
        }
    }
}
