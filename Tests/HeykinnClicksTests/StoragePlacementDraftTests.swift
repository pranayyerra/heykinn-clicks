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

    private let driveA = UUID(), driveB = UUID(), host = UUID()

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
        XCTAssertTrue(draft.move(from: driveA, to: host))
        XCTAssertEqual(
            draft.destinations, [host, driveB],
            "replaced in place — a move must not reshuffle the devices it did not touch"
        )
    }

    /// The drag has to mean what it looks like it means. Left automatic, the
    /// app would resolve its own destinations again and undo the move.
    func testMovingFixesAGroupToTheDevicesNamed() {
        var draft = StoragePlacementDraft(group: group(on: [driveA, driveB], mode: .automatic))
        XCTAssertEqual(draft.mode, .automatic)
        XCTAssertTrue(draft.move(from: driveB, to: host))
        XCTAssertEqual(draft.mode, .chosen)
    }

    func testMovesThatSayNothingChangeNothing() {
        var draft = StoragePlacementDraft(group: group(on: [driveA, driveB]))
        let before = draft
        XCTAssertFalse(draft.move(from: host, to: driveA), "the group does not use that device")
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
    ///
    /// No longer reachable by taking a device away — removal keeps "on all of
    /// them" true rather than stranding the count. It arrives the other way:
    /// a group that named three devices and had one of them forgotten.
    func testMoreCopiesThanDevicesCannotBeSaved() {
        var draft = StoragePlacementDraft(group: group(copies: 2, on: [driveA]))
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

    /// Taking a device off a group that kept a copy on all of them must not
    /// answer with an error about an arrangement nobody asked for.
    func testRemovingADeviceDoesNotProduceThatComplaint() {
        var draft = StoragePlacementDraft(group: group(copies: 2, on: [driveA, driveB]))
        draft.remove(driveB)
        XCTAssertEqual(draft.copies, 1)
        XCTAssertTrue(draft.canBeSaved)
    }

    /// A group working out its own devices is short of nothing until it has
    /// resolved them, so the count is not measured against a list it does not
    /// use. Warning here would put an error on the default arrangement.
    func testAnAutomaticGroupIsNotJudgedAgainstItsResolvedDevices() {
        var draft = StoragePlacementDraft(group: group(copies: 3, on: [driveA], mode: .automatic))
        XCTAssertNil(draft.problem, "it has not resolved its devices yet; there is nothing to be short of")
        // Naming a device is what makes the count answerable — and adding one
        // keeps every named device holding a copy, so the count follows.
        draft.add(driveB)
        XCTAssertEqual(draft.mode, .chosen)
        XCTAssertEqual(draft.copies, 2)
        XCTAssertNil(draft.problem)
        // Asking for a third copy with two devices named is the shortfall.
        draft.copies = 3
        XCTAssertNotNil(draft.problem, "three copies, two devices")
    }

    func testADraftThatMatchesItsGroupHasNothingToApply() {
        let existing = group(on: [driveA, driveB])
        var draft = StoragePlacementDraft(group: existing)
        XCTAssertFalse(draft.differs(from: existing))
        XCTAssertTrue(draft.move(from: driveA, to: host))
        XCTAssertTrue(draft.differs(from: existing))
        // And back again, which is a real thing to do with a drag.
        XCTAssertTrue(draft.move(from: host, to: driveA))
        XCTAssertFalse(
            draft.differs(from: existing),
            "dragging something out and back is not a change, and must not offer to be saved"
        )
    }
}

/// Naming devices and asking for copies are two different things, and the
/// editor has to keep the difference straight without making anybody think
/// about it.
final class StoragePlacementIntentTests: XCTestCase {

    private let driveA = UUID(), driveB = UUID(), host = UUID()
    private lazy var names: [UUID: String] = [driveA: "Owner's Back", driveB: "My Passport", host: "this device"]

    private func group(copies: Int, on destinations: [UUID]) -> StorageGroup {
        StorageGroup(
            id: UUID(), label: "G", desiredCopies: copies,
            destinationTargetIDs: destinations, destinationMode: .chosen, createdAt: Date()
        )
    }

    private func rule(_ draft: StoragePlacementDraft, choseFrom: Int = 99) -> String {
        draft.rule(choseFrom: choseFrom) { self.names[$0] ?? "?" }
    }

    /// Ticking another device usually means "and this one too". Leaving the
    /// count behind would silently demote it to a spare.
    func testAddingADeviceKeepsEveryDeviceHoldingACopy() {
        var draft = StoragePlacementDraft(group: group(copies: 2, on: [driveA, driveB]))
        XCTAssertTrue(draft.keepsACopyEverywhere)
        draft.add(host)
        XCTAssertEqual(draft.copies, 3, "all three hold a copy, which is what ticking a third means")
        XCTAssertTrue(rule(draft).contains("all 3"), rule(draft))
    }

    /// Unless spares were already in use — then another device is another spare.
    func testAddingADeviceToAGroupUsingSparesAddsASpare() {
        var draft = StoragePlacementDraft(group: group(copies: 2, on: [driveA, driveB, host]))
        draft.copies = 2
        XCTAssertFalse(draft.keepsACopyEverywhere)
        let fourth = UUID()
        draft.add(fourth)
        XCTAssertEqual(draft.copies, 2, "the arrangement in force was two of these; it still is")
    }

    /// Removing a device while "on all of them" was true must not produce an
    /// error about an arrangement nobody asked for.
    func testRemovingADeviceDoesNotStrandTheCount() {
        var draft = StoragePlacementDraft(group: group(copies: 3, on: [driveA, driveB, host]))
        draft.remove(host)
        XCTAssertEqual(draft.copies, 2)
        XCTAssertNil(draft.problem, "and it is saveable, rather than complaining about itself")
    }

    /// The sentence that explains why a count and a tick list are both needed.
    func testTheRuleSaysWhichDevicesAreSpares() {
        var draft = StoragePlacementDraft(group: group(copies: 3, on: [driveA, driveB, host]))
        draft.copies = 2
        let sentence = rule(draft)
        XCTAssertTrue(sentence.contains("two copies"), sentence)
        XCTAssertTrue(sentence.contains("Owner's Back and My Passport first"), sentence)
        XCTAssertTrue(sentence.contains("this device when one of those is full"), sentence)
    }

    func testOneDeviceReadsAsOneDevice() {
        let draft = StoragePlacementDraft(group: group(copies: 1, on: [driveA]))
        XCTAssertEqual(rule(draft), "Every photo on Owner's Back, and nowhere else.")
    }

    // MARK: - What a worked-out group says about itself

    private func automatic(copies: Int, on destinations: [UUID]) -> StoragePlacementDraft {
        StoragePlacementDraft(group: StorageGroup(
            id: UUID(), label: "G", desiredCopies: copies,
            destinationTargetIDs: destinations, destinationMode: .automatic, createdAt: Date()
        ))
    }

    /// It used to say "on devices the app works out" — which named nothing and
    /// gave no reason, and repeated the hint printed directly underneath it.
    func testAWorkedOutGroupNamesItsDevicesAndSaysWhy() {
        let sentence = rule(automatic(copies: 2, on: [driveA, driveB]))
        XCTAssertEqual(sentence, "Every photo on Owner's Back and My Passport — the devices with the most room.")
        XCTAssertFalse(sentence.contains("works out"), "the sentence still explains itself instead of answering")
    }

    func testAWorkedOutGroupWithOneDeviceSaysDeviceNotDevices() {
        XCTAssertEqual(
            rule(automatic(copies: 1, on: [driveA])),
            "Every photo on Owner's Back — the device with the most room."
        )
    }

    /// Fewer devices than copies. `problem` stays quiet for a worked-out group
    /// on purpose — a default arrangement should not wear a warning — so this
    /// sentence is the only thing that says it, and it has to say it plainly
    /// without calling it a mistake.
    func testAWorkedOutGroupShortOfDevicesSaysSoWithoutCallingItAnError() {
        let draft = automatic(copies: 2, on: [driveA])
        XCTAssertNil(draft.problem, "a worked-out group must not be warned about its own default")
        let sentence = rule(draft)
        XCTAssertTrue(sentence.contains("one copy"), sentence)
        XCTAssertTrue(sentence.contains("two copies"), sentence)
        XCTAssertTrue(sentence.contains("Owner's Back"), sentence)
    }

    /// **A reason is only given when a drive was actually passed over.**
    ///
    /// Two drives and two copies is not a judgement about room — it took both.
    /// Claiming otherwise would have the app explaining a decision it did not
    /// make, which is the same failure as claiming a copy it did not check.
    func testTakingEveryDriveThereIsClaimsNoJudgementAboutRoom() {
        let sentence = rule(automatic(copies: 2, on: [driveA, driveB]), choseFrom: 2)
        XCTAssertEqual(sentence, "Every photo on Owner's Back and My Passport.")
        XCTAssertFalse(sentence.contains("most room"), sentence)
    }

    /// The case that put this parameter here: a fresh install with no drive
    /// plugged in falls back to this device. It is not the roomiest of
    /// anything — it is the only place there is.
    func testTheFallbackToThisDeviceIsNotDescribedAsTheRoomiest() {
        let sentence = rule(automatic(copies: 1, on: [host]), choseFrom: 0)
        XCTAssertEqual(sentence, "Every photo on this device.")
        XCTAssertFalse(sentence.contains("most room"), sentence)
    }

    /// And with something passed over, the reason is earned and given.
    func testPassingOverADriveEarnsTheReason() {
        XCTAssertEqual(
            rule(automatic(copies: 1, on: [driveA]), choseFrom: 3),
            "Every photo on Owner's Back — the device with the most room."
        )
    }
}
