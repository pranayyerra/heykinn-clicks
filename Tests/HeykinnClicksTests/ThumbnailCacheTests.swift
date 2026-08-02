import XCTest
import AppKit
@testable import HeykinnClicks

final class ThumbnailCacheTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-thumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A large source image so downsampling is observable.
    private func writeImage(to url: URL, size: Int = 1200) throws {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fillEllipse(in: CGRect(x: 100, y: 100, width: size - 200, height: size - 200))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    func testThumbnailIsDownsampledAndWrittenToDisk() throws {
        let cache = ThumbnailCache(directory: try makeTempDirectory())
        let source = try makeTempDirectory().appendingPathComponent("big.png")
        try writeImage(to: source, size: 1600)
        let assetID = UUID()

        let image = try XCTUnwrap(cache.thumbnail(for: assetID, sourceURL: source))
        XCTAssertLessThanOrEqual(
            max(image.size.width, image.size.height), CGFloat(ThumbnailCache.maxPixelSize),
            "Cached thumbnails must be downsampled, not full-size"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cache.diskURL(for: assetID).path),
            "The disk tier is what keeps the Library browsable offline"
        )
        XCTAssertNotNil(cache.cachedInMemory(assetID))
    }

    func testDiskTierServesThumbnailsWhenTheSourceIsGone() throws {
        let directory = try makeTempDirectory()
        let source = try makeTempDirectory().appendingPathComponent("photo.png")
        try writeImage(to: source)
        let assetID = UUID()

        // Populate, then simulate the drive being unplugged and the app restarting.
        _ = ThumbnailCache(directory: directory).thumbnail(for: assetID, sourceURL: source)
        try FileManager.default.removeItem(at: source)

        let fresh = ThumbnailCache(directory: directory)
        XCTAssertNil(fresh.cachedInMemory(assetID), "Memory tier must start empty after a restart")
        XCTAssertNotNil(
            fresh.thumbnail(for: assetID, sourceURL: nil),
            "Disk tier must serve the thumbnail with no source available"
        )
    }

    func testMissingSourceAndNoCacheYieldsNil() throws {
        let cache = ThumbnailCache(directory: try makeTempDirectory())
        XCTAssertNil(cache.thumbnail(for: UUID(), sourceURL: nil))
        XCTAssertNil(cache.thumbnail(
            for: UUID(),
            sourceURL: URL(fileURLWithPath: "/nonexistent/nope.jpg")
        ))
    }

    func testPruneEvictsLeastRecentlyUsedDownToBudget() throws {
        let directory = try makeTempDirectory()
        let cache = ThumbnailCache(directory: directory)
        let source = try makeTempDirectory().appendingPathComponent("photo.png")
        try writeImage(to: source)

        var ids: [UUID] = []
        for index in 0..<8 {
            let id = UUID()
            ids.append(id)
            _ = cache.thumbnail(for: id, sourceURL: source)
            // Stagger use times so eviction order is deterministic.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(index))],
                ofItemAtPath: cache.diskURL(for: id).path
            )
        }
        let before = cache.diskUsageBytes
        XCTAssertGreaterThan(before, 0)

        let removed = cache.pruneDisk(budget: before / 2)
        XCTAssertGreaterThan(removed, 0)
        XCTAssertLessThanOrEqual(cache.diskUsageBytes, before / 2)
        // The oldest went first; the newest survived.
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.diskURL(for: ids[0]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.diskURL(for: ids[7]).path))
    }

    func testPruneIsANoOpWhenUnderBudget() throws {
        let cache = ThumbnailCache(directory: try makeTempDirectory())
        let source = try makeTempDirectory().appendingPathComponent("photo.png")
        try writeImage(to: source)
        _ = cache.thumbnail(for: UUID(), sourceURL: source)
        XCTAssertEqual(cache.pruneDisk(budget: 100 * 1024 * 1024), 0)
    }
}
