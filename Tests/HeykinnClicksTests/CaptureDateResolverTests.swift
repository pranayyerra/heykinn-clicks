import XCTest
@testable import HeykinnClicks

final class CaptureDateResolverTests: XCTestCase {

    private func year(_ date: Date?) -> Int? {
        date.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
    }

    // MARK: - Precedence

    func testFileMetadataOutranksEverythingElse() {
        let exif = Date(timeIntervalSince1970: 1_000_000)
        let resolved = CaptureDateResolver.resolve(
            fileURL: URL(fileURLWithPath: "/d/Photos from 2014/IMG-20160508-WA0001.jpg"),
            metadataDate: exif, sidecarDate: Date(), sidecarSource: .sidecar
        )
        XCTAssertEqual(resolved.date, exif)
        XCTAssertEqual(resolved.source, .fileMetadata)
    }

    func testSidecarUsedWhenTheFileHasNoDate() {
        let taken = Date(timeIntervalSince1970: 1_390_612_940)
        let resolved = CaptureDateResolver.resolve(
            fileURL: URL(fileURLWithPath: "/d/Photos from 2014/pic2-edited.jpg"),
            metadataDate: nil, sidecarDate: taken, sidecarSource: .originalSidecar
        )
        XCTAssertEqual(resolved.date, taken)
        XCTAssertEqual(resolved.source, .originalSidecar)
    }

    func testFilenameBeatsFolderYear() {
        let resolved = CaptureDateResolver.resolve(
            fileURL: URL(fileURLWithPath: "/d/Photos from 2014/IMG-20160508-WA0004.jpg"),
            metadataDate: nil, sidecarDate: nil, sidecarSource: nil
        )
        XCTAssertEqual(resolved.source, .filename)
        XCTAssertEqual(year(resolved.date), 2016, "The name is more specific than the folder")
    }

    func testFolderYearIsTheLastResortAndMarkedInexact() {
        let resolved = CaptureDateResolver.resolve(
            fileURL: URL(fileURLWithPath: "/d/Photos from 2014/6734fbf7-7aa0.jpg"),
            metadataDate: nil, sidecarDate: nil, sidecarSource: nil
        )
        XCTAssertEqual(resolved.source, .folderYear)
        XCTAssertEqual(year(resolved.date), 2014)
        XCTAssertFalse(resolved.source.isExact, "A folder year must not pass as a real capture time")
    }

    func testNothingKnownYieldsNoDate() {
        let resolved = CaptureDateResolver.resolve(
            fileURL: URL(fileURLWithPath: "/d/Album/photo.jpg"),
            metadataDate: nil, sidecarDate: nil, sidecarSource: nil
        )
        XCTAssertNil(resolved.date)
        XCTAssertEqual(resolved.source, .unknown)
    }

    // MARK: - Filename dates

    func testRecognisesCommonFilenameDateFormats() {
        func parsed(_ name: String) -> Int? { year(CaptureDateResolver.dateFromFilename(name)) }
        XCTAssertEqual(parsed("IMG-20160508-WA0004.jpg"), 2016)
        XCTAssertEqual(parsed("PXL_20210101_120000.jpg"), 2021)
        XCTAssertEqual(parsed("New Doc 2017-12-08_2.jpg"), 2017)
        XCTAssertEqual(parsed("2019-07-04 12.00.00.jpg"), 2019)
        XCTAssertEqual(parsed("VID_20200229_101112.mp4"), 2020, "Leap day must parse")
    }

    func testRejectsNumbersThatAreNotDates() {
        XCTAssertNil(CaptureDateResolver.dateFromFilename("1795690_725110877499486_823938910_n.jpg"))
        XCTAssertNil(CaptureDateResolver.dateFromFilename("IMG_1588.HEIC"))
        XCTAssertNil(CaptureDateResolver.dateFromFilename("20161345.jpg"), "Month 13 is not a date")
        XCTAssertNil(CaptureDateResolver.dateFromFilename("pic2.jpg"))
    }

    // MARK: - Edited derivatives

