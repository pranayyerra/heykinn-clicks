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
}
