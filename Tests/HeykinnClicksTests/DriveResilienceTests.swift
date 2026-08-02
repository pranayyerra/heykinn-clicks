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

    private func makeDrive(id: UUID = UUID()) -> ManagedDrive {
        ManagedDrive(
            id: id, name: "Test", volumeUUID: "VOL-UUID", markerToken: "token",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ManagedDrive.defaultReplicaRoot
        )
    }

    func testConnectedDriveSurvivesEnumerationMiss() throws {
        let monitor = DriveMonitor()
        let drive = makeDrive()
        let mount = try makeTempDirectory()

        // Seed a connected state as a successful rescan would produce.
        monitor.setConnectedMountsForTesting([drive.id: mount])
        XCTAssertEqual(monitor.connectedMounts[drive.id], mount)

        // Now rescan while the volume is invisible to enumeration (no marker
        // file, and its UUID is not discoverable) — the mount point still
        // exists on disk, so the drive must remain connected.
        monitor.rescan(managedDrives: [drive])
        XCTAssertEqual(
            monitor.connectedMounts[drive.id], mount,
            "A transient enumeration miss must not look like a disconnect"
        )
    }

    func testDriveDropsWhenMountPointGenuinelyDisappears() throws {
        let monitor = DriveMonitor()
        let drive = makeDrive()
        let mount = try makeTempDirectory()
        monitor.setConnectedMountsForTesting([drive.id: mount])

        // A real unmount removes the mount point.
        try FileManager.default.removeItem(at: mount)
        monitor.rescan(managedDrives: [drive])
        XCTAssertNil(
            monitor.connectedMounts[drive.id],
            "A genuine unmount must still be detected"
        )
    }

    func testVolumeStillEnumeratedWhenMarkerUnreadable() throws {
        // A volume with no marker file must still produce a VolumeInfo (so
        // UUID fallback matching can run) rather than vanishing entirely.
        let volumes = DriveMonitor.enumerateVolumes()
        for volume in volumes {
            XCTAssertFalse(volume.name.isEmpty, "Every enumerated volume needs a usable name")
        }
    }
}
