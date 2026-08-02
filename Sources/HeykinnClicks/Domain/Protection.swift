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
    /// Enough copies exist, but at least one has never been read back. Claiming
    /// a copy from a matching archive is evidence it is there, not proof the
    /// bytes are good — and "never checked" is a different statement from a
    /// check that has gone stale.
    case awaitingFirstCheck
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
        case .awaitingFirstCheck: return "Not checked yet"
        case .verificationOverdue: return "Not checked recently"
        case .notApplicable: return "—"
        }
    }

    /// Whether the redundancy policy is met. A copy awaiting its first check
    /// still counts — the copies exist; checking confirms they are undamaged.
    var isHealthy: Bool {
        self == .fullyReplicated || self == .awaitingFirstCheck || self == .notApplicable
    }
}
