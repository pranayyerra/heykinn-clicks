import Foundation

/// Everything `AppStore` needs from the device it runs on.
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
    /// Set alongside the override to keep an inspection copy off the device's
    /// real volumes: no volume scan, no snapshots written to the user's drives.
    static let offlineKey = "HEYKINN_NO_BACKGROUND_WORK"

    /// What `production()` decided, so the app can report it rather than
    /// leaving somebody to work out which archive they are looking at.
    private(set) static var resolvedLocation: ArchiveLocation.Resolution?
    /// The result of moving a pre-group archive, if one was moved on this
    /// launch. Read once by `AppStore` and written into the audit log.
    private(set) static var migration: ArchiveLocation.Migration = .notNeeded

    static func production(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppEnvironment {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        // Nil unless this build carries the app-group entitlement. An unsigned
        // `swift run` gets nothing here, which is a case `resolve` handles
        // rather than treating as "start a fresh archive".
        let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ArchiveLocation.appGroupIdentifier
        )

        let resolution = ArchiveLocation.resolve(
            override: processEnvironment[archiveDirectoryOverrideKey],
            groupContainer: group,
            home: home,
            wantsTestArchive: UserDefaults.standard.bool(forKey: ArchiveLocation.testModeKey)
        )
        resolvedLocation = resolution

        // One archive, not one per way of installing the app. Only ever from
        // the pre-group location into the shared one, only when the shared one
        // holds nothing, and never when an override is in force — a scratch
        // archive must not swallow the real one.
        if resolution.kind == .appGroup || resolution.kind == .appGroupByPath {
            migration = ArchiveLocation.migrateIfNeeded(
                legacy: ArchiveLocation.legacyPath(home: home),
                shared: resolution.url
            )
        }

        let directory = resolution.url

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
