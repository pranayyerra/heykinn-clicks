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
}
