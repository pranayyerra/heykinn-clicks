import XCTest
@testable import HeykinnClicks

/// Replication targets: identity, and the difference between the host device
/// and an external volume.
final class TargetTests: XCTestCase {

    private var temporaries: [URL] = []

    override func tearDown() {
        for url in temporaries { try? FileManager.default.removeItem(at: url) }
        temporaries = []
        super.tearDown()
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("target-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaries.append(url)
        return url
    }

    private func makeTarget(
        id: UUID = UUID(),
        kind: TargetKind,
        token: String = UUID().uuidString,
        path: String? = nil
    ) -> ReplicationTarget {
        ReplicationTarget(
            id: id,
            name: "Target",
            kind: kind,
            volumeUUID: nil,
            markerToken: token,
            registeredAt: Date(),
            lastSeenAt: nil,
            lastKnownPath: path,
            configuredPath: path,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    // MARK: - Marker compatibility

    /// Identity travels in the marker file, so a round trip has to preserve it
    /// exactly: this is what recognises a drive after a rename or a remount.
    func testMarkerRoundTripsPreservingIdentity() throws {
        let marker = TargetMarker(targetID: UUID(), markerToken: "token-abc", appName: "heykinn-clicks")

        let data = try JSONEncoder().encode(marker)
        let decoded = try JSONDecoder().decode(TargetMarker.self, from: data)

        XCTAssertEqual(decoded, marker)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["targetID"])
    }

    func testAMarkerWrittenToDiskIsReadBackIntact() throws {
        let folder = try makeTempDirectory()
        let marker = TargetMarker(targetID: UUID(), markerToken: "token-abc", appName: "heykinn-clicks")

        try TargetMonitor.writeMarker(marker, to: folder)

        XCTAssertEqual(TargetMonitor.readMarker(at: folder), marker)
    }

    // MARK: - Host device targets

    func testHostDeviceTargetIsReachableWhenItsMarkerMatches() throws {
        let folder = try makeTempDirectory()
        let target = makeTarget(kind: .hostDevice, path: folder.path)
        try TargetMonitor.writeMarker(
            TargetMarker(targetID: target.id, markerToken: target.markerToken, appName: "heykinn-clicks"),
            to: folder
        )

        XCTAssertEqual(TargetMonitor.resolveFolder(target)?.standardizedFileURL, folder.standardizedFileURL)
    }

    func testFolderWithNoMarkerIsNotAdopted() throws {
        let folder = try makeTempDirectory()
        let target = makeTarget(kind: .hostDevice, path: folder.path)

        XCTAssertNil(
            TargetMonitor.resolveFolder(target),
            "An unmarked folder must not be treated as the target — that is how an archive gets written into a stranger's directory"
        )
    }

    func testFolderHoldingAnotherTargetsMarkerIsNotAdopted() throws {
        let folder = try makeTempDirectory()
        let target = makeTarget(kind: .hostDevice, path: folder.path)
        try TargetMonitor.writeMarker(
            TargetMarker(targetID: UUID(), markerToken: "someone-else", appName: "heykinn-clicks"),
            to: folder
        )

        XCTAssertNil(TargetMonitor.resolveFolder(target))
    }

    func testAMissingFolderIsSimplyUnreachable() throws {
        let folder = try makeTempDirectory()
        let target = makeTarget(kind: .hostDevice, path: folder.path)
        try TargetMonitor.writeMarker(
            TargetMarker(targetID: target.id, markerToken: target.markerToken, appName: "heykinn-clicks"),
            to: folder
        )
        try FileManager.default.removeItem(at: folder)

        XCTAssertNil(TargetMonitor.resolveFolder(target))
    }

    // MARK: - The two kinds do not resolve as each other

    func testVolumeMatchingIgnoresHostDeviceTargets() {
        let target = makeTarget(kind: .hostDevice, path: "/somewhere")
        let volume = VolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/Impostor"),
            name: "Impostor",
            volumeUUID: nil,
            isRemovable: true,
            marker: TargetMarker(targetID: target.id, markerToken: target.markerToken, appName: "heykinn-clicks")
        )

        XCTAssertNil(
            TargetMonitor.match(volume: volume, against: [target]),
            "A host-device target must never be satisfied by a volume that happens to carry its marker"
        )
    }

    func testVolumeMatchingStillFindsExternalTargetsByMarker() {
        let target = makeTarget(kind: .externalVolume)
        let volume = VolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/Backup"),
            name: "Backup",
            volumeUUID: nil,
            isRemovable: true,
            marker: TargetMarker(targetID: target.id, markerToken: target.markerToken, appName: "heykinn-clicks")
        )

        XCTAssertEqual(TargetMonitor.match(volume: volume, against: [target])?.id, target.id)
    }

