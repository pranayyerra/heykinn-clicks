import XCTest
@testable import HeykinnClicks

/// Guards the "nothing is lost or left inconsistent across a restart"
/// properties: atomic commits, resumable imports, and recoverable records.
final class DurabilityTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCatalog() throws -> CatalogStore {
        try CatalogStore(databasePath: try makeTempDirectory().appendingPathComponent("catalog.sqlite").path)
    }

    private func makeAsset(hash: String = UUID().uuidString, batchID: UUID? = nil) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "a.jpg", importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: hash, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: batchID, exifSummary: [:]
        )
    }

    // MARK: - Atomicity

    func testTransactionRollsBackEveryWriteOnFailure() throws {
        let catalog = try makeCatalog()
        let asset = makeAsset()
        struct Boom: Error {}

        XCTAssertThrowsError(
            try catalog.transaction {
                try catalog.upsertAsset(asset)
                try catalog.upsertReplicaState(TargetReplicaState(
                    assetID: asset.id, targetID: UUID(), state: .present,
                    relativePath: "volume:x.jpg", lastVerifiedAt: Date()
                ))
                throw Boom()
            }
        )
        XCTAssertEqual(try catalog.fetchAssets().count, 0, "A failed chunk must leave no assets")
        XCTAssertEqual(try catalog.fetchReplicaStates().count, 0, "…and no dangling replica states")
    }

    func testTransactionCommitsAssetAndReplicaTogether() throws {
        let catalog = try makeCatalog()
        let asset = makeAsset()
        let targetID = UUID()
        try catalog.transaction {
            try catalog.upsertAsset(asset)
            try catalog.upsertReplicaState(TargetReplicaState(
                assetID: asset.id, targetID: targetID, state: .present,
                relativePath: "volume:x.jpg", lastVerifiedAt: Date()
            ))
        }
        XCTAssertEqual(try catalog.fetchAssets().count, 1)
        XCTAssertEqual(try catalog.fetchReplicaStates().count, 1)
    }

    // MARK: - Resume checkpoint

    func testArchiveCheckpointSurvivesReopen() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite").path
        let archiveID = UUID()
        do {
            let catalog = try CatalogStore(databasePath: path)
            try catalog.upsertTakeoutArchive(TakeoutArchive(
                id: archiveID, path: "/x/takeout-S-001", kind: .folder, sizeBytes: 10,
                targetID: nil, discoveredAt: Date(), importedAt: nil, importBatchID: nil,
                importedAssetCount: 40, skippedDuplicateCount: 5, note: nil,
                exportSetID: "S", partNumber: 1,
                importedThroughIndex: 450, importedFileTotal: 2000
            ))
        }
        // Reopen as a fresh process would.
        let reopened = try CatalogStore(databasePath: path)
        let archive = try XCTUnwrap(reopened.fetchTakeoutArchives().first { $0.id == archiveID })
        XCTAssertEqual(archive.importedThroughIndex, 450)
        XCTAssertEqual(archive.importedFileTotal, 2000)
        XCTAssertEqual(archive.importedAssetCount, 40)
        XCTAssertFalse(archive.isImported, "A checkpointed part is resumable, not finished")
    }

    func testResumeIndexIsIgnoredWhenFileCountChanged() {
        // Mirrors the guard in the import loop: an index into a list that has
        // changed length cannot be trusted, so the part restarts.
        func resumePoint(checkpoint: Int, recorded: Int, actual: Int) -> Int {
            recorded == actual ? min(checkpoint, actual) : 0
        }
        XCTAssertEqual(resumePoint(checkpoint: 450, recorded: 2000, actual: 2000), 450)
        XCTAssertEqual(resumePoint(checkpoint: 450, recorded: 2000, actual: 1900), 0)
        XCTAssertEqual(resumePoint(checkpoint: 5000, recorded: 2000, actual: 2000), 2000)
    }

    // MARK: - Recoverable records

    func testImportBatchExistsBeforeAssetsReferenceIt() throws {
        let catalog = try makeCatalog()
        let batchID = UUID()
        try catalog.upsertImportBatch(ImportBatch(
            id: batchID, sourcePath: "Takeout set", startedAt: Date(), completedAt: nil,
            importedCount: 0, duplicateCount: 0, failedCount: 0
        ))
        try catalog.upsertAsset(makeAsset(batchID: batchID))

        let batches = try catalog.fetchImportBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertNil(batches[0].completedAt, "An in-flight batch is recorded but not yet complete")
        let assets = try catalog.fetchAssets()
        XCTAssertEqual(assets[0].importBatchID, batchID)
        XCTAssertTrue(
            batches.map(\.id).contains(assets[0].importBatchID!),
            "No asset may reference a batch that does not exist"
        )
    }

    func testWALJournalKeepsCommittedDataAvailableToAReopen() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite").path
        let hash = UUID().uuidString
        do {
            let catalog = try CatalogStore(databasePath: path)
            try catalog.transaction { try catalog.upsertAsset(makeAsset(hash: hash)) }
            // No explicit close: mimics the process disappearing after commit.
        }
        let reopened = try CatalogStore(databasePath: path)
        XCTAssertEqual(reopened.fetchAssetsSafely().first?.contentHash, hash)
    }
}

private extension CatalogStore {
    func fetchAssetsSafely() -> [Asset] {
        (try? fetchAssets()) ?? []
    }
}
