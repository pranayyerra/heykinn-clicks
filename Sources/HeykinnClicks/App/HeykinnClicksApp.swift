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
        }
    }
}
