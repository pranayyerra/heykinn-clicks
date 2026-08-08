import XCTest
@testable import HeykinnClicks

/// Remembering a drive's answer, and being able to take it back.
///
/// The behaviour these pin down is the pair, not either half: the old code
/// could remember one kind of answer and had no way to undo it, and both of
/// those are the defect.
@MainActor
final class AccessGrantTests: XCTestCase {

    private var suiteName = ""

    /// A private suite per test, so these never read or write the real app's
    /// preferences — and never each other's.
    private func makeDefaults() -> UserDefaults {
        suiteName = "heykinn-access-\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testRememberedDecisionSurvivesRelaunch() {
        let defaults = makeDefaults()
        let first = AccessGrants(defaults: defaults)
        first.record(
            decision: .scan, forVolumeUUID: "VOL-1", path: "/Volumes/Field",
            displayName: "Field Drive"
        )

        // A second instance over the same preferences is what a relaunch is.
        let second = AccessGrants(defaults: defaults)
        XCTAssertEqual(second.decision(forKey: "VOL-1"), .scan)
        XCTAssertEqual(second.grant(forKey: "VOL-1")?.displayName, "Field Drive")
    }

    /// The whole point of the change. "Scan it" used to be re-asked at every
    /// mount because only refusal was ever written down.
    func testEveryDecisionIsRemembered() {
        let defaults = makeDefaults()
        let grants = AccessGrants(defaults: defaults)
        for (index, decision) in VolumeDecision.allCases.enumerated() {
            grants.record(
                decision: decision, forVolumeUUID: "VOL-\(index)", path: "/Volumes/D\(index)",
                displayName: "D\(index)"
            )
            XCTAssertEqual(grants.decision(forKey: "VOL-\(index)"), decision)
        }
        XCTAssertEqual(grants.grants.count, VolumeDecision.allCases.count)
    }

    func testNotRememberingRecordsNothing() {
        let grants = AccessGrants(defaults: makeDefaults())
        grants.record(
            decision: .ignore, forVolumeUUID: "VOL-1", path: "/Volumes/Field",
            displayName: "Field Drive", remember: false
        )
        XCTAssertNil(grants.decision(forKey: "VOL-1"))
    }

    func testRevokingLetsTheQuestionBeAskedAgain() {
        let defaults = makeDefaults()
        let grants = AccessGrants(defaults: defaults)
        grants.record(
            decision: .ignore, forVolumeUUID: "VOL-1", path: "/Volumes/Field",
            displayName: "Field Drive"
        )
        grants.revoke("VOL-1")

        XCTAssertNil(grants.decision(forKey: "VOL-1"))
        // And it stays revoked across a relaunch, rather than the removal
        // living only in memory.
        XCTAssertNil(AccessGrants(defaults: defaults).decision(forKey: "VOL-1"))
    }

    /// Users of the previous version said "don't ask about this drive" and
    /// meant it. Dropping the old key would start asking again, which is the
    /// exact complaint this work exists to answer.
    func testLegacySuppressionKeysAreCarriedForward() {
        let defaults = makeDefaults()
        defaults.set(["VOL-OLD", "/Volumes/Unnamed"], forKey: "ignoredVolumeKeys")

        let grants = AccessGrants(defaults: defaults)
        XCTAssertEqual(grants.decision(forKey: "VOL-OLD"), .ignore)
        XCTAssertEqual(grants.decision(forKey: "/Volumes/Unnamed"), .ignore)
        // Migrated, not duplicated: the old key is consumed.
        XCTAssertNil(defaults.stringArray(forKey: "ignoredVolumeKeys"))
    }

    /// A drive remounted at a different path is the same drive. The decision
    /// and the date it was made must not be reset by having been seen again.
    func testRemountUpdatesPlaceWithoutRewritingTheDecision() {
        let grants = AccessGrants(defaults: makeDefaults())
        grants.record(
            decision: .manage, forVolumeUUID: "VOL-1", path: "/Volumes/Field",
            displayName: "Field Drive"
        )
        let decidedAt = grants.grant(forKey: "VOL-1")?.decidedAt

        grants.noteSeen(key: "VOL-1", displayName: "Field Drive", path: "/Volumes/Field 1")

        XCTAssertEqual(grants.decision(forKey: "VOL-1"), .manage)
        XCTAssertEqual(grants.grant(forKey: "VOL-1")?.lastKnownPath, "/Volumes/Field 1")
        XCTAssertEqual(grants.grant(forKey: "VOL-1")?.decidedAt, decidedAt)
    }

    /// Volume UUID wins over path, because a path says where a disk was last
    /// seen and two disks can occupy one path at different times.
    func testIdentityPrefersVolumeUUID() {
        XCTAssertEqual(AccessGrants.key(forVolumeUUID: "VOL-1", path: "/Volumes/Field"), "VOL-1")
        XCTAssertEqual(AccessGrants.key(forVolumeUUID: nil, path: "/Volumes/Field"), "/Volumes/Field")
    }
}
