import XCTest
@testable import HeykinnClicks

/// Covers the connect/disconnect contract: work stops at a safe boundary,
/// nothing is lost, and a reconnect picks up where it left off.
@MainActor
final class DriveLifecycleTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeDrive(id: UUID = UUID()) -> ManagedDrive {
        ManagedDrive(
            id: id, name: "Test", volumeUUID: "VOL", markerToken: "tok",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ManagedDrive.defaultReplicaRoot
        )
    }

    /// A vanished volume must be reported as gone so loops can stop, while a
    /// merely-busy one stays connected (covered in DriveResilienceTests).
    func testUnmountedVolumeIsReportedDisconnected() throws {
        let monitor = DriveMonitor()
        let drive = makeDrive()
        let mount = try makeTempDirectory()
        monitor.setConnectedMountsForTesting([drive.id: mount])

        try FileManager.default.removeItem(at: mount)
        monitor.rescan(managedDrives: [drive])
        XCTAssertNil(monitor.connectedMounts[drive.id])
    }

    /// An interrupted part must leave a checkpoint that resumes rather than
    /// restarting — the property that makes unplugging cheap.
    func testInterruptedPartResumesFromItsCheckpoint() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite").path
        let archiveID = UUID()
        do {
            let catalog = try CatalogStore(databasePath: path)
            try catalog.upsertTakeoutArchive(TakeoutArchive(
                id: archiveID, path: "/Volumes/D/takeout-S-001", kind: .folder, sizeBytes: 1,
                driveID: nil, discoveredAt: Date(), importedAt: nil, importBatchID: nil,
                importedAssetCount: 700, skippedDuplicateCount: 12, note: nil,
                exportSetID: "S", partNumber: 1,
                importedThroughIndex: 800, importedFileTotal: 5_000
            ))
        }
        let reopened = try CatalogStore(databasePath: path)
        let archive = try XCTUnwrap(reopened.fetchTakeoutArchives().first { $0.id == archiveID })

        // Same file list -> resume; changed list -> start over.
        func resumePoint(_ actualTotal: Int) -> Int {
            archive.importedFileTotal == actualTotal
                ? min(archive.importedThroughIndex, actualTotal) : 0
        }
        XCTAssertEqual(resumePoint(5_000), 800, "Unplug must cost only the chunk in flight")
        XCTAssertEqual(resumePoint(4_900), 0, "A changed file list must not be resumed blindly")
        XCTAssertFalse(archive.isImported, "A checkpointed part is resumable, not complete")
    }

    /// Interrupted replication work must stay queued so a reconnect drains it.
    func testInterruptedReplicationStaysQueued() throws {
        let catalog = try CatalogStore(
            databasePath: try makeTempDirectory().appendingPathComponent("c.sqlite").path
        )
        let driveID = UUID()
        let task = ReplicationTask(
            id: UUID(), assetID: UUID(), driveID: driveID, action: .copy,
            state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
        )
        try catalog.upsertReplicationTask(task)

        // Simulate the app dying mid-sync: the task was never completed.
        let reloaded = try catalog.fetchReplicationTasks()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].state, .queued, "Unfinished work must survive as queued")
    }

    /// A partially written replica must never be mistaken for a good one.
    func testPartialCopyIsDiscardedRatherThanTrusted() throws {
        let mount = try makeTempDirectory()
        let drive = makeDrive()
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let source = try makeTempDirectory().appendingPathComponent("photo.jpg")
        try Data("the real bytes".utf8).write(to: source)
        let assetID = UUID()
        let stagedPath = try staging.stage(fileAt: source, assetID: assetID, fileExtension: "jpg")
        let hash = try HashingService.sha256(of: staging.url(forRelativePath: stagedPath))
        let asset = Asset(
            id: assetID, kind: .photo, originalFilename: "photo.jpg", importOrigin: .localFolder,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 14,
            pixelWidth: nil, pixelHeight: nil, contentHash: hash, residency: .local,
            residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: stagedPath, importBatchID: nil, exifSummary: [:]
        )

        // Leave the debris an unplug mid-copy would produce.
        let destination = ReplicationService.replicaURL(for: asset, drive: drive, mountURL: mount)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("half a fi".utf8).write(to: destination.appendingPathExtension("partial"))

        let result = ReplicationService.perform(
            ReplicationTask(
                id: UUID(), assetID: assetID, driveID: drive.id, action: .copy,
                state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
            ),
            drive: drive, mountURL: mount, asset: asset,
            sourceURL: staging.url(forRelativePath: stagedPath)
        )

        XCTAssertEqual(result.task.state, .completed)
        XCTAssertEqual(try HashingService.sha256(of: destination), hash)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path),
            "Debris from the interrupted copy must be gone"
        )
    }
}
