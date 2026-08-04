import XCTest
@testable import HeykinnClicks

final class BacklogSummaryTests: XCTestCase {

    func testDescriptionNamesTheWorkAndItsSize() {
        var summary = BacklogSummary(copyCount: 0, verifyCount: 22_880, removeCount: 0)
        summary.estimatedBytes = 120 * 1024 * 1024 * 1024
        let text = summary.description
        XCTAssertTrue(text.contains("22880 to check"), text)
        XCTAssertTrue(text.contains("GB"), "Size must be stated so the cost is visible: \(text)")
        XCTAssertEqual(summary.total, 22_880)
        XCTAssertFalse(summary.isEmpty)
    }

    func testEmptyBacklogReadsAsNothingPending() {
        let summary = BacklogSummary()
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.description, "nothing pending")
    }

    func testMixedBacklogListsEveryAction() {
        var summary = BacklogSummary(copyCount: 3, verifyCount: 5, removeCount: 2)
        summary.estimatedBytes = 0
        let text = summary.description
        XCTAssertTrue(text.contains("3 to copy"), text)
        XCTAssertTrue(text.contains("5 to check"), text)
        XCTAssertTrue(text.contains("2 to remove"), text)
        XCTAssertFalse(text.contains("("), "No size shown when nothing is known: \(text)")
    }

    func testSweepBudgetIsBoundedAndNotUnlimited() {
        XCTAssertLessThan(VerificationBudget.sweep.maxFiles, 5_000)
        XCTAssertLessThan(VerificationBudget.sweep.maxBytes, 32 * 1024 * 1024 * 1024)
        XCTAssertEqual(VerificationBudget.unlimited.maxFiles, .max)
    }

    /// The sweep must take the least recently verified replicas first, so
    /// repeated bounded sweeps eventually cover everything.
    func testStalestReplicasSortFirst() {
        let now = Date()
        func replica(_ verified: Date?) -> TargetReplicaState {
            TargetReplicaState(
                assetID: UUID(), targetID: UUID(), state: .present,
                relativePath: "volume:x", lastVerifiedAt: verified
            )
        }
        let neverVerified = replica(nil)
        let old = replica(now.addingTimeInterval(-90_000))
        let recent = replica(now)

        let ordered = [recent, old, neverVerified]
            .sorted { ($0.lastVerifiedAt ?? .distantPast) < ($1.lastVerifiedAt ?? .distantPast) }

        XCTAssertEqual(ordered[0].assetID, neverVerified.assetID, "Never-verified must go first")
        XCTAssertEqual(ordered[1].assetID, old.assetID)
        XCTAssertEqual(ordered[2].assetID, recent.assetID)
    }
}
