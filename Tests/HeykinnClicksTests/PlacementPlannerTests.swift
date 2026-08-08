import XCTest
@testable import HeykinnClicks

/// Copies go where the source says, and nowhere else.
final class PlacementPlannerTests: XCTestCase {

    private let gb: Int64 = 1024 * 1024 * 1024

    private func candidate(_ id: UUID, freeGB: Int64, reachable: Bool = true) -> PlacementPlanner.Candidate {
        PlacementPlanner.Candidate(targetID: id, freeBytes: freeGB * gb, isReachable: reachable)
    }

    /// The defining behaviour, and the thing two earlier designs got wrong: the
    /// planner does not choose. Five devices registered, two named — copies go
    /// to the two named, even though the others have more room.
    func testPlacesOnlyOnTheDevicesTheSourceNames() {
        let named = [UUID(), UUID()]
        let unnamed = [UUID(), UUID(), UUID()]

        let plans = PlacementPlanner.plan(
            assets: [(id: UUID(), sizeBytes: gb)],
            destinations: named,
            desiredCopies: 2,
            candidates: named.map { candidate($0, freeGB: 100) }
                + unnamed.map { candidate($0, freeGB: 9000) }
        )

        XCTAssertEqual(plans[0].destinations, named)
        XCTAssertTrue(plans[0].obstacles.isEmpty)
    }

    /// The user's order is kept: the first device someone lists is the one they
    /// think of as primary, and honouring that costs nothing.
    func testHonoursTheOrderDestinationsWereNamedIn() {
        let first = UUID(), second = UUID()
        let plans = PlacementPlanner.plan(
            assets: [(id: UUID(), sizeBytes: gb)],
            destinations: [first, second],
            desiredCopies: 2,
            // Deliberately more room on the second: it must not be promoted.
            candidates: [candidate(first, freeGB: 100), candidate(second, freeGB: 5000)]
        )
        XCTAssertEqual(plans[0].destinations, [first, second])
    }

    /// A named device already holding the file is the copy on that device.
    /// This is the "scan before you transport" rule the Takeout path already
    /// had, in its general form.
    func testADeviceAlreadyHoldingItIsSentNothing() {
        let onDrive = UUID(), other = UUID()
        let asset = UUID()

        let plans = PlacementPlanner.plan(
            assets: [(id: asset, sizeBytes: gb)],
            existingHolders: [asset: [onDrive]],
            destinations: [onDrive, other],
            desiredCopies: 2,
            candidates: [candidate(onDrive, freeGB: 500), candidate(other, freeGB: 500)]
        )

        XCTAssertEqual(plans[0].destinations, [other], "only the difference should be copied")
        XCTAssertTrue(plans[0].obstacles.isEmpty)
    }

    func testNothingToDoWhenEveryNamedDeviceAlreadyHasIt() {
        let a = UUID(), b = UUID()
        let asset = UUID()
        let plans = PlacementPlanner.plan(
            assets: [(id: asset, sizeBytes: gb)],
            existingHolders: [asset: [a, b]],
            destinations: [a, b],
            desiredCopies: 2,
            candidates: [candidate(a, freeGB: 500), candidate(b, freeGB: 500)]
        )
        XCTAssertTrue(plans[0].destinations.isEmpty)
        XCTAssertTrue(plans[0].obstacles.isEmpty)
    }

    /// A named device without room reports a shortfall against *that device*.
    /// It must never silently substitute a different disk — that is the
    /// free-space design this replaced.
    func testNoRoomIsReportedAndNeverSubstituted() {
        let full = UUID(), roomy = UUID()
        let plans = PlacementPlanner.plan(
            assets: [(id: UUID(), sizeBytes: 100 * gb)],
            destinations: [full],
            desiredCopies: 1,
            candidates: [candidate(full, freeGB: 5), candidate(roomy, freeGB: 9000)]
        )

        XCTAssertTrue(plans[0].destinations.isEmpty, "must not fall back to an unnamed device")
        guard case .noRoom(let targetID, _)? = plans[0].obstacles.first else {
            return XCTFail("expected a noRoom obstacle, got \(plans[0].obstacles)")
        }
        XCTAssertEqual(targetID, full)
    }

    func testFewerDestinationsThanCopiesIsItsOwnObstacle() {
        let only = UUID()
        let plans = PlacementPlanner.plan(
            assets: [(id: UUID(), sizeBytes: gb)],
            destinations: [only],
            desiredCopies: 2,
            candidates: [candidate(only, freeGB: 500)]
        )
        XCTAssertEqual(plans[0].destinations, [only])
        XCTAssertEqual(plans[0].obstacles, [.tooFewDestinations])
    }

