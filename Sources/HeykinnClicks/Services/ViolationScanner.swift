import Foundation

/// Detects breaches of the exclusive-residency and replication invariants.
/// Pure inspection: violations are surfaced, never silently repaired.
enum ViolationScanner {
    static func scan(
        assets: [Asset],
        replicaStates: [DriveReplicaState],
        migrationJobs: [MigrationJob],
        drivesByID: [UUID: ManagedDrive]
    ) -> [Violation] {
        var violations: [Violation] = []

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
                    driveID: nil,
                    migrationJobID: nil,
                    detail: "\(asset.originalFilename) is present in \(domains) with no active migration."
                ))
            }

            if !asset.presence.contains(asset.residency) && !inActiveMigration {
                violations.append(Violation(
                    kind: .residencyPresenceMismatch,
                    assetID: asset.id,
                    driveID: nil,
                    migrationJobID: nil,
                    detail: "\(asset.originalFilename) has residency \(asset.residency.displayName) but no known copy there."
                ))
            }
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for replica in replicaStates {
            guard let asset = assetsByID[replica.assetID] else { continue }
            let driveName = drivesByID[replica.driveID]?.name ?? "unknown drive"

            if replica.state == .drift {
                violations.append(Violation(
                    kind: .replicaDrift,
                    assetID: replica.assetID,
                    driveID: replica.driveID,
                    migrationJobID: nil,
                    detail: "\(asset.originalFilename) on \(driveName) is no longer byte-for-byte what was imported — the file on the drive may be damaged. Re-copy it from the other drive's good copy."
                ))
            }

            if asset.residency != .local,
               replica.state == .present,
               !activeMigrationAssetIDs.contains(asset.id) {
                violations.append(Violation(
                    kind: .orphanReplica,
                    assetID: replica.assetID,
                    driveID: replica.driveID,
                    migrationJobID: nil,
                    detail: "\(driveName) still holds a replica of \(asset.originalFilename), which is \(asset.residency.displayName)-resident."
                ))
            }
        }

        for job in migrationJobs where job.state == .clearingSource {
            let lingering = job.assetIDs.filter { assetsByID[$0]?.presence.contains(job.fromDomain) == true }
            if !lingering.isEmpty {
                violations.append(Violation(
                    kind: .migrationCleanupPending,
                    assetID: lingering.count == 1 ? lingering[0] : nil,
                    driveID: nil,
                    migrationJobID: job.id,
                    detail: "Migration to \(job.toDomain.displayName): \(lingering.count) asset(s) still present in \(job.fromDomain.displayName)."
                ))
            }
        }

        return violations
    }
}
