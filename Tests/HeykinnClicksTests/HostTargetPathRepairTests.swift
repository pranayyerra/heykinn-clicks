import XCTest
@testable import HeykinnClicks

/// Finding this device's own copy again after the archive has moved.
///
/// The real archive this was found on had its own device reading "away" since
/// the migration into the app-group container — the folder went with the
/// archive, the recorded path did not, and nothing recovered from it. Twelve
/// photographs stopped counting toward safety and nothing new was ever copied
/// there.
final class HostTargetPathRepairTests: XCTestCase {

    private let archive = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/x/HeykinnClicks")
    private let old = "/Users/someone/Library/Application Support/HeykinnClicks/LocalCopy"

    private func host(id: UUID = UUID(), at path: String?) -> ReplicationTarget {
        ReplicationTarget(
            id: id, name: "This device", kind: .hostDevice, volumeUUID: nil,
            markerToken: "token", registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: path, configuredPath: path,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    private func marker(for id: UUID) -> TargetMarker {
        TargetMarker(targetID: id, markerToken: "token", appName: "heykinn-clicks")
    }

    /// The case from the real archive: recorded where it used to be, sitting
    /// where the archive is now, carrying its own marker.
    func testAFolderThatMovedWithTheArchiveIsFoundAgain() {
        let id = UUID()
        let expected = archive.appendingPathComponent("LocalCopy").path
        let repaired = HostTargetPathRepair.repairedPath(
            for: host(id: id, at: old),
            archiveDirectory: archive,
            markerAt: { $0.path == expected ? self.marker(for: id) : nil },
            exists: { $0.path == expected }
        )
        XCTAssertEqual(repaired, expected)
    }

    /// **Never on the strength of the path alone.** A folder is adopted because
    /// it carries a marker naming this target — the rule registration follows,
    /// and the reason invariant 13 exists.
    func testAFolderWithNoMarkerIsNotAdopted() {
        let expected = archive.appendingPathComponent("LocalCopy").path
        XCTAssertNil(HostTargetPathRepair.repairedPath(
            for: host(at: old),
            archiveDirectory: archive,
            markerAt: { _ in nil },
            exists: { $0.path == expected }
        ))
    }

    /// And never one that belongs to a different archive.
    func testAFolderMarkedForAnotherTargetIsNotAdopted() {
        let expected = archive.appendingPathComponent("LocalCopy").path
        XCTAssertNil(HostTargetPathRepair.repairedPath(
            for: host(at: old),
            archiveDirectory: archive,
            markerAt: { _ in self.marker(for: UUID()) },
            exists: { $0.path == expected }
        ))
    }

    /// A path that still resolves is not broken. Somebody who deliberately put
    /// their copy somewhere else must not have it dragged back.
    func testAPathThatStillExistsIsLeftAlone() {
        let elsewhere = "/Volumes/Big Disk/My Archive Copy"
        XCTAssertNil(HostTargetPathRepair.repairedPath(
            for: host(at: elsewhere),
            archiveDirectory: archive,
            markerAt: { _ in nil },
            exists: { $0.path == elsewhere }
        ))
    }

    /// Nothing to find is not an error.
    func testNoFolderThereMeansNoChange() {
        XCTAssertNil(HostTargetPathRepair.repairedPath(
            for: host(at: old),
            archiveDirectory: archive,
            markerAt: { _ in nil },
            exists: { _ in false }
        ))
    }

    /// A drive is not this device, and its absence means it is unplugged.
    func testAnExternalDriveIsNeverRepointedIntoTheArchive() {
        var drive = host(at: "/Volumes/Owner's Back")
        drive.kind = .externalVolume
        XCTAssertNil(HostTargetPathRepair.repairedPath(
            for: drive,
            archiveDirectory: archive,
            markerAt: { _ in self.marker(for: drive.id) },
            exists: { $0.path.hasSuffix("LocalCopy") }
        ))
    }
}
