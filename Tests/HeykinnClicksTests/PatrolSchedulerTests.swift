import XCTest
@testable import HeykinnClicks

/// Aiming the read budget at the photos actually at risk.
final class PatrolSchedulerTests: XCTestCase {

    private let mb: Int64 = 1024 * 1024
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 24 * 3600)
    }

    private func replica(
        asset: UUID,
        target: UUID,
        verified: Date?,
        sizeMB: Int64 = 4
    ) -> PatrolScheduler.Replica {
        PatrolScheduler.Replica(
            assetID: asset, targetID: target, sizeBytes: sizeMB * mb, lastVerifiedAt: verified
        )
    }

    private func index(_ replicas: [PatrolScheduler.Replica]) -> [UUID: [PatrolScheduler.Replica]] {
        Dictionary(grouping: replicas, by: \.assetID)
    }

    /// The whole reason the rule changed.
    ///
    /// `safe` has the oldest replica in the archive — a year — but its other
    /// copy was read yesterday, so there is a known-good copy and nothing to
    /// worry about. `atRisk` has no copy read in six months. The old
    /// "least recently verified replica" rule picks `safe`; this one must not.
    func testPrefersAnAssetWithNoRecentlyReadCopy() {
        let patrolled = UUID(), other = UUID()
        let safe = UUID(), atRisk = UUID()

        let all = [
            replica(asset: safe, target: patrolled, verified: daysAgo(365)),
            replica(asset: safe, target: other, verified: daysAgo(1)),
            replica(asset: atRisk, target: patrolled, verified: daysAgo(180)),
            replica(asset: atRisk, target: other, verified: daysAgo(180)),
        ]

        let chosen = PatrolScheduler.next(
            on: patrolled,
            candidates: all.filter { $0.targetID == patrolled },
            allReplicasByAsset: index(all),
            budget: VerificationBudget(maxFiles: 1, maxBytes: .max, maxBytesPerFile: .max),
            now: now
        )

        XCTAssertEqual(chosen.map(\.assetID), [atRisk])
    }

    /// A copy nobody has ever read back is the most exposed thing there is,
    /// whatever the timestamps elsewhere say.
    func testNeverVerifiedSortsFirst() {
        let patrolled = UUID()
        let neverRead = UUID(), old = UUID()

        let all = [
            replica(asset: old, target: patrolled, verified: daysAgo(400)),
            replica(asset: neverRead, target: patrolled, verified: nil),
        ]

        let chosen = PatrolScheduler.next(
            on: patrolled,
            candidates: all,
            allReplicasByAsset: index(all),
            budget: VerificationBudget(maxFiles: 1, maxBytes: .max, maxBytesPerFile: .max),
            now: now
        )

        XCTAssertEqual(chosen.map(\.assetID), [neverRead])
    }

    /// One asset, two copies on the device being patrolled: read the older, it
    /// is likelier to be the damaged one.
    func testReadsTheOlderCopyOnTheDevice() {
        let patrolled = UUID()
        let asset = UUID()
        let fresh = replica(asset: asset, target: patrolled, verified: daysAgo(10))
        let stale = replica(asset: asset, target: patrolled, verified: daysAgo(300))

        let chosen = PatrolScheduler.next(
            on: patrolled,
            candidates: [fresh, stale],
            allReplicasByAsset: index([fresh, stale]),
            budget: .patrol,
            now: now
        )

        XCTAssertEqual(chosen.count, 1, "one read per asset per run")
        XCTAssertEqual(chosen.first?.lastVerifiedAt, stale.lastVerifiedAt)
    }

    /// A file over the per-file cap is skipped, not allowed to block every
    /// smaller file behind it — otherwise one big video parks the patrol.
    func testAnOversizedFileIsSkippedRatherThanBlocking() {
        let patrolled = UUID()
        let huge = UUID(), small = UUID()

        let all = [
            // Higher risk, but too big for the ration.
            replica(asset: huge, target: patrolled, verified: daysAgo(400), sizeMB: 4096),
            replica(asset: small, target: patrolled, verified: daysAgo(300), sizeMB: 4),
        ]

        let chosen = PatrolScheduler.next(
            on: patrolled,
            candidates: all,
            allReplicasByAsset: index(all),
            budget: VerificationBudget(maxFiles: 10, maxBytes: 64 * mb, maxBytesPerFile: 64 * mb),
            now: now
        )

        XCTAssertEqual(chosen.map(\.assetID), [small])
    }

    func testStopsAtTheByteBudget() {
        let patrolled = UUID()
        let all = (0..<10).map { offset in
            replica(asset: UUID(), target: patrolled, verified: daysAgo(Double(400 - offset)), sizeMB: 10)
        }

        let chosen = PatrolScheduler.next(
            on: patrolled,
            candidates: all,
            allReplicasByAsset: index(all),
            budget: VerificationBudget(maxFiles: 100, maxBytes: 35 * mb, maxBytesPerFile: .max),
            now: now
        )

        XCTAssertEqual(chosen.count, 3)
    }

    /// Replicas on other devices are never returned: the run is for one device.
    func testOnlyReturnsReplicasOnTheDeviceBeingPatrolled() {
        let patrolled = UUID(), other = UUID()
        let all = [
            replica(asset: UUID(), target: other, verified: nil),
            replica(asset: UUID(), target: patrolled, verified: daysAgo(5)),
        ]

        let chosen = PatrolScheduler.next(
            on: patrolled,
            candidates: all,
            allReplicasByAsset: index(all),
            budget: .patrol,
            now: now
        )

        XCTAssertTrue(chosen.allSatisfy { $0.targetID == patrolled })
    }

    func testFreshestVerificationIgnoresNeverReadSiblings() {
        let asset = UUID()
        let target = UUID()
        let freshest = PatrolScheduler.freshestVerification(of: [
            replica(asset: asset, target: target, verified: nil),
            replica(asset: asset, target: target, verified: daysAgo(3)),
        ])
        XCTAssertEqual(freshest, daysAgo(3))

        XCTAssertNil(PatrolScheduler.freshestVerification(of: [
            replica(asset: asset, target: target, verified: nil)
        ]))
    }
}
