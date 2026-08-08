import XCTest
@testable import HeykinnClicks

/// Working out what a captured payload is about, once a filename has run out.
///
/// The shape here is the real one: on a 24,639-photo archive, 9,561 photos had
/// a filename some other photo also used, and `IMG_2905.HEIC` alone belonged to
/// five different pictures.
final class MetadataProjectionTests: XCTestCase {

    private func payload(takenAt seconds: Int, title: String = "IMG_2905.HEIC") -> String {
        """
        {"title":"\(title)","description":"","imageViews":"1",\
        "photoTakenTime":{"timestamp":"\(seconds)","formatted":"—"},\
        "geoData":{"latitude":0.0,"longitude":0.0}}
        """
    }

    /// A unique name still resolves without needing the payload at all.
    func testAUniqueNameResolvesOnItsOwn() {
        let only = UUID()
        let resolved = MetadataProjection.resolveAsset(
            forSidecarNamed: "IMG_0001.jpg.supplemental-metadata.json",
            payload: payload(takenAt: 1_500_986_614),
            candidates: [(only, "IMG_0001.jpg", nil)]
        )
        XCTAssertEqual(resolved, only)
    }

    /// The case capture gives up on: one name, five photos. The capture time
    /// separates them, because it is where each photo's own date came from.
    func testASharedNameIsSettledByWhenThePhotoWasTaken() {
        let wanted = UUID()
        let candidates: [(id: UUID, filename: String, captureDate: Date?)] = [
            (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_400_000_000)),
            (wanted, "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_500_986_614)),
            (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_600_000_000)),
            (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_700_000_000)),
            (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_800_000_000)),
        ]

        let resolved = MetadataProjection.resolveAsset(
            forSidecarNamed: "IMG_2905.HEIC.supplemental-metadata.json",
            payload: payload(takenAt: 1_500_986_614),
            candidates: candidates
        )
        XCTAssertEqual(resolved, wanted)
    }

    /// Two photos with one name and one timestamp are genuinely
    /// indistinguishable from here, so nothing is attached. Picking whichever
    /// sorted first would be a guess wearing the clothes of a fact.
    func testTrulyIdenticalCandidatesAreLeftAlone() {
        let candidates: [(id: UUID, filename: String, captureDate: Date?)] = [
            (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_500_986_614)),
            (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_500_986_614)),
        ]
        XCTAssertNil(MetadataProjection.resolveAsset(
            forSidecarNamed: "IMG_2905.HEIC.json",
            payload: payload(takenAt: 1_500_986_614),
            candidates: candidates
        ))
    }

    /// A payload with no capture time cannot break a tie either.
    func testASharedNameWithNoTimestampStaysUnresolved() {
        let candidates: [(id: UUID, filename: String, captureDate: Date?)] = [
            (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_400_000_000)),
            (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_500_000_000)),
        ]
        XCTAssertNil(MetadataProjection.resolveAsset(
            forSidecarNamed: "IMG_2905.HEIC.json",
            payload: #"{"title":"IMG_2905.HEIC"}"#,
            candidates: candidates
        ))
    }

    /// The case exact matching missed on a real archive: the photo's date came
    /// from its own EXIF, which carries no timezone, while the provider's is
    /// UTC. `IMG_2891.HEIC` was out by exactly the hour and a half its camera
    /// clock was set to.
    func testAClockSetToAnotherTimezoneStillMatches() {
        let wanted = UUID()
        let takenUTC = 1_718_848_087.0
        let resolved = MetadataProjection.resolveAsset(
            forSidecarNamed: "IMG_2891.HEIC.supplemental-metadata.json",
            payload: payload(takenAt: Int(takenUTC), title: "IMG_2891.HEIC"),
            candidates: [
                (wanted, "IMG_2891.HEIC", Date(timeIntervalSince1970: takenUTC + 5_400)),
                (UUID(), "IMG_2891.HEIC", Date(timeIntervalSince1970: 1_592_655_517)),
                (UUID(), "IMG_2891.HEIC", Date(timeIntervalSince1970: 1_645_351_938)),
            ]
        )
        XCTAssertEqual(resolved, wanted, "an hour and a half is a clock, not a different photo")
    }

    /// But a tolerance wide enough for a timezone must not start merging
    /// genuinely different pictures. Two of one name on the same afternoon are
    /// still refused.
    func testTwoPhotosTakenTheSameAfternoonAreStillRefused() {
        let taken = 1_718_848_087.0
        XCTAssertNil(MetadataProjection.resolveAsset(
            forSidecarNamed: "IMG_2891.HEIC.json",
            payload: payload(takenAt: Int(taken), title: "IMG_2891.HEIC"),
            candidates: [
                (UUID(), "IMG_2891.HEIC", Date(timeIntervalSince1970: taken + 600)),
                (UUID(), "IMG_2891.HEIC", Date(timeIntervalSince1970: taken + 1_200)),
            ]
        ))
    }

    /// And a photo a year away is never confused for one a timezone away.
    func testAPhotoAYearApartIsNotAbsorbed() {
        let taken = 1_718_848_087.0
        let wanted = UUID()
        XCTAssertEqual(
            MetadataProjection.resolveAsset(
                forSidecarNamed: "IMG_2891.HEIC.json",
                payload: payload(takenAt: Int(taken), title: "IMG_2891.HEIC"),
                candidates: [
                    (wanted, "IMG_2891.HEIC", Date(timeIntervalSince1970: taken + 5_400)),
                    (UUID(), "IMG_2891.HEIC", Date(timeIntervalSince1970: taken + 31_536_000)),
                ]
            ),
            wanted
        )
    }

    /// Seconds on both sides, so a date that has been through a Double must not
    /// fail on a rounding bit.
    func testASubSecondDifferenceStillMatches() {
        let wanted = UUID()
        let resolved = MetadataProjection.resolveAsset(
            forSidecarNamed: "IMG_2905.HEIC.json",
            payload: payload(takenAt: 1_500_986_614),
            candidates: [
                (UUID(), "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_400_000_000)),
                (wanted, "IMG_2905.HEIC", Date(timeIntervalSince1970: 1_500_986_614.4)),
            ]
        )
        XCTAssertEqual(resolved, wanted)
    }

    /// A description is about a *photograph*, and the archive keeps one row per
    /// photograph however many imports found it. A picture that arrived from
    /// the Photos library and also sits in a Google export must still get its
    /// Google description — the first version scoped candidates to the record's
    /// own source and missed exactly those.
    func testAPhotoThatArrivedFromAnotherSourceIsStillMatched() {
        let fromPhotosLibrary = UUID()
        let resolved = MetadataProjection.resolveAsset(
            forSidecarNamed: "IMG_2958.PNG.supplemental-metadata.json",
            payload: payload(takenAt: 1_500_986_614, title: "IMG_2958.PNG"),
            // The caller now passes every photo of that name, whatever source
            // its asset belongs to.
            candidates: [(fromPhotosLibrary, "IMG_2958.PNG", nil)]
        )
        XCTAssertEqual(resolved, fromPhotosLibrary)
    }

    // MARK: - What a photo is called

    /// Album membership is a directory, never a field — so the path is the only
    /// way back to it, and capturing payloads without it would still have lost
    /// every album.
    func testAlbumMembershipComesFromTheDirectory() {
        let photo = UUID()
        let tags = MetadataProjection.tags(
            forRecordAt: "Takeout/Google Photos/Trip to Kolkata/IMG_1.jpg.json",
            payload: #"{"title":"IMG_1.jpg"}"#,
            assetID: photo,
            albumTitlesByDirectory: ["Takeout/Google Photos/Trip to Kolkata": "Trip to Kolkata"]
        )
        XCTAssertEqual(tags, [AssetTag(assetID: photo, kind: .album, value: "Trip to Kolkata")])
    }

    /// A year bucket is not an album. Which directories are albums comes from
    /// Google having written a `metadata.json` into them, not from the folder
    /// name looking album-ish.
    func testAYearBucketIsNotAnAlbum() {
        let tags = MetadataProjection.tags(
            forRecordAt: "Takeout/Google Photos/Photos from 2017/IMG_1.jpg.json",
            payload: #"{"title":"IMG_1.jpg"}"#,
            assetID: UUID(),
            albumTitlesByDirectory: ["Takeout/Google Photos/Trip to Kolkata": "Trip to Kolkata"]
        )
        XCTAssertTrue(tags.isEmpty)
    }

    /// An album renamed since the export still resolves, because the title
    /// comes from the payload rather than the folder.
    func testTheAlbumTitleComesFromItsPayloadNotItsFolderName() {
        let photo = UUID()
        let tags = MetadataProjection.tags(
            forRecordAt: "Takeout/Google Photos/old-folder-name/IMG_1.jpg.json",
            payload: #"{"title":"IMG_1.jpg"}"#,
            assetID: photo,
            albumTitlesByDirectory: ["Takeout/Google Photos/old-folder-name": "Wednesday night in Northgate"]
        )
        XCTAssertEqual(tags.first?.value, "Wednesday night in Northgate")
    }

    func testPeopleAreReadFromThePayload() {
        let photo = UUID()
        let tags = MetadataProjection.tags(
            forRecordAt: "Takeout/Google Photos/Photos from 2017/IMG_1.jpg.json",
            payload: #"{"title":"IMG_1.jpg","people":[{"name":"Alex Doe"},{"name":"Sam"}]}"#,
            assetID: photo,
            albumTitlesByDirectory: [:]
        )
        XCTAssertEqual(
            Set(tags.map(\.value)), ["Alex Doe", "Sam"],
            "a photo has as many people in it as it has"
        )
        XCTAssertTrue(tags.allSatisfy { $0.kind == .person })
    }

    /// A photo in an album *and* with people in it gets both — which is the
    /// difference between a tag and a storage group: many answers are fine.
    func testAPhotoCanCarryAnAlbumAndPeopleAtOnce() {
        let photo = UUID()
        let tags = MetadataProjection.tags(
            forRecordAt: "Takeout/Google Photos/Trip to Kolkata/IMG_1.jpg.json",
            payload: #"{"title":"IMG_1.jpg","people":[{"name":"Alex Doe"}]}"#,
            assetID: photo,
            albumTitlesByDirectory: ["Takeout/Google Photos/Trip to Kolkata": "Trip to Kolkata"]
        )
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(Set(tags.map(\.kind)), [.album, .person])
    }

    func testAPayloadWithNoPeopleYieldsNone() {
        XCTAssertTrue(MetadataProjection.peopleNames(in: #"{"title":"x"}"#).isEmpty)
        XCTAssertTrue(MetadataProjection.peopleNames(in: #"{"people":[]}"#).isEmpty)
        XCTAssertTrue(MetadataProjection.peopleNames(in: #"{"people":[{"name":"  "}]}"#).isEmpty)
    }

    // MARK: - What a payload is about

    /// An export carries files describing the export rather than anything in
    /// it. Capture cannot tell them from the older `IMG_0001.json` sidecar
    /// form without knowing whether any photo answers to them, so classifying
    /// them is a projection.
    func testExportLevelFilesAreReclassified() {
        for name in ["user-generated-memory-titles.json", "shared_album_comments.json"] {
            XCTAssertEqual(
                MetadataProjection.scope(
                    forSidecarNamed: name, resolvedAsset: nil, currentScope: .asset
                ),
                .export,
                "\(name) describes the download, not a photo"
            )
        }
    }

    /// A sidecar whose photo this archive simply does not hold is still about a
    /// photo — one that is missing. That is a different fact from being about
    /// the export, and conflating them would hide it.
    func testASidecarForAMissingPhotoStaysAnAssetPayload() {
        XCTAssertEqual(
            MetadataProjection.scope(
                forSidecarNamed: "IMG_9999.jpg.supplemental-metadata.json",
                resolvedAsset: nil, currentScope: .asset
            ),
            .asset
        )
    }

    /// An album stays an album whatever else is decided.
    func testAnAlbumIsNeverReclassified() {
        XCTAssertEqual(
            MetadataProjection.scope(
                forSidecarNamed: "metadata.json", resolvedAsset: nil, currentScope: .album
            ),
            .album
        )
    }

    func testTheCaptureTimeIsReadFromTheRawPayload() {
        XCTAssertEqual(
            MetadataProjection.photoTakenTime(in: payload(takenAt: 1_500_986_614)),
            Date(timeIntervalSince1970: 1_500_986_614)
        )
        XCTAssertNil(MetadataProjection.photoTakenTime(in: #"{"title":"x"}"#))
    }
}
