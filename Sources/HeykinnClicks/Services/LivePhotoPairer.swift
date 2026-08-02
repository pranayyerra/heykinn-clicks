import Foundation
import ImageIO
import AVFoundation

/// Reunites the two halves of a Live Photo.
///
/// Apple stores a Live Photo as a still plus a short movie, linked by a
/// content identifier that both files carry. Google Takeout exports both files
/// but drops the relationship, so they arrive as two unrelated assets — the
/// motion halves then clutter the Library as standalone videos.
///
/// Filename stems are only a hint (two unrelated files can share one). The
/// content identifier is the authority, so a pair is confirmed by reading it
/// from both files and requiring a match.
enum LivePhotoPairer {

    /// Longest a Live Photo's movie can plausibly be; used only to skip
    /// obviously-unrelated videos cheaply before reading metadata.
    static let maxMotionDuration: TimeInterval = 6

    struct Candidate {
        var stillAssetID: UUID
        var motionAssetID: UUID
        var stillURL: URL
        var motionURL: URL
    }

    /// Apple's Live Photo identifier from a still's maker note.
    static func stillContentIdentifier(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let apple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        // Key "17" is the Live Photo pairing UUID.
        return apple["17"] as? String
    }

    /// The same identifier as QuickTime metadata on the movie.
    static func motionContentIdentifier(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.identifier == .quickTimeMetadataContentIdentifier {
            if let value = try? await item.load(.stringValue) { return value }
        }
        return nil
    }

    static func motionDuration(_ url: URL) async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else {
            return nil
        }
        return duration.seconds
    }

    /// Confirms a candidate really is a Live Photo pair. Requires both files
    /// to carry the same Apple content identifier; a shared filename alone is
    /// never enough to merge two assets.
    static func confirm(_ candidate: Candidate) async -> Bool {
        if let duration = await motionDuration(candidate.motionURL), duration > maxMotionDuration {
            return false
        }
        guard let stillID = stillContentIdentifier(candidate.stillURL), !stillID.isEmpty else {
            return false
        }
        return await motionContentIdentifier(candidate.motionURL) == stillID
    }

    /// Pairs a still with a movie of the same stem in the same folder. Only
    /// photo/video pairs qualify, and neither may already be paired.
    static func candidates(
        from assets: [Asset],
        sourceURL: (Asset) -> URL?
    ) -> [Candidate] {
        var stillsByKey: [String: Asset] = [:]
        var motionsByKey: [String: Asset] = [:]

        for asset in assets where asset.livePhotoStillID == nil {
            guard let url = sourceURL(asset) else { continue }
            // Same folder + same stem: Apple's export convention.
            let key = url.deletingPathExtension().path
            switch asset.kind {
            case .photo, .livePhoto:
                if stillsByKey[key] == nil { stillsByKey[key] = asset }
            case .video:
                if motionsByKey[key] == nil { motionsByKey[key] = asset }
            case .unknown:
                break
            }
        }

        return motionsByKey.compactMap { key, motion -> Candidate? in
            guard let still = stillsByKey[key],
                  let stillURL = sourceURL(still),
                  let motionURL = sourceURL(motion)
            else { return nil }
            return Candidate(
                stillAssetID: still.id,
                motionAssetID: motion.id,
                stillURL: stillURL,
                motionURL: motionURL
            )
        }
    }
}
