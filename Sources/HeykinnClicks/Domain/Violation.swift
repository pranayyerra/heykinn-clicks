import Foundation

/// A detected breach of the residency/replication invariants. Violations are
/// computed from catalog state (never silently auto-fixed) and surfaced for
/// explicit resolution.
enum ViolationKind: String, Codable, CaseIterable, Hashable {
    /// Asset present in more than one domain with no active migration job.
    case multiDomainCoexistence
    /// Asset's presence does not include its own residency domain.
    case residencyPresenceMismatch
    /// Migration reached clearingSource but source presence remains.
    case migrationCleanupPending
    /// A drive replica's content no longer matches the catalog hash.
    case replicaDrift
    /// A drive holds a replica for an asset that is not Local-resident.
    case orphanReplica

    var displayName: String {
        switch self {
        case .multiDomainCoexistence: return "Multi-domain coexistence"
        case .residencyPresenceMismatch: return "Residency/presence mismatch"
        case .migrationCleanupPending: return "Migration cleanup pending"
        case .replicaDrift: return "Replica drift"
        case .orphanReplica: return "Orphan replica"
        }
    }
}

struct Violation: Identifiable, Hashable {
    var kind: ViolationKind
    var assetID: UUID?
    var driveID: UUID?
    var migrationJobID: UUID?
    var detail: String

    var id: String {
        "\(kind.rawValue)|\(assetID?.uuidString ?? "-")|\(driveID?.uuidString ?? "-")|\(migrationJobID?.uuidString ?? "-")"
    }
}
