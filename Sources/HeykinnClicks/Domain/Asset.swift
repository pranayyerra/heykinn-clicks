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
    /// The provider library's own identifier, for assets indexed from one.
    /// Present means "this row describes a photo the app does not hold" —
    /// re-indexing updates it instead of creating a second row.
    var providerLocalID: String?
    /// The same photograph in another domain, when the bytes differ because
    /// the provider re-encoded it. A link, deliberately not a presence claim:
    /// it says "these are the same picture", never "this content is there".
    var counterpartAssetID: UUID?
    /// Set on the *motion* half of a Live Photo, pointing at the still it
    /// belongs to. Apple exports a Live Photo as a still plus a short movie
    /// linked by a content identifier; Google Takeout preserves both files but
    /// not the relationship, so they arrive as two unrelated assets.
    ///
    /// The pair is linked rather than merged so each file keeps its own
    /// residency, replica state and protection tracking — the motion file is
    /// real content that still has to live somewhere and be checked.
    var livePhotoStillID: UUID?

    /// How `captureDate` was established. A folder-derived year must never
    /// read as though it came from the camera.
    var captureDateSource: CaptureDateSource = .unknown
    /// Set on an edited derivative, pointing at the original it came from.
    /// Google exports both `pic2.jpg` and `pic2-edited.jpg`; without the link
    /// they are unrelated entries, and the edit — which carries no metadata of
    /// its own — drifts to the wrong end of the timeline.
    var editedFromAssetID: UUID?

    /// Set once a video has been shown to carry no Live Photo identifier, so
    /// later pairing runs skip it instead of re-reading it off the drive.
    var livePhotoCheckedAt: Date?

    /// True for the movie half, which the Library folds into its still.
    var isLivePhotoMotion: Bool { livePhotoStillID != nil }

    /// Scopes the placeholder written into `contentHash` for a row that exists
    /// only because a provider listed it. Deliberately not hash-shaped, so it
    /// can never collide with a real digest or group as a duplicate.
    static let providerIndexHashPrefix = "apple-library:"

    /// The archive can *see* this photograph but does not *hold* it: it came
    /// from a provider's index, and nothing has ever read its bytes.
    ///
    /// This is the distinction that decides what still needs bringing in, and
    /// it is drawn on the content hash rather than on the absence of a staged
    /// copy — a Takeout asset living only on a drive has no staging path either,
    /// and the archive holds that one.
    var isIndexedOnly: Bool { contentHash.hasPrefix(Asset.providerIndexHashPrefix) }

    var fileExtension: String {
        (originalFilename as NSString).pathExtension.lowercased()
    }
}

/// A capture date that falls after the day this archive imported the file.
/// Impossible as a fact about a photograph — nothing is photographed after it
/// has been copied off a disk — so the date is wrong even though the
/// provenance behind it is honest. In practice it means a camera whose clock
/// was never set: every file that camera wrote carries the same fiction.
///
/// Derived, never stored. It compares two fields the catalog already holds, so
/// it costs no column, no migration and no backfill, and it cannot go stale
/// against the row it describes. Nothing here rewrites the date or weakens the
/// recorded source: the app says what the file said and, separately, that the
/// file is wrong. A corrected date would be a guess wearing the camera's
/// authority.
struct ImpossibleCaptureDate: Hashable {
    /// What the file, or its sidecar, claims.
    var claimed: Date
    /// When this archive first read the file — the upper bound on any real
    /// capture time.
    var imported: Date
    /// Where the wrong date came from, kept rather than downgraded: the fault
    /// is the camera's, and the provenance is the only clue to the cause.
    var source: CaptureDateSource

    /// How far past the import the claim sits.
    var ahead: TimeInterval { claimed.timeIntervalSince(imported) }

    /// A photo can legitimately be imported moments after it was taken, and
    /// device clocks disagree by seconds to minutes. Only a claim that no
    /// ordinary skew explains is worth putting in front of the user — a whole
    /// day is far past any drift, and far short of the years an unset camera
    /// clock produces.
    static let clockSkewTolerance: TimeInterval = 24 * 60 * 60
}

extension Asset {
    /// Non-nil when this asset dates itself after its own import. See
    /// `ImpossibleCaptureDate`.
    var impossibleCaptureDate: ImpossibleCaptureDate? {
        guard let captureDate,
              captureDate.timeIntervalSince(importDate) > ImpossibleCaptureDate.clockSkewTolerance
        else { return nil }
        return ImpossibleCaptureDate(
            claimed: captureDate, imported: importDate, source: captureDateSource
        )
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
