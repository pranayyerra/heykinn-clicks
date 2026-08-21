import Foundation
import AppKit
import ImageIO
import AVFoundation

/// Two-level thumbnail cache: an in-memory tier for scrolling, and a small
/// on-disk tier so the Library stays browsable when the targets are unplugged.
///
/// Without it, every cell scrolling back into view re-read and re-decoded the
/// original from the external drive. Thumbnails are stored downsampled — not
/// for decode speed (a full decode of these files is already fast) but because
/// caching full-size images would cost ~48 MB of RAM each.
///
/// The disk tier lives in `~/Library/Caches`, which is the correct home for
/// data the app can regenerate: it is excluded from backups and macOS may
/// purge it under disk pressure, in which case thumbnails are simply rebuilt.
final class ThumbnailCache {

    /// Longest edge of a stored thumbnail. Covers the Library grid at retina
    /// density; detail views trade a little sharpness for working offline.
    static let maxPixelSize = 320
    /// Disk tier ceiling. Roughly 22 KB per thumbnail, so this holds a library
    /// of ~25k assets; beyond it the least recently used are evicted.
    static let diskBudgetBytes: Int64 = 600 * 1024 * 1024

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL) {
        self.directory = directory
        // Cost is the decoded byte estimate, so the limit means what it says.
        memory.totalCostLimit = 128 * 1024 * 1024
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func defaultCache() -> ThumbnailCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return ThumbnailCache(directory: caches.appendingPathComponent("HeykinnClicks/Thumbnails", isDirectory: true))
    }

    // MARK: - Lookup

    /// Memory-tier hit, cheap enough to call from a view body.
    func cachedInMemory(_ assetID: UUID) -> NSImage? {
        memory.object(forKey: assetID.uuidString as NSString)
    }

    /// Memory → disk → generate from `sourceURL`. Returns nil only when there
    /// is no cached copy and no reachable source (e.g. drive unplugged and
    /// never viewed before).
    func thumbnail(for assetID: UUID, sourceURL: URL?) async -> NSImage? {
        if let hit = cachedInMemory(assetID) { return hit }

        let fileURL = diskURL(for: assetID)
        if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
            store(image, for: assetID)
            // Touch it so eviction treats this as recently used.
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return image
        }

        guard let sourceURL, let image = await Self.makeThumbnail(from: sourceURL) else { return nil }
        store(image, for: assetID)
        writeToDisk(image, for: assetID)
        return image
    }

    /// Memory-tier insert. Internal so provider-served thumbnails — which have
    /// no source file on disk to regenerate from — can be kept for scrolling.
    func store(_ image: NSImage, for assetID: UUID) {
        let cost = Int(image.size.width * image.size.height * 4)
        memory.setObject(image, forKey: assetID.uuidString as NSString, cost: max(cost, 1))
    }

    // MARK: - Disk tier

    /// Sharded by ID prefix so no single directory holds tens of thousands of
    /// entries, mirroring the staging layout.
    func diskURL(for assetID: UUID) -> URL {
        let id = assetID.uuidString
        return directory
            .appendingPathComponent(String(id.prefix(2)).lowercased(), isDirectory: true)
            .appendingPathComponent("\(id).jpg")
    }

    private func writeToDisk(_ image: NSImage, for assetID: UUID) {
        guard let data = Self.jpegData(from: image) else { return }
        let url = diskURL(for: assetID)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    var diskUsageBytes: Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Evicts least recently used thumbnails until the tier fits its budget.
    /// Safe to run any time: everything here can be regenerated.
    @discardableResult
    func pruneDisk(budget: Int64? = nil) -> Int {
        let limit = budget ?? Self.diskBudgetBytes
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var entries: [ThumbnailEviction.Entry] = []
        for case let url as URL in enumerator where url.pathExtension == "jpg" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            entries.append(ThumbnailEviction.Entry(
                url: url,
                size: Int64(values?.fileSize ?? 0),
                lastUsed: values?.contentModificationDate ?? .distantPast
            ))
        }

        // What to drop is a decision; removing the files is this layer's job.
        let doomed = ThumbnailEviction.choose(from: entries, budget: limit)
        for entry in doomed { try? fileManager.removeItem(at: entry.url) }
        return doomed.count
    }

    // MARK: - Generation

    /// Builds a thumbnail for either a still or a video.
    static func makeThumbnail(from url: URL) async -> NSImage? {
        if MetadataExtractor.kind(forFileExtension: url.pathExtension) == .video {
            return await makeVideoThumbnail(from: url)
        }
        return makeImageThumbnail(from: url)
    }

    /// Grabs a representative frame. The very first frame is often black or a
    /// fade-in, so it seeks a little way in — clamped for short clips — and
    /// allows generous tolerance so it can settle on a nearby keyframe instead
    /// of decoding forward to an exact time.
    static func makeVideoThumbnail(from url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        var seconds = 1.0
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            seconds = min(1.0, duration.seconds / 2)
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Downsamples with ImageIO, preferring an embedded camera thumbnail when
    /// one exists and decoding the full image only when it does not.
    static func makeImageThumbnail(from url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }
}
