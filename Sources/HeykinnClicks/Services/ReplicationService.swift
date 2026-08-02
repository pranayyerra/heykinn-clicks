import Foundation

struct ReplicaTaskResult {
    var task: ReplicationTask
    var replica: DriveReplicaState?
    var message: String
    /// The work could not be done for a reason that will pass — typically the
    /// drive holding the only copy is unplugged. Such a task must stay queued
    /// rather than be recorded as failed, or the work is silently lost.
    var isTransient: Bool = false
}

struct SyncOutcome {
    var completedTasks: [ReplicationTask]
    var failedTasks: [ReplicationTask]
    var updatedReplicas: [DriveReplicaState]
    var messages: [String]
}

/// Executes the per-drive replication backlog against a connected drive.
/// Tasks run one at a time by design: correctness over throughput, and the
/// one-task granularity is what makes sync cancellable and resumable — an
/// interrupted sync simply leaves the rest of the backlog queued. Every copy
/// is hash-verified before the catalog records the replica as present, so an
/// interruption never corrupts catalog state.
enum ReplicationService {

    /// relativePath prefix marking a replica backed by a user file at a
    /// volume-root-relative location (e.g. inside a Takeout folder) instead of
    /// the app-managed replica root. Such files belong to the user's archive:
    /// the app verifies them but never deletes them.
    static let volumeBackedPrefix = "volume:"

    /// relativePath prefix for a replica backed by an entry INSIDE a zip on
    /// the volume (e.g. an unextracted Takeout zip): the zip holds the bytes,
    /// so no separate copy is written to that drive. Format:
    /// `zipmember:<volume-relative-zip-path>!<entry-path>`.
    static let zipMemberPrefix = "zipmember:"

    static func isVolumeBacked(_ replica: DriveReplicaState?) -> Bool {
        replica?.relativePath?.hasPrefix(volumeBackedPrefix) == true
    }

    static func isZipMemberBacked(_ replica: DriveReplicaState?) -> Bool {
        replica?.relativePath?.hasPrefix(zipMemberPrefix) == true
    }

    /// Any replica whose bytes belong to the user's own archive files rather
    /// than the app-managed replica root. These are verified, never deleted.
    static func isArchiveBacked(_ replica: DriveReplicaState?) -> Bool {
        isVolumeBacked(replica) || isZipMemberBacked(replica)
    }

    static func zipMemberComponents(_ replica: DriveReplicaState?) -> (zipRelativePath: String, entry: String)? {
        guard let relative = replica?.relativePath, relative.hasPrefix(zipMemberPrefix) else { return nil }
        let payload = relative.dropFirst(zipMemberPrefix.count)
        guard let separator = payload.firstIndex(of: "!") else { return nil }
        return (
            zipRelativePath: String(payload[payload.startIndex..<separator]),
            entry: String(payload[payload.index(after: separator)...])
        )
    }

    static func replicaRelativePath(for asset: Asset) -> String {
        let bucket = String(asset.id.uuidString.prefix(2)).lowercased()
        let ext = asset.fileExtension
        let name = ext.isEmpty ? asset.id.uuidString : "\(asset.id.uuidString).\(ext)"
        return "\(bucket)/\(name)"
    }

    static func replicaURL(for asset: Asset, drive: ManagedDrive, mountURL: URL) -> URL {
        mountURL
            .appendingPathComponent(drive.replicaRootComponent, isDirectory: true)
            .appendingPathComponent(replicaRelativePath(for: asset))
    }

    /// Where this asset's replica actually lives on the drive: the recorded
    /// volume-backed location when one exists, the managed replica root
    /// otherwise.
    static func resolveReplicaURL(
        asset: Asset,
        drive: ManagedDrive,
        mountURL: URL,
        existingReplica: DriveReplicaState?
    ) -> URL {
        if let relative = existingReplica?.relativePath, relative.hasPrefix(volumeBackedPrefix) {
            return mountURL.appendingPathComponent(String(relative.dropFirst(volumeBackedPrefix.count)))
        }
        return replicaURL(for: asset, drive: drive, mountURL: mountURL)
    }

