import XCTest
@testable import HeykinnClicks

/// Moving the volume walk off the main thread must not change what it finds.
@MainActor
final class TargetMonitorThreadingTests: XCTestCase {

    private func makeTarget(name: String, path: String) -> ReplicationTarget {
        ReplicationTarget(
            id: UUID(), name: name, kind: .externalVolume, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: path, configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    /// The two forms share one `apply`, and this is what says so.
    ///
    /// The refactor that moved enumeration off the main thread split `rescan`
    /// in half; a copy-paste of the second half would drift silently, because
    /// nothing about a reachability map looks wrong until a drive is missing
    /// from it.
    func testBothScansAgreeOnWhatIsReachable() async throws {
        guard ProcessInfo.processInfo.environment["HEYKINN_VOLUME_TESTS"] == "1" else {
            throw XCTSkip("Set HEYKINN_VOLUME_TESTS=1 on a device whose mounted volumes are safe to inspect")
        }
        let targets = [makeTarget(name: "Nowhere", path: "/Volumes/Definitely Not Mounted")]

        let blocking = TargetMonitor()
        blocking.rescan(targets: targets)

        let offThread = TargetMonitor()
        await offThread.rescanOffMainThread(targets: targets)

        XCTAssertEqual(
            Set(blocking.availableVolumes.map(\.url)),
            Set(offThread.availableVolumes.map(\.url)),
            "the same volumes, whichever thread walked them"
        )
        XCTAssertEqual(blocking.reachablePaths.keys.sorted(by: { $0.uuidString < $1.uuidString }),
                       offThread.reachablePaths.keys.sorted(by: { $0.uuidString < $1.uuidString }))
    }

    /// A target that is not mounted is not reachable, on either path — the
    /// case that matters, since an unplugged drive is the normal state on one
    /// cable (invariant 12).
    func testAnUnmountedTargetIsReachableFromNeither() async throws {
        guard ProcessInfo.processInfo.environment["HEYKINN_VOLUME_TESTS"] == "1" else {
            throw XCTSkip("Set HEYKINN_VOLUME_TESTS=1 on a device whose mounted volumes are safe to inspect")
        }
        let targets = [makeTarget(name: "Away", path: "/Volumes/Definitely Not Mounted")]

        let offThread = TargetMonitor()
        await offThread.rescanOffMainThread(targets: targets)

        XCTAssertTrue(offThread.reachablePaths.isEmpty)
    }
}
