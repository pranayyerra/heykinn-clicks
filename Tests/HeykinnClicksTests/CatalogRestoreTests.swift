import XCTest
@testable import HeykinnClicks

/// The read half of catalog backup.
///
/// Snapshots were written and verified from the first release, and nothing in
/// the app ever opened one: recovery meant quitting, finding a file on a drive
/// and copying it over `catalog.sqlite` by hand. These cover the way back.
final class CatalogRestoreTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeAsset(_ name: String = "a.jpg") -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    private func makeCatalog(assets count: Int) throws -> (CatalogStore, URL) {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("catalog.sqlite")
        let catalog = try CatalogStore(databasePath: path.path)
        for _ in 0..<count { try catalog.upsertAsset(makeAsset()) }
        return (catalog, path)
    }

    // MARK: - Reading a snapshot back

    func testContentsReportsWhatASnapshotHolds() throws {
        let (catalog, _) = try makeCatalog(assets: 7)
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 7
        )

        let contents = CatalogBackupService.contents(ofSnapshotAt: snapshot.url)
        XCTAssertEqual(contents?.assetCount, 7)
        XCTAssertGreaterThan(contents?.tablesWithRows ?? 0, 0, "A populated snapshot holds rows in at least one table")
    }

    /// A file that will not open is not a way back, and must not be offered as
    /// one. Nil rather than a throw: the caller's question is only whether to
    /// list it.
    func testAnUnreadableFileIsNotOfferedAsASnapshot() throws {
        let dir = try makeTempDirectory()
        let junk = dir.appendingPathComponent("catalog-20260101-000000.sqlite")
        try Data("this is not a database".utf8).write(to: junk)

        XCTAssertNil(CatalogBackupService.contents(ofSnapshotAt: junk))
        XCTAssertNil(CatalogBackupService.contents(ofSnapshotAt: dir.appendingPathComponent("absent.sqlite")))
    }

    /// Restoring an empty catalog would drop every record of photos that are
    /// still sitting on the drives — the worst thing this feature could do, so
    /// an empty snapshot is refused before anybody can choose it.
    func testASnapshotHoldingNoAssetsIsRefused() throws {
        let dir = try makeTempDirectory()
        let empty = dir.appendingPathComponent("catalog-20260101-000000.sqlite")
        _ = try CatalogStore(databasePath: empty.path)

        XCTAssertNil(CatalogBackupService.contents(ofSnapshotAt: empty))
    }

    // MARK: - Swapping the file underneath a live connection

    func testReplaceContentsSwapsTheCatalogAndKeepsTheOldOne() throws {
        let (catalog, livePath) = try makeCatalog(assets: 3)
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 3
        )
        // Move on from the snapshot, so restoring is observably a step back.
        for _ in 0..<5 { try catalog.upsertAsset(makeAsset()) }
        XCTAssertEqual(try catalog.fetchAssets().count, 8)

        let keptAside = try catalog.replaceContents(withDatabaseAt: snapshot.url)

        XCTAssertEqual(try catalog.fetchAssets().count, 3, "The live catalog is the snapshot now")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptAside.path), "The replaced catalog is kept, not deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: livePath.path))

        // Opened the way somebody recovering from it would: copied into place
        // and used. It must hold all 8 — including the writes made after the
        // snapshot, which is the whole reason to keep it.
        let recovered = try CatalogStore(databasePath: keptAside.path)
        XCTAssertEqual(
            try recovered.fetchAssets().count, 8,
            "What is kept must be the catalog that was replaced, write-ahead log and all"
        )
    }

    /// The connection stays usable for writes afterwards. Reopening is the
    /// whole point — a restore that left a closed handle would fail at the
    /// next thing the app did rather than here.
    func testTheCatalogIsWritableAfterARestore() throws {
        let (catalog, _) = try makeCatalog(assets: 2)
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 2
        )
        try catalog.replaceContents(withDatabaseAt: snapshot.url)

        try catalog.upsertAsset(makeAsset("after-restore.jpg"))
        XCTAssertEqual(try catalog.fetchAssets().count, 3)
        XCTAssertTrue(try catalog.fetchAssets().contains { $0.originalFilename == "after-restore.jpg" })
    }

    /// A `-wal` beside the replaced database describes the database that is
    /// gone. Left there, it is how a good snapshot opens as a corrupt one.
    func testStaleJournalsDoNotSurviveTheSwap() throws {
        let (catalog, livePath) = try makeCatalog(assets: 4)
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 4
        )
        // WAL mode is on, so writing leaves one beside the catalog.
        try catalog.upsertAsset(makeAsset())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: livePath.path + "-wal"),
            "the premise: a live catalog carries a write-ahead log"
        )

        try catalog.replaceContents(withDatabaseAt: snapshot.url)

        // Whatever journal exists now belongs to the reopened database, and it
        // cannot be describing the one that was replaced.
        XCTAssertEqual(try catalog.fetchAssets().count, 4)
    }

    /// A restore that cannot complete must leave the app on the catalog it
    /// started with, still able to read and write it.
    func testAFailedRestoreLeavesTheOriginalInPlace() throws {
        let (catalog, _) = try makeCatalog(assets: 6)
        let absent = try makeTempDirectory().appendingPathComponent("not-there.sqlite")

        XCTAssertThrowsError(try catalog.replaceContents(withDatabaseAt: absent))

        XCTAssertEqual(try catalog.fetchAssets().count, 6, "Still the catalog it started with")
        try catalog.upsertAsset(makeAsset())
        XCTAssertEqual(try catalog.fetchAssets().count, 7, "And still writable")
    }
}

