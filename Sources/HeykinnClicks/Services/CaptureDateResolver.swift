import Foundation
import AVFoundation

/// How a capture date was established. Recorded alongside the date so the app
/// never presents a guess as if it were read from the file — a photo dated
/// "2014" because of its folder is a weaker claim than one dated from EXIF,
/// and the difference should survive into the catalog.
enum CaptureDateSource: String, Codable, CaseIterable, Hashable {
    /// Read from the file: EXIF for stills, container metadata for movies.
    case fileMetadata
    /// Google's companion `.json`, written next to the media.
    case sidecar
    /// The sidecar of the original this file was edited from.
    case originalSidecar
    /// A date encoded in the filename (WhatsApp, Pixel, scanner output).
    case filename
    /// Only the containing folder's year is known — day and time are a guess.
    case folderYear
    /// Nothing was found; the asset has no capture date.
    case unknown

    var displayName: String {
        switch self {
        case .fileMetadata: return "From the file"
        case .sidecar: return "From Google's metadata file"
        case .originalSidecar: return "From the original's metadata file"
        case .filename: return "From the filename"
        case .folderYear: return "Year only, from the folder"
        case .unknown: return "Unknown"
        }
    }

    /// Whether the date is precise enough to be treated as the real capture
    /// moment rather than an approximation.
    var isExact: Bool {
        switch self {
        case .fileMetadata, .sidecar, .originalSidecar: return true
        case .filename: return true
        case .folderYear, .unknown: return false
        }
    }
}

struct ResolvedCaptureDate {
    var date: Date?
    var source: CaptureDateSource

    static let unknown = ResolvedCaptureDate(date: nil, source: .unknown)
}

/// Establishes when a photo or video was taken, trying every source the
/// archive offers in descending order of trust. Used by the import pipeline so
/// every future import benefits, and by the backfill for content already in
/// the catalog.
enum CaptureDateResolver {

    /// Sidecar lookup for a file, including the original's sidecar when this
    /// is an edited derivative. Google names the companion `.json` after the
    /// *original*, so `pic2-edited.jpg` has none of its own.
    static func sidecar(
        for fileURL: URL,
        directoryListings: [String: [String]] = [:]
    ) -> (TakeoutSidecar, CaptureDateSource)? {
        if let own = TakeoutImporter.findSidecar(for: fileURL, directoryListings: directoryListings) {
            return (own, .sidecar)
        }
        guard let originalURL = originalURL(forEdited: fileURL) else { return nil }
        if let inherited = TakeoutImporter.findSidecar(for: originalURL, directoryListings: directoryListings) {
            return (inherited, .originalSidecar)
        }
        return nil
    }

    /// Google marks edits by appending a suffix before the extension:
    /// `pic2-edited.jpg`. Localised exports use other words, so a few common
    /// ones are recognised.
    static let editedSuffixes = ["-edited", "-bearbeitet", "-modifié", "-editado", "-modificato", "-bewerkt"]

