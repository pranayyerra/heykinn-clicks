import Foundation

/// Pure state-machine transitions for migration jobs. The AppStore applies the
/// returned effects (asset mutations, replication tasks) and persists them, so
/// every transition is explicit, auditable, and interruptible.
enum MigrationService {

    struct TransitionEffect {
        var job: MigrationJob
        var updatedAssets: [Asset]
        /// Remove-tasks to enqueue (only during source cleanup of Local).
        var replicationTasks: [ReplicationTask]
        var auditMessage: String
    }

    enum MigrationError: Error, LocalizedError {
        case invalidTransition(from: MigrationState, attempted: String)
        case sameDomain

        var errorDescription: String? {
            switch self {
            case .invalidTransition(let from, let attempted):
                return "Cannot \(attempted) from state \(from.displayName)"
            case .sameDomain:
                return "Source and target domains are the same"
            }
        }
    }

    static func createJob(
        assetIDs: [UUID],
        from source: ResidencyDomain,
        to target: ResidencyDomain,
        note: String?
    ) throws -> MigrationJob {
        guard source != target else { throw MigrationError.sameDomain }
        let now = Date()
        return MigrationJob(
            id: UUID(),
            assetIDs: assetIDs,
            fromDomain: source,
            toDomain: target,
            state: .pending,
            createdAt: now,
            updatedAt: now,
            note: note
        )
    }

    /// pending → copyingToTarget. The copy itself is a manual/external workflow
    /// for cloud targets in v1; the job tracks it explicitly.
    static func start(_ job: MigrationJob) throws -> MigrationJob {
        guard job.state == .pending else {
            throw MigrationError.invalidTransition(from: job.state, attempted: "start")
        }
        return advanced(job, to: .copyingToTarget)
    }

    /// copyingToTarget → verifyingTarget. Marks target presence on the assets —
    /// this is where the legal, temporary multi-domain overlap begins.
    static func markTargetCopyComplete(_ job: MigrationJob, assets: [Asset]) throws -> TransitionEffect {
        guard job.state == .copyingToTarget else {
            throw MigrationError.invalidTransition(from: job.state, attempted: "mark target copy complete")
        }
        var updated: [Asset] = []
        for var asset in assets where job.assetIDs.contains(asset.id) {
            asset.presence.set(job.toDomain, true)
            asset.updatedDate = Date()
            updated.append(asset)
        }
        return TransitionEffect(
            job: advanced(job, to: .verifyingTarget),
            updatedAssets: updated,
            replicationTasks: [],
            auditMessage: "Migration \(job.fromDomain.displayName) → \(job.toDomain.displayName): target copy reported complete for \(job.assetIDs.count) asset(s); overlap window open."
        )
    }

    /// verifyingTarget → clearingSource. Verification confirmed; source
    /// retention may now be cleared.
    static func markTargetVerified(_ job: MigrationJob) throws -> MigrationJob {
        guard job.state == .verifyingTarget else {
            throw MigrationError.invalidTransition(from: job.state, attempted: "mark target verified")
        }
        return advanced(job, to: .clearingSource)
    }

    /// clearingSource → completed. Clears source presence, flips residency to
    /// the target, and (for a Local source) enqueues explicit remove-tasks for
    /// each managed drive plus staging cleanup. Destructive by design — the UI
    /// must confirm before invoking.
    static func completeCleanup(
        _ job: MigrationJob,
        assets: [Asset],
        managedDrives: [ManagedDrive],
        replicaStates: [DriveReplicaState]
    ) throws -> TransitionEffect {
        guard job.state == .clearingSource else {
            throw MigrationError.invalidTransition(from: job.state, attempted: "complete cleanup")
        }
        var updatedAssets: [Asset] = []
        var removeTasks: [ReplicationTask] = []

        for var asset in assets where job.assetIDs.contains(asset.id) {
            asset.presence.set(job.fromDomain, false)
            asset.residency = job.toDomain
            asset.residencySource = .migration
            asset.updatedDate = Date()

            if job.fromDomain == .local {
                for drive in managedDrives {
                    let hasReplica = replicaStates.contains {
                        $0.assetID == asset.id && $0.driveID == drive.id && ($0.state == .present || $0.state == .stale || $0.state == .drift)
                    }
                    if hasReplica {
                        removeTasks.append(ReplicationTask(
                            id: UUID(),
                            assetID: asset.id,
                            driveID: drive.id,
                            action: .remove,
                            state: .queued,
                            queuedAt: Date(),
                            completedAt: nil,
                            errorMessage: nil
                        ))
                    }
                }
            }
            updatedAssets.append(asset)
        }

        return TransitionEffect(
            job: advanced(job, to: .completed),
            updatedAssets: updatedAssets,
            replicationTasks: removeTasks,
            auditMessage: "Migration \(job.fromDomain.displayName) → \(job.toDomain.displayName) completed for \(job.assetIDs.count) asset(s); source retention cleared\(removeTasks.isEmpty ? "" : ", \(removeTasks.count) drive removal task(s) queued")."
        )
    }

    static func fail(_ job: MigrationJob, reason: String) -> MigrationJob {
        var failed = advanced(job, to: .failed)
        failed.note = [job.note, "Failed: \(reason)"].compactMap { $0 }.joined(separator: " — ")
        return failed
    }

    private static func advanced(_ job: MigrationJob, to state: MigrationState) -> MigrationJob {
        var next = job
        next.state = state
        next.updatedAt = Date()
        return next
    }
}
