import XCTest
@testable import HeykinnClicks

/// What the app refuses to delete, and why.
///
/// Written as refusals first on purpose. This is the only place the app would
/// remove a file that belongs to the person using it, and the promise on the
/// Add photos screen is that originals are only ever read — so the interesting
/// behaviour is everything it declines to touch.
final class SourceFolderReclaimTests: XCTestCase {

    private func file(_ name: String, hash: String, size: Int64 = 1_000) -> SourceFolderReclaim.File {
        SourceFolderReclaim.File(
            url: URL(fileURLWithPath: "/Users/someone/Holiday/\(name)"),
            contentHash: hash,
            size: size
        )
    }

    /// The case the feature exists for: the archive holds these, on enough
    /// drives, and has read one back.
    func testFilesTheArchiveAlreadyHoldsCanGo() {
        let a = file("one.jpg", hash: "aaa"), b = file("two.jpg", hash: "bbb")
        let plan = SourceFolderReclaim.plan(
            files: [a, b],
            protectionByHash: ["aaa": .fullyReplicated, "bbb": .fullyReplicated]
        )
        XCTAssertEqual(plan.releasable, [a, b])
        XCTAssertEqual(plan.releasableBytes, 2_000)
        XCTAssertFalse(plan.leavesFilesBehind)
    }

    /// **A reading that has aged is still a reading.**
    ///
    /// `verificationOverdue` means read back, longer ago than the background
    /// reader would like. It counts as meeting policy everywhere else in the
    /// app; making it a refusal here would invent a freshness rule this app
    /// applies nowhere, and would mean a folder became un-reclaimable by the
    /// passage of time alone.
    func testACopyReadBackAWhileAgoStillCounts() {
        let a = file("one.jpg", hash: "aaa")
        let plan = SourceFolderReclaim.plan(
            files: [a], protectionByHash: ["aaa": .verificationOverdue]
        )
        XCTAssertEqual(plan.releasable, [a])
    }

    /// **But copies nothing has ever read are not evidence.**
    ///
    /// The app wrote them and believes they landed. Believing itself is exactly
    /// what it must not do before deleting somebody's file.
    func testCopiesNobodyHasReadBackAreRefused() {
        let a = file("one.jpg", hash: "aaa")
        let plan = SourceFolderReclaim.plan(
            files: [a], protectionByHash: ["aaa": .awaitingFirstCheck]
        )
        XCTAssertTrue(plan.releasable.isEmpty)
        XCTAssertEqual(plan.blocked[a], .neverReadBack)
    }

    func testTooFewCopiesAndDamagedCopiesAreRefusedSeparately() {
        let short = file("short.jpg", hash: "aaa")
        let staged = file("staged.jpg", hash: "bbb")
        let damaged = file("damaged.jpg", hash: "ccc")
        let plan = SourceFolderReclaim.plan(
            files: [short, staged, damaged],
            protectionByHash: [
                "aaa": .replicatedToOneDrive,
                "bbb": .stagedOnly,
                "ccc": .driftDetected,
            ]
        )
        XCTAssertTrue(plan.releasable.isEmpty)
        XCTAssertEqual(plan.blocked[short], .notEnoughCopies)
        XCTAssertEqual(plan.blocked[staged], .notEnoughCopies)
        XCTAssertEqual(
            plan.blocked[damaged], .damagedCopy,
            "a damaged copy must not read as merely behind — it is the reason to keep the original"
        )
    }

    /// **The refusal that matters most.** A folder almost always holds things
    /// the app never took in — a video it does not handle, a notes file, a
    /// subfolder of something else. "Remove the folder" must never quietly mean
    /// "remove things nobody looked at".
    func testFilesTheAppNeverImportedAreNeverTouched() {
        let photo = file("one.jpg", hash: "aaa")
        let stranger = file("notes.txt", hash: "zzz", size: 40)
        let plan = SourceFolderReclaim.plan(
            files: [photo, stranger], protectionByHash: ["aaa": .fullyReplicated]
        )
        XCTAssertEqual(plan.releasable, [photo])
        XCTAssertEqual(plan.notImported, [stranger])
        XCTAssertEqual(plan.notImportedBytes, 40)
        XCTAssertTrue(plan.leavesFilesBehind, "so the offer can say the folder does not disappear")
    }

    /// A photograph the archive keeps somewhere other than your drives is not
    /// one your drives hold, so this file is not spare.
    func testAPhotoTheArchiveDoesNotKeepLocallyIsLeftAlone() {
        let a = file("cloud.jpg", hash: "aaa")
        let plan = SourceFolderReclaim.plan(
            files: [a], protectionByHash: ["aaa": .notApplicable]
        )
        XCTAssertTrue(plan.releasable.isEmpty)
        XCTAssertEqual(plan.notImported, [a])
    }

    /// **Edited since it was imported.** Identity is the hash of the bytes as
    /// they are now, so a file changed after import matches nothing the archive
    /// holds and is left alone — without needing a rule of its own.
    func testAFileChangedSinceImportIsNotRecognisedAndStays() {
        let edited = file("one.jpg", hash: "edited-since")
        let plan = SourceFolderReclaim.plan(
            files: [edited], protectionByHash: ["original-bytes": .fullyReplicated]
        )
        XCTAssertTrue(plan.releasable.isEmpty)
        XCTAssertEqual(plan.notImported, [edited])
    }

    func testAnEmptyFolderOffersNothing() {
        let plan = SourceFolderReclaim.plan(files: [], protectionByHash: [:])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.leavesFilesBehind)
    }
}
