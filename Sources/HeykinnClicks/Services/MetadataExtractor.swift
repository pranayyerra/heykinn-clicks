import Foundation
import ImageIO

struct ExtractedMetadata {
    var kind: AssetKind
    var captureDate: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var exifSummary: [String: String]
}

/// EXIF/metadata extraction via ImageIO. Encapsulated so an external tool
/// (e.g. exiftool) could replace the implementation later without touching
/// the import pipeline.
enum MetadataExtractor {
    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "webp", "dng", "raw", "cr2", "nef", "arw", "bmp",
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "mts",
    ]

    static func kind(forFileExtension ext: String) -> AssetKind {
        let lowered = ext.lowercased()
        if photoExtensions.contains(lowered) { return .photo }
        if videoExtensions.contains(lowered) { return .video }
        return .unknown
    }

    static func extract(from url: URL) -> ExtractedMetadata {
        let kind = kind(forFileExtension: url.pathExtension)
        var metadata = ExtractedMetadata(kind: kind, captureDate: nil, pixelWidth: nil, pixelHeight: nil, exifSummary: [:])
        guard kind == .photo,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return metadata
        }

        metadata.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        metadata.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                metadata.captureDate = parseExifDate(dateString)
                metadata.exifSummary["DateTimeOriginal"] = dateString
            }
            if let lens = exif[kCGImagePropertyExifLensModel] as? String {
                metadata.exifSummary["LensModel"] = lens
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] as? String {
                metadata.exifSummary["Make"] = make
            }
            if let model = tiff[kCGImagePropertyTIFFModel] as? String {
                metadata.exifSummary["Model"] = model
            }
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            metadata.exifSummary["GPS"] = String(format: "%.5f, %.5f", latitude, longitude)
        }
        return metadata
    }

    private static func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: string)
    }
}
