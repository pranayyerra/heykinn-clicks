import XCTest
@testable import HeykinnClicks

/// Every shared table must actually record its changes.
///
/// `CatalogScopeTests` checks that each table has been *classified*. This
/// checks the classification is true: a table declared shared but written
/// without going through the journal produces changes no other device is ever
/// told about — and the symptom is not an error, it is one device quietly
/// missing photographs the other knows are safe.
///
/// Written as one pass over every shared table rather than a test per table, so
/// a table added next year fails this until it is wired.
final class JournalCoverageTests: XCTestCase {

    private func makeCatalog() throws -> CatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    /// One representative write per shared table.
    private func writeToEverySharedTable(_ catalog: CatalogStore) throws {
        let assetID = UUID()
        let sourceID = UUID()
        let targetID = UUID()

        try catalog.upsertAsset(Asset(
            id: assetID, kind: .photo, originalFilename: "a.jpg", importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: "hash", residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        ))

        try catalog.upsertTarget(ReplicationTarget(
            id: targetID, name: "Drive", kind: .externalVolume, volumeUUID: nil,
            markerToken: "token", registeredAt: Date(), lastSeenAt: nil, lastKnownPath: nil,
            configuredPath: nil, replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))

        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: assetID, targetID: targetID, state: .present,
            relativePath: "a.jpg", lastVerifiedAt: Date()
        ))

        // With a destination, so `storage_group_destinations` is exercised too.
        try catalog.upsertStorageGroup(StorageGroup(
            id: UUID(), label: "Group", desiredCopies: 2,
            destinationTargetIDs: [targetID], createdAt: Date()
        ))

        try catalog.upsertSource(PhotoArchiveSource(
            id: sourceID, kind: .folder, label: "Folder", originPath: "/tmp",
            addedAt: Date()
        ))

        try catalog.upsertPolicyRule(PolicyRule(
            id: UUID(), name: "Rule", priority: 1, isEnabled: true,
            matchOrigin: nil, matchKind: nil, minFileSize: nil, targetResidency: .local
        ))

        try catalog.upsertMigrationJob(MigrationJob(
            id: UUID(), assetIDs: [assetID], fromDomain: .local, toDomain: .appleCloud,
            state: .pending, createdAt: Date(), updatedAt: Date(), note: nil
        ))

        try catalog.upsertImportBatch(ImportBatch(
            id: UUID(), sourcePath: "/tmp", startedAt: Date(), completedAt: nil,
            importedCount: 0, duplicateCount: 0, failedCount: 0
        ))

        try catalog.upsertTakeoutArchive(TakeoutArchive(
            id: UUID(), path: "/tmp/takeout.zip", kind: .zip, sizeBytes: 1,
            targetID: nil, discoveredAt: Date(), importedAssetCount: 0,
            skippedDuplicateCount: 0
        ))

        try catalog.appendAuditEvent(AuditEvent(
            id: UUID(), at: Date(), category: .drive, message: "something happened",
            assetID: nil, targetID: nil
        ))

        try catalog.addTag(AssetTag(assetID: assetID, kind: .album, value: "Rome"))

        try catalog.recordCapture(setID: "set-1", partNumber: 1)

        // Writes `metadata_records` and, through it, `metadata_schemas`.
        try catalog.upsertMetadataRecord(MetadataRecord(
            id: UUID(), assetID: assetID, sourceID: sourceID, scope: .asset,
            provider: "google", originPath: "/tmp/a.json", capturedAt: Date(),
            schemaFingerprint: "fingerprint", payload: #"{"title":"a"}"#
        ))
    }

    func testEverySharedTableRecordsItsChanges() throws {
        let catalog = try makeCatalog()
        try writeToEverySharedTable(catalog)

        let journalled = Set(try catalog.database.query(
            "SELECT DISTINCT table_name FROM change_field_versions;"
        ) { $0.text(0) })

        let missing = CatalogScope.shared.union(CatalogScope.appendOnly)
            .subtracting(journalled)

        XCTAssertTrue(
            missing.isEmpty,
            """
            These tables are declared shared but recorded no change: \
            \(missing.sorted().joined(separator: ", ")). \
            Wrap their writes in `journaled(_:_:)`, or this device's edits to \
            them will never reach another one.
            """
        )
    }

    /// The other direction. A device-local table that recorded a change would
    /// be offering another device a `/Volumes` path from this one.
    func testNoMachineLocalTableRecordsChanges() throws {
        let catalog = try makeCatalog()
        try writeToEverySharedTable(catalog)

        let journalled = Set(try catalog.database.query(
            "SELECT DISTINCT table_name FROM change_field_versions;"
        ) { $0.text(0) })

        let leaked = journalled.intersection(CatalogScope.deviceLocal)
        XCTAssertTrue(
            leaked.isEmpty,
            "Device-local tables recorded changes: \(leaked.sorted().joined(separator: ", "))"
        )
    }

    /// Everything written above should survive a round trip to another catalog.
    /// This is the whole point stated once: two archives, one set of facts.
    func testAWholeArchiveTravelsToAFreshDevice() throws {
        let source = try makeCatalog()
        try writeToEverySharedTable(source)

        let destination = try makeCatalog()
        let records = try source.journal.changes(since: nil)
        let outcome = try destination.journal.merge(records)

        XCTAssertTrue(outcome.rejected.isEmpty, "Rejected: \(outcome.rejected)")
        XCTAssertGreaterThan(outcome.applied, 0)

        // Spot-check across several tables rather than trusting the count.
        XCTAssertEqual(try destination.fetchStorageGroups().count, 1)
        XCTAssertEqual(try destination.fetchTargets().count, 1)
        XCTAssertEqual(try destination.fetchAssets().count, 1)
        XCTAssertEqual(try destination.fetchSources().count, 1)
        XCTAssertEqual(try destination.fetchPolicyRules().count, 1)
        XCTAssertEqual(try destination.fetchReplicaStates().count, 1)
        XCTAssertEqual(try destination.fetchAllTags().count, 1)
        XCTAssertEqual(try destination.fetchTakeoutArchives().count, 1)
    }
}
