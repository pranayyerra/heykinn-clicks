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

    /// A volume the app cannot write to is the failure a user actually hits:
    /// macOS gates external volumes, and SQLite reports the refusal as
    /// "unable to open database", which reads like corruption and sends you
    /// looking at the disk instead of at the permission.
    func testAnUnwritableVolumeIsReportedAsBlockedAccessNotCorruption() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 3)
        let mount = try makeTempDirectory()
        let directory = CatalogBackupService.backupDirectory(onMount: mount)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Read and execute, no write: what a denied volume looks like from here.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        XCTAssertThrowsError(
            try CatalogBackupService.writeSnapshot(
                from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 3
            )
        ) { error in
            guard case CatalogBackupService.BackupError.accessBlocked(let volume, _) = error else {
                return XCTFail("Expected accessBlocked, got \(error)")
            }
            XCTAssertEqual(volume, mount.lastPathComponent)
            let described = error.localizedDescription
            XCTAssertTrue(described.contains("Privacy & Security"), "Must say how to fix it")
        }
    }

    func testSnapshotIsReadableAndCompleteAndLeavesNoTempFile() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 25)
        let mount = try makeTempDirectory()

        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, targetID: UUID(), expectedAssetCount: 25
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
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 12
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
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 4
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.url.path))
        let restored = try CatalogStore(databasePath: snapshot.url.path)
        XCTAssertEqual(try restored.fetchAssets().count, 4)
    }

    func testVerificationRejectsATruncatedSnapshot() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 10)
        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 10
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
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 5
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
                from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 3,
                now: Date().addingTimeInterval(Double(offset))
            )
            written.append(snapshot.url)
        }
        let remaining = CatalogBackupService.listSnapshots(onMount: mount, targetID: nil)
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
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 21
        )
        let restored = try CatalogStore(databasePath: snapshot.url.path)
        XCTAssertEqual(try restored.fetchAssets().count, 21)
        // The live catalog keeps working after the snapshot.
        try catalog.upsertAsset(makeAsset())
        XCTAssertEqual(try catalog.fetchAssets().count, 22)
    }
}

/// What "complete" has to mean now that the catalog holds more than the
/// photos' own records.
extension CatalogBackupTests {

    private func makeRecord(assetID: UUID?, sourceID: UUID) -> MetadataRecord {
        let payload = #"{"title":"a.jpg","description":"by the lake"}"#
        return MetadataRecord(
            id: UUID(), assetID: assetID, sourceID: sourceID, scope: .asset,
            provider: "google", originPath: "Takeout/\(UUID().uuidString).json",
            capturedAt: Date(), schemaFingerprint: MetadataRecord.fingerprint(of: payload),
            payload: payload
        )
    }

    /// The failure this was written for, reproduced.
    ///
    /// A snapshot taken on a real archive held every one of its assets and not
    /// one of the provider payloads captured beside them. It
    /// passed `integrity_check`, it passed the asset count, and it went into
    /// the audit log as "verified" — while missing the only part of the catalog
    /// that cannot be rebuilt without re-reading every export zip.
    ///
    /// A backup is not complete because the photos are in it.
    func testASnapshotMissingCapturedMetadataIsNotVerified() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 3)
        let source = UUID()
        try catalog.upsertMetadataRecord(makeRecord(assetID: nil, sourceID: source))

        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 3
        )

        // Empty the payloads out of the copy, exactly as the real snapshot was.
        let doctored = try SQLiteDatabase(path: snapshot.url.path)
        try doctored.exec("DELETE FROM metadata_records;")

        XCTAssertNoThrow(
            try CatalogBackupService.verify(snapshotAt: snapshot.url, expectedAssetCount: 3),
            "the premise: the old check saw nothing wrong with this file"
        )
        XCTAssertThrowsError(
            try CatalogBackupService.verify(
                snapshotAt: snapshot.url,
                expectedAssetCount: 3,
                mustHoldRowsIn: ["assets", "metadata_records"]
            )
        ) { error in
            guard case CatalogBackupService.BackupError.incomplete(let tables) = error else {
                return XCTFail("Expected incomplete, got \(error)")
            }
            XCTAssertEqual(tables, ["metadata_records"])
            XCTAssertTrue(error.localizedDescription.contains("metadata_records"))
        }
    }

    /// A table added after the backup code was written must be covered without
    /// anybody remembering to add it. `asset_tags` did not exist when snapshots
    /// were built, and was absent from the real snapshot entirely — not empty,
    /// missing — which a check that only counts rows in known tables would step
    /// straight past.
    func testTablesAreDiscoveredFromTheSchemaRatherThanListedByHand() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 2)
        let source = UUID()
        try catalog.upsertMetadataRecord(makeRecord(assetID: nil, sourceID: source))

        let populated = try catalog.nonEmptyTables()
        XCTAssertTrue(populated.contains("assets"))
        XCTAssertTrue(
            populated.contains("metadata_records"),
            "a table holding rows must be found without being named anywhere"
        )
        XCTAssertFalse(
            populated.contains("asset_tags"),
            "and a table holding nothing is nothing to lose, so it is not demanded"
        )
    }

    /// A snapshot a few rows behind a catalog that is still being written to is
    /// a good snapshot. Only a whole category going missing is a failure, so
    /// counts are not compared.
    func testASnapshotTakenWhileTheCatalogGrowsIsStillComplete() throws {
        let (catalog, _) = try makePopulatedCatalog(assets: 3)
        let source = UUID()
        try catalog.upsertMetadataRecord(makeRecord(assetID: nil, sourceID: source))

        let mount = try makeTempDirectory()
        let snapshot = try CatalogBackupService.writeSnapshot(
            from: catalog, toMount: mount, targetID: nil, expectedAssetCount: 3
        )
        // The catalog moves on after the copy was taken.
        try catalog.upsertMetadataRecord(makeRecord(assetID: nil, sourceID: source))
        try catalog.upsertAsset(makeAsset())

        XCTAssertNoThrow(try CatalogBackupService.verify(
            snapshotAt: snapshot.url,
            expectedAssetCount: 3,
            mustHoldRowsIn: try catalog.nonEmptyTables()
        ))
    }
}
