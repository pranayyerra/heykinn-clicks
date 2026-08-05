import XCTest
@testable import HeykinnClicks

/// What happens when the app learns, after the fact, that a target was holding
/// content all along.
///
/// The archive's shape used to depend on the order the user did things in.
/// Registering a drive and then importing from it recorded the drive's own
/// files as its copy; importing first and registering second sent that same
/// drive a second copy of files it was already holding, under the app's own
/// names, with no way back. Same two actions, same drive, two different
/// archives — and nothing in the app would ever revisit the difference.
@MainActor
final class AdoptionTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []
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

    /// Auto-sync off by default here: these tests are about what happens
    /// *before* a copy is made, and a sync racing the assertion would hide it.
    private func makeStore(autoSync: Bool = false) throws -> (store: AppStore, directory: URL) {
        let directory = try makeDirectory("store")
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(autoSync, forKey: "autoSyncOnConnect")
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory, defaults: defaults, runsBackgroundWork: false
        ))
        return (store, directory)
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 15,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func importFolder(_ store: AppStore, _ url: URL) async throws {
        store.importFolders([url])
        try await waitUntil("the import of \(url.lastPathComponent) to finish") { !store.isImporting }
    }

    private func replicaRoot(_ mount: URL, _ drive: ReplicationTarget) -> URL {
        mount.appendingPathComponent(drive.replicaRootComponent, isDirectory: true)
    }

    /// Registering a drive after importing from it: the copy it was already
    /// holding is credited to it, and the copy the app had queued is withdrawn
    /// before anything is written.
    func testRegisteringAfterImportingCreditsTheCopyTheDriveAlreadyHad() async throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("drive")
        try Data("a photo".utf8).write(to: mount.appendingPathComponent("photo.jpg"))

        try await importFolder(store, mount)
        let asset = try XCTUnwrap(store.assets.first)
        XCTAssertNotNil(asset.stagingRelativePath, "Nowhere managed to put it yet")

        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let drive = try XCTUnwrap(store.targets.first, store.lastError ?? "")
        XCTAssertEqual(
            store.replicationTasks.filter { $0.state == .queued && $0.action == .copy }.count, 1,
            "Registering seeds a copy of everything Local"
        )

        try await importFolder(store, mount)

        let replica = try XCTUnwrap(store.replicaStates.first { $0.assetID == asset.id })
        XCTAssertEqual(replica.state, .present)
        XCTAssertEqual(replica.relativePath, ReplicationService.volumeBackedPrefix + "photo.jpg")
        XCTAssertTrue(
            store.replicationTasks.filter { $0.state == .queued && $0.action == .copy }.isEmpty,
            "The copy is unnecessary and was withdrawn, not executed"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: replicaRoot(mount, drive).path),
            "Nothing was written into the app's folder on the drive"
        )
    }

    /// The order people actually do things in, with auto-sync left on as it
    /// ships: import from a drive, then register it.
    ///
    /// Registering does not read the drive, so nothing knew the content was
    /// already there and the backlog would copy the drive's own files back onto
    /// it. Connecting now re-reads the folders that were imported from — which
    /// the app recorded at the time — and credits what it finds before the sync
    /// gets a chance to duplicate it.
    func testConnectingCreditsWhatTheDriveHoldsBeforeTheSyncCanDuplicateIt() async throws {
        let (store, _) = try makeStore(autoSync: true)
        let mount = try makeDirectory("drive")
        try Data("a photo".utf8).write(to: mount.appendingPathComponent("photo.jpg"))

        try await importFolder(store, mount)
        let asset = try XCTUnwrap(store.assets.first)
        XCTAssertNotNil(asset.stagingRelativePath)

        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let drive = try XCTUnwrap(store.targets.first, store.lastError ?? "")

        try await waitUntil("the connect sequence to settle") {
            !store.isImporting && !store.isSyncing
                && store.replicaStates.contains { $0.assetID == asset.id && $0.state == .present }
        }

        let replica = try XCTUnwrap(store.replicaStates.first { $0.assetID == asset.id })
        XCTAssertEqual(
            replica.relativePath, ReplicationService.volumeBackedPrefix + "photo.jpg",
            "Credited to the file the drive already had"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ReplicationService.replicaURL(for: asset, drive: drive, mountURL: mount).path
            ),
            "No duplicate was ever written — not written and then reclaimed"
        )
    }

    /// The same drive, one step later: the app already made its duplicate. The
    /// sweep repoints the catalog at the user's own file and takes back the
    /// copy it had written beside it.
    func testASweepReclaimsADuplicateTheAppAlreadyWrote() async throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("drive")
        try Data("a photo".utf8).write(to: mount.appendingPathComponent("photo.jpg"))

        try await importFolder(store, mount)
        let asset = try XCTUnwrap(store.assets.first)
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let drive = try XCTUnwrap(store.targets.first, store.lastError ?? "")

        // Let it make the duplicate this test exists to reclaim.
        store.syncDrive(drive.id)
        try await waitUntil("the copy to land") {
            store.replicaStates.contains { $0.assetID == asset.id && $0.state == .present }
        }
        let managed = ReplicationService.replicaURL(for: asset, drive: drive, mountURL: mount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path), "The duplicate exists")

        try await importFolder(store, mount)

        let replica = try XCTUnwrap(store.replicaStates.first { $0.assetID == asset.id })
        XCTAssertEqual(
            replica.relativePath, ReplicationService.volumeBackedPrefix + "photo.jpg",
            "Now credited to the user's own file"
        )
        XCTAssertEqual(replica.state, .present)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: managed.path),
            "And the app's duplicate of it is gone"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: mount.appendingPathComponent("photo.jpg").path),
            "The user's file is never what gets removed"
        )
    }

    // MARK: - Exports arriving down the wrong path

    /// An export brought in as a folder would copy every photo separately onto
    /// every drive, discarding the machinery that lets a handful of files stand
    /// for all of them. The app holds it back and offers the other way in.
    func testChoosingAnExportAsAFolderOffersTheExportPathInstead() async throws {
        let (store, _) = try makeStore()
        let export = try makeDirectory("source").appendingPathComponent("Takeout", isDirectory: true)
        let photos = export.appendingPathComponent("Google Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("a photo".utf8).write(to: photos.appendingPathComponent("photo.jpg"))

        store.importFolders([export])

        XCTAssertEqual(store.takeoutRedirect?.url, export)
        XCTAssertFalse(store.isImporting, "Held back rather than swept")
        XCTAssertTrue(store.assets.isEmpty)
    }

    /// A renamed export has no telling name, so the structure has to carry it.
    func testARenamedExportIsRecognisedByWhatIsInside() throws {
        let renamed = try makeDirectory("source")
            .appendingPathComponent("holiday pics", isDirectory: true)
        let photos = renamed.appendingPathComponent("Google Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)

        XCTAssertTrue(TakeoutScanner.looksLikeTakeoutRoot(renamed))
        XCTAssertFalse(
            TakeoutScanner.looksLikeTakeoutRoot(try makeDirectory("ordinary")),
            "An ordinary folder is not an export"
        )
    }

    /// Sweeping a whole drive must not explode an export that happens to be
    /// sitting on it — the case the drive rescan walks straight into.
    func testASweepStepsOverAnExportItFindsInside() throws {
        let root = try makeDirectory("drive")
        try Data("loose".utf8).write(to: root.appendingPathComponent("mine.jpg"))
        let export = root.appendingPathComponent("Takeout", isDirectory: true)
        let photos = export.appendingPathComponent("Google Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("from the export".utf8).write(to: photos.appendingPathComponent("exported.jpg"))

        XCTAssertEqual(
            ImportService.mediaFileURLs(under: [root], skippingExports: true).map(\.lastPathComponent),
            ["mine.jpg"]
        )
        XCTAssertEqual(
            ImportService.mediaFileURLs(under: [root]).map(\.lastPathComponent).sorted(),
            ["exported.jpg", "mine.jpg"],
            "The export importer is pointed at exports on purpose"
        )
    }

    /// `sourcePath` promised a path and was given a name, so the screen listing
    /// folders somebody added could not say where any of them were.
    func testAFolderImportRecordsWhereItCameFrom() async throws {
        let (store, _) = try makeStore()
        let folder = try makeDirectory("source")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))

        try await importFolder(store, folder)

        let batch = try XCTUnwrap(store.importBatches.first)
        XCTAssertEqual(batch.sourcePath, folder.path)
        XCTAssertTrue(batch.isFilesystemPath, "So the row can show it and offer to open it")
        XCTAssertTrue(batch.isFolderImport)
    }

    // MARK: - What adoption costs

    /// Adopting a file rather than copying it is right, and it has a price:
    /// the archive's copy is now a file in a folder somebody may clear out.
    /// The app has to know which photos are in that position — it sorts them
    /// to the front of the copy queue and says so on screen.
    func testAPhotoKeptOnlyWhereTheUserPutItIsKnownToBe() async throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("drive")
        try Data("in place".utf8).write(to: mount.appendingPathComponent("adopted.jpg"))

        store.registerHostDeviceTarget(at: mount, name: "Drive")
        XCTAssertNotNil(store.targets.first, store.lastError ?? "")
        try await importFolder(store, mount)

        let adopted = try XCTUnwrap(store.assets.first { $0.originalFilename == "adopted.jpg" })
        XCTAssertNil(adopted.stagingRelativePath)
        XCTAssertTrue(
            store.hasOnlyArchiveBackedCopies(adopted.id),
            "Its only copy is the user's own file"
        )

        // One brought in from somewhere unmanaged has a copy of the app's own.
        let loose = try makeDirectory("source")
        try Data("copied in".utf8).write(to: loose.appendingPathComponent("staged.jpg"))
        try await importFolder(store, loose)

        let staged = try XCTUnwrap(store.assets.first { $0.originalFilename == "staged.jpg" })
        XCTAssertNotNil(staged.stagingRelativePath)
        XCTAssertFalse(
            store.hasOnlyArchiveBackedCopies(staged.id),
            "Staging is a copy the user cannot delete by tidying a folder"
        )
    }

    /// Adoption is about content the app can see. A drive that is not attached
    /// cannot be credited with anything, and must not be repointed at a file
    /// nobody can check.
    func testContentAlreadyAdoptedInPlaceIsLeftAlone() async throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("drive")
        try Data("a photo".utf8).write(to: mount.appendingPathComponent("photo.jpg"))

        store.registerHostDeviceTarget(at: mount, name: "Drive")
        XCTAssertNotNil(store.targets.first, store.lastError ?? "")

        try await importFolder(store, mount)
        let asset = try XCTUnwrap(store.assets.first)
        let first = try XCTUnwrap(store.replicaStates.first { $0.assetID == asset.id })
        XCTAssertEqual(first.relativePath, ReplicationService.volumeBackedPrefix + "photo.jpg")
        XCTAssertNil(asset.stagingRelativePath, "Adopted on the way in, never staged")

        // Sweeping again finds the same file in the same place.
        try await importFolder(store, mount)

        let second = try XCTUnwrap(store.replicaStates.first { $0.assetID == asset.id })
        XCTAssertEqual(second.relativePath, first.relativePath)
        XCTAssertEqual(store.assets.count, 1, "No second asset for the same bytes")
    }
}
