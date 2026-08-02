import XCTest
@testable import HeykinnClicks

final class CatalogBackupTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeAsset() -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "a.jpg", importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    private func makePopulatedCatalog(assets count: Int) throws -> (CatalogStore, URL) {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("catalog.sqlite")
        let catalog = try CatalogStore(databasePath: path.path)
        for _ in 0..<count { try catalog.upsertAsset(makeAsset()) }
        return (catalog, path)
    }

    func testSnapshotIsReadableAndCompleteAndLeavesNoTempFile() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 25)
        let mount = try makeTempDirectory()

        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, driveID: UUID(), expectedAssetCount: 25
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.url.path))
        XCTAssertGreaterThan(snapshot.sizeBytes, 0)
        XCTAssertEqual(snapshot.url.pathExtension, "sqlite")

        // The snapshot must open as a real catalog with the same contents.
        let restored = try CatalogStore(databasePath: snapshot.url.path)
        XCTAssertEqual(try restored.fetchAssets().count, 25)

        // No partial artefacts left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: CatalogBackupService.backupDirectory(onMount: mount).path
        )
        XCTAssertFalse(entries.contains { $0.hasSuffix(".writing") })
    }

    func testVerificationLeavesNoJournalFilesBesideTheBackup() throws {
        // Verifying read-write would switch the snapshot to WAL and strand
        // `-wal`/`-shm` files on the drive next to the backup.
        let (catalog, _) = try makePopulatedCatalog(assets: 12)
        let mount = try makeTempDirectory()
        try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, driveID: nil, expectedAssetCount: 12
        )
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: CatalogBackupService.backupDirectory(onMount: mount).path
        )
        XCTAssertEqual(entries.filter { $0.hasSuffix(".sqlite") }.count, 1)
        XCTAssertTrue(
            entries.allSatisfy { !$0.contains("-wal") && !$0.contains("-shm") && !$0.contains(".writing") },
            "Backup directory must hold only snapshots, found: \(entries)"
        )
    }

    func testBackupWorksWhenThePathContainsAnApostrophe() throws {
        // Real drive names like "Owner's Back" must not break the VACUUM INTO
        // statement or leave an unverified snapshot.
        let (catalog, _) = try makePopulatedCatalog(assets: 4)
        let parent = try makeTempDirectory()
        let mount = parent.appendingPathComponent("Owner's Back", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, driveID: nil, expectedAssetCount: 4
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.url.path))
        let restored = try CatalogStore(databasePath: snapshot.url.path)
        XCTAssertEqual(try restored.fetchAssets().count, 4)
    }

    func testVerificationRejectsATruncatedSnapshot() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 10)
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, driveID: nil, expectedAssetCount: 10
        )
        // Corrupt the snapshot the way a half-finished write would.
        try Data(repeating: 0, count: 4096).write(to: snapshot.url)
        XCTAssertThrowsError(
            try CatalogBackupService.verify(snapshotAt: snapshot.url, expectedAssetCount: 10)
        )
    }

    func testVerificationRejectsASnapshotMissingAssets() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 5)
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, driveID: nil, expectedAssetCount: 5
        )
        // A snapshot that holds fewer assets than the live catalog is stale or
        // partial and must not pass as a backup.
        XCTAssertThrowsError(
            try CatalogBackupService.verify(snapshotAt: snapshot.url, expectedAssetCount: 500)
        )
    }

    func testRetentionKeepsNewestAndPrunesOlder() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 3)
        let mount = try makeTempDirectory()
        var written: [URL] = []
        for offset in 0..<(CatalogBackupService.retainCount + 3) {
            let snapshot = try CatalogBackupService.writeSnapshot(
                from: catalog, toMount: mount, driveID: nil, expectedAssetCount: 3,
                now: Date().addingTimeInterval(Double(offset))
            )
            written.append(snapshot.url)
        }
        let remaining = CatalogBackupService.listSnapshots(onMount: mount, driveID: nil)
        XCTAssertEqual(remaining.count, CatalogBackupService.retainCount)
        // The newest must survive, the oldest must be gone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.last!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.first!.path))
        // Listing is newest-first.
        XCTAssertEqual(remaining, remaining.sorted { $0.createdAt > $1.createdAt })
    }

    func testSnapshotSucceedsWhileCatalogIsBeingWritten() throws {
        // VACUUM INTO must produce a consistent copy of a live catalog.
        let (catalog, _) = try makePopulatedCatalog(assets: 20)
        let mount = try makeTempDirectory()
        try catalog.upsertAsset(makeAsset())
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, driveID: nil, expectedAssetCount: 21
        )
        let restored = try CatalogStore(databasePath: snapshot.url.path)
        XCTAssertEqual(try restored.fetchAssets().count, 21)
        // The live catalog keeps working after the snapshot.
        try catalog.upsertAsset(makeAsset())
        XCTAssertEqual(try catalog.fetchAssets().count, 22)
    }
}
