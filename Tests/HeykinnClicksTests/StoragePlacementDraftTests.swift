import XCTest
@testable import HeykinnClicks

/// Editing where a group is kept, by moving its placements around.
///
/// The rules matter more here than they did behind the old sheet of
/// checkboxes. A sheet could only offer legal moves; direct manipulation
/// cannot, because picking a placement up is half of putting it down. So every
/// state these tests describe is one somebody can be in — and the point of each
/// is which of them may be saved.
final class StoragePlacementDraftTests: XCTestCase {

    private let driveA = UUID(), driveB = UUID(), mac = UUID()

    private func group(
        copies: Int = 2,
        on destinations: [UUID],
        mode: StorageGroup.DestinationMode = .chosen
    ) -> StorageGroup {
        StorageGroup(
            id: UUID(), label: "Books", desiredCopies: copies,
            destinationTargetIDs: destinations, destinationMode: mode, createdAt: Date()
        )
    }

    func testMovingAPlacementKeepsTheOrderOfTheOtherDevices() {
        var draft = StoragePlacementDraft(group: group(on: [driveA, driveB]))
        XCTAssertTrue(draft.move(from: driveA, to: mac))
        XCTAssertEqual(
            draft.destinations, [mac, driveB],
            "replaced in place — a move must not reshuffle the devices it did not touch"
        )
    }

    /// The drag has to mean what it looks like it means. Left automatic, the
    /// app would resolve its own destinations again and undo the move.
    func testMovingFixesAGroupToTheDevicesNamed() {
        var draft = StoragePlacementDraft(group: group(on: [driveA, driveB], mode: .automatic))
        XCTAssertEqual(draft.mode, .automatic)
        XCTAssertTrue(draft.move(from: driveB, to: mac))
        XCTAssertEqual(draft.mode, .chosen)
    }

    func testMovesThatSayNothingChangeNothing() {
        var draft = StoragePlacementDraft(group: group(on: [driveA, driveB]))
        let before = draft
        XCTAssertFalse(draft.move(from: mac, to: driveA), "the group does not use that device")
        XCTAssertFalse(draft.move(from: driveA, to: driveB), "it is already kept there")
        XCTAssertFalse(draft.move(from: driveA, to: driveA))
        XCTAssertEqual(draft, before, "a refused move leaves the draft exactly as it was")
    }

    /// The state between picking one up and putting it down.
    func testAGroupWithNowhereToLiveCannotBeSaved() {
        var draft = StoragePlacementDraft(group: group(copies: 1, on: [driveA]))
        draft.remove(driveA)
        XCTAssertFalse(draft.canBeSaved)
        XCTAssertEqual(draft.problem, "Nowhere to keep them. Give this group at least one device.")
    }

    /// Asking for more copies than there are homes for them.
    func testMoreCopiesThanDevicesCannotBeSaved() {
        var draft = StoragePlacementDraft(group: group(copies: 2, on: [driveA, driveB]))
        draft.remove(driveB)
        XCTAssertFalse(draft.canBeSaved)
        XCTAssertEqual(
            draft.problem,
            "two copies on 1 device — 1 more device needed, or fewer copies.",
            "says both ways out, because either is a fix"
        )
        // And the other way out closes it.
        draft.copies = 1
        XCTAssertTrue(draft.canBeSaved)
    }

    /// A group working out its own devices is short of nothing until it has
    /// resolved them, so the count is not measured against a list it does not
    /// use. Warning here would put an error on the default arrangement.
    func testAnAutomaticGroupIsNotJudgedAgainstItsResolvedDevices() {
        var draft = StoragePlacementDraft(group: group(copies: 3, on: [driveA], mode: .automatic))
        XCTAssertNil(draft.problem)
        // Naming a device is what makes the count answerable.
        draft.add(driveB)
        XCTAssertEqual(draft.mode, .chosen)
        XCTAssertNotNil(draft.problem, "three copies, two devices — now it is a real shortfall")
    }

    func testADraftThatMatchesItsGroupHasNothingToApply() {
        let existing = group(on: [driveA, driveB])
        var draft = StoragePlacementDraft(group: existing)
        XCTAssertFalse(draft.differs(from: existing))
        XCTAssertTrue(draft.move(from: driveA, to: mac))
        XCTAssertTrue(draft.differs(from: existing))
        // And back again, which is a real thing to do with a drag.
        XCTAssertTrue(draft.move(from: mac, to: driveA))
        XCTAssertFalse(
            draft.differs(from: existing),
            "dragging something out and back is not a change, and must not offer to be saved"
        )
    }
}
