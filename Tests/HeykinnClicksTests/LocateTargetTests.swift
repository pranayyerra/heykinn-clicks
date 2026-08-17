import XCTest
@testable import HeykinnClicks

/// Pointing the app at a device it already knows, so a sandboxed build can
/// reach it.
///
/// Bookmarks are taken when a device is registered, and every device registered
/// before bookmarks existed has none. Unsandboxed that costs nothing, because
/// the marker sweep finds drives regardless. Sandboxed it is total: reading the
/// root of every mounted volume is exactly what is not allowed, so a drive with
/// no bookmark is invisible rather than slow — somebody upgrading would find
/// every one of their drives reading as away while plugged into the device.
@MainActor
final class LocateTargetTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-locate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var url = raw
        if let resolved = realpath(raw.path, nil) {
            url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStore(in directory: URL) -> AppStore {
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
    }

    /// Registers a device the way an older version did: a marker on the disk
    /// and a row in the catalog, and no bookmark anywhere.
    private func registerWithoutBookmark(
        _ store: AppStore, named name: String, at root: URL
    ) throws -> ReplicationTarget {
        let target = ReplicationTarget(
            id: UUID(), name: name, kind: .externalVolume, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: root.path, configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
        try TargetMonitor.writeMarker(
            TargetMarker(targetID: target.id, markerToken: target.markerToken, appName: "heykinn-clicks"),
            to: root
        )
        try store.catalog.upsertTarget(target)
        store.loadAll()
        return target
    }

    /// The marker decides, not the folder somebody picked in a panel. A
    /// bookmark recorded against the wrong disk would have this archive writing
    /// its copies onto a stranger's drive and counting them as safe.
    func testAFolderThatIsNotTheDeviceIsRefused() throws {
        let directory = try makeDirectory()
        let store = makeStore(in: directory)
        let root = try makeDirectory()
        let target = try registerWithoutBookmark(store, named: "My Passport", at: root)

        let somewhereElse = try makeDirectory()
        XCTAssertFalse(store.locateTarget(target.id, at: somewhereElse))

        let error = try XCTUnwrap(store.lastError)
        XCTAssertTrue(error.contains("My Passport"), error)
        XCTAssertFalse(store.targetBookmarks.hasBookmark(for: target.id), "Nothing was recorded")
    }

    /// A drive this archive does know, but not the one being looked for. The
    /// names are similar and the panels are small; this is the mistake somebody
    /// actually makes.
    func testTheWrongOneOfTwoKnownDevicesIsRefused() throws {
        let directory = try makeDirectory()
        let store = makeStore(in: directory)
        let firstRoot = try makeDirectory()
        let secondRoot = try makeDirectory()
        let first = try registerWithoutBookmark(store, named: "My Passport", at: firstRoot)
        _ = try registerWithoutBookmark(store, named: "Field Drive", at: secondRoot)

        XCTAssertFalse(
            store.locateTarget(first.id, at: secondRoot),
            "A different device's marker is not this device"
        )
        XCTAssertTrue(store.lastError?.contains("not My Passport") ?? false, store.lastError ?? "")
        XCTAssertFalse(store.targetBookmarks.hasBookmark(for: first.id))
    }

    /// The good case: the right disk, and it is remembered.
    func testLocatingTheRightDeviceRecordsIt() throws {
        let directory = try makeDirectory()
        let store = makeStore(in: directory)
        let root = try makeDirectory()
        let target = try registerWithoutBookmark(store, named: "My Passport", at: root)

        XCTAssertTrue(store.locateTarget(target.id, at: root))
        XCTAssertTrue(store.targetBookmarks.hasBookmark(for: target.id))
        XCTAssertEqual(
            store.targetBookmarks.resolvedURL(for: target.id)?.standardizedFileURL.path,
            root.standardizedFileURL.path
        )
    }

    /// It is written down, because "you will not be asked again" is the whole
    /// point of the exercise.
    func testLocatingIsRecordedInTheLog() throws {
        let directory = try makeDirectory()
        let store = makeStore(in: directory)
        let root = try makeDirectory()
        let target = try registerWithoutBookmark(store, named: "My Passport", at: root)

        store.locateTarget(target.id, at: root)

        XCTAssertTrue(
            store.auditEvents.contains { $0.message.contains("located again") },
            "A device becoming reachable again is a thing that happened to the archive"
        )
    }

    /// Unsandboxed, nothing needs locating however few bookmarks exist — the
    /// marker sweep finds every drive, and asking somebody to go and find one
    /// they can already see would be nonsense.
    func testNothingNeedsLocatingWhenTheSweepCanRun() throws {
        let directory = try makeDirectory()
        let store = makeStore(in: directory)
        let root = try makeDirectory()
        _ = try registerWithoutBookmark(store, named: "My Passport", at: root)

        XCTAssertFalse(TargetBookmarks.isSandboxed, "the premise: tests are not sandboxed")
        XCTAssertTrue(
            store.targetsNeedingLocating.isEmpty,
            "Only a sandboxed build is blind without a bookmark"
        )
    }
}
