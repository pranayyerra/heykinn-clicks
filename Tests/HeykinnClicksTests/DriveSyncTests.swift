import XCTest
@testable import HeykinnClicks

/// Two archives, one drive.
///
/// The point of the whole design, exercised end to end: a directory stands in
/// for a plugged-in drive, two catalogs write to it and read from it, and they
/// have to end up agreeing — including when the drive is pulled out half way
/// through a write, which is the failure removable media actually has.
final class DriveSyncTests: XCTestCase {

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-sync-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        let directory = try makeDirectory(label)
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    /// A drive: somewhere both devices can reach, one at a time.
    private func makeDrive() throws -> DirectorySegmentStore {
        DirectorySegmentStore(root: try makeDirectory("drive"))
    }

    private func makeGroup(id: UUID = UUID(), label: String, copies: Int = 2) -> StorageGroup {
        StorageGroup(
            id: id, label: label, desiredCopies: copies,
            destinationTargetIDs: [], createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private func labels(_ catalog: CatalogStore) throws -> [String] {
        try catalog.fetchStorageGroups().map(\.label).sorted()
    }

    // MARK: - The basic journey

    func testWorkTravelsFromOneMacToAnotherOnADrive() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive)

        // Drive unplugged, carried across the room, plugged into the other device.
        let report = try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertTrue(report.outcome.rejected.isEmpty, "\(report.outcome.rejected)")
        XCTAssertEqual(try labels(deviceB), ["Family"])
    }

    func testBothMachinesEndUpWithEverything() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.synchronise(deviceA, with: drive)

        try deviceB.upsertStorageGroup(makeGroup(label: "Work"))
        try DriveSync.synchronise(deviceB, with: drive)

        // And back to the first device.
        try DriveSync.synchronise(deviceA, with: drive)

