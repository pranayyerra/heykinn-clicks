import Foundation

enum AuditCategory: String, Codable, CaseIterable, Hashable {
    case importEvent = "import"
    case replication
    case drive
    case migration
    case policy
    case violation
    case system

    var displayName: String {
        switch self {
        case .importEvent: return "Import"
        case .replication: return "Replication"
        case .drive: return "Drive"
        case .migration: return "Migration"
        case .policy: return "Policy"
        case .violation: return "Violation"
        case .system: return "System"
        }
    }
}

struct AuditEvent: Identifiable, Hashable {
    let id: UUID
    var at: Date
    var category: AuditCategory
    var message: String
    var assetID: UUID?
    var targetID: UUID?
}
