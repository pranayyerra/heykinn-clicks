import Foundation

/// Where the archive lives, for a build that ships two ways.
///
/// A sandboxed app does not get `~/Library/Application Support` — it gets a
/// container of its own. Left alone, that means the App Store build and the
/// Developer ID build would each keep an archive, on the same device, with the
/// same name, and somebody who installed both would have two: two catalogs,
/// two sets of drives registered, and every count on every screen quietly
/// describing half of what they own.
///
/// An **app group container** is the one place both can reach. It is Apple's
/// mechanism for exactly this, the group identifier has to carry the team
/// prefix on macOS, and a non-sandboxed app can use it too.
enum ArchiveLocation {

    /// Team-prefixed, because macOS requires it of app groups.
    static let appGroupIdentifier = "344B87D3CV.com.heykinn.HeykinnClicks"

    /// The folder name used inside whichever container is chosen, and the name
    /// of the pre-group location.
    static let folderName = "HeykinnClicks"

    /// What was chosen, so the app can say so rather than leaving somebody to
    /// work out which of two archives they are looking at.
    /// Preference asking this copy of the app to open a throwaway archive.
    ///
    /// Per build, because a sandboxed app keeps its own preferences — so the
    /// App Store copy can be put in test mode while the website copy stays on
    /// the real archive, which is the arrangement somebody publishing both
    /// actually wants.
    static let testModeKey = "useTestArchive"

    enum Kind: Equatable {
        /// The environment override, for tests and for looking at a scratch
        /// archive without touching a real one.
        case overridden
        /// A throwaway archive, chosen inside the app. Beside the real one and
        /// never inside it: a test archive nested in the real one would be
        /// swept, counted and backed up as though it were content.
        case test
        /// The shared group container: both builds, one archive.
        case appGroup
        /// The group container's own path, reached directly. An unsandboxed
        /// build with no entitlement — `swift run` — cannot ask the API for it
        /// but is not forbidden from reading it, and must not start a second
        /// archive just because it could not ask politely.
        case appGroupByPath
        /// `~/Library/Application Support/HeykinnClicks`, where every archive
        /// written before this existed still is.
        case legacy
    }

    struct Resolution: Equatable {
        var url: URL
        var kind: Kind
    }

    /// Picks the archive directory.
    ///
    /// The order is the whole design, so it is written out rather than left in
    /// the control flow:
    ///
    /// 1. An explicit override always wins. It is how a test and a curious
    ///    developer avoid the real archive entirely.
    /// 2. The group container, when the process is entitled to ask for one.
    /// 3. The group container's path, when it already exists but this process
    ///    cannot ask. Without this, running `swift run` after using a signed
    ///    build would find the old location empty and cheerfully begin a
    ///    second, empty archive.
    /// 4. The pre-group location, which is where a first run of an unsigned
    ///    build starts and where every existing archive is until it is moved.
    static func resolve(
        override: String?,
        groupContainer: URL?,
        home: URL,
        wantsTestArchive: Bool = false,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Resolution {
        if let override, !override.isEmpty {
            return Resolution(url: URL(fileURLWithPath: override, isDirectory: true), kind: .overridden)
        }
        // Before the real archive is even worked out, so nothing about test
        // mode can touch it. Sandboxed, the container is the only place this
        // copy may write, which is also where it belongs.
        if wantsTestArchive {
            let base = groupContainer ?? groupContainerPath(home: home)
            return Resolution(
                url: base.appendingPathComponent(folderName + "-Test", isDirectory: true),
                kind: .test
            )
        }
        if let groupContainer {
            return Resolution(
                url: groupContainer.appendingPathComponent(folderName, isDirectory: true),
                kind: .appGroup
            )
        }
        let byPath = groupContainerPath(home: home).appendingPathComponent(folderName, isDirectory: true)
        if exists(byPath) {
            return Resolution(url: byPath, kind: .appGroupByPath)
        }
        return Resolution(url: legacyPath(home: home), kind: .legacy)
    }

    /// Where macOS puts a group container. Derived rather than asked for,
    /// because the whole point of case 3 above is a process that cannot ask.
    static func groupContainerPath(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupIdentifier, isDirectory: true)
    }

    static func legacyPath(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Moving an existing archive

    enum Migration: Equatable {
        /// Nothing to move.
        case notNeeded
        case moved(from: URL, to: URL)
        /// Both places hold an archive. Deliberately not merged: two catalogs
        /// describing overlapping sets of photographs cannot be reconciled by
        /// copying files around, and picking one silently would throw away
        /// whichever the user cared about. This is reported and left alone.
        case refusedBothExist(legacy: URL, shared: URL)
        case failed(String)
    }

    /// Moves a pre-group archive into the shared container, once.
    ///
    /// A move rather than a copy: two archives is the thing being fixed, and
    /// leaving the old one behind means the next unsigned build finds it and
    /// carries on writing to it. `moveItem` on the same volume is a rename, so
    /// there is no window where the catalog exists in neither place.
    static func migrateIfNeeded(
        legacy: URL,
        shared: URL,
        fileManager: FileManager = .default
    ) -> Migration {
        let legacyExists = fileManager.fileExists(atPath: legacy.appendingPathComponent("catalog.sqlite").path)
        let sharedExists = fileManager.fileExists(atPath: shared.appendingPathComponent("catalog.sqlite").path)

        guard legacyExists else { return .notNeeded }
        guard !sharedExists else { return .refusedBothExist(legacy: legacy, shared: shared) }

        do {
            try fileManager.createDirectory(
                at: shared.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacy, to: shared)
            return .moved(from: legacy, to: shared)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
