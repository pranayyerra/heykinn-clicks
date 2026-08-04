import Foundation

/// State of one asset's replica on one managed drive.
enum ReplicaFileState: String, Codable, Hashable {
    /// Expected on this drive, not yet copied.
    case pending
    /// Copy in progress (or interrupted; safe to retry).
    case copying
    /// File exists and last verification matched the catalog hash.
    case present
    /// Catalog thinks it should be present but a sync failed or was interrupted.
    case stale
    /// Expected removed (e.g. after migration cleanup) or confirmed absent.
    case missing
    /// File exists but its content no longer matches the catalog hash.
    case drift

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .copying: return "Copying"
        case .present: return "Present"
        case .stale: return "Stale"
        case .missing: return "Missing"
        case .drift: return "Changed on disk"
        }
    }
}

struct TargetReplicaState: Hashable, Identifiable {
    var assetID: UUID
    var targetID: UUID
    var state: ReplicaFileState
    /// Path relative to the drive's replica root.
    var relativePath: String?
    var lastVerifiedAt: Date?

    /// What the file looked like the last time the app knew it was right: the
    /// size and modification date observed when the copy was written or last
    /// verified.
    ///
    /// The third leg of the aimed-reads triad. Comparing Merkle roots cannot
    /// see an in-place edit — no hash the catalog holds changed, so the trees
    /// go on agreeing — and stat-ing anchors only sees whole directories move.
    /// A file edited under an intact path is invisible to both, and would wait
    /// for the rot patrol to reach it. Keeping the observed stat here is what
    /// lets a connect aim the expensive read at the few files that moved.
    ///
    /// Nil until the first observation. A baseline nobody recorded is not
    /// evidence of anything, so the first pass establishes it and claims
    /// nothing.
    var observedSize: Int64?
    var observedModifiedAt: Date?

    var id: String { "\(assetID.uuidString)/\(targetID.uuidString)" }
}

/// What one drive actually holds, tallied in a single pass over replica state.
/// The UI draws a drive's share of the archive on every redraw; recomputing it
/// by filtering the whole replica table each time does not survive a catalog
/// with hundreds of thousands of rows.
struct DriveContentBreakdown: Equatable {
    var present = 0
    /// Expected on the drive but not there yet: queued, mid-copy, or interrupted.
    var pending = 0
    var drift = 0
    var missing = 0
    var presentBytes: Int64 = 0

    /// The same tallies counted in photos rather than files: a Live Photo is
    /// one photo, though it is a still *and* a movie on disk. Files are what
    /// gets copied and verified; photos are what the user thinks they own, and
    /// showing one number where the other is meant reads as a contradiction.
    var presentPhotos = 0
    var pendingPhotos = 0
    var driftPhotos = 0

    /// Everything the target is meant to end up holding.
    var expected: Int { present + pending + drift }
    var expectedPhotos: Int { presentPhotos + pendingPhotos + driftPhotos }
}

enum ReplicationAction: String, Codable, Hashable {
    case copy
    case verify
    case remove
}

enum ReplicationTaskState: String, Codable, Hashable {
    case queued
    case inProgress
    case completed
    case failed
}

/// How many managed targets should hold each Local asset.
///
/// Two is the shape the product is designed around — one drive can fail, and a
/// second is what makes that survivable — but nothing in the model requires
/// that number, so it lives here rather than as a literal scattered through
/// protection, planning and registration.
struct LocalRedundancyPolicy: Equatable {
    var desiredCopies: Int

    static let `default` = LocalRedundancyPolicy(desiredCopies: 2)

    /// Human phrasing for the policy, used wherever it is explained.
    var description: String {
        desiredCopies == 2 ? "two copies" : "\(desiredCopies) copies"
    }

    func isSatisfied(byCopies count: Int) -> Bool { count >= desiredCopies }
}

/// What a drive's pending backlog actually consists of. A bare task count
/// hides the difference between "copy 3 files" and "re-read 120 GB", which are
/// wildly different asks of the user's time and drive.
struct BacklogSummary: Equatable {
    var copyCount: Int = 0
    var verifyCount: Int = 0
    var removeCount: Int = 0
    /// Bytes that must be read or written to drain the backlog.
    var estimatedBytes: Int64 = 0

    var total: Int { copyCount + verifyCount + removeCount }
    var isEmpty: Bool { total == 0 }

    /// Human description of the work, heaviest action first.
    var description: String {
        var parts: [String] = []
        if copyCount > 0 { parts.append("\(copyCount) to copy") }
        if verifyCount > 0 { parts.append("\(verifyCount) to check") }
        if removeCount > 0 { parts.append("\(removeCount) to remove") }
        guard !parts.isEmpty else { return "nothing pending" }
        let work = parts.joined(separator: ", ")
        guard estimatedBytes > 0 else { return work }
        return "\(work) (~\(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)))"
    }
}

/// Limits how much verification a single sweep queues. Re-hashing a whole
/// archive is legitimate work but must never be dumped on the drive as one
/// enormous burst; sweeps take the stalest replicas first and stop at a budget.
struct VerificationBudget {
    var maxFiles: Int
    var maxBytes: Int64

    static let sweep = VerificationBudget(maxFiles: 500, maxBytes: 4 * 1024 * 1024 * 1024)
    static let unlimited = VerificationBudget(maxFiles: .max, maxBytes: .max)
    /// The background patrol's ration. Small enough that a run finishes in
    /// seconds and is never what the user notices about the app — the point is
    /// that reading eventually happens, not that it happens quickly.
    static let patrol = VerificationBudget(maxFiles: 40, maxBytes: 256 * 1024 * 1024)
}

/// Live progress of an in-flight sync against one drive. Present only while a
/// sync runs; cancellation or disconnect simply leaves unprocessed tasks
/// queued, so resuming is just running sync again.
struct SyncProgress: Equatable {
    var targetID: UUID
    var targetName: String
    var totalTasks: Int
    var completedTasks: Int
    var failedTasks: Int
    var currentItem: String?

    var fractionComplete: Double {
        totalTasks == 0 ? 0 : Double(completedTasks + failedTasks) / Double(totalTasks)
    }
}

/// One unit of the per-drive replication backlog. Queued whenever the drive is
/// absent or busy; processed serially when the drive is connected.
struct ReplicationTask: Identifiable, Hashable {
    let id: UUID
    var assetID: UUID
    var targetID: UUID
    var action: ReplicationAction
    var state: ReplicationTaskState
    var queuedAt: Date
    var completedAt: Date?
    var errorMessage: String?
}
