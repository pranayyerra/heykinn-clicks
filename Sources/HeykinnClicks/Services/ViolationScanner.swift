import Foundation

/// Detects breaches of the exclusive-residency and replication invariants.
/// Pure inspection: violations are surfaced, never silently repaired.
enum ViolationScanner {
    static func scan(
        assets: [Asset],
        replicaStates: [TargetReplicaState],
        migrationJobs: [MigrationJob],
        targetsByID: [UUID: ReplicationTarget],
        takeoutArchives: [TakeoutArchive] = []
    ) -> [Violation] {
        var violations: [Violation] = []

        // One per drive rather than one per file. Six parts of an export
        // vanishing is one event with one cause — a folder dragged to the bin,
        // a drive tidied up — and six identical rows describe it worse than a
        // count does. It also keeps the violation's identity unique, which is
        // derived from its kind and the things it names.
        let goneByTarget = Dictionary(
            grouping: takeoutArchives.filter { $0.missingSince != nil && $0.targetID != nil },
            by: { $0.targetID! }
        )
        for (targetID, gone) in goneByTarget.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let name = targetsByID[targetID]?.name ?? "a drive"
            let since = gone.compactMap(\.missingSince).min()
            violations.append(Violation(
                kind: .exportPartMissing,
                targetID: targetID,
                detail: "\(Formatters.count(gone.count, "export file")) that \(name) was holding "
                    + "\(gone.count == 1 ? "is" : "are") no longer there"
                    + (since.map { " — first noticed \(Formatters.relative($0))" } ?? "")
                    + ". \(gone.map(\.displayName).sorted().prefix(3).joined(separator: ", "))"
                    + (gone.count > 3 ? " and \(gone.count - 3) more." : ".")
            ))
        }

        let activeMigrationAssetIDs: Set<UUID> = Set(
            migrationJobs.filter { $0.state.isActive }.flatMap(\.assetIDs)
        )

        for asset in assets {
            let inActiveMigration = activeMigrationAssetIDs.contains(asset.id)

            if asset.presence.count > 1 && !inActiveMigration {
                let domains = asset.presence.domains.map(\.displayName).joined(separator: " + ")
                violations.append(Violation(
                    kind: .multiDomainCoexistence,
                    assetID: asset.id,
                    targetID: nil,
                    migrationJobID: nil,
                    detail: "\(asset.originalFilename) is present in \(domains) with no active migration."
                ))
            }

            if !asset.presence.contains(asset.residency) && !inActiveMigration {
                violations.append(Violation(
                    kind: .residencyPresenceMismatch,
                    assetID: asset.id,
                    targetID: nil,
                    migrationJobID: nil,
                    detail: "\(asset.originalFilename) has residency \(asset.residency.displayName) but no known copy there."
                ))
            }
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for replica in replicaStates {
            guard let asset = assetsByID[replica.assetID] else { continue }
            let targetName = targetsByID[replica.targetID]?.name ?? "unknown drive"

            if replica.state == .drift {
                violations.append(Violation(
                    kind: .replicaDrift,
                    assetID: replica.assetID,
                    targetID: replica.targetID,
                    migrationJobID: nil,
                    detail: "\(asset.originalFilename) on \(targetName) is no longer byte-for-byte what was imported — the file on the drive may be damaged. Re-copy it from the other drive's good copy."
                ))
            }

            if asset.residency != .local,
               replica.state == .present,
               !activeMigrationAssetIDs.contains(asset.id) {
                violations.append(Violation(
                    kind: .orphanReplica,
                    assetID: replica.assetID,
                    targetID: replica.targetID,
                    migrationJobID: nil,
                    detail: "\(targetName) still holds a replica of \(asset.originalFilename), which is \(asset.residency.displayName)-resident."
                ))
            }
        }

        for job in migrationJobs where job.state == .clearingSource {
            let lingering = job.assetIDs.filter { assetsByID[$0]?.presence.contains(job.fromDomain) == true }
            if !lingering.isEmpty {
                violations.append(Violation(
                    kind: .migrationCleanupPending,
                    assetID: lingering.count == 1 ? lingering[0] : nil,
                    targetID: nil,
                    migrationJobID: job.id,
                    detail: "Migration to \(job.toDomain.displayName): \(Formatters.count(lingering.count, "asset")) still present in \(job.fromDomain.displayName)."
                ))
            }
        }

        return violations
    }
}
