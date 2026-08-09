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

/// When the patrol should decline to do anything.
final class PatrolFloorTests: XCTestCase {

    private let drive = UUID()

    private func replica(_ id: UUID, read: Date?) -> PatrolScheduler.Replica {
        PatrolScheduler.Replica(assetID: id, targetID: drive, sizeBytes: 1_000, lastVerifiedAt: read)
    }

    private func pick(
        _ replicas: [PatrolScheduler.Replica], floor: TimeInterval, now: Date = Date()
    ) -> [PatrolScheduler.Replica] {
        PatrolScheduler.next(
            on: drive,
            candidates: replicas,
            allReplicasByAsset: Dictionary(grouping: replicas, by: \.assetID),
            freshEnough: floor,
            now: now
        )
    }

    /// The behaviour that made a drive busy forty-eight times a day: thirty-three
    /// candidates, a budget of forty, and nothing to say how recent is recent
    /// enough — so every run read all of them again.
    func testCopiesReadRecentlyAreLeftAlone() {
        let now = Date()
        let fresh = (1...33).map { _ in
            replica(UUID(), read: now.addingTimeInterval(-30 * 60))
        }
        XCTAssertEqual(
            pick(fresh, floor: PatrolScheduler.freshEnough, now: now).count, 0,
            "read half an hour ago is not where rot will be found"
        )
        XCTAssertEqual(
            pick(fresh, floor: 0, now: now).count, 33,
            "and an explicit check still reads every one of them"
        )
    }

    func testAcopyOlderThanTheFloorIsStillRead() {
        let now = Date()
        let old = replica(UUID(), read: now.addingTimeInterval(-40 * 24 * 60 * 60))
        let recent = replica(UUID(), read: now.addingTimeInterval(-60))
        let chosen = pick([old, recent], floor: PatrolScheduler.freshEnough, now: now)
        XCTAssertEqual(chosen.map(\.assetID), [old.assetID])
    }

    /// The exemption that must survive any floor: a copy nobody has ever read
    /// is the most exposed thing in the archive.
    func testACopyNeverReadIsAlwaysWorthReading() {
        let never = replica(UUID(), read: nil)
        XCTAssertEqual(
            pick([never], floor: PatrolScheduler.freshEnough).map(\.assetID),
            [never.assetID]
        )
    }
}

/// Taking back a read-back claim that was never earned.
final class UnreadPartVerificationTests: XCTestCase {

    func testOnlyPartBackedClaimsAreWithdrawn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-withdraw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let drive = UUID()
        let read = Date(timeIntervalSince1970: 1_700_000_000)
        let part = UUID(), member = UUID(), ownFile = UUID()

        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: part, targetID: drive, state: .present,
            relativePath: ReplicationService.archivePartPrefix + "takeout-set-001",
            lastVerifiedAt: read
        ))
        // Streamed out of the zip and hashed — a real read, and it keeps its claim.
        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: member, targetID: drive, state: .present,
            relativePath: ReplicationService.zipMemberPrefix + "Exports/a.zip!Takeout/x.jpg",
            lastVerifiedAt: read
        ))
        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: ownFile, targetID: drive, state: .present,
            relativePath: "Buckets/aa/x.jpg", lastVerifiedAt: read
        ))

        XCTAssertEqual(try catalog.withdrawUnreadPartVerifications(), 1)
        let byAsset = try catalog.fetchReplicaStates()
            .reduce(into: [UUID: Date?]()) { $0[$1.assetID] = $1.lastVerifiedAt }
        XCTAssertNil(byAsset[part] ?? nil, "confirmed by name, never read")
        XCTAssertEqual(byAsset[member] ?? nil, read, "streamed out of the zip and hashed")
        XCTAssertEqual(byAsset[ownFile] ?? nil, read, "a file of its own, read directly")

        XCTAssertEqual(
            try catalog.withdrawUnreadPartVerifications(), 0,
            "and it stays withdrawn — safe to run at every launch"
        )
    }
}
