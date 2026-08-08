import XCTest
@testable import HeykinnClicks

/// The app must not read its own copies back in as photos somebody added, and
/// registering a device must actually queue the copies that device is owed.
@MainActor
final class SelfImportGuardTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func makeStore() throws -> (store: AppStore, directory: URL) {
        let directory = try makeDirectory("store")
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory, defaults: defaults, runsBackgroundWork: false
        ))
        return (store, directory)
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - The app's own folders

    /// The bug this exists for: the Drives screen offered "look for copies this
    /// drive already has" for every target, and a host device's mount *is* the
    /// app's own copy folder — so it swept the archive's own replicas back in
    /// as a user folder.
    func testTheAppsOwnDirectoryIsNotSomewhereToImportFrom() throws {
        let (store, directory) = try makeStore()
        XCTAssertTrue(store.isAppOwnedFolder(directory))
        XCTAssertTrue(
            store.isAppOwnedFolder(directory.appendingPathComponent("LocalCopy", isDirectory: true)),
            "and anything inside it"
        )
    }

    /// The one folder the app owns on a drive is refused; the rest of the drive
    /// is the user's and is not.
    func testTheAppsFolderOnADriveIsRefusedButTheDriveIsNot() throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("drive")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        XCTAssertNotNil(store.targets.first, store.lastError ?? "")

        XCTAssertTrue(
            store.isAppOwnedFolder(
                mount.appendingPathComponent(ReplicationTarget.appFolderName, isDirectory: true)
            )
        )
        XCTAssertFalse(store.isAppOwnedFolder(mount), "the drive itself is the user's")
        XCTAssertFalse(
            store.isAppOwnedFolder(mount.appendingPathComponent("My Photos", isDirectory: true))
        )
    }

    /// A folder that merely *contains* the app's own is still importable — the
    /// home folder contains Application Support — because the sweep steps over
    /// the app's directories on the way down.
    func testAFolderContainingTheAppsOwnIsStillImportable() throws {
        let (store, directory) = try makeStore()
        XCTAssertFalse(store.isAppOwnedFolder(directory.deletingLastPathComponent()))
    }

    /// And the guard is enforced where it matters, not only queryable.
    func testImportingTheAppsOwnFolderIsRefused() async throws {
        let (store, directory) = try makeStore()
        let localCopy = directory.appendingPathComponent("LocalCopy", isDirectory: true)
        try FileManager.default.createDirectory(at: localCopy, withIntermediateDirectories: true)
        try Data("a replica".utf8).write(to: localCopy.appendingPathComponent("photo.jpg"))

        store.importFolders([localCopy])

        XCTAssertFalse(store.isImporting, "the import never started")
        XCTAssertNotNil(store.lastError)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(store.assets.isEmpty, "and nothing was catalogued")
    }

    // MARK: - Registering a device

    /// Registering a device queues the copies the archive is short.
    ///
    /// It did not. The placement audit ran before the scan that makes the new
    /// device reachable, so every photo came back "no room" — a device nobody
    /// has measured reports nil free bytes — and the audit queued nothing.
    /// Registering a drive appeared to work and then sat there doing nothing
    /// until some unrelated event happened to re-run the audit.
    func testRegisteringADeviceQueuesTheCopiesItIsOwed() async throws {
        let (store, _) = try makeStore()
        let source = try makeDirectory("source")
        try Data("a photo".utf8).write(to: source.appendingPathComponent("photo.jpg"))
        let mount = try makeDirectory("target")

        store.importFolders([source])
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let asset = try XCTUnwrap(store.assets.first)
        XCTAssertNotNil(asset.stagingRelativePath, "nowhere managed to put it yet")

        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        XCTAssertEqual(
            store.replicationTasks.filter { $0.state == .queued && $0.action == .copy }.count, 1,
            "the copy the new device is owed is queued by registering it"
        )
        XCTAssertEqual(store.backlogCount(for: driveID), 1)
    }
}
