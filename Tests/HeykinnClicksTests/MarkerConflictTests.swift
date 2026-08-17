import XCTest
@testable import HeykinnClicks

/// Invariant 13: a marker naming another archive is never overwritten silently.
///
/// Registering a drive writes a marker at its root, and used to overwrite one
/// already there. Two archives on one device is not exotic — the app offers a
/// test archive beside the real one — and the second to register a drive took
/// it, leaving the first unable to identify by its primary mechanism what was,
/// as far as it knew, still its drive.
@MainActor
final class MarkerConflictTests: XCTestCase {

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeStore() throws -> AppStore {
        let directory = try makeDirectory("archive")
        let suiteName = "heykinn-marker-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
    }

    /// Someone else's drive, with their marker already on it.
    private func makeForeignDrive() throws -> (URL, TargetMarker) {
        let root = try makeDirectory("drive")
        let marker = TargetMarker(
            targetID: UUID(), markerToken: UUID().uuidString, appName: "heykinn-clicks"
        )
        try TargetMonitor.writeMarker(marker, to: root)
        return (root, marker)
    }

    private func volume(at url: URL) -> VolumeInfo {
        VolumeInfo(
            url: url, name: "Field Drive", volumeUUID: UUID().uuidString,
            isRemovable: true, isReadOnly: false, marker: TargetMonitor.readMarker(at: url)
        )
    }

    // MARK: - The invariant

    func testRegisteringDoesNotTakeAnotherArchivesMarker() throws {
        let store = try makeStore()
        let (root, theirs) = try makeForeignDrive()

        let registered = store.registerVolumeTarget(volume: volume(at: root), name: "Field Drive")

        XCTAssertFalse(registered, "The drive was taken without asking")
        XCTAssertEqual(
            TargetMonitor.readMarker(at: root), theirs,
            "Their marker was overwritten — the archive that owns this drive can no longer recognise it"
        )
        XCTAssertTrue(store.targets.isEmpty, "A target row was written for a drive that was refused")
        XCTAssertNotNil(store.markerConflict, "Refused, but the user was never told or offered a way on")
        XCTAssertEqual(store.markerConflict?.existing, theirs)
    }

    /// Refusing outright would be wrong: a target forgotten here leaves its
    /// marker behind, and so does an archive that no longer exists. The user is
    /// the only one who can tell those from somebody else's drive.
    func testTheDriveCanStillBeTakenOverDeliberately() throws {
        let store = try makeStore()
        let (root, theirs) = try makeForeignDrive()

        _ = store.registerVolumeTarget(volume: volume(at: root), name: "Field Drive")
        let conflict = try XCTUnwrap(store.markerConflict)
        let registered = store.takeOverDrive(conflict)

        XCTAssertTrue(registered, "Saying yes did not register the drive")
        XCTAssertNil(store.markerConflict, "The prompt stayed up after it was answered")
        XCTAssertEqual(store.targets.count, 1)

        let now = try XCTUnwrap(TargetMonitor.readMarker(at: root))
        XCTAssertNotEqual(now, theirs, "Taking over left the old marker in place")
        XCTAssertEqual(now.targetID, store.targets.first?.id)
    }

    /// A drive with no marker at all is the ordinary case and must not be
    /// slowed down by any of this.
    func testAnUnclaimedDriveRegistersWithoutAsking() throws {
        let store = try makeStore()
        let root = try makeDirectory("blank")

        let registered = store.registerVolumeTarget(volume: volume(at: root), name: "New Drive")

        XCTAssertTrue(registered, "\(store.lastError ?? "no error reported")")
        XCTAssertNil(store.markerConflict)
        XCTAssertEqual(store.targets.count, 1)
    }
}