    // MARK: - One device, one copy

    func testTwoFoldersOnTheSameDiskAreTheSamePlace() throws {
        let first = try makeTempDirectory()
        let second = try makeTempDirectory()

        let a = try XCTUnwrap(TargetStorage.of(first))
        let b = try XCTUnwrap(TargetStorage.of(second))

        XCTAssertTrue(
            a.isSamePlace(as: b),
            "Two copies on one disk do not survive that disk failing, so registration has to see them as one place"
        )
    }

    func testTemporaryDirectoryIsRecognisedAsHostStorage() throws {
        let folder = try makeTempDirectory()
        let storage = try XCTUnwrap(TargetStorage.of(folder))

        XCTAssertTrue(storage.isHostDevice, "A folder on the device's own disk is the host device")
    }

    func testDifferentVolumesAreDifferentPlaces() {
        let host = TargetStorage(
            volumeURL: URL(fileURLWithPath: "/"),
            volumeUUID: "AAAA-1111",
            isInternal: true,
            isRemovable: false
        )
        let drive = TargetStorage(
            volumeURL: URL(fileURLWithPath: "/Volumes/Backup"),
            volumeUUID: "BBBB-2222",
            isInternal: false,
            isRemovable: true
        )

        XCTAssertFalse(host.isSamePlace(as: drive))
        XCTAssertFalse(drive.isHostDevice, "An external drive is a target in its own right, not the host device")
    }
}

/// A running app could only ever open the user's own archive, so looking at a
/// screen meant looking at real photos on real drives — and any check of a
/// screen's behaviour was a change to an archive somebody depends on.
final class ArchiveDirectoryOverrideTests: XCTestCase {

    func testProductionUsesTheRealArchiveByDefault() {
        let environment = AppEnvironment.production(processEnvironment: [:])
        XCTAssertEqual(environment.appDirectory.lastPathComponent, "HeykinnClicks")
        XCTAssertTrue(environment.runsBackgroundWork)
        XCTAssertEqual(environment.defaults, UserDefaults.standard)
    }

    func testAnOverriddenArchiveIsUsedInstead() {
        let environment = AppEnvironment.production(processEnvironment: [
            AppEnvironment.archiveDirectoryOverrideKey: "/tmp/inspection-archive",
        ])
        XCTAssertEqual(environment.appDirectory.path, "/tmp/inspection-archive")
    }

    /// Sharing the real preferences would have an inspection copy reading and
    /// writing the policy, the ignored volumes and the iCloud answer that
    /// belong to the archive it is standing in for.
    func testAnOverriddenArchiveGetsItsOwnPreferences() {
        let environment = AppEnvironment.production(processEnvironment: [
            AppEnvironment.archiveDirectoryOverrideKey: "/tmp/inspection-archive",
        ])
        XCTAssertNotEqual(environment.defaults, UserDefaults.standard)
    }

    func testBackgroundWorkCanBeLeftOffSoRealVolumesAreNeverTouched() {
        let environment = AppEnvironment.production(processEnvironment: [
            AppEnvironment.archiveDirectoryOverrideKey: "/tmp/inspection-archive",
            AppEnvironment.offlineKey: "1",
        ])
        XCTAssertFalse(environment.runsBackgroundWork)
    }
}
