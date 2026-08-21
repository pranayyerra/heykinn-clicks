import AVFoundation
import Foundation
import ImageIO

/// Reading the identifiers a Live Photo's halves carry. The part that genuinely
/// needs the platform; the rules that use them are in `Domain/LivePhotoPairer`.
struct AppleLivePhotoIdentifiers: LivePhotoIdentifiers {

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

    func stillIdentifier(_ url: URL) -> String? { Self.stillContentIdentifier(url) }
    func motionIdentifier(_ url: URL) async -> String? { await Self.motionContentIdentifier(url) }
    func motionDuration(_ url: URL) async -> TimeInterval? { await Self.motionDuration(url) }
}

extension LivePhotoPairer {
    /// Kept so the import pipeline does not change in the same commit as the
    /// seam. Reads through the platform, as it always did.
    static func confirm(_ candidate: Candidate) async -> Confidence {
        await confirm(candidate, using: AppleLivePhotoIdentifiers())
    }

    static func stillContentIdentifier(_ url: URL) -> String? {
        AppleLivePhotoIdentifiers.stillContentIdentifier(url)
    }

    static func motionContentIdentifier(_ url: URL) async -> String? {
        await AppleLivePhotoIdentifiers.motionContentIdentifier(url)
    }
}
