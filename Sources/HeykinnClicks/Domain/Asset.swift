import Foundation

enum AssetKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case photo
    case video
    case livePhoto
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .photo: return "Photo"
        case .video: return "Video"
        case .livePhoto: return "Live Photo"
        case .unknown: return "Unknown"
        }
    }
}

enum ImportOrigin: String, Codable, CaseIterable, Identifiable, Hashable {
    case localFolder
    case whatsapp
    case appleExport
    case googleTakeout
    case messagingApp
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localFolder: return "Local folder"
        case .whatsapp: return "WhatsApp"
        case .appleExport: return "Apple export"
        case .googleTakeout: return "Google Takeout"
        case .messagingApp: return "Messaging app"
        case .unknown: return "Unknown"
        }
    }
}

/// The catalog's canonical record for one logical photo/video.
/// Identity is independent of any physical file location: staging copies,
/// drive replicas, and cloud copies are all references to this one asset.
struct Asset: Identifiable, Hashable {
    let id: UUID
    var kind: AssetKind
    var originalFilename: String
    var importOrigin: ImportOrigin
    var captureDate: Date?
    var importDate: Date
    var updatedDate: Date
    var fileSize: Int64
    var pixelWidth: Int?
    var pixelHeight: Int?
    var contentHash: String
    var residency: ResidencyDomain
    var residencySource: ResidencyAssignmentSource
    var presence: DomainPresence
    /// Path relative to the Mac staging root, when a staged copy exists.
    var stagingRelativePath: String?
    var importBatchID: UUID?
    var exifSummary: [String: String]
    /// Provenance of any cloud-domain presence on this asset. The app never
    /// writes `.verified` without a connected account confirming it.
    var cloudPresenceEvidence: CloudPresenceEvidence = .none
    var cloudPresenceCheckedAt: Date?
    /// Set on the *motion* half of a Live Photo, pointing at the still it
    /// belongs to. Apple exports a Live Photo as a still plus a short movie
    /// linked by a content identifier; Google Takeout preserves both files but
    /// not the relationship, so they arrive as two unrelated assets.
    ///
    /// The pair is linked rather than merged so each file keeps its own
    /// residency, replica state and protection tracking — the motion file is
    /// real content that still has to live somewhere and be checked.
    var livePhotoStillID: UUID?

    /// Set once a video has been shown to carry no Live Photo identifier, so
    /// later pairing runs skip it instead of re-reading it off the drive.
    var livePhotoCheckedAt: Date?

    /// True for the movie half, which the Library folds into its still.
    var isLivePhotoMotion: Bool { livePhotoStillID != nil }

    var fileExtension: String {
        (originalFilename as NSString).pathExtension.lowercased()
    }
}

enum AssetVariantKind: String, Codable, CaseIterable, Hashable {
    case original
    case livePhotoVideo
    case sidecar
    case thumbnail
}

/// A physical file variant belonging to an asset (e.g. the paired video of a
/// Live Photo, or an XMP sidecar). V1 creates only `.original`.
struct AssetVariant: Identifiable, Hashable {
    let id: UUID
    var assetID: UUID
    var kind: AssetVariantKind
    var relativePath: String
    var fileSize: Int64
}