    /// A device named by the source but forgotten since is distinct from one
    /// that is merely full — different cause, different fix.
    func testAForgottenDestinationIsReportedAsMissing() {
        let live = UUID(), forgotten = UUID()
        let plans = PlacementPlanner.plan(
            assets: [(id: UUID(), sizeBytes: gb)],
            destinations: [live, forgotten],
            desiredCopies: 2,
            candidates: [candidate(live, freeGB: 500)]
        )
        XCTAssertEqual(plans[0].destinations, [live])
        XCTAssertEqual(plans[0].obstacles, [.destinationMissing(targetID: forgotten)])
    }

    /// Bytes promised earlier in the batch count against the device's room, so
    /// a batch that overruns a drive says so rather than each asset
    /// independently believing there was space.
    func testABatchCountsWhatItHasAlreadyPromised() {
        let device = UUID()
        // Room for roughly two 40 GB assets above the 10 GB reserve.
        let assets = (0..<3).map { _ in (id: UUID(), sizeBytes: 40 * gb) }

        let plans = PlacementPlanner.plan(
            assets: assets,
            destinations: [device],
            desiredCopies: 1,
            candidates: [candidate(device, freeGB: 100)]
        )

        let placed = plans.filter { !$0.destinations.isEmpty }.count
        XCTAssertEqual(placed, 2)
        XCTAssertEqual(plans.filter { !$0.obstacles.isEmpty }.count, 1)
    }

    /// Placement decides where bytes live for years. A plan that varied between
    /// runs could not be tested, reasoned about, or reproduced after a crash.
    func testPlanIsDeterministic() {
        let devices = [UUID(), UUID()]
        let assets = (0..<20).map { _ in (id: UUID(), sizeBytes: gb) }
        let candidates = devices.map { candidate($0, freeGB: 500) }

        let first = PlacementPlanner.plan(
            assets: assets, destinations: devices, desiredCopies: 2, candidates: candidates
        )
        let second = PlacementPlanner.plan(
            assets: assets, destinations: devices, desiredCopies: 2, candidates: candidates
        )

        XCTAssertEqual(first.map(\.destinations), second.map(\.destinations))
    }

    /// An unreachable named device is still where the copies belong. It is
    /// planned for and the corridor handles the delay — dropping it because it
    /// is unplugged would silently rewrite the user's choice.
    func testAnUnreachableDestinationIsStillPlannedFor() {
        let away = UUID()
        let plans = PlacementPlanner.plan(
            assets: [(id: UUID(), sizeBytes: gb)],
            destinations: [away],
            desiredCopies: 1,
            candidates: [candidate(away, freeGB: 500, reachable: false)]
        )
        XCTAssertEqual(plans[0].destinations, [away])
    }

    /// The same case in the shape production actually produces it.
    ///
    /// The test above hands an unreachable device a free-space figure, which
    /// `AppStore.placementCandidates` never does: a device nobody can reach
    /// reports **nil**, deliberately, because its free space when it was last
    /// seen is not evidence about its free space now. Reading that nil as zero
    /// made every absent destination come back `.noRoom`, so nothing was ever
    /// owed to a drive that was not plugged in — the exact case the Mac's
    /// holding area exists to serve — and registering a device queued nothing
    /// at all, since a device is unreachable until the scan that follows
    /// registering it.
    func testAnUnmeasurableDestinationIsOwedACopyRatherThanReportedFull() {
        let away = UUID()
        let plans = PlacementPlanner.plan(
            assets: [(id: UUID(), sizeBytes: gb)],
            destinations: [away],
            desiredCopies: 1,
            candidates: [
                PlacementPlanner.Candidate(targetID: away, freeBytes: nil, isReachable: false)
            ]
        )
        XCTAssertEqual(plans[0].destinations, [away])
        XCTAssertTrue(plans[0].obstacles.isEmpty, "unknown room is not a shortfall")
    }

    /// And the other side of it: a device that is here and genuinely full still
    /// reports no room. Deferring the check for absent devices must not turn
    /// the check itself into a formality.
    func testAReachableDeviceWithNoRoomStillReportsIt() {
        let full = UUID()
        let plans = PlacementPlanner.plan(
            assets: [(id: UUID(), sizeBytes: 40 * gb)],
            destinations: [full],
            desiredCopies: 1,
            candidates: [candidate(full, freeGB: 12)]
        )

        XCTAssertTrue(plans[0].destinations.isEmpty)
        guard case .noRoom = plans[0].obstacles.first else {
            return XCTFail("expected a noRoom obstacle, got \(plans[0].obstacles)")
        }
    }
}
