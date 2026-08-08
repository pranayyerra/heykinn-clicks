import Foundation

/// Which replicas the background patrol should read next.
///
/// Reading is the only thing that finds bit rot — every cheap check compares
/// the catalog to itself, and a file whose bytes decayed still matches
/// everything the catalog knows about it. So the read budget is the scarcest
/// thing in the verification system, and how it is aimed is the whole design.
///
/// The rule this replaces was "read the least recently verified replicas". It
/// is the obvious rule and it aims at the wrong files once devices hold
/// different subsets:
///
/// - A photo on drive A (read yesterday) and drive B (read a year ago) is
///   **safe**. There is a known-good copy; if B has rotted, A restores it.
///   B's replica is the oldest in the archive and reading it buys almost
///   nothing.
/// - A photo on drives C and D, both read six months ago, has **no trusted
///   copy at all**. Neither replica is the oldest anything, so the old rule
///   never reaches it — and it is the photo actually at risk of being gone.
///
/// Risk belongs to the asset, not to the replica. So the queue is ordered by
/// the age of each asset's *freshest* copy, and within an asset the oldest
/// reachable copy is the one read: it is likeliest to be the damaged one, and
/// verifying it resets both the asset's risk and that replica's own clock.
enum PatrolScheduler {

    /// One replica the patrol could read.
    struct Replica: Hashable {
        var assetID: UUID
        var targetID: UUID
        var sizeBytes: Int64
        /// Nil means never read back. Treated as infinitely stale — an asset
        /// no copy of which has ever been verified is the most exposed thing
        /// in the archive, whatever the timestamps on everything else say.
        var lastVerifiedAt: Date?
    }

    /// How stale an asset is, judged by its *best* copy.
    ///
    /// `.distantPast` for an asset with a never-verified copy, so it sorts
    /// ahead of everything with a real timestamp.
    static func freshestVerification(
        of replicas: [Replica]
    ) -> Date? {
        guard !replicas.isEmpty else { return nil }
        var freshest: Date?
        for replica in replicas {
            // One never-read copy does not make the asset unverified — another
            // copy may have been read. But if *every* copy is nil the max is
            // nil, which is the answer we want.
            guard let verified = replica.lastVerifiedAt else { continue }
            if freshest == nil || verified > freshest! { freshest = verified }
        }
        return freshest
    }

    /// Picks what to read on one device, worst-risk asset first.
    ///
    /// - Parameters:
    ///   - candidates: replicas on the device about to be patrolled.
    ///   - allReplicasByAsset: every present replica of those assets, on every
    ///     device. Required — the risk of an asset cannot be judged from the
    ///     one device being patrolled, which is the mistake the old rule made.
    static func next(
        on targetID: UUID,
        candidates: [Replica],
        allReplicasByAsset: [UUID: [Replica]],
        budget: VerificationBudget = .patrol,
        now: Date = Date()
    ) -> [Replica] {
        // At most one replica per asset per run: reading a second copy of a
        // photo whose first copy just verified clean is the least valuable
        // read available, and the ration is small.
        var bestPerAsset: [UUID: Replica] = [:]
        for replica in candidates where replica.targetID == targetID {
            guard let existing = bestPerAsset[replica.assetID] else {
                bestPerAsset[replica.assetID] = replica
                continue
            }
            // Oldest copy on this device wins — likeliest to be damaged.
            if isOlder(replica, than: existing) { bestPerAsset[replica.assetID] = replica }
        }

        let ordered = bestPerAsset.values.sorted { left, right in
            let leftRisk = riskKey(for: left, allReplicasByAsset: allReplicasByAsset, now: now)
            let rightRisk = riskKey(for: right, allReplicasByAsset: allReplicasByAsset, now: now)
            if leftRisk != rightRisk { return leftRisk > rightRisk }
            // Deterministic, so a run that reads nothing new is reproducible
            // and a test can pin it.
            return left.assetID.uuidString < right.assetID.uuidString
        }

        var chosen: [Replica] = []
        var bytes: Int64 = 0
        for replica in ordered {
            guard chosen.count < budget.maxFiles else { break }
            // Skipped, not stopped on: a file above the per-file cap must not
            // block every smaller file behind it, or one huge video parks the
            // patrol permanently. The rot patrol is not the only thing that
            // will ever read it — an explicit sweep still can.
            guard replica.sizeBytes <= budget.maxBytesPerFile else { continue }
            guard bytes + replica.sizeBytes <= budget.maxBytes else { continue }
            chosen.append(replica)
            bytes += replica.sizeBytes
        }
        return chosen
    }

    /// Seconds since the asset's freshest copy was verified; `.greatestFinite`
    /// when no copy has ever been read back.
    private static func riskKey(
        for replica: Replica,
        allReplicasByAsset: [UUID: [Replica]],
        now: Date
    ) -> TimeInterval {
        let siblings = allReplicasByAsset[replica.assetID] ?? [replica]
        guard let freshest = freshestVerification(of: siblings) else {
            return .greatestFiniteMagnitude
        }
        return now.timeIntervalSince(freshest)
    }

    private static func isOlder(_ lhs: Replica, than rhs: Replica) -> Bool {
        switch (lhs.lastVerifiedAt, rhs.lastVerifiedAt) {
        case (nil, nil): return lhs.assetID.uuidString < rhs.assetID.uuidString
        case (nil, _): return true
        case (_, nil): return false
        case (let left?, let right?): return left < right
        }
    }
}
