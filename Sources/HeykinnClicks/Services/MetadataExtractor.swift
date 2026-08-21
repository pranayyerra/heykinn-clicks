import Foundation
import ImageIO

enum MetadataExtractor {
    static func extract(from url: URL) -> ExtractedMetadata {
        let kind = kind(forFileExtension: url.pathExtension)
        var metadata = ExtractedMetadata(kind: kind, captureDate: nil, pixelWidth: nil, pixelHeight: nil, exifSummary: [:])
        guard kind == .photo || kind == .livePhoto,
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

    /// EXIF carries no zone, so the string is read in the device's current
    /// one. That is what import did, and re-reading it later on a device that has
    /// since moved zones lands hours away — which is why provenance recovery
    /// treats a failure to reproduce a stored date as a refusal, not a repair.

    /// Kept so the pipeline's call sites do not all change in the same commit
    /// as the seam; `MediaKinds` is where these live now.
    static func kind(forFileExtension ext: String) -> AssetKind {
        MediaKinds.kind(forFileExtension: ext)
    }

    static func parseExifDate(_ string: String) -> Date? {
        MediaKinds.parseExifDate(string)
    }

    /// The protocol's instance requirement, satisfied by the static one.
    func extract(from url: URL) -> ExtractedMetadata { Self.extract(from: url) }
}