    /// Executes one backlog task to completion (or failure). Never throws:
    /// the outcome is always encoded in the returned task state so the caller
    /// can persist it and move on. Remove actions are only ever enqueued by
    /// explicit migration cleanup — never speculatively.
    /// `sourceURL` is any readable copy of the asset — Mac staging, or a copy
    /// on another connected drive (including archive-backed Takeout files).
    /// Assets that live only on drives are copied drive-to-drive without ever
    /// being staged on the Mac.
    static func perform(
        _ task: ReplicationTask,
        drive: ManagedDrive,
        mountURL: URL,
        asset: Asset?,
        sourceURL: URL?,
        existingReplica: DriveReplicaState? = nil
    ) -> ReplicaTaskResult {
        var task = task
        guard let asset else {
            task.state = .failed
            task.errorMessage = "Asset missing from catalog"
            return ReplicaTaskResult(task: task, replica: nil, message: "Skipped task for unknown asset")
        }
        do {
            let replica: DriveReplicaState
            let message: String
            switch task.action {
            case .copy:
                replica = try performCopy(asset: asset, drive: drive, mountURL: mountURL, sourceURL: sourceURL)
                message = "Copied \(asset.originalFilename) to \(drive.name)"
            case .verify:
                replica = try performVerify(asset: asset, drive: drive, mountURL: mountURL, existingReplica: existingReplica)
                let verdict = replica.state == .present ? "verified" : replica.state.displayName.lowercased()
                message = "\(asset.originalFilename) on \(drive.name): \(verdict)"
            case .remove:
                if isArchiveBacked(existingReplica) {
                    // The bytes live in the user's own archive (e.g. a Takeout
                    // folder). Release the catalog's claim, never delete.
                    replica = DriveReplicaState(
                        assetID: asset.id,
                        driveID: drive.id,
                        state: .missing,
                        relativePath: nil,
                        lastVerifiedAt: Date()
                    )
                    message = "Released archive-backed copy of \(asset.originalFilename) on \(drive.name); the Takeout file was left in place"
                } else {
                    replica = try performRemove(asset: asset, drive: drive, mountURL: mountURL)
                    message = "Removed \(asset.originalFilename) from \(drive.name)"
                }
            }
            task.state = .completed
            task.completedAt = Date()
            return ReplicaTaskResult(task: task, replica: replica, message: message)
        } catch {
            // No reachable source is a statement about right now, not about
            // the task: the copy is still owed once a drive holding the bytes
            // comes back.
            if case ReplicationError.noSourceCopy = error {
                task.errorMessage = "Waiting for a drive holding this file"
                return ReplicaTaskResult(
                    task: task,
                    replica: nil,
                    message: "No reachable copy of \(asset.originalFilename) — leaving it queued",
                    isTransient: true
                )
            }
            task.state = .failed
            task.errorMessage = error.localizedDescription
            return ReplicaTaskResult(
                task: task,
                replica: nil,
                message: "Failed \(task.action.rawValue) of \(asset.originalFilename) on \(drive.name): \(error.localizedDescription)"
            )
        }
    }

    /// Batch convenience over `perform` — processes every queued task for the
    /// drive serially. Used by tests and headless flows; the app's interactive
    /// sync loop drives `perform` directly for progress and cancellation.
    static func processBacklog(
        tasks: [ReplicationTask],
        drive: ManagedDrive,
        mountURL: URL,
        assetsByID: [UUID: Asset],
        staging: StagingStore,
        replicaStates: [DriveReplicaState] = [],
        sourceURLProvider: ((Asset) -> URL?)? = nil
    ) -> SyncOutcome {
        var outcome = SyncOutcome(completedTasks: [], failedTasks: [], updatedReplicas: [], messages: [])
        let replicasByKey = Dictionary(uniqueKeysWithValues: replicaStates.map { ($0.id, $0) })
        let queued = tasks
            .filter { $0.driveID == drive.id && $0.state == .queued }
            .sorted { $0.queuedAt < $1.queuedAt }

        for task in queued {
            let existing = replicasByKey["\(task.assetID.uuidString)/\(task.driveID.uuidString)"]
            let asset = assetsByID[task.assetID]
            let source = asset.flatMap { candidate -> URL? in
                if let sourceURLProvider { return sourceURLProvider(candidate) }
                guard let relative = candidate.stagingRelativePath, staging.exists(relativePath: relative) else { return nil }
                return staging.url(forRelativePath: relative)
            }
            let result = perform(task, drive: drive, mountURL: mountURL, asset: asset, sourceURL: source, existingReplica: existing)
            if result.task.state == .completed {
                outcome.completedTasks.append(result.task)
            } else {
                outcome.failedTasks.append(result.task)
            }
            if let replica = result.replica {
                outcome.updatedReplicas.append(replica)
            }
            outcome.messages.append(result.message)
        }
        return outcome
    }