        XCTAssertEqual(try labels(deviceA), ["Family", "Work"])
        XCTAssertEqual(try labels(deviceB), ["Family", "Work"])
    }

    /// A drive plugged in repeatedly with nothing new must do nothing, rather
    /// than growing a file or re-applying what is already known.
    func testSyncingRepeatedlyWithNoChangesIsQuiet() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()
        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))

        let first = try DriveSync.publish(from: deviceA, to: drive)
        XCTAssertGreaterThan(first.recordsWritten, 0)

        let second = try DriveSync.publish(from: deviceA, to: drive)
        let third = try DriveSync.publish(from: deviceA, to: drive)

        XCTAssertTrue(second.upToDate, "Republished work it had already written")
        XCTAssertTrue(third.upToDate)
    }

    /// Reading the same drive again is expected — it is plugged in every day.
    func testMergingTheSameDriveTwiceAppliesNothingTheSecondTime() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()
        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive)

        let first = try DriveSync.merge(into: deviceB, from: drive)
        let second = try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertGreaterThan(first.outcome.applied, 0)
        XCTAssertEqual(second.outcome.applied, 0, "Re-reading a drive applied changes again")
        XCTAssertEqual(try labels(deviceB), ["Family"])
    }

    /// A device never reads its own directory back. It already knows.
    func testADeviceIgnoresItsOwnSegments() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()
        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive)

        let report = try DriveSync.merge(into: deviceA, from: drive)

        XCTAssertEqual(report.peersRead, 0)
        XCTAssertEqual(report.outcome.applied, 0)
    }

    // MARK: - Conflicts across the drive

    /// Two devices edit the same group without seeing each other, then both
    /// meet the drive. They have to agree — not merely each pick something.
    func testTwoMachinesEditingTheSameThingAgreeAfterwards() throws {
        let shared = UUID()
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(id: shared, label: "Original"))
        try DriveSync.synchronise(deviceA, with: drive)
        try DriveSync.synchronise(deviceB, with: drive)

        var onA = try XCTUnwrap(deviceA.fetchStorageGroups().first)
        onA.label = "Named by A"
        try deviceA.upsertStorageGroup(onA)

        var onB = try XCTUnwrap(deviceB.fetchStorageGroups().first)
        onB.label = "Named by B"
        try deviceB.upsertStorageGroup(onB)

        // Each meets the drive, twice round, as they would over a few days.
        try DriveSync.synchronise(deviceA, with: drive)
        try DriveSync.synchronise(deviceB, with: drive)
        try DriveSync.synchronise(deviceA, with: drive)

        XCTAssertEqual(
            try labels(deviceA), try labels(deviceB),
            "The two devices disagree, so they will never converge"
        )
    }

    /// Deleting on one device must not be undone by the other still holding it.
    func testADeletionTravels() throws {
        let shared = UUID()
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(id: shared, label: "Temporary"))
        try DriveSync.synchronise(deviceA, with: drive)
        try DriveSync.synchronise(deviceB, with: drive)
        XCTAssertEqual(try labels(deviceB), ["Temporary"])

        try deviceA.deleteStorageGroup(id: shared)
        try DriveSync.synchronise(deviceA, with: drive)
        try DriveSync.synchronise(deviceB, with: drive)

        XCTAssertTrue(try labels(deviceB).isEmpty, "The deletion did not travel")

        // And B, which still remembers holding it, must not hand it back.
        try DriveSync.synchronise(deviceA, with: drive)
        XCTAssertTrue(try labels(deviceA).isEmpty, "The group came back from the dead")
    }

    // MARK: - The drive being pulled out

    /// The failure removable media actually has. A half-written line must cost
    /// the records that were being written and nothing else — and they must
    /// arrive on the next sync, because the sender's watermark never moved past
    /// them.
    ///
    /// **One row is held back beyond the damage, deliberately.** Everything a
    /// single write produces carries one stamp, so a tear cuts into at most one
    /// stamp — and from the file alone there is no way to tell whether the last
    /// stamp still readable was whole or was where the cut landed. Its surviving
    /// records look identical either way. So both sides treat the last stamp of
    /// a damaged segment as suspect: the reader does not apply it and the writer
    /// does not count it as sent.
    ///
    /// The cost is that a row which *did* survive is delayed by one sync. The
    /// alternative was measured on a real volume and is worse: a row arriving
    /// with columns missing, both sides believing it delivered, and no sync ever
    /// asking for the rest.
    func testADriveYankedMidWriteLosesOnlyTheTornTail() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        let segment = DriveSync.segmentPath(deviceA.journal.device.id, index: 1)

        // Three separate writes, so the segment holds three stamps and the one
        // held back as suspect is not the whole file.
        try deviceA.upsertStorageGroup(makeGroup(label: "First"))
        try DriveSync.publish(from: deviceA, to: drive)

        try deviceA.upsertStorageGroup(makeGroup(label: "Second"))
        try DriveSync.publish(from: deviceA, to: drive)
        let intact = try XCTUnwrap(try drive.read(segment)).count

        try deviceA.upsertStorageGroup(makeGroup(label: "Third"))
        try DriveSync.publish(from: deviceA, to: drive)

        // Cut a little way into the third batch, the way an interrupted append
        // leaves a file: everything before it whole, one line half-written.
        //
        // Cutting merely a few bytes off the end is not this test. One storage
        // group is several records — one per column — so clipping the tail only
        // loses one of them. The cut has to land inside the batch to be a torn
        // write at all.
        let whole = try XCTUnwrap(try drive.read(segment))
        try drive.writeAtomically(whole.prefix(intact + 20), to: segment)

        let damaged = try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertEqual(damaged.truncatedPeers, [deviceA.journal.device.id], "Damage went unreported")
        XCTAssertEqual(
            try labels(deviceB), ["First"],
            "Everything before the suspect stamp should still have arrived"
        )

        // Plugged in again, with the drive now writable: the lost work is
        // re-published because A never recorded it as sent.
        try DriveSync.publish(from: deviceA, to: drive)
        try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertEqual(
            try labels(deviceB), ["First", "Second", "Third"],
            "The torn records never came back"
        )
    }

    /// A drive nobody has ever synced to is not an error.
    func testAnEmptyDriveIsSimplyEmpty() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()

        let report = try DriveSync.merge(into: deviceA, from: drive)

        XCTAssertEqual(report.peersRead, 0)
        XCTAssertTrue(report.outcome.isEmpty)
    }

    // MARK: - Version skew

    /// A drive is a time device: it can carry a log written by a build this
    /// device has not installed. Refusing is the point.
    func testADriveWrittenByANewerBuildIsRefused() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()
        let manifest = SyncManifest(
            formatVersion: SyncManifest.currentFormatVersion + 1,
            catalogSchemaVersion: CatalogStore.schemaVersion
        )
        try drive.writeAtomically(try JSONEncoder().encode(manifest), to: DriveSync.manifestPath)

        XCTAssertThrowsError(try DriveSync.merge(into: deviceA, from: drive))
        XCTAssertThrowsError(try DriveSync.publish(from: deviceA, to: drive))
    }

    func testADriveFromANewerCatalogSchemaIsRefused() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()
        let manifest = SyncManifest(
            formatVersion: SyncManifest.currentFormatVersion,
            catalogSchemaVersion: CatalogStore.schemaVersion + 1
        )
        try drive.writeAtomically(try JSONEncoder().encode(manifest), to: DriveSync.manifestPath)

        XCTAssertThrowsError(try DriveSync.merge(into: deviceA, from: drive))
    }

    // MARK: - Three devices

    /// More drives and devices converge faster, and any one drive is enough.
    /// Here a third device that has never met the first still learns its work.
    func testWorkReachesAThirdMachineItNeverMet() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let deviceC = try makeCatalog("c")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(label: "From A"))
        try DriveSync.synchronise(deviceA, with: drive)

        try deviceB.upsertStorageGroup(makeGroup(label: "From B"))
        try DriveSync.synchronise(deviceB, with: drive)

        try DriveSync.synchronise(deviceC, with: drive)

        XCTAssertEqual(try labels(deviceC), ["From A", "From B"])
    }

    /// What a device publishes about itself, so another can eventually work out
    /// what everyone has seen.
    func testADevicePublishesWhatItHasSeen() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.synchronise(deviceA, with: drive)
        try DriveSync.synchronise(deviceB, with: drive)

        let data = try XCTUnwrap(try drive.read(DriveSync.deviceInfoPath(deviceB.journal.device.id)))
        let info = try JSONDecoder().decode(SyncDeviceInfo.self, from: data)

        XCTAssertEqual(info.id, deviceB.journal.device.id)
        XCTAssertNotNil(info.seen[deviceA.journal.device.id], "B did not record having read A")
    }
}
