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

    // MARK: - Recovering provenance for a date already held

    /// The 16,284-row case: the date was read from EXIF at import, but the
    /// provenance column did not exist yet, so the row says `unknown` and the
    /// UI demotes a to-the-second timestamp to "(approximate)". The raw string
    /// is still in the catalog, so no drive is needed to settle it.
    func testProvenanceIsRecoveredFromTheStoredExifString() {
        let text = "2016:05:08 14:22:07"
        let stored = try? XCTUnwrap(MetadataExtractor.parseExifDate(text))
        let source = CaptureDateResolver.provenance(
            forStoredDate: try! XCTUnwrap(stored), exifSummary: ["DateTimeOriginal": text]
        )
        XCTAssertEqual(source, .fileMetadata)
        XCTAssertTrue(try! XCTUnwrap(source).isExact, "This is what stops the UI saying 'approximate'")
    }

    /// EXIF carries no timezone, so a Mac that has changed zones since the
    /// import reparses the same string to a different instant. On the real
    /// catalog that is 2,091 rows, all at half-hour offsets. Asserting
    /// `fileMetadata` there would attach the camera's authority to a date the
    /// camera did not give — invariant 2 — so it must decline.
    func testAStringThatNoLongerReproducesTheStoredDateIsDeclined() {
        let text = "2016:05:08 14:22:07"
        let stored = try! XCTUnwrap(MetadataExtractor.parseExifDate(text))
        XCTAssertNil(CaptureDateResolver.provenance(
            forStoredDate: stored.addingTimeInterval(5.5 * 3600),
            exifSummary: ["DateTimeOriginal": text]
        ), "A 5.5-hour offset is a timezone, not a camera")
        XCTAssertNil(CaptureDateResolver.provenance(
            forStoredDate: stored.addingTimeInterval(-3600),
            exifSummary: ["DateTimeOriginal": text]
        ))
    }

    func testNoExifStringYieldsNoProvenance() {
        let stored = Date(timeIntervalSince1970: 1_462_710_127)
        XCTAssertNil(CaptureDateResolver.provenance(forStoredDate: stored, exifSummary: [:]))
        XCTAssertNil(CaptureDateResolver.provenance(
            forStoredDate: stored, exifSummary: ["Make": "GoPro", "Model": "HERO9 Black"]
        ), "Other EXIF keys say nothing about when")
        XCTAssertNil(CaptureDateResolver.provenance(
            forStoredDate: stored, exifSummary: ["DateTimeOriginal": "not a date"]
        ))
    }

    /// Sub-second, because EXIF is written to the second and the catalog
    /// stores a floating-point interval.
    func testReproducesToleratesOnlySubSecondDifference() {
        let base = Date(timeIntervalSince1970: 1_462_710_127)
        XCTAssertTrue(CaptureDateResolver.reproduces(base, base.addingTimeInterval(0.4)))
        XCTAssertFalse(CaptureDateResolver.reproduces(base, base.addingTimeInterval(2)))
    }

    // MARK: - Dates that cannot be true

    private func makeAsset(
        _ name: String = "GOPR1411.JPG",
        captured: Date?,
        imported: Date,
        source: CaptureDateSource = .fileMetadata
    ) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: captured, importDate: imported, updatedDate: imported, fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString,
            residency: .local, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:],
            captureDateSource: source
        )
    }

    /// The GoPro case: a camera whose clock was never set stamps every file
    /// with a date years ahead of the import that read it.
    func testCaptureDateAfterImportIsFlagged() {
        let imported = Date(timeIntervalSince1970: 1_785_660_745)  // 2026-08
        let asset = makeAsset(captured: Date(timeIntervalSince1970: 1_808_882_116), imported: imported)  // 2027-04
        let impossible = try? XCTUnwrap(asset.impossibleCaptureDate)
        XCTAssertNotNil(impossible)
        XCTAssertEqual(impossible?.imported, imported)
        XCTAssertGreaterThan(impossible?.ahead ?? 0, 0)
    }

    /// The provenance is honest and must survive: the file really did say
    /// this. Flagging the value may never quietly downgrade the source.
    func testFlaggingPreservesTheRecordedSourceAndDate() {
        let captured = Date(timeIntervalSince1970: 1_808_882_116)
        var asset = makeAsset(captured: captured, imported: Date(timeIntervalSince1970: 1_785_660_745))
        let impossible = asset.impossibleCaptureDate
        XCTAssertEqual(impossible?.claimed, captured)
        XCTAssertEqual(impossible?.source, .fileMetadata, "The camera is at fault, not the reading of it")
        XCTAssertEqual(asset.captureDate, captured, "Detection is derived; it never rewrites the row")
        XCTAssertEqual(asset.captureDateSource, .fileMetadata)

        // And it holds for a date the app already calls approximate: a wrong
        // year from a folder is still a date that cannot be in the future.
        asset.captureDateSource = .folderYear
        XCTAssertEqual(asset.impossibleCaptureDate?.source, .folderYear)
    }

    func testOrdinaryPastDatesAreNotFlagged() {
        let imported = Date(timeIntervalSince1970: 1_785_660_745)
        XCTAssertNil(makeAsset(captured: Date(timeIntervalSince1970: 1_390_612_940), imported: imported)
            .impossibleCaptureDate)
        XCTAssertNil(makeAsset(captured: nil, imported: imported).impossibleCaptureDate,
                     "No date is not a wrong date")
    }

    /// A photo imported moments after it was taken, off a device whose clock
    /// runs a little fast, is not evidence of anything. Only a gap no ordinary
    /// skew explains is worth telling the user about.
    func testClockSkewWithinADayIsNotReportedAsImpossible() {
        let imported = Date(timeIntervalSince1970: 1_785_660_745)
        XCTAssertNil(makeAsset(captured: imported.addingTimeInterval(90), imported: imported)
            .impossibleCaptureDate)
        XCTAssertNil(makeAsset(captured: imported.addingTimeInterval(23 * 3600), imported: imported)
            .impossibleCaptureDate)
        XCTAssertNotNil(makeAsset(captured: imported.addingTimeInterval(25 * 3600), imported: imported)
            .impossibleCaptureDate)
    }

    /// The bound is the import date, not "now": a catalog opened years later
    /// must reach the same verdict about the same row.
    func testTheBoundIsTheImportDateNotTheCurrentClock() {
        let longAgo = Date(timeIntervalSince1970: 1_000_000_000)  // 2001
        let asset = makeAsset(captured: longAgo.addingTimeInterval(86_400 * 400), imported: longAgo)
        XCTAssertNotNil(asset.impossibleCaptureDate,
                        "Both dates are in the past, and the claim is still impossible")
    }

    /// The wording is the whole feature — the finding is useless if it does not
    /// let the user check it, and saying what is wrong without saying that the
    /// app left it alone reads as a defect the app failed to handle.
    func testTheExplanationNamesBothDatesAndTheRestraint() throws {
        let asset = makeAsset(
            captured: Date(timeIntervalSince1970: 1_808_882_116),
            imported: Date(timeIntervalSince1970: 1_785_660_745)
        )
        let impossible = try XCTUnwrap(asset.impossibleCaptureDate)

        // Both dates appear as the app formats them elsewhere, so the claim is
        // checkable against the rows directly above it.
        XCTAssertTrue(impossible.finding.contains(Formatters.dateTime.string(from: impossible.claimed)))
        XCTAssertTrue(impossible.finding.contains(Formatters.dateTime.string(from: impossible.imported)))
        XCTAssertTrue(impossible.finding.contains(Formatters.span(impossible.ahead)),
                      "The gap is stated, not left for the user to subtract")
        XCTAssertFalse(Formatters.span(impossible.ahead).isEmpty)

        // Invariant 2 in the copy itself: the app must say it changed nothing.
        XCTAssertTrue(impossible.restraint.contains("left exactly as it was found"))

        print("headline:  \(ImpossibleCaptureDate.headline)")
        print("finding:   \(impossible.finding)")
        print("restraint: \(impossible.restraint)")
    }
}
