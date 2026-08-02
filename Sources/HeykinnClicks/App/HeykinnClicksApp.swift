import SwiftUI
import AppKit

@main
struct HeykinnClicksApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear {
                    // Needed when launched as a bare SwiftPM executable
                    // (swift run) so the window actually comes to front.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}
