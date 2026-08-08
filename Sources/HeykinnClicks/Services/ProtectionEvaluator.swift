import Foundation

/// Computes the protection state of a Local asset from replica states and
/// staging presence. Pure function of catalog state — never stored blindly.
enum ProtectionEvaluator {
    /// Replicas verified longer ago than this are considered stale.
    static let verificationMaxAge: TimeInterval = 30 * 24 * 3600

    /// Computes protection for every asset in one pass. Indexing the replicas
    /// once turns what was an O(assets × replicas) scan into O(assets +
    /// replicas): with tens of thousands of each, the per-asset `filter` cost
    /// hundreds of millions of struct copies and stalled the main thread.
    /// - Parameter desiredCopies: how many copies this asset's own source asks
    ///   for. A function rather than a number: there is no archive-wide figure
    ///   any more, and every asset is judged against what the user set for the
    ///   thing it came from.
    static func protectionStates(
        for assets: [Asset],
        replicaStates: [TargetReplicaState],
        desiredCopies: (UUID) -> Int,
        now: Date = Date()
    ) -> [UUID: ProtectionState] {
        let byAsset = Dictionary(grouping: replicaStates, by: \.assetID)
        var result = [UUID: ProtectionState](minimumCapacity: assets.count)
        for asset in assets {
            result[asset.id] = protectionState(
                for: asset,
                replicaStates: byAsset[asset.id] ?? [],
                alreadyFiltered: true,
                desiredCopies: desiredCopies(asset.id),
                now: now
            )
        }
        return result
    }

    /// `alreadyFiltered` means `replicaStates` holds only this asset's
    /// replicas, letting batch callers skip the per-asset scan.
    static func protectionState(
        for asset: Asset,
        replicaStates: [TargetReplicaState],
        alreadyFiltered: Bool = false,
        desiredCopies: Int,
        now: Date = Date()
    ) -> ProtectionState {
        guard asset.residency == .local else { return .notApplicable }

        let states = alreadyFiltered ? replicaStates : replicaStates.filter { $0.assetID == asset.id }

        if states.contains(where: { $0.state == .drift }) {
            return .driftDetected
        }
        // A replica the catalog expected but a sync left stale also counts as drift
        // from the expected state.
        if states.contains(where: { $0.state == .stale }) {
            return .driftDetected
        }

        // Full replication means as many devices hold the asset as its source
        // asks for. With fewer devices named than that, an asset can never be
        // fully replicated — a truthful statement about the archive, not a bug.
        let present = states.filter { $0.state == .present }

        if present.count >= desiredCopies {
            // Never read back at all is a different claim from read back too
            // long ago, and saying "not checked recently" about a copy recorded
            // minutes ago is simply untrue.
            if present.contains(where: { $0.lastVerifiedAt == nil }) {
                return .awaitingFirstCheck
            }
            let overdue = present.contains { replica in
                guard let verified = replica.lastVerifiedAt else { return true }
                return now.timeIntervalSince(verified) > verificationMaxAge
            }
            return overdue ? .verificationOverdue : .fullyReplicated
        }
        // Any number of copies short of what the source asks for is partial
        // protection — not "staged only", which would claim no drive holds it
        // at all. Where a source asks for more than two, two copies is still
        // partial.
        if present.count >= 1 {
            return .replicatedToOneDrive
        }
        return .stagedOnly
    }
}
