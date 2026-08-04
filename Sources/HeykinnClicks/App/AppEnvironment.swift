import Foundation

/// Everything `AppStore` needs from the machine it runs on.
///
/// The store used to have one initialiser, and it opened
/// `~/Library/Application Support/HeykinnClicks/catalog.sqlite` — so no test
/// could ever construct one, and the orchestration that decides when to sync,
/// what to repoint, and whether a Photos original is new content was checked
/// only by running the app by hand. This is the seam that lets a test build a
/// whole store over a temporary directory.
struct AppEnvironment {
    /// Holds the catalog, staging, and the export-part relay.
    var appDirectory: URL
    /// Where preferences are read and written. A test passes its own suite so
    /// it neither reads nor disturbs the user's real settings.
    var defaults: UserDefaults
    /// Whether to scan volumes at launch, run the periodic tick, and prune the
    /// thumbnail cache on disk. Off under test — the methods the tick calls are
    /// driven directly, which is the whole point of testing them.
    var runsBackgroundWork: Bool

    static func production() -> AppEnvironment {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return AppEnvironment(
            appDirectory: support.appendingPathComponent("HeykinnClicks", isDirectory: true),
            defaults: .standard,
            runsBackgroundWork: true
        )
    }
}
