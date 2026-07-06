import SwiftUI

@main
struct TVTVApp: App {
    /// The app owns the single `AppModel` (shared DuckDB connection +
    /// coordinator); both the window content and the File menu route opens
    /// through it.
    @State private var model = AppModel()

    var body: some Scene {
        // A single `Window`, not `WindowGroup`: TVTV is a single-window file
        // viewer (one shared DuckDB connection / model). `WindowGroup` spawned
        // a duplicate empty window on file-open — `Window` guarantees exactly
        // one.
        Window("TVTV", id: "tvtv-main") {
            ContentView(model: model)
                // Finder double-click / open-on-launch / `open <file>`.
                .onOpenURL { url in model.open(url: url) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openViaPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // ⌘F "Find": focuses the toolbar's search field (search-UX
            // Task 1). Placed in its own group after Edit's text-editing
            // commands (Copy/Paste/Select All, etc.) — the conventional Mac
            // home for Find — rather than folded into `.newItem`, so it
            // reads as its own "Find" menu item and works regardless of
            // whether the SQL editor panel is open (it only needs
            // `model.hasData`, which the search field's own toolbar presence
            // already requires). `AppModel.focusSearch()` just bumps
            // `focusSearchToken`; `ContentView`'s `@FocusState` bridge (see
            // that property's doc) does the rest.
            CommandGroup(after: .textEditing) {
                Button("Find") { model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.hasData)
            }
            // Save / Save As write the edited table back (only while editing).
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.coordinator.isEditing)
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.coordinator.isEditing)
            }
            // ⌘Z undoes the last cell edit while editing.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undoCellEdit() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.coordinator.isEditing)
            }
        }
    }
}
