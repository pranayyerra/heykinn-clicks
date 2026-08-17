import XCTest
@testable import HeykinnClicks

/// Changes made by paths that are not an upsert.
///
/// `JournalCoverageTests` checks that every shared *table* records something.
/// That is weaker than it looks, and it gave false confidence: a table can be
/// journalled on its main upsert and still have several other statements that
/// write to it directly and record nothing. Eleven such statements existed —
/// assigning a photo to a group, pointing it at a source, repointing a copy
/// that moved on a drive, deleting a photo — and every one of them would have
/// produced a change no other device was ever told about.
///
/// So these test *write paths*, not tables, and they assert the change survives
/// a round trip through a drive rather than merely that a stamp appeared.
final class JournalWritePathTests: XCTestCase {

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-paths-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        try CatalogStore(
            databasePath: try makeDirectory(label).appendingPathComponent("catalog.sqlite").path
        )
    }

    private func makeDrive() throws -> DirectorySegmentStore {
        DirectorySegmentStore(root: try makeDirectory("drive"))
    }

    private func makeAsset(_ id: UUID = UUID(), _ name: String = "a.jpg") -> Asset {
        Asset(
            id: id, kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    private func makeGroup(_ id: UUID = UUID(), _ label: String = "Family") -> StorageGroup {
        StorageGroup(
            id: id, label: label, desiredCopies: 2,
            destinationTargetIDs: [], createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    /// Both devices meet the drive, twice round, so everything settles.
    private func settle(_ a: CatalogStore, _ b: CatalogStore, _ drive: DirectorySegmentStore) throws {
        try DriveSync.synchronise(a, with: drive)
        try DriveSync.synchronise(b, with: drive)
        try DriveSync.synchronise(a, with: drive)
    }

    // MARK: - Which group a photo is in

    /// The single most hand-made piece of state in the app, and it was written
    /// by a bare `UPDATE` that recorded nothing.
    func testAssigningAPhotoToAGroupTravels() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let assetID = UUID()
        let groupID = UUID()

        try deviceA.upsertAsset(makeAsset(assetID))
        try deviceA.upsertStorageGroup(makeGroup(groupID))
        // Settled *before* the assignment, deliberately.
        //
        // A row's creation is recorded as one whole-row stamp that expands to
        // every column at send time, reading the values as they are then — so
        // an unrecorded change to a photo the other device has never seen still
        // travels, carried along by the creation. The gap only bites once the
        // row is already known elsewhere, which is why a test that creates and
        // changes in one breath passes with the bug still in place. This one
        // did, until it was split.
        try settle(deviceA, deviceB, drive)

        try deviceA.assignStorageGroup(groupID, toAssets: [assetID])
        try settle(deviceA, deviceB, drive)

        XCTAssertEqual(
            try deviceB.fetchStorageGroupIDsByAsset()[assetID], groupID,
            "The other device does not know which group this photo is in"
        )
    }

    /// Deleting a group leaves its photos pointing at nothing. If that does not
    /// travel, the other device goes on believing they are in a group that no
    /// longer exists.
    func testPhotosLosingTheirGroupTravels() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let assetID = UUID()
        let groupID = UUID()

        try deviceA.upsertAsset(makeAsset(assetID))
        try deviceA.upsertStorageGroup(makeGroup(groupID))
        try deviceA.assignStorageGroup(groupID, toAssets: [assetID])
        try settle(deviceA, deviceB, drive)
        XCTAssertEqual(try deviceB.fetchStorageGroupIDsByAsset()[assetID], groupID)

        try deviceA.deleteStorageGroup(id: groupID)
        try settle(deviceA, deviceB, drive)

        XCTAssertNil(
            try deviceB.fetchStorageGroupIDsByAsset()[assetID],
            "The other device still has this photo in a group that was deleted"
        )
    }

    // MARK: - Which devices a group sends copies to

    /// The case this whole normalisation exists for. Two devices each add a
    /// *different* drive to the same group, neither having seen the other.
    ///
    /// While the destinations were a JSON array in one column, per-field merge
    /// treated the list as a single value and one addition was silently
    /// discarded — measured at 1 of 2 surviving. As rows, each destination is
    /// its own row with its own stamp, so both are creations and both live.
    func testTwoDevicesEachAddingADestinationKeepBoth() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let groupID = UUID()
        let driveFromA = UUID()
        let driveFromB = UUID()

        try deviceA.upsertStorageGroup(StorageGroup(
            id: groupID, label: "Family", desiredCopies: 2,
            destinationTargetIDs: [], createdAt: Date(timeIntervalSince1970: 1_000_000)
        ))
        try settle(deviceA, deviceB, drive)

        var onA = try XCTUnwrap(deviceA.fetchStorageGroups().first)
        onA.destinationTargetIDs = [driveFromA]
        try deviceA.upsertStorageGroup(onA)

        var onB = try XCTUnwrap(deviceB.fetchStorageGroups().first)
        onB.destinationTargetIDs = [driveFromB]
        try deviceB.upsertStorageGroup(onB)

        try settle(deviceA, deviceB, drive)

        for (name, catalog) in [("Device A", deviceA), ("Device B", deviceB)] {
            let held = Set(try XCTUnwrap(catalog.fetchStorageGroups().first).destinationTargetIDs)
            XCTAssertEqual(
                held, [driveFromA, driveFromB],
                "\(name) kept \(held.count) of 2 destinations — one device's addition was lost"
            )
        }
    }

    /// Removing a destination has to travel too, or the other device goes on
    /// sending copies to a drive nobody named any more.
    func testRemovingADestinationTravels() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let groupID = UUID()
        let keep = UUID()
        let remove = UUID()

        try deviceA.upsertStorageGroup(StorageGroup(
            id: groupID, label: "Family", desiredCopies: 2,
            destinationTargetIDs: [keep, remove], createdAt: Date(timeIntervalSince1970: 1_000_000)
        ))
        try settle(deviceA, deviceB, drive)
        XCTAssertEqual(try XCTUnwrap(deviceB.fetchStorageGroups().first).destinationTargetIDs.count, 2)

        var onA = try XCTUnwrap(deviceA.fetchStorageGroups().first)
        onA.destinationTargetIDs = [keep]
        try deviceA.upsertStorageGroup(onA)
        try settle(deviceA, deviceB, drive)

        XCTAssertEqual(
            try XCTUnwrap(deviceB.fetchStorageGroups().first).destinationTargetIDs, [keep],
            "The removal did not travel"
        )
        // And the device that still remembered it must not put it back.
        try settle(deviceA, deviceB, drive)
        XCTAssertEqual(try XCTUnwrap(deviceA.fetchStorageGroups().first).destinationTargetIDs, [keep])
    }

    /// Order is what placement uses to decide which drives get copies when a
    /// group names more than it wants, so it has to survive the round trip.
    func testDestinationOrderSurvives() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let first = UUID(), second = UUID(), third = UUID()

        try deviceA.upsertStorageGroup(StorageGroup(
            id: UUID(), label: "Family", desiredCopies: 2,
            destinationTargetIDs: [first, second, third],
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        ))
        try settle(deviceA, deviceB, drive)

        XCTAssertEqual(
            try XCTUnwrap(deviceB.fetchStorageGroups().first).destinationTargetIDs,
            [first, second, third],
            "The order the user named devices in was not preserved"
        )
    }

    // MARK: - Where a photo came from

    func testAssigningAPhotoToASourceTravels() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let assetID = UUID()
        let sourceID = UUID()

        try deviceA.upsertAsset(makeAsset(assetID))
        try deviceA.upsertSource(PhotoArchiveSource(
            id: sourceID, kind: .folder, label: "Folder", originPath: "/tmp", addedAt: Date()
        ))
        // Settled before the assignment, for the reason given above.
        try settle(deviceA, deviceB, drive)

        try deviceA.assignSource(sourceID, toAssets: [assetID])
        try settle(deviceA, deviceB, drive)

        XCTAssertEqual(try deviceB.fetchSourceIDsByAsset()[assetID], sourceID)
    }

    // MARK: - Deleting a photo

    /// A photo removed here and merely absent there is indistinguishable from
    /// one the other device has never been told about — so without a tombstone
    /// the next sync hands it straight back, along with every claim about where
    /// its copies live.
    func testDeletingAPhotoTravelsAndStays() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let assetID = UUID()

        try deviceA.upsertAsset(makeAsset(assetID))
        try settle(deviceA, deviceB, drive)
        XCTAssertEqual(try deviceB.fetchAssets().count, 1)

        try deviceA.deleteAsset(id: assetID)
        try settle(deviceA, deviceB, drive)

        XCTAssertTrue(try deviceB.fetchAssets().isEmpty, "The deletion did not travel")
        // And the device that still remembered it must not put it back.
        try settle(deviceA, deviceB, drive)
        XCTAssertTrue(try deviceA.fetchAssets().isEmpty, "The photo came back from the dead")
    }

    // MARK: - Where a copy lives

    /// A copy that moved on a drive is a fact about the drive, not about this
    /// device. Another device that is not told goes looking in the old place.
    func testARepointedCopyTravels() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let assetID = UUID()
        let targetID = UUID()

        try deviceA.upsertAsset(makeAsset(assetID))
        try deviceA.upsertTarget(ReplicationTarget(
            id: targetID, name: "Drive", kind: .externalVolume, volumeUUID: nil,
            markerToken: "token", registeredAt: Date(), lastSeenAt: nil, lastKnownPath: nil,
            configuredPath: nil, replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        try deviceA.upsertReplicaState(TargetReplicaState(
            assetID: assetID, targetID: targetID, state: .present,
            relativePath: "\(ReplicationService.zipMemberPrefix)old/photo.jpg",
            lastVerifiedAt: Date()
        ))
        try settle(deviceA, deviceB, drive)

        _ = try deviceA.repointZipMembers(onTarget: targetID, from: "old", to: "new")
        try settle(deviceA, deviceB, drive)

        let onB = try XCTUnwrap(deviceB.fetchReplicaStates().first)
        XCTAssertEqual(
            onB.relativePath, "\(ReplicationService.zipMemberPrefix)new/photo.jpg",
            "The other device would look for this copy in the old place"
        )
    }

    /// Withdrawing an unearned read-back claim is a correction. If it does not
    /// travel, the other device goes on reporting photos as verified that were
    /// never read.
    func testWithdrawnVerificationTravels() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let assetID = UUID()
        let targetID = UUID()

        try deviceA.upsertAsset(makeAsset(assetID))
        try deviceA.upsertTarget(ReplicationTarget(
            id: targetID, name: "Drive", kind: .externalVolume, volumeUUID: nil,
            markerToken: "token", registeredAt: Date(), lastSeenAt: nil, lastKnownPath: nil,
            configuredPath: nil, replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        try deviceA.upsertReplicaState(TargetReplicaState(
            assetID: assetID, targetID: targetID, state: .present,
            relativePath: "\(ReplicationService.archivePartPrefix)part-1",
            lastVerifiedAt: Date()
        ))
        try settle(deviceA, deviceB, drive)
        XCTAssertNotNil(try deviceB.fetchReplicaStates().first?.lastVerifiedAt)

        _ = try deviceA.withdrawUnreadPartVerifications()
        try settle(deviceA, deviceB, drive)

        XCTAssertNil(
            try deviceB.fetchReplicaStates().first?.lastVerifiedAt,
            "The other device still reports this copy as read back"
        )
    }

    // MARK: - Tags

    func testClearingTagsTravels() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        let assetID = UUID()

        try deviceA.upsertAsset(makeAsset(assetID))
        try deviceA.addTag(AssetTag(assetID: assetID, kind: .album, value: "Rome"))
        try settle(deviceA, deviceB, drive)
        XCTAssertEqual(try deviceB.fetchAllTags().count, 1)

        try deviceA.deleteAllTags()
        try settle(deviceA, deviceB, drive)

        XCTAssertTrue(try deviceB.fetchAllTags().isEmpty, "Cleared tags came back")
    }
}
