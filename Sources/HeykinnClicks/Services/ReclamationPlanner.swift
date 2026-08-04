import Foundation

/// What reclamation would release today — and removes nothing.
///
/// Reclamation is the end of the vision: proven local redundancy releases the
/// cloud copy, automatically, with no prompt and no per-asset confirmation.
/// The preconditions *are* the safety mechanism, which is exactly why they are
/// worth computing before anything can act on them: a list nobody can execute
/// still answers "how close is this archive to owning itself outright?", and
/// it makes the preconditions visible rather than a paragraph in a document.
///
/// Every condition here is one the app can prove from what it has already
/// checked. The last condition in the spec — the provider confirming the same
/// content immediately before release — is deliberately not one of them: it is
/// a check made at the moment of release, and asserting it in advance would be
/// claiming a verification nobody has run.
enum ReclamationPlanner {

    /// Why an asset with a cloud copy is not releasable yet. Each is a
    /// precondition that has not been met, never a fault.
    enum Blocker: String, CaseIterable, Hashable {
        case notEnoughCopies
        case notReadBack
        case targetsDisagree

        var displayName: String {
            switch self {
            case .notEnoughCopies: return "not enough local copies yet"
            case .notReadBack: return "a copy has never been read back"
            case .targetsDisagree: return "the targets do not agree on what they hold"
            }
        }
    }

    struct Plan: Equatable {
        /// Assets whose cloud copy could be released on the evidence the app
        /// already holds.
        var releasableAssetIDs: Set<UUID> = []
        /// What those copies weigh in the cloud.
        var releasableBytes: Int64 = 0
        /// Assets with a verified cloud copy that is not yet releasable,
        /// counted by what is holding them up.
        var blocked: [Blocker: Int] = [:]
        /// Assets with a verified cloud copy at all. Zero means there is
        /// nothing to reclaim — a different statement from "nothing qualifies".
        var withVerifiedCloudCopy = 0

        var isEmpty: Bool { withVerifiedCloudCopy == 0 }
    }

    /// `agreeingTargetIDs` are the targets whose Merkle trees agree with every
    /// other target's. A copy on a target that disagrees with its peers is a
    /// copy the archive has an open question about, and an open question is not
    /// the ground to delete a cloud original from.
    static func plan(
        assets: [Asset],
        replicasByAssetID: [UUID: [TargetReplicaState]],
        registeredTargetIDs: Set<UUID>,
        agreeingTargetIDs: Set<UUID>,
        policy: LocalRedundancyPolicy
    ) -> Plan {
        var plan = Plan()

        for asset in assets {
            // Reclamation releases the cloud copy of content that lives
            // locally. Nothing is released for an asset whose home is the
            // cloud — that is a migration, and a different decision.
            guard asset.residency == .local else { continue }
            guard asset.presence.appleCloud, asset.cloudPresenceEvidence == .verified else { continue }
            plan.withVerifiedCloudCopy += 1

            let present = (replicasByAssetID[asset.id] ?? []).filter {
                $0.state == .present && registeredTargetIDs.contains($0.targetID)
            }

            guard policy.isSatisfied(byCopies: present.count) else {
                plan.blocked[.notEnoughCopies, default: 0] += 1
                continue
            }
            // "Verified" here means what it means everywhere else in this app:
            // somebody read the bytes back and they matched.
            guard present.allSatisfy({ $0.lastVerifiedAt != nil }) else {
                plan.blocked[.notReadBack, default: 0] += 1
                continue
            }
            guard present.allSatisfy({ agreeingTargetIDs.contains($0.targetID) }) else {
                plan.blocked[.targetsDisagree, default: 0] += 1
                continue
            }

            plan.releasableAssetIDs.insert(asset.id)
            plan.releasableBytes += asset.fileSize
        }
        return plan
    }
}
