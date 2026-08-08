import XCTest
@testable import HeykinnClicks

/// Reading the metadata out of exports already imported.
///
/// The sidecar names here are the ones Google actually writes, including the
/// truncated `supplemental-metadata` that its own filename cap produces.
final class MetadataBackfillTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    // MARK: - Which photo a sidecar is about

    func testEveryNamingGoogleUsesResolvesToTheSameMediaFile() {
        let expected = "IMG_0001.jpg"
        for sidecar in [
            "IMG_0001.jpg.json",
            "IMG_0001.jpg.supplemental-metadata.json",
            "IMG_0001.jpg.supplemen.json",
            "IMG_0001.jpg.suppl.json",
        ] {
            XCTAssertEqual(
                TakeoutMetadataBackfill.mediaFilename(forSidecar: sidecar), expected,
                "\(sidecar) is about \(expected)"
            )
        }
    }

    /// The older form names the photo without its extension, which the caller
    /// resolves by lookup rather than by guessing a suffix.
    func testTheExtensionlessFormReturnsTheStem() {
        XCTAssertEqual(TakeoutMetadataBackfill.mediaFilename(forSidecar: "IMG_0001.json"), "IMG_0001")
    }

    /// Videos too — the rule is "the last part that looks like media", not a
    /// list of image extensions.
    func testItWorksForVideos() {
        XCTAssertEqual(
            TakeoutMetadataBackfill.mediaFilename(forSidecar: "GH011471.MP4.supplemental-metadata.json"),
            "GH011471.MP4"
        )
    }

    // MARK: - Reading a part

    /// Builds a zip shaped like a Takeout part and reads it the way the
    /// backfill does — no extraction of the media, only the JSON.
    func testCaptureReadsSidecarsWithoutTouchingTheMedia() throws {
        let staging = try makeDirectory()
        let tree = staging.appendingPathComponent("Takeout/Google Photos/Photos from 2017", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let album = staging.appendingPathComponent("Takeout/Google Photos/Kodaikanal", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)

        try Data(repeating: 0xAB, count: 4096).write(to: tree.appendingPathComponent("IMG_0001.jpg"))
        try #"{"title":"IMG_0001.jpg","imageViews":"10"}"#
            .write(to: tree.appendingPathComponent("IMG_0001.jpg.supplemental-metadata.json"),
                   atomically: true, encoding: .utf8)
        try #"{"title":"Kodaikanal","access":"protected"}"#
            .write(to: album.appendingPathComponent("metadata.json"),
                   atomically: true, encoding: .utf8)

        let zipURL = try makeDirectory().appendingPathComponent("part.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", zipURL.path, "Takeout"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let assetID = UUID()
        let result = TakeoutMetadataBackfill.capture(
            fromZip: zipURL,
            sourceID: UUID(),
            assetIDsByFilename: ["IMG_0001.jpg": assetID],
            workspace: try makeDirectory()
        )

        XCTAssertEqual(result.captured.count, 2, "both JSON files, and neither photo")

        let photo = try XCTUnwrap(result.captured.first { $0.scope == .asset })
        XCTAssertEqual(photo.assetID, assetID, "matched by name where the name is unique")
        XCTAssertTrue(photo.payload.contains("imageViews"), "kept whole")
        XCTAssertTrue(
            photo.originPath.contains("Photos from 2017"),
            "with the folder it sat in"
        )

        let albumRecord = try XCTUnwrap(result.captured.first { $0.scope == .album })
        XCTAssertNil(albumRecord.assetID, "an album is about a set, not a photo")
        XCTAssertTrue(albumRecord.originPath.contains("Kodaikanal"), "which the path is the only record of")
    }

    /// A re-run does the work it has not done. A 127 GB read is not something
    /// anybody can promise not to interrupt.
    func testARerunSkipsWhatIsAlreadyHeld() throws {
        let staging = try makeDirectory()
        let tree = staging.appendingPathComponent("Takeout/Google Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        for index in 0..<3 {
            try #"{"title":"x"}"#.write(
                to: tree.appendingPathComponent("IMG_000\(index).jpg.json"),
                atomically: true, encoding: .utf8
            )
        }
        let zipURL = try makeDirectory().appendingPathComponent("part.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", zipURL.path, "Takeout"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()

        let first = TakeoutMetadataBackfill.capture(
            fromZip: zipURL, sourceID: UUID(), workspace: try makeDirectory()
        )
        XCTAssertEqual(first.captured.count, 3)

        let held = Set(first.captured.map(\.originPath))
        let second = TakeoutMetadataBackfill.capture(
            fromZip: zipURL, sourceID: UUID(), skipping: held, workspace: try makeDirectory()
        )
        XCTAssertTrue(second.captured.isEmpty, "nothing read twice")
        XCTAssertEqual(second.alreadyHeld, 3)
    }

    /// A name shared by several photos is left unlinked rather than guessed at.
    /// The payload and its path are still kept, which is what lets a later
    /// pass settle it on better evidence than a filename.
    func testAnAmbiguousNameIsCapturedButNotLinked() throws {
        let staging = try makeDirectory()
        let tree = staging.appendingPathComponent("Takeout/Google Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try #"{"title":"IMG_0001.jpg"}"#.write(
            to: tree.appendingPathComponent("IMG_0001.jpg.json"),
            atomically: true, encoding: .utf8
        )
        let zipURL = try makeDirectory().appendingPathComponent("part.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", zipURL.path, "Takeout"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()

        // The caller passes only unambiguous names, so this one is absent.
        let result = TakeoutMetadataBackfill.capture(
            fromZip: zipURL, sourceID: UUID(),
            assetIDsByFilename: [:], workspace: try makeDirectory()
        )

        XCTAssertEqual(result.captured.count, 1, "kept regardless")
        XCTAssertNil(result.captured[0].assetID, "but not attached to a guess")
        XCTAssertFalse(result.captured[0].payload.isEmpty)
    }
}
