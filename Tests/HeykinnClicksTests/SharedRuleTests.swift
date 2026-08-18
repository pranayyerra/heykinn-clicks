import XCTest
@testable import HeykinnClicks

/// When the storage screen shows one line instead of a row per import.
///
/// The whole of P2 came down to this: groups can recede only if the one thing
/// they are needed for — saying "this set is kept differently" — still gets
/// said. It does, by being the very thing that stops the collapse.
final class SharedRuleTests: XCTestCase {

    private let driveA = UUID(), driveB = UUID(), driveC = UUID()

    private func group(
        _ label: String,
        copies: Int,
        on destinations: [UUID],
        mode: StorageGroup.DestinationMode = .automatic
    ) -> StorageGroup {
        StorageGroup(
            id: UUID(), label: label, desiredCopies: copies,
            destinationTargetIDs: destinations, destinationMode: mode, createdAt: Date()
        )
    }

    /// Six imports, one rule, one line.
    func testSetsKeptTheSameWayCollapseToOne() {
        let sets = (1...6).map { group("Import \($0)", copies: 2, on: [driveA, driveB]) }
        XCTAssertNotNil(StorageGroup.sharedRule(among: sets))
    }

    /// **The case the whole design had to protect.** Somebody keeps one set off
    /// the drive they travel with. Nothing detects that intention; the set
    /// simply differs, and a difference is what stops the collapse.
    func testASetKeptOffOneDriveStopsTheCollapse() {
        let sets = [
            group("Photos library", copies: 2, on: [driveA, driveB]),
            group("Photos library 2", copies: 2, on: [driveA, driveB]),
            group("Offsite only", copies: 1, on: [driveC], mode: .chosen),
        ]
        XCTAssertNil(
            StorageGroup.sharedRule(among: sets),
            "a set kept somewhere else was folded in with the rest"
        )
    }

    /// A different number of copies is a difference too, even on the same
    /// drives — it is the difference between two copies and one.
    func testADifferentCopyCountStopsTheCollapse() {
        let sets = [
            group("A", copies: 2, on: [driveA, driveB]),
            group("B", copies: 1, on: [driveA, driveB]),
        ]
        XCTAssertNil(StorageGroup.sharedRule(among: sets))
    }

    /// Mode is not a difference: it says what happens next, not where the
    /// photos are. Two sets on the same drives are in the same place.
    func testHowTheDevicesWereDecidedIsNotADifference() {
        let sets = [
            group("Worked out", copies: 2, on: [driveA, driveB], mode: .automatic),
            group("Named by hand", copies: 2, on: [driveA, driveB], mode: .chosen),
        ]
        XCTAssertNotNil(StorageGroup.sharedRule(among: sets))
    }

    /// Order is a difference, because the first device named is the one
    /// somebody thinks of as primary and the app honours that order.
    func testTheOrderDevicesAreNamedInIsADifference() {
        let sets = [
            group("A", copies: 2, on: [driveA, driveB]),
            group("B", copies: 2, on: [driveB, driveA]),
        ]
        XCTAssertNil(StorageGroup.sharedRule(among: sets))
    }

    /// Nothing to collapse: one set is the archive, and an empty archive has
    /// no rule to state.
    func testOneSetOrNoneCollapsesNothing() {
        XCTAssertNil(StorageGroup.sharedRule(among: []))
        XCTAssertNil(StorageGroup.sharedRule(among: [group("Only", copies: 2, on: [driveA, driveB])]))
    }
}