    private static func performCopy(
        asset: Asset,
        drive: ManagedDrive,
        mountURL: URL,
        sourceURL: URL?
    ) throws -> DriveReplicaState {
        guard let source = sourceURL, FileManager.default.fileExists(atPath: source.path) else {
            throw ReplicationError.noSourceCopy(asset.originalFilename)
        }
        let destination = replicaURL(for: asset, drive: drive, mountURL: mountURL)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Copy to a temp name, verify, then atomically move into place, so an
        // interrupted sync never leaves a plausible-but-corrupt replica. A
        // leftover .partial from a previous interruption is discarded here.
        let temporary = destination.appendingPathExtension("partial")
        if FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }
        try FileManager.default.copyItem(at: source, to: temporary)
        let copiedHash = try HashingService.sha256(of: temporary)
        guard copiedHash == asset.contentHash else {
            try? FileManager.default.removeItem(at: temporary)
            throw ReplicationError.hashMismatchAfterCopy(asset.originalFilename)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return DriveReplicaState(
            assetID: asset.id,
            driveID: drive.id,
            state: .present,
            relativePath: replicaRelativePath(for: asset),
            lastVerifiedAt: Date()
        )
    }

    private static func performVerify(
        asset: Asset,
        drive: ManagedDrive,
        mountURL: URL,
        existingReplica: DriveReplicaState?
    ) throws -> DriveReplicaState {
        // Zip-member replicas verify by streaming the entry out of the zip.
        if let components = zipMemberComponents(existingReplica) {
            var replica = DriveReplicaState(
                assetID: asset.id,
                driveID: drive.id,
                state: .missing,
                relativePath: existingReplica?.relativePath,
                lastVerifiedAt: Date()
            )
            let zipURL = mountURL.appendingPathComponent(components.zipRelativePath)
            guard FileManager.default.fileExists(atPath: zipURL.path) else { return replica }
            if let hash = try? HashingService.sha256OfZipEntry(zipURL: zipURL, entry: components.entry) {
                replica.state = hash == asset.contentHash ? .present : .drift
            }
            return replica
        }

        let replicaFile = resolveReplicaURL(asset: asset, drive: drive, mountURL: mountURL, existingReplica: existingReplica)
        var replica = DriveReplicaState(
            assetID: asset.id,
            driveID: drive.id,
            state: .missing,
            relativePath: isVolumeBacked(existingReplica)
                ? existingReplica?.relativePath
                : replicaRelativePath(for: asset),
            lastVerifiedAt: Date()
        )
        guard FileManager.default.fileExists(atPath: replicaFile.path) else {
            return replica
        }
        let actualHash = try HashingService.sha256(of: replicaFile)
        replica.state = actualHash == asset.contentHash ? .present : .drift
        return replica
    }

    private static func performRemove(
        asset: Asset,
        drive: ManagedDrive,
        mountURL: URL
    ) throws -> DriveReplicaState {
        let replicaFile = replicaURL(for: asset, drive: drive, mountURL: mountURL)
        if FileManager.default.fileExists(atPath: replicaFile.path) {
            try FileManager.default.removeItem(at: replicaFile)
        }
        return DriveReplicaState(
            assetID: asset.id,
            driveID: drive.id,
            state: .missing,
            relativePath: nil,
            lastVerifiedAt: Date()
        )
    }
}

enum ReplicationError: Error, LocalizedError {
    case noSourceCopy(String)
    case hashMismatchAfterCopy(String)

    var errorDescription: String? {
        switch self {
        case .noSourceCopy(let name):
            return "No staged source copy available for \(name)"
        case .hashMismatchAfterCopy(let name):
            return "Hash mismatch after copying \(name) — copy discarded"
        }
    }
}
