import XCTest
@testable import HeykinnClicks

final class LivePhotoPairerTests: XCTestCase {

    private func makeAsset(_ name: String, _ kind: AssetKind, paired: UUID? = nil) -> Asset {
        Asset(
            id: UUID(), kind: kind, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString,
            residency: .local, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:],
            livePhotoStillID: paired
        )
    }

    private func urls(_ map: [UUID: String]) -> (Asset) -> URL? {
        { asset in map[asset.id].map { URL(fileURLWithPath: $0) } }
    }

    func testPairsStillWithSameStemMovieInSameFolder() {
        let still = makeAsset("IMG_1.HEIC", .photo)
        let motion = makeAsset("IMG_1.MP4", .video)
        let resolve = urls([still.id: "/d/Photos/IMG_1.HEIC", motion.id: "/d/Photos/IMG_1.MP4"])

        let found = LivePhotoPairer.candidates(from: [still, motion], sourceURL: resolve)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].stillAssetID, still.id)
        XCTAssertEqual(found[0].motionAssetID, motion.id)
    }

    /// Takeout splits by size, so a Live Photo's halves routinely land in
    /// different export parts. Cross-folder pairs must still be offered —
    /// the content identifier, not the folder, decides.
    func testPairsAcrossDifferentFolders() {
        let still = makeAsset("IMG_1.HEIC", .photo)
        let motion = makeAsset("IMG_1.MP4", .video)
        let resolve = urls([still.id: "/d/part-005/IMG_1.HEIC", motion.id: "/d/part-006/IMG_1.MP4"])
        XCTAssertEqual(LivePhotoPairer.candidates(from: [still, motion], sourceURL: resolve).count, 1)
    }

    func testSameFolderPairIsOfferedBeforeCrossFolderOnes() {
        let still = makeAsset("IMG_1.HEIC", .photo)
        let sameFolderMotion = makeAsset("IMG_1.MP4", .video)
        let otherFolderMotion = makeAsset("IMG_1.MOV", .video)
        let resolve = urls([
            still.id: "/d/A/IMG_1.HEIC",
            sameFolderMotion.id: "/d/A/IMG_1.MP4",
            otherFolderMotion.id: "/d/B/IMG_1.MOV",
        ])
        let found = LivePhotoPairer.candidates(
            from: [still, sameFolderMotion, otherFolderMotion], sourceURL: resolve
        )
        XCTAssertEqual(found.first?.motionAssetID, sameFolderMotion.id)
    }

    func testCombinationsPerStemAreCapped() {
        var assets: [Asset] = []
        var map: [UUID: String] = [:]
        for index in 0..<6 {
            let still = makeAsset("IMG_9.HEIC", .photo)
            let motion = makeAsset("IMG_9.MP4", .video)
            assets.append(contentsOf: [still, motion])
            map[still.id] = "/d/\(index)/IMG_9.HEIC"
            map[motion.id] = "/d/\(index)/IMG_9.MP4"
        }
        let found = LivePhotoPairer.candidates(from: assets, sourceURL: urls(map))
        XCTAssertLessThanOrEqual(found.count, LivePhotoPairer.maxCombinationsPerStem)
    }

    func testDoesNotPairTwoStillsOrTwoVideos() {
        let a = makeAsset("IMG_1.HEIC", .photo)
        let b = makeAsset("IMG_1.JPG", .photo)
        let resolve = urls([a.id: "/d/IMG_1.HEIC", b.id: "/d/IMG_1.JPG"])
        XCTAssertTrue(LivePhotoPairer.candidates(from: [a, b], sourceURL: resolve).isEmpty)
    }

    func testAlreadyPairedAssetsAreNotOfferedAgain() {
        let still = makeAsset("IMG_1.HEIC", .livePhoto)
        let motion = makeAsset("IMG_1.MP4", .video, paired: still.id)
        let resolve = urls([still.id: "/d/IMG_1.HEIC", motion.id: "/d/IMG_1.MP4"])
        XCTAssertTrue(
            LivePhotoPairer.candidates(from: [still, motion], sourceURL: resolve).isEmpty,
            "Pairing must be idempotent"
        )
    }

    func testUnreachableFilesYieldNoCandidates() {
        let still = makeAsset("IMG_1.HEIC", .photo)
        let motion = makeAsset("IMG_1.MP4", .video)
        // Drive unplugged: no source URLs resolve.
        XCTAssertTrue(LivePhotoPairer.candidates(from: [still, motion], sourceURL: { _ in nil }).isEmpty)
    }

    /// A same-stem pair with no Apple content identifier must be rejected —
    /// the filename is a hint, the identifier is the proof.
    func testConfirmRejectsFilesWithoutMatchingIdentifiers() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let still = dir.appendingPathComponent("IMG_1.jpg")
        let motion = dir.appendingPathComponent("IMG_1.mp4")
        try Data("not a real jpeg".utf8).write(to: still)
        try Data("not a real movie".utf8).write(to: motion)

        let candidate = LivePhotoPairer.Candidate(
            stillAssetID: UUID(), motionAssetID: UUID(), stillURL: still, motionURL: motion
        )
        let confidence = await LivePhotoPairer.confirm(candidate)
        XCTAssertFalse(confidence.isPair, "Neither file carries a Live Photo identifier")
        XCTAssertEqual(confidence, .notAPair)
    }

    func testMotionHalfIsFlaggedAndHiddenFromTheGrid() {
        let still = makeAsset("IMG_1.HEIC", .livePhoto)
        let motion = makeAsset("IMG_1.MP4", .video, paired: still.id)
        XCTAssertFalse(still.isLivePhotoMotion)
        XCTAssertTrue(motion.isLivePhotoMotion)
        XCTAssertEqual([still, motion].filter { !$0.isLivePhotoMotion }.count, 1)
    }
}
