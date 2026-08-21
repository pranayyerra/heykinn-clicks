import Foundation

/// **Moved out of `Services/CaptureDateResolver.swift`, which needs
/// AVFoundation.** The catalog stores this value and reads it back, so
/// `Persistence` named a type declared in a file that only compiles on Apple
/// platforms — and `Persistence` is otherwise Foundation and SQLite alone,
/// which is the whole of what a status reader on another platform needs. One
/// enum was the difference between that being true and being nearly true.
///
/// Nothing here needs a framework; it was only there because the first thing to
/// produce one of these was the resolver.

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
