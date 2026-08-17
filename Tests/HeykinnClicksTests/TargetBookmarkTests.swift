import XCTest
@testable import HeykinnClicks

/// Bookmarks to registered devices — the permission half of reaching a drive,
/// as against the marker file, which is the identity half.
///
/// These run unsandboxed, so the bookmarks made here are plain ones: a
/// security-scoped bookmark needs the sandbox entitlement, and asking for one
/// without it fails. That is the point of the fallback being tested — the same
/// code has to work in both builds, and the unsandboxed build must not end up
/// silently storing nothing.
@MainActor
final class TargetBookmarkTests: XCTestCase {

    private var suiteNames: [String] = []
    private var stores: [TargetBookmarks] = []

    override func tearDown() {
        for store in stores { store.releaseAll() }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        stores = []; suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "heykinn-bookmarks-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeStore(_ defaults: UserDefaults) -> TargetBookmarks {
        let store = TargetBookmarks(defaults: defaults)
        stores.append(store)
        return store
    }

    private func makeDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-bm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var url = raw
        if let resolved = realpath(raw.path, nil) {
            url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testABookmarkedTargetResolvesBackToTheSamePlace() throws {
        let directory = try makeDirectory()
        let store = makeStore(makeDefaults())
        let targetID = UUID()

        XCTAssertTrue(store.record(targetID: targetID, path: directory.path))
        XCTAssertTrue(store.hasBookmark(for: targetID))

        let resolved = try XCTUnwrap(store.resolvedURL(for: targetID))
        XCTAssertEqual(resolved.standardizedFileURL.path, directory.standardizedFileURL.path)
    }

    /// A device the archive has never been pointed at is not reachable, and
    /// asking must not invent a path.
    func testAnUnknownTargetResolvesToNothing() {
        let store = makeStore(makeDefaults())
        XCTAssertNil(store.resolvedURL(for: UUID()))
        XCTAssertFalse(store.hasBookmark(for: UUID()))
    }

    /// Registration must not fail because a bookmark could not be taken. The
    /// marker sweep finds the drive regardless, and unsandboxed the app can
    /// reach it without one.
    func testAPathThatDoesNotExistIsRefusedWithoutThrowing() {
        let store = makeStore(makeDefaults())
        let targetID = UUID()
        XCTAssertFalse(store.record(targetID: targetID, path: "/nowhere/at/all-\(UUID().uuidString)"))
        XCTAssertFalse(store.hasBookmark(for: targetID))
    }

    /// The whole point: a drive attached at launch is reachable before the user
    /// does anything, which means surviving a relaunch.
    func testBookmarksSurviveARelaunch() throws {
        let directory = try makeDirectory()
        let defaults = makeDefaults()
        let targetID = UUID()

        let first = makeStore(defaults)
        XCTAssertTrue(first.record(targetID: targetID, path: directory.path))
        first.releaseAll()

        // A fresh process reading the same preferences.
        let second = makeStore(defaults)
        XCTAssertTrue(second.hasBookmark(for: targetID), "The bookmark outlives the process that took it")
        second.resumeAccess()
        let resolved = try XCTUnwrap(second.resolvedURL(for: targetID))
        XCTAssertEqual(resolved.standardizedFileURL.path, directory.standardizedFileURL.path)
    }

    /// Unregistering a device gives its permission back. Holding access to a
    /// drive the archive no longer claims is access nobody asked for.
    func testForgettingATargetDropsItsBookmark() throws {
        let directory = try makeDirectory()
        let defaults = makeDefaults()
        let targetID = UUID()

        let store = makeStore(defaults)
        XCTAssertTrue(store.record(targetID: targetID, path: directory.path))
        store.forget(targetID: targetID)

        XCTAssertFalse(store.hasBookmark(for: targetID))
        XCTAssertNil(store.resolvedURL(for: targetID))
        // And it stays gone for the next launch, not just this one.
        XCTAssertFalse(makeStore(defaults).hasBookmark(for: targetID))
    }

    /// Two devices are two bookmarks. Keying by target id rather than by path
    /// is what lets the same disk be re-registered without colliding.
    func testTargetsAreKeptApart() throws {
        let a = try makeDirectory()
        let b = try makeDirectory()
        let store = makeStore(makeDefaults())
        let first = UUID(), second = UUID()

        XCTAssertTrue(store.record(targetID: first, path: a.path))
        XCTAssertTrue(store.record(targetID: second, path: b.path))

        XCTAssertEqual(store.resolvedURL(for: first)?.standardizedFileURL.path, a.standardizedFileURL.path)
        XCTAssertEqual(store.resolvedURL(for: second)?.standardizedFileURL.path, b.standardizedFileURL.path)

        store.forget(targetID: first)
        XCTAssertNil(store.resolvedURL(for: first))
        XCTAssertNotNil(store.resolvedURL(for: second), "Forgetting one device must not reach the other")
    }

    /// Bookmarks are per-device and must never travel in a catalog snapshot,
    /// which is copied to the drives and can be restored onto a different device.
    /// Preferences are where per-device state lives; the catalog is not.
    func testBookmarksAreNotKeptInTheCatalog() throws {
        let directory = try makeDirectory()
        let catalogDirectory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: catalogDirectory.appendingPathComponent("catalog.sqlite").path
        )
        let store = makeStore(makeDefaults())
        store.record(targetID: UUID(), path: directory.path)

        let tables = try catalog.database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table';"
        ) { $0.text(0) }
        for table in tables {
            let columns = try catalog.database.query("PRAGMA table_info(\"\(table)\");") { $0.text(1) }
            XCTAssertFalse(
                columns.contains { $0.localizedCaseInsensitiveContains("bookmark") },
                "\(table) holds a bookmark column; a snapshot restored on another device would carry a pointer to nothing"
            )
        }
    }
}

