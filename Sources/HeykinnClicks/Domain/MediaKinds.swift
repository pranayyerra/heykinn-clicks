import Foundation

/// What reading a media file yields, whatever reads it.
///
/// No Apple type in here on purpose: this crosses the seam between the reader
/// and everything that consumes it, so a reader on another platform fills in
/// the same struct.
struct ExtractedMetadata {
    var kind: AssetKind
    var captureDate: Date?
    var captureDateSource: CaptureDateSource = .unknown
    var pixelWidth: Int?
    var pixelHeight: Int?
    var exifSummary: [String: String]
}

/// Which files this app treats as photographs and which as video, and how an
/// EXIF timestamp is read.
///
/// **Portable because it has to agree, not because it happens to compile.**
/// Both of these decide what ends up in the catalog — the kind is stored on
/// every asset, and the parsed date becomes its capture date — so a reader on
/// another platform that disagreed would produce a different archive from the
/// same files. The extension lists are the app's answer to "is this a
/// photograph", and there is no framework call that would give the same one.
enum MediaKinds {
    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "webp", "dng", "raw", "cr2", "nef", "arw", "bmp",
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "mts",
    ]

    static func kind(forFileExtension ext: String) -> AssetKind {
        let lowered = ext.lowercased()
        if photoExtensions.contains(lowered) { return .photo }
        if videoExtensions.contains(lowered) { return .video }
        return .unknown
    }

    /// EXIF's own format, which is not ISO 8601 and never has been.
    ///
    /// Fixed locale so a device set to a non-Gregorian calendar reads the same
    /// bytes the same way, and the device's own zone because EXIF carries none
    /// — a photograph taken at 14:03 is 14:03 where it was taken.
    static func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: string)
    }
}

/// Reading a media file's own metadata. The half of `MetadataExtractor` that
/// genuinely needs a platform behind it.
protocol MetadataReading {
    func extract(from url: URL) -> ExtractedMetadata
}
