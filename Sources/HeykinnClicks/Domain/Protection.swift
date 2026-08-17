import Foundation

/// Local protection state — how safely a Local-resident asset is replicated
/// across the two managed targets. Deliberately richer than "backed up or not",
/// and deliberately separate from residency: residency says *where the asset
/// logically lives*, protection says *how safe the local copies are*.
enum ProtectionState: String, Codable, Hashable {
    /// Exists only in the local staging area; not yet on any managed drive.
    case stagedOnly
    /// On exactly one managed drive; pending on the other.
    case replicatedToOneDrive
    /// Present and verified on both managed targets.
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
        // Accurate whatever the policy asks for: with two targets this is one
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
    var isHealthy: Bool { verdict.isSatisfied || verdict == .notLocal }

    /// What the user is told.
    var verdict: ProtectionVerdict {
        switch self {
        case .fullyReplicated, .awaitingFirstCheck, .verificationOverdue: return .meetsPolicy
        case .replicatedToOneDrive, .stagedOnly: return .shortOfPolicy
        case .driftDetected: return .diverged
        case .notApplicable: return .notLocal
        }
    }

    /// What is known about the copies, as distinct from how many there are.
    var checkStanding: CheckStanding {
        switch self {
        case .awaitingFirstCheck: return .neverRead
        case .verificationOverdue: return .stale
        case .fullyReplicated: return .fresh
        case .driftDetected: return .disagreed
        case .replicatedToOneDrive, .stagedOnly, .notApplicable: return .notApplicable
        }
    }
}

/// The only protection answer the user is given: the asset meets the local
/// redundancy policy, or it does not.
///
/// Copy count and evidence are separate axes, and collapsing them into one
/// ranked list of states is what produced a screen reporting six shades of
/// nearly-safe. A check that has gone stale is not a copy that has gone
/// missing: nothing is *known* to disagree, so the policy is still met and the
/// staleness is reported as what it is — see `CheckStanding`.
enum ProtectionVerdict: Equatable {
    case meetsPolicy
    case shortOfPolicy
    /// A target's content diverged from what the catalog recorded. Copies exist
    /// but one of them is wrong, which is a failure however many there are.
    case diverged
    /// Not Local-resident, so local protection makes no claim. The UI shows no
    /// verdict at all rather than a state meaning "not applicable".
    case notLocal

    var isSatisfied: Bool { self == .meetsPolicy }
}

/// How well established the copies are. Never a verdict on its own.
enum CheckStanding: Equatable {
    case neverRead
    case fresh
    case stale
    case disagreed
    case notApplicable
}