/// Finding a device by its bookmark rather than by sweeping every mounted
/// volume — which is the only way it can be found once the app is sandboxed.
@MainActor
final class BookmarkedTargetDiscoveryTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-disc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var url = raw
        if let resolved = realpath(raw.path, nil) {
            url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func target(token: String) -> ReplicationTarget {
        ReplicationTarget(
            id: UUID(), name: "Field Drive", kind: .externalVolume, volumeUUID: nil,
            markerToken: token, registeredAt: Date(), lastSeenAt: nil, lastKnownPath: nil,
            configuredPath: nil, replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    /// A directory is not a mounted volume, so the sweep cannot see it. The
    /// bookmark can, and the marker agrees, so it counts as reachable.
    func testABookmarkFindsADeviceTheVolumeSweepCannot() throws {
        let root = try makeDirectory()
        let one = target(token: UUID().uuidString)
        try TargetMonitor.writeMarker(
            TargetMarker(targetID: one.id, markerToken: one.markerToken, appName: "heykinn-clicks"),
            to: root
        )

        let monitor = TargetMonitor()
        monitor.rescanKnownLocations(targets: [one])
        XCTAssertNil(monitor.reachablePaths[one.id], "the premise: the sweep does not find it")

        monitor.rescanKnownLocations(targets: [one], bookmarked: [one.id: root])
        XCTAssertEqual(
            monitor.reachablePaths[one.id]?.standardizedFileURL.path,
            root.standardizedFileURL.path
        )
    }

    /// The bookmark is permission; the marker is identity. A bookmark can
    /// resolve onto a disk that was reformatted or replaced, and writing this
    /// archive's replicas into a stranger's volume because a token still
    /// resolved is the mistake this guards against.
    func testAResolvedPlaceWithTheWrongMarkerIsNotThisDevice() throws {
        let root = try makeDirectory()
        let one = target(token: "the-real-token")
        try TargetMonitor.writeMarker(
            TargetMarker(targetID: UUID(), markerToken: "a-different-disk", appName: "heykinn-clicks"),
            to: root
        )

        let monitor = TargetMonitor()
        monitor.rescanKnownLocations(targets: [one], bookmarked: [one.id: root])

        XCTAssertNil(monitor.reachablePaths[one.id], "A token that does not match is not this device")
    }

    /// And a place with no marker at all is not it either — an empty folder
    /// somebody picked, or a drive whose marker was deleted.
    func testAResolvedPlaceWithNoMarkerIsNotThisDevice() throws {
        let root = try makeDirectory()
        let one = target(token: UUID().uuidString)

        let monitor = TargetMonitor()
        monitor.rescanKnownLocations(targets: [one], bookmarked: [one.id: root])

        XCTAssertNil(monitor.reachablePaths[one.id])
    }
}
