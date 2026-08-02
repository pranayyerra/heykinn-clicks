import XCTest
@testable import HeykinnClicks

/// A copy that cannot run because the drive holding the bytes is unplugged is
/// still owed. Recording it as failed loses the work silently.
final class SourceUnavailableTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeDrive() -> ManagedDrive {
        ManagedDrive(
            id: UUID(), name: "Target", volumeUUID: nil, markerToken: "t",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ManagedDrive.defaultReplicaRoot
        )
    }

    private func makeAsset() -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "photo.jpg", importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 10,
            pixelWidth: nil, pixelHeight: nil, contentHash: "abc", residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    func testMissingSourceLeavesTheTaskQueuedRatherThanFailed() throws {
        let drive = makeDrive()
        let asset = makeAsset()
        let task = ReplicationTask(
            id: UUID(), assetID: asset.id, driveID: drive.id, action: .copy,
            state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
        )

        let result = ReplicationService.perform(
            task, drive: drive, mountURL: try makeTempDirectory(),
            asset: asset, sourceURL: nil
        )

        XCTAssertTrue(result.isTransient, "An unplugged source is temporary, not a failure")
        XCTAssertEqual(result.task.state, .queued, "The copy is still owed")
        XCTAssertNil(result.replica, "Nothing may be recorded as present")
    }

    func testAGenuineFailureIsStillRecordedAsFailed() throws {
        let drive = makeDrive()
        var asset = makeAsset()
        asset.contentHash = "hash-that-will-not-match"

        let sourceDir = try makeTempDirectory()
        let source = sourceDir.appendingPathComponent("photo.jpg")
        try Data("content that hashes differently".utf8).write(to: source)

        let result = ReplicationService.perform(
            ReplicationTask(
                id: UUID(), assetID: asset.id, driveID: drive.id, action: .copy,
                state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
            ),
            drive: drive, mountURL: try makeTempDirectory(), asset: asset, sourceURL: source
        )

        XCTAssertFalse(result.isTransient, "A hash mismatch is a real failure, not a wait")
        XCTAssertEqual(result.task.state, .failed)
    }

    func testCopySucceedsOnceASourceIsReachableAgain() throws {
        let drive = makeDrive()
        let sourceDir = try makeTempDirectory()
        let source = sourceDir.appendingPathComponent("photo.jpg")
        try Data("real bytes".utf8).write(to: source)

        var asset = makeAsset()
        asset.contentHash = try HashingService.sha256(of: source)
        let mount = try makeTempDirectory()

        // First attempt with the source drive absent.
        let blocked = ReplicationService.perform(
            ReplicationTask(
                id: UUID(), assetID: asset.id, driveID: drive.id, action: .copy,
                state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
            ),
            drive: drive, mountURL: mount, asset: asset, sourceURL: nil
        )
        XCTAssertTrue(blocked.isTransient)

        // The drive comes back and the same task now succeeds.
        let retried = ReplicationService.perform(
            blocked.task, drive: drive, mountURL: mount, asset: asset, sourceURL: source
        )
        XCTAssertEqual(retried.task.state, .completed)
        XCTAssertEqual(retried.replica?.state, .present)
    }
}
