import XCTest
@testable import HeykinnClicks

/// The four ways a Live Photo pairing can end.
///
/// Three of them were unreachable from a test until the reader became a seam:
/// they need a still and a movie carrying matching Apple content identifiers,
/// which cannot be written by hand. Only the rejection could be exercised, so
/// the case these rules exist for — Google re-encoding a still and dropping
/// Apple's maker note — was held up by a comment.
final class LivePhotoConfidenceTests: XCTestCase {

    /// A stand-in for two files, saying what each carries.
    private struct Files: LivePhotoIdentifiers {
        var still: String?
        var motion: String?
        var duration: TimeInterval? = 3
        func stillIdentifier(_ url: URL) -> String? { still }
        func motionIdentifier(_ url: URL) async -> String? { motion }
        func motionDuration(_ url: URL) async -> TimeInterval? { duration }
    }

    private var candidate: LivePhotoPairer.Candidate {
        LivePhotoPairer.Candidate(
            stillAssetID: UUID(), motionAssetID: UUID(),
            stillURL: URL(fileURLWithPath: "/tmp/IMG_1.jpg"),
            motionURL: URL(fileURLWithPath: "/tmp/IMG_1.mov")
        )
    }

    /// Both halves carry the same identifier: as certain as this gets.
    func testMatchingIdentifiersArePair() async {
        let result = await LivePhotoPairer.confirm(
            candidate, using: Files(still: "ABC-123", motion: "ABC-123")
        )
        XCTAssertEqual(result, .identifiersMatch)
        XCTAssertTrue(result.isPair)
    }

    /// **The case the rules exist for.** Google re-encodes some stills and drops
    /// Apple's maker note, so the identifier survives on the movie's side only.
    /// The movie proves it is *a* Live Photo's motion half, and the shared
    /// filename stem is the rest of the evidence. Without this, those pairs
    /// would never reunite.
    func testAMovieWithAnIdentifierAndAStillWithoutIsStillAPair() async {
        let result = await LivePhotoPairer.confirm(
            candidate, using: Files(still: nil, motion: "ABC-123")
        )
        XCTAssertEqual(result, .motionIdentifierAndName)
        XCTAssertTrue(result.isPair)
        XCTAssertFalse(
            result.isConclusiveRejection,
            "nothing was ruled out here, so nothing may be recorded as settled"
        )
    }

    /// The movie is a Live Photo's motion half — but of some other still. It
    /// stays open, because the right still may yet be imported.
    func testAMovieBelongingToADifferentStillStaysOpen() async {
        let result = await LivePhotoPairer.confirm(
            candidate, using: Files(still: "STILL-1", motion: "OTHER-2")
        )
        XCTAssertEqual(result, .stillDoesNotMatch)
        XCTAssertFalse(result.isPair)
        XCTAssertFalse(
            result.isConclusiveRejection,
            "recording this as settled would stop the real still ever finding it"
        )
    }

    /// No identifier on the movie means an ordinary video, whatever it is
    /// called. A shared filename is never sufficient on its own.
    func testAMovieWithNoIdentifierIsAnOrdinaryVideo() async {
        let result = await LivePhotoPairer.confirm(
            candidate, using: Files(still: "ABC-123", motion: nil)
        )
        XCTAssertEqual(result, .notLivePhotoMotion)
        XCTAssertTrue(result.isConclusiveRejection)
    }

    func testAnEmptyIdentifierIsNoIdentifier() async {
        let result = await LivePhotoPairer.confirm(
            candidate, using: Files(still: "ABC-123", motion: "")
        )
        XCTAssertEqual(result, .notLivePhotoMotion)
    }

    /// Long videos are rejected before anything is read — the cheap check that
    /// keeps pairing affordable on every import.
    func testAVideoTooLongToBeALivePhotoIsRejectedWithoutReadingIt() async {
        let result = await LivePhotoPairer.confirm(
            candidate,
            using: Files(still: "ABC-123", motion: "ABC-123",
                         duration: LivePhotoPairer.maxMotionDuration + 1)
        )
        XCTAssertEqual(result, .notLivePhotoMotion, "identifiers matched, but it is a real video")
    }

    /// A movie whose duration cannot be read is not thereby disqualified — the
    /// identifier still decides.
    func testAnUnreadableDurationDoesNotDisqualify() async {
        let result = await LivePhotoPairer.confirm(
            candidate, using: Files(still: "ABC-123", motion: "ABC-123", duration: nil)
        )
        XCTAssertEqual(result, .identifiersMatch)
    }
}
