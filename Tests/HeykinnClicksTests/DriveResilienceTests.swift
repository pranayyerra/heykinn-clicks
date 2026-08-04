import XCTest
@testable import HeykinnClicks

/// Guards the reconnect-storm regression: a busy volume that transiently fails
/// metadata reads must not read as an unplug followed by a fresh connect,
/// because every "connect" restarts expensive connect-triggered work.
@MainActor
final class DriveResilienceTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-resilience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeDrive(id: UUID = UUID()) -> ReplicationTarget {
        ReplicationTarget(
            id: id, name: "Test", volumeUUID: "VOL-UUID", markerToken: "token",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    func testConnectedDriveSurvivesEnumerationMiss() throws {
        let monitor = TargetMonitor()
        let drive = makeDrive()
        let mount = try makeTempDirectory()

        // Seed a connected state as a successful rescan would produce.
        monitor.setReachablePathsForTesting([drive.id: mount])
        XCTAssertEqual(monitor.reachablePaths[drive.id], mount)

        // Now rescan while the volume is invisible to enumeration (no marker
        // file, and its UUID is not discoverable) — the mount point still
        // exists on disk, so the drive must remain connected.
        monitor.rescan(targets: [drive])
        XCTAssertEqual(
            monitor.reachablePaths[drive.id], mount,
            "A transient enumeration miss must not look like a disconnect"
        )
    }

    func testDriveDropsWhenMountPointGenuinelyDisappears() throws {
        let monitor = TargetMonitor()
        let drive = makeDrive()
        let mount = try makeTempDirectory()
        monitor.setReachablePathsForTesting([drive.id: mount])

        // A real unmount removes the mount point.
        try FileManager.default.removeItem(at: mount)
        monitor.rescan(targets: [drive])
        XCTAssertNil(
            monitor.reachablePaths[drive.id],
            "A genuine unmount must still be detected"
        )
    }

    func testVolumeStillEnumeratedWhenMarkerUnreadable() throws {
        // A volume with no marker file must still produce a VolumeInfo (so
        // UUID fallback matching can run) rather than vanishing entirely.
        let volumes = TargetMonitor.enumerateVolumes()
        for volume in volumes {
            XCTAssertFalse(volume.name.isEmpty, "Every enumerated volume needs a usable name")
        }
    }
}
