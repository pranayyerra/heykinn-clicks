import XCTest
@testable import HeykinnClicks

/// The two decisions a reader on another platform has to make identically.
///
/// Both end up in the catalog — the kind is stored on every asset, the parsed
/// date becomes its capture date — so a second reader that disagreed would
/// build a different archive from the same files. They are in `Domain/` for
/// that reason, not because they happened to compile without ImageIO.
final class MediaKindsTests: XCTestCase {

    func testWhatCountsAsAPhotographAndWhatAsVideo() {
        for ext in ["jpg", "JPEG", "heic", "dng", "cr2", "webp"] {
            XCTAssertEqual(MediaKinds.kind(forFileExtension: ext), .photo, ext)
        }
        for ext in ["mov", "MP4", "mkv", "3gp", "mts"] {
            XCTAssertEqual(MediaKinds.kind(forFileExtension: ext), .video, ext)
        }
        for ext in ["txt", "json", "pdf", "", "zip"] {
            XCTAssertEqual(MediaKinds.kind(forFileExtension: ext), .unknown, ext)
        }
    }

    /// A Google export ships a `.json` beside every photograph, and a folder
    /// somebody imports is full of things that are not photographs. Treating
    /// one as media would put it in the archive; the reclaim then reads it as
    /// something the app holds a copy of.
    func testTheSidecarsAndStrangersAreNotMedia() {
        XCTAssertEqual(MediaKinds.kind(forFileExtension: "json"), .unknown)
        XCTAssertEqual(MediaKinds.kind(forFileExtension: "aae"), .unknown)
    }

    /// EXIF's format is not ISO 8601, and the separators are colons throughout.
    func testTheExifDateFormat() throws {
        let parsed = try XCTUnwrap(MediaKinds.parseExifDate("2019:07:04 14:03:09"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        XCTAssertEqual(parts.year, 2019)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 4)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 3)
        XCTAssertEqual(parts.second, 9)
    }

    /// **Read in the device's own zone, deliberately.** EXIF carries no offset,
    /// so a photograph taken at 14:03 is 14:03 where it was taken. Reading it
    /// as UTC would move every photograph in the archive by the reader's
    /// offset — which is exactly the kind of disagreement between two platforms
    /// this file exists to prevent.
    func testAnExifDateHasNoTimeZoneAndIsReadAsLocal() throws {
        let parsed = try XCTUnwrap(MediaKinds.parseExifDate("2019:07:04 14:03:09"))
        let asUTC = ISO8601DateFormatter()
        asUTC.timeZone = TimeZone(identifier: "UTC")
        XCTAssertEqual(
            parsed.timeIntervalSince1970,
            (try XCTUnwrap(asUTC.date(from: "2019-07-04T14:03:09Z"))).timeIntervalSince1970
                - Double(TimeZone.current.secondsFromGMT(for: parsed)),
            accuracy: 1
        )
    }

    func testRubbishIsNotADate() {
        XCTAssertNil(MediaKinds.parseExifDate(""))
        XCTAssertNil(MediaKinds.parseExifDate("2019-07-04T14:03:09Z"), "ISO 8601 is not EXIF's format")
        XCTAssertNil(MediaKinds.parseExifDate("yesterday"))
    }

    /// The old spelling still answers, so the pipeline's call sites did not all
    /// have to change in the same commit as the seam.
    func testTheOldNamesStillDelegate() {
        XCTAssertEqual(MetadataExtractor.kind(forFileExtension: "jpg"), .photo)
        XCTAssertEqual(
            MetadataExtractor.parseExifDate("2019:07:04 14:03:09"),
            MediaKinds.parseExifDate("2019:07:04 14:03:09")
        )
    }
}
