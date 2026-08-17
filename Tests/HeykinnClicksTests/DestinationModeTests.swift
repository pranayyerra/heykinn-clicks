import XCTest
@testable import HeykinnClicks

/// Whether a group's devices were worked out or picked — a question the model
/// could not previously answer, which is why a drive bought later held nothing.
@MainActor
final class DestinationModeTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []; suiteNames = []
        super.tearDown()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    /// Seeds an external drive straight into the catalog, the way the other
    /// suites do — registering one for real needs a mounted volume.
    @discardableResult
    private func addDrive(_ name: String, to directory: URL, at when: Date) throws -> UUID {
        let id = UUID()
        try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
            .upsertTarget(ReplicationTarget(
                id: id, name: name, kind: .externalVolume, volumeUUID: nil,
                markerToken: UUID().uuidString, registeredAt: when, lastSeenAt: nil,
                lastKnownPath: "/Volumes/\(name)", configuredPath: nil,
                replicaRootComponent: ReplicationTarget.defaultReplicaRoot
            ))
        return id
    }

    private func makeStore() throws -> (AppStore, URL) {
        let directory = try makeDirectory("store")
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
        return (store, directory)
    }

    /// The defect, stated as a test.
    ///
    /// Buy a third drive, register it, walk away — and it holds nothing, for
    /// ever, silently. Every group kept the two devices it was born with,
    /// because a bare `[UUID]` cannot say whether that list was a decision or
    /// just a photograph of the drives that existed that day.
    func testAThirdDriveIsUsedOnceTheGroupAsksForAThirdCopy() throws {
        let (store, directory) = try makeStore()
        // Drives first, as in life — `newSourceDefaults` asks for as many
        // copies as there are devices to hold them, so a group made before any
        // drive exists starts at one.
        try addDrive("Drive A", to: directory, at: Date(timeIntervalSince1970: 1))
        try addDrive("Drive B", to: directory, at: Date(timeIntervalSince1970: 2))
        store.loadAll()
        let group = try XCTUnwrap(store.createStorageGroup(label: "Everything"))
        XCTAssertEqual(group.destinationMode, .automatic, "a new group works its devices out")
        store.resolveAutomaticDestinations()
        XCTAssertEqual(store.storageGroups.first?.destinationTargetIDs.count, 2)

        // A third drive changes nothing on its own — the group has the copies
        // it asked for, so there is nothing for the new drive to hold, and
        // moving photos onto it unasked would be worse than leaving it empty.
        try addDrive("Drive C", to: directory, at: Date(timeIntervalSince1970: 3))
        store.loadAll()
        store.resolveAutomaticDestinations()
        let settled = try XCTUnwrap(store.storageGroups.first)
        XCTAssertEqual(settled.destinationTargetIDs.count, 2)
        XCTAssertEqual(store.idleDeviceCount(forStorageGroup: settled), 1, "and the UI can say so")

        // Raising the count is what puts it to work — and under the old model
        // this did nothing, because the destination list was fixed.
        store.applyStorageGroupSettings(
            settled, desiredCopies: 3, destinations: settled.destinationTargetIDs
        )
        XCTAssertEqual(store.storageGroups.first?.destinationTargetIDs.count, 3)
    }

    /// The other half: a deliberate placement must survive a new drive.
    ///
    /// Someone who keeps a group off the drive they travel with has a reason
    /// the app has no access to. Re-working it out would overrule them.
    func testAPickedGroupIgnoresADriveAddedLater() throws {
        let (store, directory) = try makeStore()
        let onlyA = try addDrive("Drive A", to: directory, at: Date(timeIntervalSince1970: 1))
        try addDrive("Drive B", to: directory, at: Date(timeIntervalSince1970: 2))
        store.loadAll()
        let group = try XCTUnwrap(store.createStorageGroup(label: "Cold storage"))

        store.applyStorageGroupSettings(
            group, desiredCopies: 1, destinations: [onlyA], mode: .chosen
        )
        XCTAssertEqual(store.storageGroups.first?.destinationMode, .chosen)

        try addDrive("Drive C", to: directory, at: Date(timeIntervalSince1970: 3))
        store.loadAll()
        store.resolveAutomaticDestinations()
        XCTAssertEqual(store.storageGroups.first?.destinationTargetIDs, [onlyA])
    }

    /// Adjusting the copy count must not quietly pin a worked-out group.
    ///
    /// Saving a settings sheet says nothing about whether a person opened the
    /// device picker, so a write that does not mention the mode leaves it
    /// alone. Otherwise nudging the number on a group that names both drives
    /// would fix it to those two, and the next drive would be ignored —
    /// reintroducing the defect through the settings sheet.
    func testChangingOnlyTheCopyCountLeavesAGroupWorkingItOut() throws {
        let (store, directory) = try makeStore()
        try addDrive("Drive A", to: directory, at: Date(timeIntervalSince1970: 1))
        try addDrive("Drive B", to: directory, at: Date(timeIntervalSince1970: 2))
        store.loadAll()
        let group = try XCTUnwrap(store.createStorageGroup(label: "Everything"))
        store.resolveAutomaticDestinations()

        let both = try XCTUnwrap(store.storageGroups.first).destinationTargetIDs
        XCTAssertEqual(both.count, 2)
        store.applyStorageGroupSettings(group, desiredCopies: 2, destinations: both)

        XCTAssertEqual(store.storageGroups.first?.destinationMode, .automatic)
    }

    /// Reading a catalog is not background work, and a migration that only
    /// runs when it is will not run in the harness built to check migrations.
    ///
    /// This one sat below `guard environment.runsBackgroundWork else` at first.
    /// Every test constructs its store with background work off, so the
    /// migration never fired — including the live-catalog check, which passed
    /// against a real archive whose groups it had silently not touched.
    func testTheMigrationRunsWithoutBackgroundWork() throws {
        let directory = try makeDirectory("legacy")
        let a = try addDrive("Drive A", to: directory, at: Date(timeIntervalSince1970: 1))
        let b = try addDrive("Drive B", to: directory, at: Date(timeIntervalSince1970: 2))
        // A group as an older build wrote one: a plain list, naming every drive
        // because there was nothing else it could name.
        try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
            .upsertStorageGroup(StorageGroup(
                id: UUID(), label: "Everything", desiredCopies: 2,
                destinationTargetIDs: [a, b], destinationMode: .chosen, createdAt: Date()
            ))

        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))

        XCTAssertEqual(store.storageGroups.first?.destinationMode, .automatic)
        XCTAssertEqual(store.storageGroups.first?.destinationTargetIDs, [a, b], "and nothing moved")
    }

    /// The host is the device the drives exist to survive, so a worked-out
    /// group never spreads onto it. Counting it would let "2 copies" be
    /// satisfied by this device plus one drive and call that safe.
    func testThisMacIsNeverPickedAutomatically() throws {
        let (store, directory) = try makeStore()
        store.registerHostDeviceTarget(at: try makeDirectory("host"), name: "This device")
        try addDrive("Drive A", to: directory, at: Date(timeIntervalSince1970: 1))
        store.loadAll()
        let group = try XCTUnwrap(store.createStorageGroup(label: "Everything"))
        store.resolveAutomaticDestinations()

        let resolved = try XCTUnwrap(store.storageGroups.first)
        XCTAssertEqual(resolved.destinationTargetIDs.count, 1, "one drive, not the device as a second")
        XCTAssertFalse(resolved.isSatisfiable, "so it says it is short, rather than claiming safety")
    }
}