/// Restoring through the store: what the app offers, what it refuses, and what
/// the archive looks like afterwards.
@MainActor
final class CatalogRestoreOrchestrationTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-restore-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

    private func makeAsset(_ name: String) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    /// End to end: a snapshot taken, the archive moved on, then put back.
    func testRestoringPutsTheArchiveBackToTheSnapshot() throws {
        let directory = try makeTempDirectory()
        let store = makeStore(in: directory)
        for index in 0..<4 { try store.catalog.upsertAsset(makeAsset("early-\(index).jpg")) }
        store.loadAll()
        XCTAssertEqual(store.countedPhotoTotal, 4)

        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: store.catalog, toMount: mount, targetID: nil, expectedAssetCount: 4
        )

        for index in 0..<3 { try store.catalog.upsertAsset(makeAsset("later-\(index).jpg")) }
        store.loadAll()
        XCTAssertEqual(store.countedPhotoTotal, 7)

        store.restoreCatalog(from: snapshot)

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.countedPhotoTotal, 4, "Derived state is rebuilt from the restored catalog, not left stale")
        XCTAssertEqual(store.assets.count, 4)
        XCTAssertFalse(store.assets.contains { $0.originalFilename.hasPrefix("later-") })
    }

    /// The restore is written into the catalog it produced, because that is
    /// where somebody asking "why does this say something different" looks.
    func testTheRestoreIsRecordedInTheRestoredCatalog() throws {
        let directory = try makeTempDirectory()
        let store = makeStore(in: directory)
        try store.catalog.upsertAsset(makeAsset("a.jpg"))
        store.loadAll()
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: store.catalog, toMount: mount, targetID: nil, expectedAssetCount: 1
        )

        store.restoreCatalog(from: snapshot)

        let recorded = store.auditEvents.first { $0.message.contains("Catalog restored from") }
        XCTAssertNotNil(recorded, "A restore is a thing that happened to the archive")
        XCTAssertTrue(
            recorded?.message.contains("kept at") ?? false,
            "It must say where the replaced catalog went, since that is the way back from the way back"
        )
    }

    /// A damaged or absent snapshot is refused with something a person can act
    /// on, and the catalog is left alone.
    func testAnUnreadableSnapshotIsRefusedWithoutTouchingTheCatalog() throws {
        let directory = try makeTempDirectory()
        let store = makeStore(in: directory)
        try store.catalog.upsertAsset(makeAsset("a.jpg"))
        store.loadAll()

        let junkDirectory = try makeTempDirectory()
        let junk = junkDirectory.appendingPathComponent("catalog-20260101-000000.sqlite")
        try Data("not a database".utf8).write(to: junk)

        store.restoreCatalog(from: CatalogSnapshot(url: junk, createdAt: Date(), sizeBytes: 20, targetID: nil))

        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.lastError?.contains("reconnect") ?? false, "Must say what to try")
        XCTAssertEqual(store.assets.count, 1, "The catalog is untouched")
    }

    /// Work in flight is writing rows into the catalog that is about to be
    /// replaced. The half that lands after the snapshot would describe files
    /// the restored catalog has never heard of.
    func testARestoreIsRefusedWhileAnImportIsRunning() throws {
        let directory = try makeTempDirectory()
        let store = makeStore(in: directory)
        try store.catalog.upsertAsset(makeAsset("a.jpg"))
        store.loadAll()
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: store.catalog, toMount: mount, targetID: nil, expectedAssetCount: 1
        )

        store.isImporting = true
        XCTAssertNotNil(store.catalogRestoreBlocker)
        store.restoreCatalog(from: snapshot)

        XCTAssertTrue(store.lastError?.contains("import") ?? false)

        store.isImporting = false
        XCTAssertNil(store.catalogRestoreBlocker, "And allowed once it finishes")
    }
}
