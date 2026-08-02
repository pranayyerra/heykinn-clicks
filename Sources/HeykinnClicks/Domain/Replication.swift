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

struct DriveReplicaState: Hashable, Identifiable {
    var assetID: UUID
    var driveID: UUID
    var state: ReplicaFileState
    /// Path relative to the drive's replica root.
    var relativePath: String?
    var lastVerifiedAt: Date?

    var id: String { "\(assetID.uuidString)/\(driveID.uuidString)" }
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
}

/// Live progress of an in-flight sync against one drive. Present only while a
/// sync runs; cancellation or disconnect simply leaves unprocessed tasks
/// queued, so resuming is just running sync again.
struct SyncProgress: Equatable {
    var driveID: UUID
    var driveName: String
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
    var driveID: UUID
    var action: ReplicationAction
    var state: ReplicationTaskState
    var queuedAt: Date
    var completedAt: Date?
    var errorMessage: String?
}
