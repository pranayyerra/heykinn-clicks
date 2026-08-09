import SwiftUI
import AppKit

@main
struct HeykinnClicksApp: App {
    @StateObject private var store = AppStore()
    /// Owned here rather than in the window, because the menus are built here
    /// and a menu item has no way to reach a view's own state.
    @StateObject private var commands = AppCommandBus()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(commands)
                // Every number this app shows is one somebody may need to
                // paste somewhere — into a note, a support message, a search.
                // Four places had opted in by hand; everywhere else the text
                // was a picture of itself. `textSelection` travels down the
                // environment, so the whole window inherits it and the four
                // hand-written opt-ins become redundant rather than wrong.
                //
                // Controls are unaffected: SwiftUI suppresses selection inside
                // a button's own label, so a row that is a button still takes
                // the click rather than starting a drag-selection.
                .textSelection(.enabled)
                .frame(minWidth: 1000, minHeight: 660)
                .onAppear {
                    // Needed when launched as a bare SwiftPM executable
                    // (swift run) so the window actually comes to front.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        // A deliberate opening size rather than whatever macOS picks from the
        // minimum: at 1000 points the Overview's protection card puts its ring
        // and its legend side by side with nothing to spare, and the Library
        // grid gets four columns. The window is worth opening wider than it can
        // survive at.
        .defaultSize(width: 1240, height: 820)
        .commands {
            HeykinnCommands(bus: commands, store: store)
        }

        // Preferences belong behind ⌘, rather than mixed into the screens that
        // show the archive itself.
        Settings {
            SettingsView()
                .environmentObject(store)
                .textSelection(.enabled)
        }
    }
}
