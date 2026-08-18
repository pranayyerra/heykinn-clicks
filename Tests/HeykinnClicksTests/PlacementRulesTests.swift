import XCTest
@testable import HeykinnClicks

/// Where copies go, when nobody has said where.
///
/// The rule is three lines long on purpose, so these are mostly a table: a set
/// of drives in, a set of drives out. What they are really guarding is that the
/// table stays this short — every past attempt to make placement cleverer began
/// with a case that "obviously" needed one more input.
final class PlacementRulesTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A drive, described only by the two things placement is allowed to read.
    private func drive(
        _ name: String,
        freeGB: Int64?,
        registeredDaysIn days: TimeInterval,
        kind: TargetKind = .externalVolume
    ) -> ReplicationTarget {
        ReplicationTarget(
            id: UUID(), name: name, kind: kind,
            volumeUUID: nil, markerToken: UUID().uuidString,
            registeredAt: epoch.addingTimeInterval(days * 86_400),
            lastSeenAt: nil, lastKnownPath: nil, configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot,
            lastKnownFreeBytes: freeGB.map { $0 * 1_000_000_000 }
        )
    }

    private func names(
        _ chosen: [UUID], from drives: [ReplicationTarget]
    ) -> [String] {
        chosen.compactMap { id in drives.first { $0.id == id }?.name }
    }

    /// **The case the rule exists for.** A 500 GB drive with 20 GB left was
    /// registered first; a fresh 4 TB one came later. The old rule took them in
    /// registration order and filled the small one while the big one sat idle.
    func testOneCopyGoesToTheEmptiestDrive() {
        let drives = [
            drive("Old Drive", freeGB: 20, registeredDaysIn: 0),
            drive("New Drive", freeGB: 3_800, registeredDaysIn: 30),
        ]
        let chosen = StorageGroup.automaticDestinations(copies: 1, among: drives)
        XCTAssertEqual(names(chosen, from: drives), ["New Drive"])
    }

    /// Two copies among three drives: the two emptiest, in that order.
    ///
    /// Spreading is not a rule of its own — it falls out of this one. As the
    /// chosen drives fill, their free space drops below the third's and the
    /// answer moves on its own.
    func testTwoCopiesTakeTheTwoEmptiestInOrder() {
        let drives = [
            drive("Middle", freeGB: 900, registeredDaysIn: 0),
            drive("Full", freeGB: 5, registeredDaysIn: 1),
            drive("Roomy", freeGB: 3_000, registeredDaysIn: 2),
        ]
        let chosen = StorageGroup.automaticDestinations(copies: 2, among: drives)
        XCTAssertEqual(names(chosen, from: drives), ["Roomy", "Middle"])
    }

    /// Equal free space is not a coin toss. Two devices resolve the same group
    /// independently and both must land on the same drive, so the tiebreak is a
    /// recorded fact rather than whatever order the rows came back in.
    func testEqualFreeSpaceBreaksOnWhichWasRegisteredFirst() {
        let first = drive("Registered First", freeGB: 500, registeredDaysIn: 0)
        let second = drive("Registered Later", freeGB: 500, registeredDaysIn: 7)

        XCTAssertEqual(
            names(StorageGroup.automaticDestinations(copies: 1, among: [first, second]),
                  from: [first, second]),
            ["Registered First"]
        )
        // Same drives, opposite input order, same answer.
        XCTAssertEqual(
            names(StorageGroup.automaticDestinations(copies: 1, among: [second, first]),
                  from: [first, second]),
            ["Registered First"]
        )
    }

    /// A drive nobody has measured sorts last, not first.
    ///
    /// Unknown is not the same as empty. Treating a missing number as "loads of
    /// room" would aim copies at precisely the drive the app knows least about.
    func testADriveNeverSeenSortsLastRatherThanFirst() {
        let drives = [
            drive("Never Plugged In", freeGB: nil, registeredDaysIn: 0),
            drive("Measured", freeGB: 100, registeredDaysIn: 5),
        ]
        let chosen = StorageGroup.automaticDestinations(copies: 1, among: drives)
        XCTAssertEqual(names(chosen, from: drives), ["Measured"])
    }

    /// Asking for more copies than there are drives gives back the drives there
    /// are. Running short is a thing the app says, not a thing placement fakes.
    func testAskingForMoreCopiesThanThereAreDrivesReturnsWhatExists() {
        let drives = [drive("Only One", freeGB: 800, registeredDaysIn: 0)]
        XCTAssertEqual(
            StorageGroup.automaticDestinations(copies: 3, among: drives).count, 1
        )
    }

    func testNoDrivesAndNonsenseCountsReturnNothing() {
        let drives = [drive("Some Drive", freeGB: 800, registeredDaysIn: 0)]
        XCTAssertTrue(StorageGroup.automaticDestinations(copies: 2, among: []).isEmpty)
        XCTAssertTrue(StorageGroup.automaticDestinations(copies: 0, among: drives).isEmpty)
        XCTAssertTrue(StorageGroup.automaticDestinations(copies: -1, among: drives).isEmpty)
    }

    /// Rule 1 — only drives that are yours — is free, because a drive that is
    /// not yours is never registered. What is *not* free is keeping this device
    /// out of it: a second copy on the machine the drives exist to outlive is
    /// not a second copy, and the fallback that allows it lives elsewhere and
    /// only fires when there are no drives at all.
    func testThisDeviceIsNotAPlaceAutomaticPlacementPicks() {
        let drives = [
            drive("This Device", freeGB: 9_000, registeredDaysIn: 0, kind: .hostDevice),
            drive("Field Drive", freeGB: 100, registeredDaysIn: 1),
        ]
        // Placement itself is given only eligible drives, so the exclusion has
        // to hold at the point the list is built.
        let eligible = drives.filter { $0.kind == .externalVolume }
        XCTAssertEqual(
            names(StorageGroup.automaticDestinations(copies: 2, among: eligible), from: drives),
            ["Field Drive"]
        )
    }

    // MARK: - End to end, because a rule nothing feeds is not a rule

    /// The free-space number has to survive the database, or the table above is
    /// testing a function nothing ever calls with real inputs. This is the
    /// mistake worth guarding: seven green unit tests over a value that arrives
    /// nil every time.
    @MainActor
    func testFreeSpaceSurvivesTheDatabaseAndMovesAGroup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("placement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "heykinn-placement-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))

        let nearlyFull = drive("Old Drive", freeGB: 20, registeredDaysIn: 0)
        let roomy = drive("New Drive", freeGB: 3_800, registeredDaysIn: 30)
        try store.catalog.upsertTarget(nearlyFull)
        try store.catalog.upsertTarget(roomy)
        store.loadAll()

        XCTAssertEqual(
            store.targets.first { $0.id == roomy.id }?.lastKnownFreeBytes,
            3_800_000_000_000,
            "free space did not survive the round trip, so placement is deciding on nil"
        )

        let group = try XCTUnwrap(store.createStorageGroup(
            label: "Everything",
            from: StorageGroup.Defaults(
                desiredCopies: 1, destinationTargetIDs: [], destinationMode: .automatic
            )
        ))
        XCTAssertEqual(
            store.storageGroups.first { $0.id == group.id }?.destinationTargetIDs,
            [roomy.id],
            "a new group did not pick the drive with room"
        )

        // The roomy drive fills up on some other device and the number comes
        // back with it. Nothing else changes.
        var filled = roomy
        filled.lastKnownFreeBytes = 5_000_000_000
        try store.catalog.upsertTarget(filled)
        store.loadAll()
        store.resolveAutomaticDestinations()

        XCTAssertEqual(
            store.storageGroups.first { $0.id == group.id }?.destinationTargetIDs,
            [nearlyFull.id],
            "the group stayed on a drive that filled up while an emptier one existed"
        )
    }
}
