import SwiftUI

/// What the menu bar can ask the window to do.
///
/// A menu item is built outside the view hierarchy, so it cannot reach into a
/// screen's `@State` to open that screen's file picker or move its selection.
/// This is the channel between the two: the command records an intent, and the
/// window that owns the matching sheet or selection acts on it. Deliberately
/// nothing but intent — no work happens here — so a menu item and the button
/// beside it on the screen run the same code rather than two copies of it.
@MainActor
final class AppCommandBus: ObservableObject {
    /// A page the menu bar has asked for. The window clears it once it has
    /// moved, so asking for the same page twice running still works.
    @Published var requestedPage: SidebarSection?
    @Published var isImportPickerPresented = false
    @Published var isExportSearchPickerPresented = false
    @Published var isHelpPresented = false
}

/// The app's menus.
///
/// Until now there were none: a windowed Mac app with no `Commands` gets the
/// menu bar SwiftUI gives away for free, which is an About box, a Quit, and a
/// File menu whose only item — "New Window" — does something this app has no
/// meaning for. Every action lived on a toolbar somewhere, so the two questions
/// a Mac user answers with the menu bar ("what can this thing do?" and "what is
/// the shortcut for it?") had nowhere to be answered.
///
/// Nothing here is new capability. Each item is the same call the on-screen
/// button makes, given a name and a key.
struct HeykinnCommands: Commands {
    @ObservedObject var bus: AppCommandBus
    @ObservedObject var store: AppStore

    var body: some Commands {
        // "New Window" is meaningless for an app that is one archive on one
        // Mac, and it is the only thing in File by default. Replaced with the
        // two ways photos actually get in, plus the two things somebody would
        // reach for when something has gone wrong.
        CommandGroup(replacing: .newItem) {
            Button("Add Photos from a Folder…") {
                bus.isImportPickerPresented = true
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(store.isImporting)

            Button("Search a Folder for Google Downloads…") {
                bus.isExportSearchPickerPresented = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(store.takeoutActivity != nil)

            Divider()

            Button("Back Up the Catalog Now") {
                store.backupCatalog(force: true)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(store.reachablePaths.isEmpty)

            Button("Save a Diagnostics Report…") {
                saveDiagnostics()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        // Into the View menu macOS already builds for the split view, under
        // Show/Hide Sidebar — rather than a second menu of the same name.
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Overview") { bus.requestedPage = .overview }
                .keyboardShortcut("1", modifiers: .command)
            Button("Photos") { bus.requestedPage = .library }
                .keyboardShortcut("2", modifiers: .command)
            Button("Add photos") { bus.requestedPage = .takeout }
                .keyboardShortcut("3", modifiers: .command)
            Button("Keep safe") { bus.requestedPage = .targets }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Look for Drives Again") {
                Task { @MainActor in
                    await store.rescanTargetsOffMainThread()
                    // On demand means on demand: check the paths still resolve
                    // rather than only noticing at the next mount. Same work
                    // the Rescan button on Keep safe does.
                    for target in store.targets where store.reachablePaths[target.id] != nil {
                        _ = store.repairReplicaPaths(for: target.id)
                    }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        // The default Help menu points at a help book this app does not ship,
        // so choosing it opened Help Viewer on an error. The app's own ideas —
        // a target, a residency, what "safe" is claiming — are explained in the
        // app instead, which is also where somebody is standing when they want
        // them.
        CommandGroup(replacing: .help) {
            Button("heykinn clicks Help") { bus.isHelpPresented = true }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    /// Writes the report somewhere the user chooses. A save panel rather than a
    /// fixed location, because the point of the file is to be sent to somebody.
    @MainActor
    private func saveDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Save a Diagnostics Report"
        panel.nameFieldStringValue = "heykinn-clicks-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Counts, states and timings only. No file names, no folder paths, "
            + "and nothing about the photographs themselves."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.diagnosticsReport().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.lastError = "The diagnostics report could not be written to that location. "
                + "Try somewhere in your home folder. (\(error.localizedDescription))"
        }
    }
}