    static func originalURL(forEdited url: URL) -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        let lowered = stem.lowercased()
        guard let suffix = editedSuffixes.first(where: { lowered.hasSuffix($0) }) else { return nil }
        let originalStem = String(stem.dropLast(suffix.count))
        guard !originalStem.isEmpty else { return nil }
        return url.deletingLastPathComponent()
            .appendingPathComponent(originalStem)
            .appendingPathExtension(url.pathExtension)
    }

    static func isEditedDerivative(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        return editedSuffixes.contains { stem.hasSuffix($0) }
    }

    // MARK: - Filename and folder

    /// Dates encoded in filenames: `IMG-20160508-WA0004.jpg`,
    /// `PXL_20210101_120000.jpg`, `New Doc 2017-12-08_2.jpg`,
    /// `2019-07-04 12.00.00.jpg`.
    static func dateFromFilename(_ filename: String) -> Date? {
        let digits = Array(filename)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date? {
            guard (1970...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
            var components = DateComponents()
            components.year = year; components.month = month; components.day = day
            components.hour = 12  // Midday: the day is known, the time is not.
            return calendar.date(from: components)
        }

        // Contiguous yyyyMMdd.
        var index = 0
        while index + 8 <= digits.count {
            let window = digits[index..<(index + 8)]
            if window.allSatisfy(\.isNumber) {
                let text = String(window)
                if let year = Int(text.prefix(4)),
                   let month = Int(text.dropFirst(4).prefix(2)),
                   let day = Int(text.suffix(2)),
                   let date = makeDate(year, month, day) {
                    return date
                }
            }
            index += 1
        }

        // Separated yyyy-MM-dd / yyyy_MM_dd / yyyy.MM.dd.
        let separators: Set<Character> = ["-", "_", ".", "/"]
        index = 0
        while index + 10 <= digits.count {
            let window = Array(digits[index..<(index + 10)])
            if window[0...3].allSatisfy(\.isNumber),
               separators.contains(window[4]),
               window[5...6].allSatisfy(\.isNumber),
               separators.contains(window[7]),
               window[8...9].allSatisfy(\.isNumber),
               let year = Int(String(window[0...3])),
               let month = Int(String(window[5...6])),
               let day = Int(String(window[8...9])),
               let date = makeDate(year, month, day) {
                return date
            }
            index += 1
        }
        return nil
    }

    /// Google files un-albumed media under `Photos from YYYY`. That fixes only
    /// the year, so the result is deliberately mid-year and marked as such.
    /// How far up from the file to look for a year. The immediate folder is
    /// the album or year folder; beyond a couple of levels the names belong to
    /// the export or the user's own filing, not to when the photo was taken.
    static let folderYearSearchDepth = 2

    static func yearFromFolder(_ url: URL) -> Date? {
        // Deliberately structural rather than matching "Photos from". Google
        // localises that folder name — "Fotos de 2016", "Photos de 2016",
        // "Fotos von 2016" — so keying on the English wording silently gives
        // non-English exports no year at all. A four-digit year in the folder
        // name is the part that survives translation, and it also picks up
        // album folders that name their year ("Spring 2016").
        var components = url.pathComponents.dropLast()  // drop the filename
        var examined = 0
        while let component = components.last, examined < folderYearSearchDepth {
            components = components.dropLast()
            // An export part folder carries the *export* timestamp, which says
            // nothing about when anything inside it was taken.
            if TakeoutArchive.parseExportComponents(filename: component) == nil,
               let year = standaloneYear(in: component) {
                var parts = DateComponents()
                // Mid-year: the year is known, the day is not, and pretending
                // otherwise would put everything on 1 January.
                parts.year = year; parts.month = 7; parts.day = 1; parts.hour = 12
                return Calendar(identifier: .gregorian).date(from: parts)
            }
            examined += 1
        }
        return nil
    }

    /// A plausible four-digit year that is not part of a longer number, so
    /// identifiers like `1795690_725110877499486` are not read as dates.
    static func standaloneYear(in text: String) -> Int? {
        let characters = Array(text)
        var index = 0
        while index + 4 <= characters.count {
            defer { index += 1 }
            guard characters[index...(index + 3)].allSatisfy(\.isNumber) else { continue }
            if index > 0, characters[index - 1].isNumber { continue }
            if index + 4 < characters.count, characters[index + 4].isNumber { continue }
            guard let year = Int(String(characters[index...(index + 3)])),
                  (1970...2100).contains(year) else { continue }
            return year
        }
        return nil
    }

    // MARK: - Resolution

    /// Full precedence chain. `metadataDate` is whatever the file itself
    /// yielded (EXIF for stills, container metadata for movies).
    static func resolve(
        fileURL: URL,
        metadataDate: Date?,
        sidecarDate: Date?,
        sidecarSource: CaptureDateSource?
    ) -> ResolvedCaptureDate {
        if let metadataDate {
            return ResolvedCaptureDate(date: metadataDate, source: .fileMetadata)
        }
        if let sidecarDate, let sidecarSource {
            return ResolvedCaptureDate(date: sidecarDate, source: sidecarSource)
        }
        if let named = dateFromFilename(fileURL.lastPathComponent) {
            return ResolvedCaptureDate(date: named, source: .filename)
        }
        if let year = yearFromFolder(fileURL) {
            return ResolvedCaptureDate(date: year, source: .folderYear)
        }
        return .unknown
    }

    // MARK: - Recovering provenance for a date already held

    /// Whether re-deriving a capture date landed on the one the catalog holds.
    /// EXIF is written to the second and the catalog stores a real number, so
    /// "the same instant" is a sub-second comparison rather than equality.
    static func reproduces(_ stored: Date, _ derived: Date) -> Bool {
        abs(stored.timeIntervalSince(derived)) < 1
    }
    /// Recovers where a stored capture date came from, using only what the
    /// catalog already holds — no drive need be connected.
    ///
    /// Rows imported before `capture_date_source` existed carry a real date and
    /// no record of its origin, so the app understates itself: an EXIF
    /// timestamp known to the second displays as an approximate year, because
    /// `.unknown` is not exact. The evidence to settle that is already in
    /// `exifSummary`, which kept the raw `DateTimeOriginal` string.
    ///
    /// A source is adopted only when re-deriving it reproduces the stored date.
    /// Anything else stays unknown — a source that cannot be re-derived is a
    /// guess about a guess, and the common cause of the mismatch (an EXIF
    /// string parsed under a different local timezone) is exactly the case
    /// where asserting `fileMetadata` would attach the camera's authority to a
    /// date the camera did not give.
    static func provenance(forStoredDate stored: Date, exifSummary: [String: String]) -> CaptureDateSource? {
        guard let text = exifSummary["DateTimeOriginal"],
              let parsed = MetadataExtractor.parseExifDate(text),
              reproduces(stored, parsed)
        else { return nil }
        return .fileMetadata
    }

    /// Creation date from a movie's container metadata — the video equivalent
    /// of EXIF, and previously not read at all.
    static func movieCreationDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate) {
            if let value = try? await item.load(.dateValue) { return value }
            if let text = try? await item.load(.stringValue) { return parseISOish(text) }
        }
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.commonKey == .commonKeyCreationDate {
            if let value = try? await item.load(.dateValue) { return value }
            if let text = try? await item.load(.stringValue), let parsed = parseISOish(text) { return parsed }
        }
        return nil
    }

    private static func parseISOish(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
