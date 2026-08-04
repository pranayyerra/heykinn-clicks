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

    /// Environment variable naming an archive directory to use instead of the
    /// real one.
    ///
    /// A test can already build a whole store over a temporary archive, but a
    /// *running* app could only ever open the user's own — so looking at the
    /// app meant looking at 24,000 real photos on real drives, and any check of
    /// a screen's behaviour was a change to the archive somebody depends on.
    /// Redirecting `HOME` does not work: Application Support resolves through
    /// the user domain, not the environment. This is the seam that was missing.
    static let archiveDirectoryOverrideKey = "HEYKINN_ARCHIVE_DIRECTORY"
    /// Set alongside the override to keep an inspection copy off the machine's
    /// real volumes: no volume scan, no snapshots written to the user's drives.
    static let offlineKey = "HEYKINN_NO_BACKGROUND_WORK"

    static func production(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppEnvironment {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = processEnvironment[archiveDirectoryOverrideKey].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? support.appendingPathComponent("HeykinnClicks", isDirectory: true)

        // A redirected archive gets its own preferences too. Sharing the real
        // ones would have an inspection copy reading — and writing — the
        // policy, the ignored volumes and the iCloud answer that belong to the
        // archive it is standing in for.
        let defaults = processEnvironment[archiveDirectoryOverrideKey].flatMap {
            UserDefaults(suiteName: "HeykinnClicks.archive." + $0.replacingOccurrences(of: "/", with: "."))
        } ?? .standard

        return AppEnvironment(
            appDirectory: directory,
            defaults: defaults,
            runsBackgroundWork: processEnvironment[offlineKey] == nil
        )
    }
}
