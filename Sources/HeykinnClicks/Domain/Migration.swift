import Foundation

/// Lifecycle of a controlled residency move. Multi-domain presence is legal
/// only while a job is in an active state; `clearingSource` is the phase where
/// the temporary overlap is removed, and `completed` requires the source
/// domain to have been cleared.
enum MigrationState: String, Codable, CaseIterable, Hashable {
    case pending
    case copyingToTarget
    case verifyingTarget
    case clearingSource
    case completed
    case failed

    var displayName: String {
        switch self {
        case .pending: return "Not started"
        case .copyingToTarget: return "Copying across"
        case .verifyingTarget: return "Checking the new copies"
        case .clearingSource: return "Releasing the old place"
        case .completed: return "Done"
        case .failed: return "Stopped"
        }
    }

    /// Active jobs legitimize temporary multi-domain presence for their assets.
    var isActive: Bool {
        switch self {
        case .completed, .failed: return false
        default: return true
        }
    }
}

struct MigrationJob: Identifiable, Hashable {
    let id: UUID
    var assetIDs: [UUID]
    var fromDomain: ResidencyDomain
    var toDomain: ResidencyDomain
    var state: MigrationState
    var createdAt: Date
    var updatedAt: Date
    var note: String?
}
