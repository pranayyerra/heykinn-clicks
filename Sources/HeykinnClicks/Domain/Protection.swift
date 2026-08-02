import Foundation

/// Local protection state — how safely a Local-resident asset is replicated
/// across the two managed drives. Deliberately richer than "backed up or not",
/// and deliberately separate from residency: residency says *where the asset
/// logically lives*, protection says *how safe the local copies are*.
enum ProtectionState: String, Codable, Hashable {
    /// Exists only in the Mac staging area; not yet on any managed drive.
    case stagedOnly
    /// On exactly one managed drive; pending on the other.
    case replicatedToOneDrive
    /// Present and verified on both managed drives.
    case fullyReplicated
    /// Actual replica state differs from expected (checksum mismatch, missing file).
    case driftDetected
    /// Replicas exist but integrity verification is stale.
    case verificationOverdue
    /// Asset is not Local-resident, so local protection does not apply.
    case notApplicable

    var displayName: String {
        switch self {
        case .stagedOnly: return "Staged only"
        // Accurate whatever the policy asks for: with two drives this is one
        // of two, with three it may be two of three.
        case .replicatedToOneDrive: return "Partly replicated"
        case .fullyReplicated: return "Fully replicated"
        case .driftDetected: return "Damaged copy found"
        case .verificationOverdue: return "Not checked recently"
        case .notApplicable: return "—"
        }
    }

    var isHealthy: Bool {
        self == .fullyReplicated || self == .notApplicable
    }
}
