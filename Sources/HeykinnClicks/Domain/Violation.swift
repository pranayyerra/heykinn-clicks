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
    /// A file of a provider export was on a drive and is no longer, while the
    /// drive was still connected to be absent from.
    ///
    /// Its own kind because an export is not a replica. It is the source
    /// document the archive is re-read from, kept deliberately and permanently,
    /// and the photos inside it have no file of their own — so one going is a
    /// loss the replica model cannot describe and, until now, only showed
    /// inside a panel two clicks deep.
    case exportPartMissing

    /// Named for what happened, not for the invariant that caught it. These are
    /// the headings a reader meets first, and four of the five were the model's
    /// vocabulary: "multi-domain coexistence" describes a photo that is in two
    /// places at once, which is a sentence anybody can act on, and the other
    /// one is not.
    var displayName: String {
        switch self {
        case .multiDomainCoexistence: return "In two places at once"
        case .residencyPresenceMismatch: return "Not where it is meant to be"
        case .migrationCleanupPending: return "A move that never finished"
        case .replicaDrift: return "A copy no longer matches"
        case .orphanReplica: return "A drive is holding something it should not"
        case .exportPartMissing: return "Part of an export has gone from a drive"
        }
    }

    /// What the reader should understand about a group of these, once, instead
    /// of inferring it from twenty-five near-identical rows.
    var explanation: String {
        switch self {
        case .multiDomainCoexistence:
            return "Every photo is meant to live in exactly one place. These are in more than one, and no move is running to settle them — so you are likely paying to store the same photo twice."
        case .residencyPresenceMismatch:
            return "These photos are recorded as living somewhere the app cannot find them. Nothing is lost; the record is wrong and needs correcting."
        case .migrationCleanupPending:
            return "A move copied these to their new place but never released the old one, so they are still in both."
        case .replicaDrift:
            return "The file on the drive is no longer what was imported — damage, or something edited it in place. The other drive's copy is the good one to re-copy from."
        case .exportPartMissing:
            return "A file of a Google export was on this drive and is not any more, while the drive was still connected. The exports are kept on purpose — they are what the app re-reads when it learns to read them better, and most of these photos have no file of their own outside them. Plug in a drive that still has it and the app will put it back."
        case .orphanReplica:
            return "A drive is holding copies of photos that are not meant to live on your drives at all. Nothing is at risk; the space is being used for nothing."
        }
    }
}

struct Violation: Identifiable, Hashable {
    var kind: ViolationKind
    var assetID: UUID?
    var targetID: UUID?
    var migrationJobID: UUID?
    var detail: String

    var id: String {
        "\(kind.rawValue)|\(assetID?.uuidString ?? "-")|\(targetID?.uuidString ?? "-")|\(migrationJobID?.uuidString ?? "-")"
    }
}
