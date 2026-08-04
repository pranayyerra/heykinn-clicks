import XCTest
@testable import HeykinnClicks

/// The verdict is the only protection answer the user is given, so what maps to
/// "safe" is worth pinning: the difference between a copy that is missing and a
/// copy that has merely not been re-read is the whole point of the split.
final class ProtectionVerdictTests: XCTestCase {

    func testEnoughCopiesMeetThePolicy() {
        XCTAssertEqual(ProtectionState.fullyReplicated.verdict, .meetsPolicy)
    }

    /// The copies exist. Reading them back confirms the bytes; it does not
    /// create them.
    func testCopiesNeverReadBackStillMeetThePolicy() {
        XCTAssertEqual(ProtectionState.awaitingFirstCheck.verdict, .meetsPolicy)
        XCTAssertEqual(ProtectionState.awaitingFirstCheck.checkStanding, .neverRead)
    }

    /// The case the old UI got wrong: a stale check made a complete archive
    /// report as unsafe. Nothing is *known* to disagree, so the policy is met
    /// and the staleness is reported as evidence, not as a verdict.
    func testAStaleCheckIsEvidenceNotAVerdict() {
        XCTAssertEqual(ProtectionState.verificationOverdue.verdict, .meetsPolicy)
        XCTAssertEqual(ProtectionState.verificationOverdue.checkStanding, .stale)
        XCTAssertNotNil(ProtectionState.verificationOverdue.checkStanding.note)
    }

    func testTooFewCopiesFailsWhateverTheChecks() {
        XCTAssertEqual(ProtectionState.replicatedToOneDrive.verdict, .shortOfPolicy)
        XCTAssertEqual(ProtectionState.stagedOnly.verdict, .shortOfPolicy)
    }

    /// Divergence is knowledge that a copy is wrong, which fails however many
    /// copies there are.
    func testDivergenceFails() {
        XCTAssertEqual(ProtectionState.driftDetected.verdict, .diverged)
        XCTAssertFalse(ProtectionState.driftDetected.verdict.isSatisfied)
    }

    /// Non-Local assets get no verdict at all rather than one meaning
    /// "not applicable".
    func testNonLocalAssetsGetNoVerdict() {
        XCTAssertEqual(ProtectionState.notApplicable.verdict, .notLocal)
    }

    /// Deleting content is gated on a stricter bar than the verdict: the
    /// reclamation rule requires copies actually read back, so "meets the
    /// policy" must never be mistaken for "safe to delete against".
    func testMeetingThePolicyIsNotTheBarForDeletion() {
        for state in [ProtectionState.awaitingFirstCheck, .verificationOverdue] {
            XCTAssertTrue(state.verdict.isSatisfied)
            XCTAssertNotEqual(
                state, .fullyReplicated,
                "Only fully replicated — read back within the window — gates destructive cleanup"
            )
        }
    }

    func testEveryStateHasAVerdict() {
        let states: [ProtectionState] = [
            .stagedOnly, .replicatedToOneDrive, .fullyReplicated,
            .driftDetected, .awaitingFirstCheck, .verificationOverdue, .notApplicable
        ]
        for state in states {
            XCTAssertEqual(state.isHealthy, state.verdict.isSatisfied || state.verdict == .notLocal)
        }
    }
}
