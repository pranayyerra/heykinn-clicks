import Foundation

/// Every derived fact about the archive, worked out once.
///
/// **Why this exists.** Every number on screen is derived — how many
/// photographs there are, how many are short of their copies, what a drive
/// holds, what is arriving, what is leaving — and it was derived in three
/// places: eagerly in `AppStore.recomputeDerivedState`, again in computed
/// properties on the store, and again in the views. Two of those answering
/// differently is not a slip, it is the default outcome, and it shipped: the
/// headline read *25 photographs are not yet on all the drives they are meant
/// to be on* while the queue printed directly beneath it worked through 294.
/// The verdict counted copies on any drive at all; the planner counted only
/// copies on the drives a group names. See D17 in `ARCHITECTURE-DECISIONS.md`.
///
/// `SafetyAnswer` is the precedent and the warning. It was written because two
/// screens computed the headline separately and drifted, and it settled the
/// wording — but its `Facts` is still gathered by the caller, so the drift moved
/// down a layer into the numbers it is built from. This is the same instinct
/// applied to the derivation rather than to the sentence.
///
/// Two properties carry the weight:
///
/// - **Keyed by photograph, not by row.** A Live Photo is one photograph made of
///   two files. The movie half is not in `photographs`, so counting one as a
///   photograph is unwriteable rather than merely discouraged — which is the
///   mistake that put a numerator of 25 over a total of 23,121 that excluded
///   every one of them.
/// - **Every sense of "held" is a named field.** There were four in the store,
///   each written as an inline filter at the point of use, so which one a screen
///   got was an accident. They are all correct for their own question; naming
///   them makes choosing between them deliberate.
enum ArchiveProjection {

    /// Everything the derivation needs, gathered and normalised once.
    ///
    /// Plain values rather than the store, so the rules can be tested against an
    /// archive built to be awkward — the same reason `LossProjection.Input`
    /// gives, and for the same reason: a real archive is too healthy to prove
    /// any of this.
    struct Input {
        /// Photographs, one row each. A Live Photo's movie half is not here; it
        /// is reached through its still.
        var photographs: [Asset]
        /// Motion halves, keyed by the still they belong to.
        var motionByStill: [UUID: Asset]
        var replicasByAsset: [UUID: [TargetReplicaState]]
        /// Queued removals, as (asset, target) pairs.
        var removalsByAsset: [UUID: Set<UUID>]
        var groupOfAsset: [UUID: UUID]
        /// What each group asks for. Resolved once rather than per asset: the
        /// store reached this through `placementPolicy(forAsset:)`, which
        /// rebuilt a dictionary of every group on each call.
        var policyOfGroup: [UUID: Policy]
        /// Used when an asset belongs to no group at all.
        var fallbackPolicy: Policy

        struct Policy: Equatable {
            var wants: Int
            var named: Set<UUID>

            init(wants: Int, named: Set<UUID>) {
                self.wants = wants
                self.named = named
            }
        }

        init(
            assets: [Asset],
            replicaStates: [TargetReplicaState],
            replicationTasks: [ReplicationTask] = [],
            groupOfAsset: [UUID: UUID] = [:],
            policyOfGroup: [UUID: Policy] = [:],
            fallbackPolicy: Policy = Policy(wants: 2, named: [])
        ) {
            var stills: [Asset] = []
            var motion: [UUID: Asset] = [:]
            stills.reserveCapacity(assets.count)
            for asset in assets {
                if asset.isLivePhotoMotion {
                    // First wins, matching `livePhotoMotionByStillID`: a still
                    // holds one movie, and a second claiming the same still is a
                    // pairing fault, not a second photograph.
                    if let stillID = asset.livePhotoStillID, motion[stillID] == nil {
                        motion[stillID] = asset
                    }
                } else {
                    stills.append(asset)
                }
            }
            photographs = stills
            motionByStill = motion
            replicasByAsset = Dictionary(grouping: replicaStates, by: \.assetID)
            removalsByAsset = replicationTasks.reduce(into: [:]) { out, task in
                guard task.state == .queued, task.action == .remove else { return }
                out[task.assetID, default: []].insert(task.targetID)
            }
            self.groupOfAsset = groupOfAsset
            self.policyOfGroup = policyOfGroup
            self.fallbackPolicy = fallbackPolicy
        }
    }

