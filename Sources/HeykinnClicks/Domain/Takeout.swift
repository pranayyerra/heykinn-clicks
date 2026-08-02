import Foundation

enum TakeoutArchiveKind: String, Codable, Hashable {
    case zip
    case folder

    var displayName: String {
        switch self {
        case .zip: return "Zip archive"
        case .folder: return "Extracted folder"
        }
    }
}

/// A discovered Google Takeout export — a `takeout-*.zip` (or any zip whose
/// listing starts with `Takeout/`) or an already-extracted `Takeout` folder.
/// The archive itself stays where it was found (typically on an external
/// drive); the catalog tracks discovery and import state.
struct TakeoutArchive: Identifiable, Hashable {
    let id: UUID
    var path: String
    var kind: TakeoutArchiveKind
    var sizeBytes: Int64
    /// Managed drive it was found on, if any — lets the UI say "on Drive A
    /// (offline)" when the volume is unmounted.
    var driveID: UUID?
    var discoveredAt: Date
    var importedAt: Date?
    var importBatchID: UUID?
    var importedAssetCount: Int
    var skippedDuplicateCount: Int
    var note: String?
    /// Session token from Google's split-download naming
    /// (`takeout-20260101T000000Z-002.zip` → "20260101T000000Z"). Parts with
    /// the same token form one export set and should be imported together.
    var exportSetID: String?
    /// 1-based part index within the export set (`-002` → 2).
    var partNumber: Int?
    /// Resume checkpoint: how many of this archive's media files (in stable
    /// sorted order) have already been committed, and how many were seen when
    /// that count was recorded. An interrupted import resumes after this
    /// point instead of re-hashing gigabytes it already processed. The count
    /// is only trusted when the file total still matches.
    var importedThroughIndex: Int = 0
    var importedFileTotal: Int = 0
    /// Whole-file SHA-256 of a zip archive, fingerprinted opportunistically.
    /// Two zips with equal hashes are byte-identical, which lets a second
    /// drive's copy be claimed as replicas by mapping transfer instead of
    /// per-entry hashing.
    var contentHash: String? = nil

    var displayName: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
    var isImported: Bool { importedAt != nil }

    /// Parses `takeout-<session>-<part>.zip` (Google's split-download naming)
    /// or the same name without `.zip` — the natural name of a folder someone
    /// extracted from one part. Session tokens may themselves contain dashes
    /// (re-runs look like `20260710T081521Z-2`), so the part is whatever
    /// follows the LAST dash.
    static func parseExportComponents(filename: String) -> (setID: String, part: Int)? {
        let lowered = filename.lowercased()
        guard lowered.hasPrefix("takeout-") else { return nil }
        var stem = filename.dropFirst("takeout-".count)
        if lowered.hasSuffix(".zip") {
            stem = stem.dropLast(".zip".count)
        }
        guard let lastDash = stem.lastIndex(of: "-") else { return nil }
        let session = String(stem[stem.startIndex..<lastDash])
        let partString = String(stem[stem.index(after: lastDash)...])
        guard !session.isEmpty, !partString.isEmpty, let part = Int(partString) else { return nil }
        return (setID: session, part: part)
    }
}

/// A group of split-download parts belonging to one Takeout export session.
struct TakeoutExportSet: Identifiable {
    var setID: String
    var parts: [TakeoutArchive]

    var id: String { setID }

    /// Part numbers expected but not discovered — parts are numbered
    /// contiguously from 1, so gaps below the highest seen part are real holes.
    /// (Parts beyond the highest seen cannot be detected.)
    var missingPartNumbers: [Int] {
        let seen = Set(parts.compactMap(\.partNumber))
        guard let highest = seen.max(), highest > seen.count else { return [] }
        return (1...highest).filter { !seen.contains($0) }
    }

    /// A part can have twin representations: the original zip and a folder the
    /// user extracted from it (same part number). These group them.
    var representativesByPartNumber: [Int: [TakeoutArchive]] {
        Dictionary(grouping: parts.filter { $0.partNumber != nil }) { $0.partNumber! }
    }

    var uniquePartCount: Int { representativesByPartNumber.count }

    /// A part counts as imported when any of its representations was imported —
    /// the zip and its extracted folder hold the same content.
    var importedPartCount: Int {
        representativesByPartNumber.values.filter { reps in reps.contains { $0.isImported } }.count
    }

    /// One representative per not-yet-imported part, in part order, preferring
    /// an extracted folder over its zip twin: importing a folder skips the
    /// (potentially very large) extraction step entirely.
    var unimportedPreferredParts: [TakeoutArchive] {
        representativesByPartNumber
            .filter { _, reps in !reps.contains { $0.isImported } }
            .sorted { $0.key < $1.key }
            .map { _, reps in
                reps.first { $0.kind == .folder } ?? reps[0]
            }
    }
}

/// What the Takeout pipeline is doing right now. Phases are distinct so the
/// UI never reports extraction or import as "scanning".
enum TakeoutPhase: String, Hashable {
    case scanning
    case reconciling
    case extracting
    case importing
    case fingerprinting

    var displayName: String {
        switch self {
        case .scanning: return "Scanning"
        case .reconciling: return "Checking existing copies"
        case .extracting: return "Extracting"
        case .importing: return "Importing"
        case .fingerprinting: return "Fingerprinting"
        }
    }

    var symbolName: String {
        switch self {
        case .scanning: return "magnifyingglass"
        case .reconciling: return "checkmark.shield"
        case .extracting: return "shippingbox"
        case .importing: return "square.and.arrow.down"
        case .fingerprinting: return "number"
        }
    }
}

struct TakeoutActivity: Equatable {
    var phase: TakeoutPhase
    var detail: String
    /// 1-based position within a multi-item phase (e.g. part 3 of 12).
    var stepIndex: Int?
    var stepCount: Int?
    /// Progress *within* the current step (e.g. files processed of this part).
    /// Without this the bar would sit still for the whole of a long step and
    /// then jump, which reads as a stall.
    var itemIndex: Int?
    var itemCount: Int?
    var note: String?

    var stepText: String? {
        guard let stepIndex, let stepCount, stepCount > 1 else { return nil }
        return "\(stepIndex) of \(stepCount)"
    }

    /// Fraction of the current step that is done, if known.
    var stepFraction: Double {
        guard let itemIndex, let itemCount, itemCount > 0 else { return 0 }
        return min(1, max(0, Double(itemIndex) / Double(itemCount)))
    }

    /// Overall progress, blending completed steps with progress inside the
    /// step currently running.
    var fractionComplete: Double? {
        guard let stepIndex, let stepCount, stepCount > 0 else { return nil }
        let completed = Double(stepIndex - 1)
        return min(1, (completed + stepFraction) / Double(stepCount))
    }
}

/// The metadata sidecar Google writes next to each media file in a Takeout
/// export (`IMG_001.jpg.json` / `….supplemental-metadata.json`).
struct TakeoutSidecar: Decodable {
    struct TimeInfo: Decodable {
        let timestamp: String?
    }
    struct GeoData: Decodable {
        let latitude: Double?
        let longitude: Double?
    }

    let title: String?
    let description: String?
    let photoTakenTime: TimeInfo?
    let geoData: GeoData?

    var takenDate: Date? {
        guard let raw = photoTakenTime?.timestamp, let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
