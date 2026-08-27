import XCTest
@testable import HeykinnClicks

/// Reclaiming staging should not leave a tree of empty folders behind.
///
/// The replica side of this was fixed first; staging had the identical bug and
/// the identical shape — two-hex-character buckets, removed one file at a time
/// — so it gets the identical guards and the same tests over them.
final class StagingPruneTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeStaging() throws -> StagingStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return StagingStore(rootURL: url)
    }

    /// Stage one file, remove it, and the bucket goes with it.
    func testRemovingTheLastFileTakesItsBucket() throws {
        let staging = try makeStaging()
        let origin = staging.rootURL.appendingPathComponent("origin.jpg")
        try Data("a photo".utf8).write(to: origin)
        let assetID = UUID()

        let relative = try staging.stage(fileAt: origin, assetID: assetID, fileExtension: "jpg")
        let bucket = staging.url(forRelativePath: relative).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bucket.path))

        try staging.remove(relativePath: relative)

        XCTAssertFalse(staging.exists(relativePath: relative))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bucket.path),
            "the bucket has nothing left in it"
        )
    }

    /// Two assets can share a bucket — the first two hex characters of a UUID
    /// collide often enough at archive scale. Removing one must not take the
    /// folder the other still lives in.
    func testABucketStillHoldingAnotherFileIsKept() throws {
        let staging = try makeStaging()
        let origin = staging.rootURL.appendingPathComponent("origin.jpg")
        try Data("a photo".utf8).write(to: origin)

        // Two IDs sharing a bucket, found rather than assumed: the bucket is
        // the first two characters of the UUID string, so this asks for two
        // that agree there.
        var first = UUID()
        var second = UUID()
        while String(first.uuidString.prefix(2)) != String(second.uuidString.prefix(2)) {
            first = UUID()
            second = UUID()
        }

        let a = try staging.stage(fileAt: origin, assetID: first, fileExtension: "jpg")
        let b = try staging.stage(fileAt: origin, assetID: second, fileExtension: "jpg")
        let bucket = staging.url(forRelativePath: a).deletingLastPathComponent()

        try staging.remove(relativePath: a)

        XCTAssertTrue(staging.exists(relativePath: b), "the other file is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bucket.path))
    }

    /// The staging root itself stays. `stage` recreates buckets on demand but
    /// relies on the root being there.
    func testTheStagingRootIsNeverRemoved() throws {
        let staging = try makeStaging()
        let origin = staging.rootURL.appendingPathComponent("origin.jpg")
        try Data("a photo".utf8).write(to: origin)
        let relative = try staging.stage(fileAt: origin, assetID: UUID(), fileExtension: "jpg")

        try staging.remove(relativePath: relative)
        try FileManager.default.removeItem(at: origin)

        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.rootURL.path))
    }

    /// Removing a path that is already gone is not an error, and takes nothing
    /// with it. Reclamation runs over rows the catalog holds, and a file
    /// somebody deleted by hand must not turn that into a failure.
    func testRemovingSomethingAlreadyGoneIsHarmless() throws {
        let staging = try makeStaging()
        XCTAssertNoThrow(try staging.remove(relativePath: "ab/\(UUID().uuidString).jpg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.rootURL.path))
    }

    func testTheSweepClearsEmptyBucketsAndKeepsOccupiedOnes() throws {
        let staging = try makeStaging()
        for name in ["00", "1a", "ff"] {
            try FileManager.default.createDirectory(
                at: staging.rootURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let occupied = staging.rootURL.appendingPathComponent("7c", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: occupied.appendingPathComponent("keep.jpg"))

        let removed = staging.pruneEmptyBuckets()

        XCTAssertEqual(removed, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.rootURL.path))
    }
}
