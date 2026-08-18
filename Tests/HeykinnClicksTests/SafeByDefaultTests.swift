import XCTest
@testable import HeykinnClicks

/// P1: how much must somebody decide before their photos are safe?
///
/// The strongest version of the answer is that they install this, point it at
/// their photos, walk away, and are safer than they were — having answered
/// nothing. These cover the distance between that and what actually happens.
@MainActor
final class SafeByDefaultTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A fresh install: the device adopts itself as a place for copies, and no
    /// drive has ever been plugged in.
    private func makeFreshStore() throws -> AppStore {
        let directory = try makeDirectory("archive")
        let suiteName = "heykinn-safe-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
        store.adoptHostDeviceIfNeeded()
        return store
    }

    /// **The first thing somebody does, on the setup they arrive with.**
    ///
    /// `SPEC.md` says the host device is registered by default "so a fresh
    /// install has a real destination before any drive is plugged in". If that
    /// holds, adding a folder of photographs must be possible with no drive.
    func testAddingPhotosWorksBeforeAnyDriveIsPluggedIn() throws {
        let store = try makeFreshStore()
        let photos = try makeDirectory("photos")

        XCTAssertFalse(store.targets.isEmpty, "the device did not adopt itself as a place for copies")
        XCTAssertTrue(
            store.targets.allSatisfy { $0.kind == .hostDevice },
            "this test is about the case where no drive exists"
        )

        store.beginAddingSource([photos])
        let setup = try XCTUnwrap(store.pendingSourceSetup, "adding a folder did not even open")

        // `AddSourceSheet` disables its confirm button on exactly this.
        XCTAssertFalse(
            setup.destinationTargetIDs.isEmpty,
            """
            Nowhere to put them, so the sheet's button is disabled and the \
            photographs cannot be added at all — on a fresh install with no \
            drive, which is what everybody starts with.
            """
        )
    }

    /// And with a drive, which is the case that was designed for.
    ///
    /// The drive is put into the catalog directly rather than registered: a
    /// temporary folder is on the same disk as the archive, and registration
    /// rightly refuses that — two copies on one device do not survive that
    /// device failing. What is under test here is what `beginAddingSource`
    /// proposes, not the registration rules.
    func testAddingPhotosWorksOnceADriveExists() throws {
        let store = try makeFreshStore()
        let photos = try makeDirectory("photos")

        try store.catalog.upsertTarget(ReplicationTarget(
            id: UUID(), name: "Field Drive", kind: .externalVolume,
            volumeUUID: UUID().uuidString, markerToken: UUID().uuidString,
            registeredAt: Date(), lastSeenAt: Date(), lastKnownPath: "/Volumes/Field Drive",
            configuredPath: nil, replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        store.loadAll()

        store.beginAddingSource([photos])
        let setup = try XCTUnwrap(store.pendingSourceSetup)

        XCTAssertFalse(setup.destinationTargetIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(setup.desiredCopies, 1)

        // The fallback must not have become the rule. A copy on the device the
        // drives exist to outlive is not redundancy, so the drive is what gets
        // proposed the moment there is one.
        let chosen = Set(setup.destinationTargetIDs)
        let host = Set(store.targets.filter { $0.kind == .hostDevice }.map(\.id))
        XCTAssertTrue(
            chosen.isDisjoint(with: host),
            "this device was proposed even though a drive exists"
        )
    }

    /// The honest consequence of the fallback, stated rather than hidden: one
    /// copy is one copy, and the app says so in the same words it uses for any
    /// other shortfall.
    func testOneCopyOnThisDeviceIsReportedAsOnePlace() throws {
        let store = try makeFreshStore()
        let photos = try makeDirectory("photos")

        store.beginAddingSource([photos])
        let setup = try XCTUnwrap(store.pendingSourceSetup)

        XCTAssertEqual(setup.desiredCopies, 1, "asked for more copies than there are places to put them")
        XCTAssertEqual(setup.destinationTargetIDs.count, 1)
    }

    // MARK: - What one import teaches the next

    private func registerDrive(
        _ store: AppStore, _ name: String, freeGB: Int64
    ) throws -> UUID {
        let id = UUID()
        try store.catalog.upsertTarget(ReplicationTarget(
            id: id, name: name, kind: .externalVolume, volumeUUID: UUID().uuidString,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: Date(),
            lastKnownPath: "/Volumes/\(name)", configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot,
            lastKnownFreeBytes: freeGB * 1_000_000_000
        ))
        store.loadAll()
        return id
    }

    /// **A drive bought later gets used.**
    ///
    /// The defect this replaces had a year-long fuse. Opening `Change…` and
    /// clicking a drive — even to look — made that group `.chosen`, which is
    /// right; it also saved that drive list as the default for *every* later
    /// import. A drive registered afterwards was then never proposed for
    /// anything again, silently, because each new group was born naming the
    /// drives its owner happened to have on the day they once clicked
    /// something. Every archive on the machine this was found on had reached
    /// that state, which is why it was worth a behaviour change rather than a
    /// note.
    func testADriveRegisteredAfterAnImportIsUsedByTheNextOne() throws {
        let store = try makeFreshStore()
        let small = try registerDrive(store, "Small Drive", freeGB: 50)

        store.beginAddingSource([try makeDirectory("first")])
        var first = try XCTUnwrap(store.pendingSourceSetup)
        // Exactly what SourceSettingsPicker.toggle() does.
        first.destinationMode = .chosen
        first.destinationTargetIDs = [small]
        store.confirmAddingSource(first)

        let big = try registerDrive(store, "Big New Drive", freeGB: 4_000)

        store.beginAddingSource([try makeDirectory("second")])
        let second = try XCTUnwrap(store.pendingSourceSetup)
        XCTAssertTrue(
            second.destinationTargetIDs.contains(big),
            """
            A drive registered since the last import was not offered to this             one. The previous import's device list is being carried forward,             which freezes the archive onto whatever was plugged in the first             time anybody touched the list.
            """
        )
        XCTAssertEqual(second.destinationMode, .automatic)
    }

    /// The half that still travels: how safe somebody said they wanted to be.
    func testTheCopyCountIsStillRememberedFromOneImportToTheNext() throws {
        let store = try makeFreshStore()
        _ = try registerDrive(store, "One", freeGB: 500)
        _ = try registerDrive(store, "Two", freeGB: 400)
        _ = try registerDrive(store, "Three", freeGB: 300)

        store.beginAddingSource([try makeDirectory("first")])
        var first = try XCTUnwrap(store.pendingSourceSetup)
        first.desiredCopies = 3
        store.confirmAddingSource(first)

        store.beginAddingSource([try makeDirectory("second")])
        let second = try XCTUnwrap(store.pendingSourceSetup)
        XCTAssertEqual(second.desiredCopies, 3, "the copy count is a preference and should carry")
        XCTAssertEqual(second.destinationTargetIDs.count, 3)
    }

    /// And a group told to use specific drives keeps them. Re-deriving the
    /// *default* must not re-derive a decision somebody actually made.
    func testAChosenGroupIsNotDisturbedByTheNewDefault() throws {
        let store = try makeFreshStore()
        let small = try registerDrive(store, "Small Drive", freeGB: 50)

        store.beginAddingSource([try makeDirectory("first")])
        var first = try XCTUnwrap(store.pendingSourceSetup)
        first.destinationMode = .chosen
        first.destinationTargetIDs = [small]
        store.confirmAddingSource(first)

        _ = try registerDrive(store, "Big New Drive", freeGB: 4_000)
        store.resolveAutomaticDestinations()

        let group = try XCTUnwrap(store.storageGroups.first)
        XCTAssertEqual(group.destinationMode, .chosen)
        XCTAssertEqual(group.destinationTargetIDs, [small], "a named list was overruled")
    }
}