/// The two structs that carry settings into a new group.
extension DestinationModeTests {

    /// Both default to `chosen`, and both had to.
    ///
    /// Naming devices in one of these is an explicit act. A default of
    /// `automatic` throws the list away and works the devices out — which, on
    /// a setup whose only device is this device, works out to nothing at all,
    /// because the host is never picked automatically. A test that named a
    /// host device and got an empty group is how this was found, twice: once
    /// in `StorageGroup.Defaults` and again in `PendingSourceSetup`.
    func testNamingDevicesInSettingsMeansThem() throws {
        let (store, directory) = try makeStore()
        store.registerHostDeviceTarget(at: try makeDirectory("host"), name: "This device")
        let host = try XCTUnwrap(store.targets.first).id

        let fromDefaults = try XCTUnwrap(store.createStorageGroup(
            label: "Named",
            from: StorageGroup.Defaults(desiredCopies: 1, destinationTargetIDs: [host])
        ))
        XCTAssertEqual(fromDefaults.destinationTargetIDs, [host])
        XCTAssertEqual(fromDefaults.destinationMode, .chosen)

        let setup = AppStore.PendingSourceSetup(
            urls: [directory], label: "Also named",
            desiredCopies: 1, destinationTargetIDs: [host]
        )
        XCTAssertEqual(setup.destinationMode, .chosen)
    }

    /// And the path that means `automatic` says so for itself — working the
    /// devices out from the drives rather than from every registered target,
    /// which would have opened the add sheet proposing this device.
    func testTheAddSheetWorksItsDevicesOutFromDrivesOnly() throws {
        let (store, directory) = try makeStore()
        store.registerHostDeviceTarget(at: try makeDirectory("host"), name: "This device")
        let driveA = try addDrive("Drive A", to: directory, at: Date(timeIntervalSince1970: 1))
        store.loadAll()

        store.beginAddingSource([directory])
        let setup = try XCTUnwrap(store.pendingSourceSetup)
        XCTAssertEqual(setup.destinationMode, .automatic)
        XCTAssertEqual(setup.destinationTargetIDs, [driveA], "the drive, not the device")
    }
}
