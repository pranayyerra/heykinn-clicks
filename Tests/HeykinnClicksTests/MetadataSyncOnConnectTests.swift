import XCTest
@testable import HeykinnClicks

/// The app actually doing it, rather than the engine being able to.
///
/// Everything under `DriveSyncTests` proves two catalogs converge through a
/// directory. This covers the layer above: that `AppStore` points at the right
/// place on the drive, records what happened, and — the part most easily got
/// wrong — reloads what is on screen afterwards, since every view is drawn from
/// state read at launch and a merge changes rows underneath it.
@MainActor
final class MetadataSyncOnConnectTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-connect-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStore(_ label: String) throws -> (AppStore, URL) {
        let directory = try makeDirectory(label)
        let suiteName = "heykinn-connect-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
        return (store, directory)
    }

    /// A drive: a directory the app is told is a mounted volume.
    private func makeDrive() throws -> URL {
        try makeDirectory("drive")
    }

    private func syncRoot(_ mount: URL) -> URL {
        mount
            .appendingPathComponent(ReplicationTarget.appFolderName, isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
    }

    private func makeGroup(_ label: String) -> StorageGroup {
        StorageGroup(
            id: UUID(), label: label, desiredCopies: 2,
            destinationTargetIDs: [], createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    // MARK: -

    /// The whole journey at the level a person experiences it: work done on one
    /// device, a drive carried across, and the second device showing it.
    func testWorkFromAnotherMacArrivesAndIsOnScreen() throws {
        let (deviceA, _) = try makeStore("a")
        let (deviceB, _) = try makeStore("b")
        let mount = try makeDrive()
        let store = DirectorySegmentStore(root: syncRoot(mount))

        try deviceA.catalog.upsertStorageGroup(makeGroup("Family"))
        try DriveSync.publish(from: deviceA.catalog, to: store)

        let expectation = expectation(description: "merged")
        Task { @MainActor in
            await deviceB.syncMetadata(with: store, named: "My Passport", targetID: nil)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(try deviceB.catalog.fetchStorageGroups().map(\.label), ["Family"])
        XCTAssertEqual(
            deviceB.storageGroups.map(\.label), ["Family"],
            "The catalog has it but the screen does not — the reload after merging is missing"
        )
    }

    /// A drive that has nothing new must not produce a line claiming it did.
    func testASyncWithNothingToShareIsQuiet() throws {
        let (deviceA, _) = try makeStore("a")
        let mount = try makeDrive()
        let store = DirectorySegmentStore(root: syncRoot(mount))

        var summary: AppStore.MetadataSyncSummary?
        let expectation = expectation(description: "synced")
        Task { @MainActor in
            summary = await deviceA.syncMetadata(with: store, named: "My Passport", targetID: nil)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(summary?.received, 0)
        XCTAssertNil(summary?.failure)
        XCTAssertTrue(summary?.isQuiet ?? false)
    }

    /// A drive written by a newer build is refused, and that has to be reported
    /// rather than swallowed — the archive is fine, this copy of the app is not
    /// the one to read it.
    func testADriveFromANewerBuildIsReportedNotCrashed() throws {
        let (deviceA, _) = try makeStore("a")
        let mount = try makeDrive()
        let store = DirectorySegmentStore(root: syncRoot(mount))

        let manifest = SyncManifest(
            formatVersion: SyncManifest.currentFormatVersion + 1,
            catalogSchemaVersion: CatalogStore.schemaVersion
        )
        try store.writeAtomically(try JSONEncoder().encode(manifest), to: DriveSync.manifestPath)

        var summary: AppStore.MetadataSyncSummary?
        let expectation = expectation(description: "synced")
        Task { @MainActor in
            summary = await deviceA.syncMetadata(with: store, named: "My Passport", targetID: nil)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        let failure = try XCTUnwrap(summary?.failure)
        XCTAssertTrue(
            failure.lowercased().contains("newer"),
            "The message should say the app needs updating, got: \(failure)"
        )
    }

    /// The sync directory belongs under the app's own folder on the drive, not
    /// scattered at the volume root. One folder, so a person can see at a
    /// glance what is the app's and what is theirs.
    func testSyncFilesLiveUnderTheAppsOwnFolder() throws {
        let (deviceA, _) = try makeStore("a")
        let mount = try makeDrive()
        let store = DirectorySegmentStore(root: syncRoot(mount))

        try deviceA.catalog.upsertStorageGroup(makeGroup("Family"))
        try DriveSync.publish(from: deviceA.catalog, to: store)

        let expected = mount
            .appendingPathComponent(ReplicationTarget.appFolderName)
            .appendingPathComponent("Sync")
            .appendingPathComponent(DriveSync.manifestPath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expected.path),
            "Expected the manifest under HeykinnClicks/Sync/"
        )
    }
}
