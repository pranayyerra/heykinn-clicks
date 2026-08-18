import XCTest
@testable import HeykinnClicks

/// The one answer to "are my photos safe".
///
/// Both screens wrote this sentence for themselves, and neither could be
/// reached from a test — which is how they came to disagree without anybody
/// noticing. These fix the order once.
final class SafetyAnswerTests: XCTestCase {

    private func facts(
        photos: Int = 100, places: Int = 2, damaged: Int = 0, short: Int = 0,
        copiesShort: Int = 0, fewest: Int? = 2, atFewest: Int = 100,
        unsatisfiable: [String] = []
    ) -> SafetyAnswer.Facts {
        SafetyAnswer.Facts(
            photos: photos, places: places, damaged: damaged, short: short,
            copiesShort: copiesShort, fewestPlaces: fewest,
            photosAtFewest: atFewest, unsatisfiable: unsatisfiable
        )
    }

    /// **The defect this was built for.**
    ///
    /// A photograph with a damaged copy is not satisfied, so Overview counted
    /// it among photos "not yet on all the drives they are meant to be on" —
    /// the sentence for work in progress — while Keep safe said a copy no
    /// longer matched. The screen a person opens first gave the reassuring
    /// answer about a photograph that was rotting.
    func testDamageIsSaidBeforeBeingBehind() {
        let sentence = SafetyAnswer.headline(facts(damaged: 3, short: 3))
        XCTAssertEqual(sentence, "3 photos have a copy that no longer matches.")
        XCTAssertFalse(sentence.contains("not yet on"), sentence)
    }

    func testDamagedIsNeverSound() {
        XCTAssertFalse(SafetyAnswer.isSound(facts(damaged: 1), everythingRead: true))
        XCTAssertTrue(SafetyAnswer.isSound(facts(), everythingRead: true))
        XCTAssertFalse(SafetyAnswer.isSound(facts(), everythingRead: false),
                       "copies nobody has read back are not proof")
        XCTAssertFalse(SafetyAnswer.isSound(facts(fewest: 1), everythingRead: true),
                       "one place is not two")
    }

    /// Held nowhere at all beats being behind, for the same reason damage does:
    /// it is worse and more specific.
    func testInNoPlaceAtAllIsSaidBeforeBeingBehind() {
        XCTAssertEqual(
            SafetyAnswer.headline(facts(short: 9, fewest: 0, atFewest: 4)),
            "4 photos are in no place at all."
        )
    }

    /// No amount of copying fixes asking for more copies than there are drives,
    /// so it is said before the backlog it would otherwise hide behind.
    func testAskingForMoreCopiesThanDrivesIsNamed() {
        let sentence = SafetyAnswer.headline(facts(short: 40, unsatisfiable: ["Wedding"]))
        XCTAssertTrue(sentence.hasPrefix("Wedding asks for more copies"), sentence)
    }

    func testTheOrdinaryAnswers() {
        XCTAssertEqual(SafetyAnswer.headline(facts(photos: 0)), "Nothing in the archive yet.")
        XCTAssertTrue(SafetyAnswer.headline(facts(places: 0)).contains("no drive is set up"))
        XCTAssertEqual(
            SafetyAnswer.headline(facts(fewest: 1, atFewest: 12)),
            "12 photos are in one place only."
        )
        XCTAssertEqual(SafetyAnswer.headline(facts(fewest: 3)), "Every photo is in 3 places.")
    }

    /// Copies, not just photographs: one photo can be a copy short or three,
    /// and "412 photos short" reads the same either way.
    func testTheBacklogSaysHowManyCopiesWhenItDiffers() {
        XCTAssertTrue(
            SafetyAnswer.headline(facts(short: 10, copiesShort: 25))
                .contains("25 copies still to make")
        )
        XCTAssertFalse(
            SafetyAnswer.headline(facts(short: 10, copiesShort: 10)).contains("still to make"),
            "saying it twice when the numbers agree is noise"
        )
    }
}
