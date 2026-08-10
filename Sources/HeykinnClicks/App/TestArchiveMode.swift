import AppKit
import Foundation

/// Opening a throwaway archive, from inside the app.
///
/// Two copies of this app share one archive on purpose, so only one may be in
/// it at a time — and somebody publishing to both the App Store and a website
/// will want both open at once. The way to do that was an environment variable
/// typed into Terminal, which is a fine answer for whoever wrote the app and no
/// answer at all for anybody else.
///
/// So it is a button. The choice is a preference, read at the next launch, and
/// switching either way relaunches: the archive directory is settled once when
/// the app starts and everything — the catalog, staging, the lock — is opened
/// against it, so changing it underneath a running app would mean rebuilding
/// all of that mid-flight for a case that happens twice a year.
enum TestArchiveMode {

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: ArchiveLocation.testModeKey)
    }

    /// Whether this copy can restart itself. `swift run` produces a bare
    /// executable with no bundle to reopen, so it is told to quit and start
    /// again rather than being offered a button that does nothing.
    static var canRelaunch: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Turns the throwaway archive on or off and restarts into it.
    ///
    /// A new instance first, then this one quits. The other way round leaves a
    /// moment with no app at all, and if the relaunch fails the user is left
    /// looking at a closed window wondering what they broke.
    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: ArchiveLocation.testModeKey)
        UserDefaults.standard.synchronize()
        relaunch()
    }

    private static func relaunch() {
        guard canRelaunch else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // The point is a second copy running beside the first, so this must not
        // simply bring the existing one forward.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
