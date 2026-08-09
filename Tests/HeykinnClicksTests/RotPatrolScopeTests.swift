import XCTest
@testable import HeykinnClicks

/// What the background patrol is for, and what it must not spend itself on.
///
/// The patrol reads bytes, because reading is the only thing that finds rot.
/// Most of this archive's copies have no bytes of their own to read — they are
/// photos counted inside an export part — so the forty files it read every half
/// hour were almost never files and almost never read.
@MainActor
final class RotPatrolScopeTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []; suiteNames = []
        super.tearDown()
    }

    private func asset(_ name: String) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    /// A part-backed copy confirmed present has not been read, so it must not
    /// come away claiming it was. This is what let 21,117 photos be reported as
    /// "all read back" on the strength of a file existing with the right name.
    func testConfirmingAPartIsThereDoesNotCountAsReadingTheBytes() throws {
        let drive = ReplicationTarget(
            id: UUID(), name: "Owner's Back", volumeUUID: nil, markerToken: "token",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-patrol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        roots.append(mount)
        let stem = "takeout-set-001"
        let partURL = mount.appendingPathComponent(stem + ".zip")
        try Data("not really a zip".utf8).write(to: partURL)

        let photo = asset("IMG_1.HEIC")
        let existing = TargetReplicaState(
            assetID: photo.id, targetID: drive.id, state: .present,
            relativePath: ReplicationService.archivePartPrefix + stem,
            lastVerifiedAt: nil
        )
        let task = ReplicationTask(
            id: UUID(), assetID: photo.id, targetID: drive.id,
            action: .verify, state: .queued, queuedAt: Date()
        )

        let result = ReplicationService.perform(
            task, drive: drive, mountURL: mount, asset: photo, sourceURL: nil,
            existingReplica: existing,
            archivePathsByStem: [stem: partURL.path]
        )
        XCTAssertEqual(result.replica?.state, .present, "the part is there, so the copy is there")
        XCTAssertNil(
            result.replica?.lastVerifiedAt,
            "and nothing was read, so nothing may claim to have been read back"
        )
    }

    /// The path is known, so finding it must not mean searching for it.
    func testAPartIsFoundWhereTheCatalogSaysRatherThanBySearching() throws {
        let drive = ReplicationTarget(
            id: UUID(), name: "Drive", volumeUUID: nil, markerToken: "token",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
        // A mount the walk could never succeed on: the part is not under it.
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-empty-\(UUID().uuidString)", isDirectory: true)
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-real-\(UUID().uuidString)", isDirectory: true)
        for url in [mount, elsewhere] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            roots.append(url)
        }
        let stem = "takeout-set-007"
        let partURL = elsewhere.appendingPathComponent(stem + ".zip")
        try Data("x".utf8).write(to: partURL)

        let photo = asset("IMG_2.HEIC")
        let result = ReplicationService.perform(
            ReplicationTask(
                id: UUID(), assetID: photo.id, targetID: drive.id,
                action: .verify, state: .queued, queuedAt: Date()
            ),
            drive: drive, mountURL: mount, asset: photo, sourceURL: nil,
            existingReplica: TargetReplicaState(
                assetID: photo.id, targetID: drive.id, state: .present,
                relativePath: ReplicationService.archivePartPrefix + stem,
                lastVerifiedAt: nil
            ),
            archivePathsByStem: [stem: partURL.path]
        )
        XCTAssertEqual(
            result.replica?.state, .present,
            "the recorded path answered it; a walk of the mount never could have"
        )
    }

    /// The patrol's budget goes to copies that can actually be read.
    func testThePatrolSkipsCopiesThatHaveNoBytesOfTheirOwn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-patrol-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        roots.append(directory)
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let drive = UUID()
        let inPart = asset("in-part.jpg"), ownFile = asset("own-file.jpg")
        for one in [inPart, ownFile] { try catalog.upsertAsset(one) }
        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: inPart.id, targetID: drive, state: .present,
            relativePath: ReplicationService.archivePartPrefix + "takeout-set-001",
            lastVerifiedAt: nil
        ))
        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: ownFile.id, targetID: drive, state: .present,
            relativePath: "Buckets/aa/own-file.jpg", lastVerifiedAt: nil
        ))

        // Not the store's queueing path — that needs a mounted drive — but the
        // rule it applies, stated where it can be checked.
        let patrolWorthy = try catalog.fetchReplicaStates().filter {
            !ReplicationService.isInsideADownload($0.relativePath)
        }
        XCTAssertEqual(patrolWorthy.map(\.assetID), [ownFile.id])
    }

    func testTheProgressLineSaysWhichWorkItIsDoing() {
        var progress = SyncProgress(
            targetID: UUID(), targetName: "Owner's Back",
            totalTasks: 40, completedTasks: 0, failedTasks: 0,
            currentItem: "IMG_3636.HEIC"
        )
        progress.currentAction = .verify
        XCTAssertEqual(progress.currentVerb, "Checking", "a re-read is not a copy")
        progress.currentAction = .copy
        XCTAssertEqual(progress.currentVerb, "Copying")
        progress.currentAction = .remove
        XCTAssertEqual(progress.currentVerb, "Removing")
    }
}