    func testFindsTheOriginalBehindAnEditedName() {
        let edited = URL(fileURLWithPath: "/d/Photos from 2014/pic2-edited.jpg")
        let original = CaptureDateResolver.originalURL(forEdited: edited)
        XCTAssertEqual(original?.lastPathComponent, "pic2.jpg")
        XCTAssertEqual(original?.deletingLastPathComponent(), edited.deletingLastPathComponent())
    }

    func testRecognisesLocalisedEditedSuffixes() {
        XCTAssertTrue(CaptureDateResolver.isEditedDerivative("urlaub-bearbeitet.jpg"))
        XCTAssertTrue(CaptureDateResolver.isEditedDerivative("photo-edited.JPG"))
        XCTAssertFalse(CaptureDateResolver.isEditedDerivative("unedited-scan.jpg"))
        XCTAssertFalse(CaptureDateResolver.isEditedDerivative("pic2.jpg"))
    }

    func testNonEditedFileHasNoOriginal() {
        XCTAssertNil(CaptureDateResolver.originalURL(forEdited: URL(fileURLWithPath: "/d/pic2.jpg")))
    }

    // MARK: - Folder year

    func testYearFolderParsing() {
        XCTAssertEqual(
            year(CaptureDateResolver.yearFromFolder(URL(fileURLWithPath: "/d/Google Photos/Photos from 2014/x.jpg"))),
            2014
        )
        XCTAssertNil(CaptureDateResolver.yearFromFolder(URL(fileURLWithPath: "/d/Google Photos/Bhutan trip/x.jpg")))
        XCTAssertNil(CaptureDateResolver.yearFromFolder(URL(fileURLWithPath: "/d/Photos from nineteen/x.jpg")))
    }

    /// Google translates the year-folder name. Keying on the English wording
    /// gave every non-English export no year at all.
    func testYearFolderWorksInOtherLanguages() {
        func parsed(_ path: String) -> Int? {
            year(CaptureDateResolver.yearFromFolder(URL(fileURLWithPath: path)))
        }
        XCTAssertEqual(parsed("/d/Google Fotos/Fotos de 2016/x.jpg"), 2016)
        XCTAssertEqual(parsed("/d/Google Fotos/Fotos von 2018/x.jpg"), 2018)
        XCTAssertEqual(parsed("/d/Google Photos/Photos de 2019/x.jpg"), 2019)
        XCTAssertEqual(parsed("/d/Google/2020年の写真/x.jpg"), 2020)
        // An album that names its year is just as informative.
        XCTAssertEqual(parsed("/d/Google Photos/Spring 2016/x.jpg"), 2016)
    }

    /// The export folder carries the *export* timestamp. Reading it as a
    /// capture year would date the entire archive to the day it was exported.
    func testExportPartFolderIsNotMistakenForACaptureYear() {
        XCTAssertNil(
            CaptureDateResolver.yearFromFolder(
                URL(fileURLWithPath: "/d/takeout-20260710T081521Z-2-001/x.jpg")
            ),
            "20260710 is when the export ran, not when the photo was taken"
        )
    }

    func testDigitsInsideLongerNumbersAreNotYears() {
        XCTAssertNil(CaptureDateResolver.standaloneYear(in: "1795690_725110877499486_823938910_n"))
        XCTAssertNil(CaptureDateResolver.standaloneYear(in: "12016"), "Not a standalone year")
        XCTAssertNil(CaptureDateResolver.standaloneYear(in: "20164"), "Not a standalone year")
        XCTAssertEqual(CaptureDateResolver.standaloneYear(in: "Trip 2016 highlights"), 2016)
        XCTAssertNil(CaptureDateResolver.standaloneYear(in: "Album 1850"), "Before photography here")
    }

    /// Only the folders near the file are consulted, so the user's own filing
    /// above the export ("Backup 2019", say) does not date its contents.
    func testSearchDoesNotReachDistantAncestorFolders() {
        XCTAssertNil(
            CaptureDateResolver.yearFromFolder(
                URL(fileURLWithPath: "/d/Backup 1999/Google Photos/Bhutan trip/album/x.jpg")
            )
        )
    }
}
