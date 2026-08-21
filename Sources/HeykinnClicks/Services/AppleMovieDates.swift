import AVFoundation
import Foundation

/// Reading a movie's own creation date out of its container — the video
/// equivalent of EXIF, and the only part of resolving a capture date that needs
/// a platform behind it.
///
/// **The other two hundred and fifty lines went to `Domain/`.** Which filenames
/// carry a date, how a folder's year is read, which source wins, and how a
/// stored date's provenance is recovered are this app's rules, and they decide
/// what goes in the catalog — so a second platform has to reach the same
/// answers or build a different archive from the same files. Parsing an
/// ISO-ish string went with them: reading a date out of text is not a
/// platform's job either.
protocol MovieDateReading {
    func creationDate(of url: URL) async -> Date?
}

enum AppleMovieDates: MovieDateReading {
    /// Creation date from a movie's container metadata — the video equivalent
    /// of EXIF, and previously not read at all.
    static func movieCreationDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate) {
            if let value = try? await item.load(.dateValue) { return value }
            if let text = try? await item.load(.stringValue) { return CaptureDateResolver.parseISOish(text) }
        }
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.commonKey == .commonKeyCreationDate {
            if let value = try? await item.load(.dateValue) { return value }
            if let text = try? await item.load(.stringValue), let parsed = CaptureDateResolver.parseISOish(text) { return parsed }
        }
        return nil
    }

    func creationDate(of url: URL) async -> Date? { await Self.movieCreationDate(url) }
}

extension CaptureDateResolver {
    /// Kept so the import pipeline's call sites do not move in the same commit
    /// as the seam.
    static func movieCreationDate(_ url: URL) async -> Date? {
        await AppleMovieDates.movieCreationDate(url)
    }
}
