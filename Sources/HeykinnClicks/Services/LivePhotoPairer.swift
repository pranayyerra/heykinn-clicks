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

    /// How firmly a pair was established.
    enum Confidence: String {
        /// Both files carry the same Apple content identifier.
        case identifiersMatch
        /// The movie is provably the motion half of *a* Live Photo (it carries
        /// a QuickTime content identifier) and shares the still's filename
        /// stem, but the still's identifier is gone. Google re-encodes some
        /// stills and drops Apple's maker note, so the link survives on one
        /// side only; without it these pairs would never reunite.
        case motionIdentifierAndName
        /// The movie is a Live Photo's motion half, but not of *this* still.
        /// Another still may yet match it, so it stays open for future checks.
        case stillDoesNotMatch
        /// The movie carries no Live Photo identifier (or runs far too long),
        /// so on the evidence available it is an ordinary video and stays in
        /// the Library as one. Recorded so later runs skip it — but the record
        /// is cleared if a newly imported still shares its name, because
        /// Google sometimes strips this metadata and the pairing may yet be
        /// provable.
        case notLivePhotoMotion

        var isPair: Bool { self == .identifiersMatch || self == .motionIdentifierAndName }
        /// Settled for good — safe to record so the file is never re-tested.
        var isConclusiveRejection: Bool { self == .notLivePhotoMotion }
    }

    /// Confirms a candidate really is a Live Photo pair. A shared filename is
    /// never sufficient on its own — at minimum the movie must prove it is a
    /// Live Photo's motion half by carrying a content identifier.
    static func confirm(_ candidate: Candidate) async -> Confidence {
        if let duration = await motionDuration(candidate.motionURL), duration > maxMotionDuration {
            return .notLivePhotoMotion
        }
        let motionID = await motionContentIdentifier(candidate.motionURL)
        guard let motionID, !motionID.isEmpty else { return .notLivePhotoMotion }

        if let stillID = stillContentIdentifier(candidate.stillURL), !stillID.isEmpty {
            return stillID == motionID ? .identifiersMatch : .stillDoesNotMatch
        }
        // Still has no identifier to compare; the movie's presence plus the
        // matching stem is the best evidence available.
        return .motionIdentifierAndName
    }

    /// Most still/movie combinations tried per filename stem. Guards against a
    /// stem shared by many unrelated files (phones reuse names like IMG_1588)
    /// turning into a combinatorial scan.
    static let maxCombinationsPerStem = 9

    /// Pairs a still with a movie sharing its filename stem. Deliberately not
    /// restricted to one folder: Google splits an export by size, so a Live
    /// Photo's two halves routinely land in different parts, and duplicate
    /// collapsing can keep the still from one album and the movie from
    /// another. Matching across folders is safe only because a pair is
    /// confirmed by Apple's content identifier, never by name alone.
    ///
    /// Same-folder pairs are offered first, since they are the likeliest match
    /// and confirming one lets the rest of that stem be skipped.
    static func candidates(
        from assets: [Asset],
        sourceURL: (Asset) -> URL?
    ) -> [Candidate] {
        var stillsByStem: [String: [(Asset, URL)]] = [:]
        var motionsByStem: [String: [(Asset, URL)]] = [:]

        for asset in assets where asset.livePhotoStillID == nil && asset.livePhotoCheckedAt == nil {
            guard let url = sourceURL(asset) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            switch asset.kind {
            case .photo, .livePhoto: stillsByStem[stem, default: []].append((asset, url))
            case .video: motionsByStem[stem, default: []].append((asset, url))
            case .unknown: break
            }
        }

        var result: [Candidate] = []
        for (stem, motions) in motionsByStem {
            guard let stills = stillsByStem[stem] else { continue }
            var pairs: [(still: (Asset, URL), motion: (Asset, URL))] = []
            for motion in motions {
                for still in stills { pairs.append((still, motion)) }
            }
            // Same directory first, then everything else.
            pairs.sort { lhs, rhs in
                let lhsSame = lhs.still.1.deletingLastPathComponent() == lhs.motion.1.deletingLastPathComponent()
                let rhsSame = rhs.still.1.deletingLastPathComponent() == rhs.motion.1.deletingLastPathComponent()
                return lhsSame && !rhsSame
            }
            for pair in pairs.prefix(maxCombinationsPerStem) {
                result.append(Candidate(
                    stillAssetID: pair.still.0.id,
                    motionAssetID: pair.motion.0.id,
                    stillURL: pair.still.1,
                    motionURL: pair.motion.1
                ))
            }
        }
        return result
    }
}