    /// Where one file's copies are, on every axis the app asks about.
    ///
    /// The four senses of "held" that used to be inline filters are fields here.
    /// They are not interchangeable and the differences are the point:
    ///
    /// - `presentOnNamed` — copies where the group asked for them. The only
    ///   sense that answers "is this kept the way it was asked to be".
    /// - `presentElsewhere` — real files on drives the group does not name.
    ///   Counting these as protection is what had the archive calling a
    ///   photograph safe on the strength of a copy it was about to delete.
    /// - `verifiedOnNamed` — read back and matched. What a removal is allowed to
    ///   be queued against.
    /// - `readable` — present, stale or drifted: there are bytes to read, so the
    ///   patrol has something to check even when it no longer matches.
    struct Placement: Equatable {
        var wants: Int = 0
        var named: Set<UUID> = []
        var presentOnNamed: Set<UUID> = []
        var presentElsewhere: Set<UUID> = []
        var verifiedOnNamed: Set<UUID> = []
        var readable: Set<UUID> = []
        var pending: Set<UUID> = []
        /// Queued to be deleted from here, because the group no longer keeps its
        /// photos on that device. Going away, never arriving.
        var leaving: Set<UUID> = []
        var damaged: Set<UUID> = []
        /// Present copies anywhere, named or not. What "how many places hold
        /// this" means, as distinct from whether they are the right places.
        var presentAnywhere: Set<UUID> { presentOnNamed.union(presentElsewhere) }

        /// This file is short of the copies asked for it, counting only the
        /// drives that were asked. Not the same question as
        /// `Photograph.isShort`, which answers for the whole photograph.
        var isShortOfWanted: Bool { presentOnNamed.count < wants }
    }

    /// One photograph: a still, and the movie half when it has one.
    struct Photograph: Equatable {
        var id: UUID
        var motion: UUID?
        var group: UUID?
        /// The still's own copies.
        var placement: Placement
        /// The movie half's copies, when there is one.
        var motionPlacement: Placement?
        /// The verdict for the photograph, which is the worse of its halves — a
        /// photograph is only as safe as the worse-off file it is made of.
        var verdict: ProtectionState

        /// Short as the headline counts it: the photograph's verdict, so a still
        /// kept twice whose movie is kept once is short.
        var isShort: Bool { verdict.verdict == .shortOfPolicy }
    }

    /// The archive, derived. Everything a screen needs and nothing it has to
    /// work out again.
    struct Result: Equatable {
        var photographs: [Photograph] = []
        /// Index into `photographs` by still id.
        var indexByID: [UUID: Int] = [:]

        /// Photographs the app is looking after. A Live Photo counts once.
        var counted: Int { photographs.count }
        /// Photographs short of the copies asked for them.
        var short: Int = 0
        /// Photographs with a copy that no longer matches what was imported.
        var damaged: Int = 0
        /// Verdict histogram, on the same terms as `counted`.
        var verdictCounts: [ProtectionState: Int] = [:]
        /// How many photographs are held by exactly N places. Photographs held
        /// nowhere are absent rather than counted as zero, matching the question
        /// the drives screen asks of it.
        var copyCoverage: [Int: Int] = [:]
        /// Photographs in each group. Motion halves are not counted.
        var countByGroup: [UUID: Int] = [:]
        /// Photographs in each group that are short, counted per photograph —
        /// so this can never exceed `countByGroup` for the same group.
        var shortByGroup: [UUID: Int] = [:]

        func photograph(_ id: UUID) -> Photograph? {
            indexByID[id].map { photographs[$0] }
        }
    }

