import Foundation

/// Which devices hold an asset's copies: the ones its source names.
///
/// This planner does not choose. An earlier version did — it ranked devices by
/// free space and picked the emptiest — which removed the cap on how many
/// drives could be registered and, in the same move, took away the one thing
/// the user had asked for by name: saying where their photos go. Free space is
/// a *constraint* here, never a policy. A destination without room produces a
/// reported shortfall, never a quiet substitution onto some other disk.
///
/// Pure and deterministic. Placement decides where bytes live for years, so a
/// plan that varied between runs could not be tested, reasoned about, or
/// reproduced after a crash.
enum PlacementPlanner {

    /// A device an asset could be placed on.
    struct Candidate: Hashable {
        var targetID: UUID
        /// Bytes free now. Nil when it could not be measured — an unreachable
        /// drive, usually.
        var freeBytes: Int64?
        var isReachable: Bool
    }

    /// Why a copy the source asked for cannot be made.
    enum Obstacle: Hashable {
        /// The source names fewer devices than it wants copies. Only the user
        /// can fix this, by naming another device.
        case tooFewDestinations
        /// A named device has no room. Reported against that device by name,
        /// because "not enough space" without saying where is unactionable.
        case noRoom(targetID: UUID, shortBy: Int64)
        /// A named device is not registered any more — forgotten since the
        /// source was configured.
        case destinationMissing(targetID: UUID)
    }

    /// One asset's destinations.
    struct Placement {
        var assetID: UUID
        /// Devices that should receive a copy. Excludes any already holding
        /// one, in place or otherwise.
        var destinations: [UUID]
        /// Copies the source asked for that cannot be made, and why.
        var obstacles: [Obstacle]

        var shortfall: Int { obstacles.count }
    }

    /// Free space to leave on a device after placing onto it.
    ///
    /// A drive filled to the last byte cannot take a catalog snapshot, cannot
    /// receive a delivered export part, and behaves badly at the filesystem
    /// level. The reserve keeps a device useful rather than merely full.
    static let reserveBytes: Int64 = 10 * 1024 * 1024 * 1024

    /// Plans a source's assets onto the devices that source names.
    ///
    /// Batch-aware: it tracks bytes already promised to each device, so a
    /// thousand photos planned in one pass see a device fill up and report the
    /// shortfall, rather than each independently believing there is room.
    ///
    /// - Parameters:
    ///   - assets: the assets to place, as (id, size) pairs.
    ///   - existingHolders: devices already holding each asset — files counted
    ///     where they sit, or copies from an earlier run. Never re-placed;
    ///     invariant 5 says never copy what a device already holds.
    ///   - destinations: the source's named devices, in the user's order.
    ///   - desiredCopies: how many copies the source asks for.
    ///   - candidates: registered devices, for room and reachability. A named
    ///     destination absent from here has been forgotten since.
    static func plan(
        assets: [(id: UUID, sizeBytes: Int64)],
        existingHolders: [UUID: Set<UUID>] = [:],
        destinations: [UUID],
        desiredCopies: Int,
        candidates: [Candidate]
    ) -> [Placement] {
        let byID = Dictionary(
            candidates.map { ($0.targetID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // Registered destinations, in the order the user named them. Placement
        // is not free to reorder these: the first device someone lists is the
        // one they think of as primary, and honouring that costs nothing.
        let usable = destinations.filter { byID[$0] != nil }
        let missing = destinations.filter { byID[$0] == nil }

        var projected: [UUID: Int64] = [:]
        for candidate in candidates {
            projected[candidate.targetID] = candidate.freeBytes ?? 0
        }

        var placements: [Placement] = []
        placements.reserveCapacity(assets.count)

        for asset in assets {
            let held = existingHolders[asset.id] ?? []
            var chosen: [UUID] = []
            var obstacles: [Obstacle] = []

            // A device already holding it counts towards the copy count and is
            // sent nothing — that is the whole point of scanning a drive before
            // transporting to it.
            var satisfied = held.filter { destinations.contains($0) }.count

            for targetID in usable where !held.contains(targetID) {
                guard satisfied + chosen.count < desiredCopies else { break }
                // A device that is not plugged in cannot be measured, and "not
                // measured" is not "full". Reading its nil as zero free bytes
                // made every named-but-absent device report `.noRoom`, so the
                // archive never owed an unplugged drive anything — which is
                // exactly the case the device's holding area exists to serve, and
                // it left a drive that is only occasionally connected receiving
                // nothing at all. It also made registering a drive a no-op
                // until something else happened to re-run the audit, because a
                // device is unreachable until the scan after it is registered.
                //
                // The copy is owed now and its room is checked at copy time,
                // when the drive is here and the figure means something.
                guard byID[targetID]?.isReachable != false else {
                    chosen.append(targetID)
                    continue
                }
                let free = projected[targetID] ?? 0
                guard free - asset.sizeBytes >= reserveBytes else {
                    obstacles.append(.noRoom(
                        targetID: targetID,
                        shortBy: asset.sizeBytes - max(free - reserveBytes, 0)
                    ))
                    continue
                }
                chosen.append(targetID)
                projected[targetID] = free - asset.sizeBytes
            }

            for targetID in missing where satisfied + chosen.count < desiredCopies {
                obstacles.append(.destinationMissing(targetID: targetID))
            }

            // Named devices exhausted and still short. Distinct from "no room":
            // this one is only fixable by naming another device.
            satisfied += chosen.count
            if satisfied < desiredCopies, obstacles.isEmpty {
                for _ in 0..<(desiredCopies - satisfied) {
                    obstacles.append(.tooFewDestinations)
                }
            }

            placements.append(Placement(
                assetID: asset.id, destinations: chosen, obstacles: obstacles
            ))
        }

        return placements
    }
}
