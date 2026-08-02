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
    static func protectionStates(
        for assets: [Asset],
        replicaStates: [DriveReplicaState],
        now: Date = Date()
    ) -> [UUID: ProtectionState] {
        let byAsset = Dictionary(grouping: replicaStates, by: \.assetID)
        var result = [UUID: ProtectionState](minimumCapacity: assets.count)
        for asset in assets {
            result[asset.id] = protectionState(
                for: asset,
                replicaStates: byAsset[asset.id] ?? [],
                alreadyFiltered: true,
                now: now
            )
        }
        return result
    }

    /// `alreadyFiltered` means `replicaStates` holds only this asset's
    /// replicas, letting batch callers skip the per-asset scan.
    static func protectionState(
        for asset: Asset,
        replicaStates: [DriveReplicaState],
        alreadyFiltered: Bool = false,
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

        // Full replication means both managed drives hold the asset. With fewer
        // than two drives registered, an asset can never be fully replicated —
        // that is a truthful statement about the archive, not a bug.
        let present = states.filter { $0.state == .present }

        if present.count >= 2 {
            let overdue = present.contains { replica in
                guard let verified = replica.lastVerifiedAt else { return true }
                return now.timeIntervalSince(verified) > verificationMaxAge
            }
            return overdue ? .verificationOverdue : .fullyReplicated
        }
        if present.count == 1 {
            return .replicatedToOneDrive
        }
        return .stagedOnly
    }
}