    /// One pass over the photographs, one lookup each.
    ///
    /// Deliberately not a per-photograph entry point with a bulk wrapper: a bulk
    /// path that drifted from a single path would be a set of numbers that
    /// disagreed with each other on the same screen, which is the whole fault
    /// this is here to end.
    static func project(_ input: Input, now: Date = Date()) -> Result {
        var result = Result()
        result.photographs.reserveCapacity(input.photographs.count)

        for still in input.photographs {
            let group = input.groupOfAsset[still.id]
            let policy = group.flatMap { input.policyOfGroup[$0] } ?? input.fallbackPolicy
            let placement = place(still, policy: policy, in: input)

            let motion = input.motionByStill[still.id]
            let motionPlacement = motion.map { half -> Placement in
                // The movie half follows its own group where it has one; after
                // `reuniteLivePhotoHalves` that is the still's group, but a
                // half that has not been reunited yet must still be judged
                // against what it is actually set to.
                let halfGroup = input.groupOfAsset[half.id]
                let halfPolicy = halfGroup.flatMap { input.policyOfGroup[$0] } ?? policy
                return place(half, policy: halfPolicy, in: input)
            }

            let ownVerdict = verdict(for: still, policy: policy, in: input, now: now)
            let halfVerdict = motion.map { half -> ProtectionState in
                let halfGroup = input.groupOfAsset[half.id]
                let halfPolicy = halfGroup.flatMap { input.policyOfGroup[$0] } ?? policy
                return verdict(for: half, policy: halfPolicy, in: input, now: now)
            }
            let worst = (halfVerdict?.severity ?? -1) > ownVerdict.severity
                ? (halfVerdict ?? ownVerdict)
                : ownVerdict

            let photograph = Photograph(
                id: still.id,
                motion: motion?.id,
                group: group,
                placement: placement,
                motionPlacement: motionPlacement,
                verdict: worst
            )
            result.indexByID[still.id] = result.photographs.count
            result.photographs.append(photograph)

            if worst != .notApplicable {
                result.verdictCounts[worst, default: 0] += 1
            }
            if photograph.isShort {
                result.short += 1
                if let group { result.shortByGroup[group, default: 0] += 1 }
            }
            if worst == .driftDetected { result.damaged += 1 }
            if let group { result.countByGroup[group, default: 0] += 1 }

            let held = placement.presentAnywhere.count
            if held > 0 { result.copyCoverage[held, default: 0] += 1 }
        }
        return result
    }

    /// Sorts one file's replica rows onto the axes above.
    private static func place(_ asset: Asset, policy: Input.Policy, in input: Input) -> Placement {
        var placement = Placement(wants: policy.wants, named: policy.named)
        for replica in input.replicasByAsset[asset.id] ?? [] {
            switch replica.state {
            case .present:
                if policy.named.contains(replica.targetID) {
                    placement.presentOnNamed.insert(replica.targetID)
                    if replica.lastVerifiedAt != nil {
                        placement.verifiedOnNamed.insert(replica.targetID)
                    }
                } else {
                    placement.presentElsewhere.insert(replica.targetID)
                }
                placement.readable.insert(replica.targetID)
            case .pending, .copying:
                placement.pending.insert(replica.targetID)
            case .drift:
                placement.damaged.insert(replica.targetID)
                placement.readable.insert(replica.targetID)
            case .stale:
                placement.damaged.insert(replica.targetID)
                placement.readable.insert(replica.targetID)
            case .missing:
                break
            }
        }
        placement.leaving = (input.removalsByAsset[asset.id] ?? [])
        return placement
    }

    /// Delegates to `ProtectionEvaluator`, which already owns this rule.
    ///
    /// Deliberately not re-derived from `Placement`, however convenient that
    /// looks: a second implementation of the verdict is exactly the fault this
    /// type exists to end, and it would drift the first time one of them learned
    /// about a replica state the other had not met.
    private static func verdict(
        for asset: Asset, policy: Input.Policy, in input: Input, now: Date
    ) -> ProtectionState {
        ProtectionEvaluator.protectionState(
            for: asset,
            replicaStates: input.replicasByAsset[asset.id] ?? [],
            alreadyFiltered: true,
            desiredCopies: policy.wants,
            destinations: policy.named.isEmpty ? nil : Array(policy.named),
            now: now
        )
    }
}
