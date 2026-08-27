import Foundation

struct ReplicaTaskResult {
    var task: ReplicationTask
    var replica: TargetReplicaState?
    var message: String
    /// The work could not be done for a reason that will pass — typically the
    /// drive holding the only copy is unplugged. Such a task must stay queued
    /// rather than be recorded as failed, or the work is silently lost.
    var isTransient: Bool = false
}

struct SyncOutcome {
    var completedTasks: [ReplicationTask]
    var failedTasks: [ReplicationTask]
    var updatedReplicas: [TargetReplicaState]
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

    /// relativePath prefix for a replica satisfied by this drive's copy of a
    /// whole export part: `archivepart:takeout-<set>-<part>`. The archive is
    /// made of a handful of large zips, so holding the part *is* holding the
    /// assets inside it. Recording that directly avoids copying tens of
    /// thousands of files onto a drive that already has them, and avoids
    /// decompressing every entry just to name it.
    static let archivePartPrefix = "archivepart:"

    static func isVolumeBacked(_ replica: TargetReplicaState?) -> Bool {
        replica?.relativePath?.hasPrefix(volumeBackedPrefix) == true
    }

    static func isArchivePartBacked(_ replica: TargetReplicaState?) -> Bool {
        replica?.relativePath?.hasPrefix(archivePartPrefix) == true
    }

    /// The export part stem a replica is satisfied by, if any.
    static func archivePartStem(_ replica: TargetReplicaState?) -> String? {
        guard let relative = replica?.relativePath, relative.hasPrefix(archivePartPrefix) else {
            return nil
        }
        return String(relative.dropFirst(archivePartPrefix.count))
    }

    static func isZipMemberBacked(_ replica: TargetReplicaState?) -> Bool {
        replica?.relativePath?.hasPrefix(zipMemberPrefix) == true
    }

    /// Any replica whose bytes belong to the user's own archive files rather
    /// than the app-managed replica root. These are verified, never deleted.
    static func isArchiveBacked(_ replica: TargetReplicaState?) -> Bool {
        isVolumeBacked(replica) || isZipMemberBacked(replica) || isArchivePartBacked(replica)
    }

    /// Bytes that live inside a .zip rather than as a file of their own.
    ///
    /// Two of the four prefixes mean this, and code that knew about only one of
    /// them under-reported the risk by thousands of copies on a real archive —
    /// it read `zipmember:` as a file the photo owned, when it is a photo the app
    /// never wrote out and can only reach by opening the download. `volume:` really
    /// is a file of its own; it just is not one the app put there.
    ///
    /// Named once because the question is asked in four places and the answer
    /// has to be the same in all of them.
    static func isInsideADownload(_ relativePath: String?) -> Bool {
        guard let relativePath else { return false }
        return relativePath.hasPrefix(zipMemberPrefix)
            || relativePath.hasPrefix(archivePartPrefix)
    }

    static func zipMemberComponents(_ replica: TargetReplicaState?) -> (zipRelativePath: String, entry: String)? {
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

    static func replicaURL(for asset: Asset, drive: ReplicationTarget, mountURL: URL) -> URL {
        mountURL
            .appendingPathComponent(drive.replicaRootComponent, isDirectory: true)
            .appendingPathComponent(replicaRelativePath(for: asset))
    }

    /// Where this asset's replica actually lives on the drive: the recorded
    /// volume-backed location when one exists, the managed replica root
    /// otherwise.
    static func resolveReplicaURL(
        asset: Asset,
        drive: ReplicationTarget,
        mountURL: URL,
        existingReplica: TargetReplicaState?
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
    /// `sourceURL` is any readable copy of the asset — local staging, or a copy
    /// on another connected drive (including archive-backed Takeout files).
    /// Assets that live only on targets are copied drive-to-drive without ever
    /// being staged on the device.
    /// - Parameter archivePathsByStem: where each export part actually is on
    ///   this drive. Without it a part-backed replica can only be confirmed by
    ///   searching the volume for something with that name, which is a
    ///   recursive walk of the whole disk to answer a question the catalog
    ///   already knows the answer to.
    static func perform(
        _ task: ReplicationTask,
        drive: ReplicationTarget,
        mountURL: URL,
        asset: Asset?,
        sourceURL: URL?,
        existingReplica: TargetReplicaState? = nil,
        archivePathsByStem: [String: String] = [:]
    ) -> ReplicaTaskResult {
        var task = task
        guard let asset else {
            task.state = .failed
            task.errorMessage = "Asset missing from catalog"
            return ReplicaTaskResult(task: task, replica: nil, message: "Skipped task for unknown asset")
        }
        do {
            let replica: TargetReplicaState
            let message: String
            switch task.action {
            case .copy:
                replica = try performCopy(
                    asset: asset, drive: drive, mountURL: mountURL,
                    sourceURL: sourceURL, existingReplica: existingReplica
                )
                message = "Copied \(asset.originalFilename) to \(drive.name)"
            case .verify:
                replica = try performVerify(
                    asset: asset, drive: drive, mountURL: mountURL,
                    existingReplica: existingReplica, archivePathsByStem: archivePathsByStem
                )
                let verdict = replica.state == .present ? "verified" : replica.state.displayName.lowercased()
                message = "\(asset.originalFilename) on \(drive.name): \(verdict)"
            case .remove:
                if isArchiveBacked(existingReplica) {
                    // The bytes live in the user's own archive (e.g. a Takeout
                    // folder). Release the catalog's claim, never delete.
                    replica = TargetReplicaState(
                        assetID: asset.id,
                        targetID: drive.id,
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
    /// sync loop targets `perform` directly for progress and cancellation.
    static func processBacklog(
        tasks: [ReplicationTask],
        drive: ReplicationTarget,
        mountURL: URL,
        assetsByID: [UUID: Asset],
        staging: StagingStore,
        replicaStates: [TargetReplicaState] = [],
        sourceURLProvider: ((Asset) -> URL?)? = nil
    ) -> SyncOutcome {
        var outcome = SyncOutcome(completedTasks: [], failedTasks: [], updatedReplicas: [], messages: [])
        let replicasByKey = Dictionary(uniqueKeysWithValues: replicaStates.map { ($0.id, $0) })
        let queued = tasks
            .filter { $0.targetID == drive.id && $0.state == .queued }
            .sorted { $0.queuedAt < $1.queuedAt }

        for task in queued {
            let existing = replicasByKey["\(task.assetID.uuidString)/\(task.targetID.uuidString)"]
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

    /// `existingReplica` is what the catalog already recorded for this asset on
    /// this drive — including a copy that has gone missing. A file the user
    /// kept somewhere of their own is restored to exactly that path: it is
    /// where they put it, and re-landing it in the app's replica root under a
    /// UUID would answer "the file is gone" with a second, differently-named
    /// file somewhere else. Only content that never had a place of its own on
    /// the drive goes to the managed root.
    private static func performCopy(
        asset: Asset,
        drive: ReplicationTarget,
        mountURL: URL,
        sourceURL: URL?,
        existingReplica: TargetReplicaState?
    ) throws -> TargetReplicaState {
        guard let source = sourceURL, FileManager.default.fileExists(atPath: source.path) else {
            throw ReplicationError.noSourceCopy(asset.originalFilename)
        }
        // Only a `volume:` replica names a file of its own. A zip member or a
        // whole export part is restored by putting the archive back, not by
        // writing one loose photo where a zip used to be.
        let restoresInPlace = isVolumeBacked(existingReplica)
        let destination = restoresInPlace
            ? resolveReplicaURL(
                asset: asset, drive: drive, mountURL: mountURL, existingReplica: existingReplica
            )
            : replicaURL(for: asset, drive: drive, mountURL: mountURL)
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
        var replica = TargetReplicaState(
            assetID: asset.id,
            targetID: drive.id,
            state: .present,
            relativePath: restoresInPlace
                ? existingReplica?.relativePath
                : replicaRelativePath(for: asset),
            lastVerifiedAt: Date()
        )
        // The moment the app knows this file is right is the moment to write
        // down what it looks like, so the next connect can tell whether it
        // still does without reading it.
        recordObservation(of: destination, on: &replica)
        return replica
    }

    /// Writes what a file looks like right now onto the replica that was just
    /// confirmed against it.
    static func recordObservation(of url: URL, on replica: inout TargetReplicaState) {
        guard let observation = ReplicaStatGate.observe(url) else { return }
        replica.observedSize = observation.size
        replica.observedModifiedAt = observation.modifiedAt
    }

    private static func performVerify(
        asset: Asset,
        drive: ReplicationTarget,
        mountURL: URL,
        existingReplica: TargetReplicaState?,
        archivePathsByStem: [String: String] = [:]
    ) throws -> TargetReplicaState {
        // A part-backed replica is satisfied by the drive still holding that
        // export part. Checking the part is the honest unit of work here:
        // decompressing every entry to confirm one photo would be absurd when
        // the part is what the policy actually counts.
        if let stem = archivePartStem(existingReplica) {
            // `lastVerifiedAt` is carried over, not stamped with now.
            //
            // It means "the bytes of this copy were read back and matched",
            // and confirming that an export part is still on the disk reads
            // none of them. Stamping it here is how a whole archive came to be
            // reported as "all read back" on the strength of a file existing
            // with the right name — the reassurance the whole patrol exists to
            // earn, awarded for the one check that cannot earn it.
            var replica = TargetReplicaState(
                assetID: asset.id,
                targetID: drive.id,
                state: .missing,
                relativePath: existingReplica?.relativePath,
                lastVerifiedAt: existingReplica?.lastVerifiedAt
            )
            // Where the catalog says it is, in one `stat`.
            //
            // This used to enumerate the volume from its mount point looking
            // for a file whose *name* matched the stem — a recursive walk of a
            // whole disk, run once per photo, to rediscover a path already
            // recorded. Forty of those is the background patrol, on a drive
            // that is marked in-use for the duration.
            if let path = archivePathsByStem[stem], FileManager.default.fileExists(atPath: path) {
                replica.state = .present
                return replica
            }
            // Nothing recorded for this stem — a part the catalog has lost
            // track of. The search is kept as the fallback, because finding it
            // once is what lets the path be repaired.
            guard let enumerator = FileManager.default.enumerator(
                at: mountURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return replica }
            for case let url as URL in enumerator {
                if url.deletingPathExtension().lastPathComponent == stem
                    || url.lastPathComponent == stem {
                    replica.state = .present
                    break
                }
            }
            return replica
        }

        // Zip-member replicas verify by streaming the entry out of the zip.
        if let components = zipMemberComponents(existingReplica) {
            var replica = TargetReplicaState(
                assetID: asset.id,
                targetID: drive.id,
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
        var replica = TargetReplicaState(
            assetID: asset.id,
            targetID: drive.id,
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
        // Re-baseline whatever the verdict: a file read back and found wrong is
        // still a file whose current shape is now known, and re-reporting the
        // same change on every connect would bury the next real one.
        recordObservation(of: replicaFile, on: &replica)
        return replica
    }

    private static func performRemove(
        asset: Asset,
        drive: ReplicationTarget,
        mountURL: URL
    ) throws -> TargetReplicaState {
        let replicaFile = replicaURL(for: asset, drive: drive, mountURL: mountURL)
        if FileManager.default.fileExists(atPath: replicaFile.path) {
            try FileManager.default.removeItem(at: replicaFile)
        }
        // A copy interrupted before its rename leaves one of these. Removing
        // the asset without it would strand a file named after content the
        // catalog no longer claims, which nothing else would ever look at.
        let partial = replicaFile.appendingPathExtension("partial")
        if FileManager.default.fileExists(atPath: partial.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        // The bucket directory this file lived in, if it is now empty. Replicas
        // are filed under the first two characters of their id, so draining a
        // device leaves up to 256 empty directories behind — invisible to the
        // app and confusing in Finder, where the user sees a folder tree the
        // app said it had stopped using.
        pruneEmptyBucket(
            replicaFile.deletingLastPathComponent(),
            replicaRoot: replicaRoot(drive: drive, mountURL: mountURL)
        )
        return TargetReplicaState(
            assetID: asset.id,
            targetID: drive.id,
            state: .missing,
            relativePath: nil,
            lastVerifiedAt: Date()
        )
    }

    static func replicaRoot(drive: ReplicationTarget, mountURL: URL) -> URL {
        mountURL.appendingPathComponent(drive.replicaRootComponent, isDirectory: true)
    }

    /// Removes a replica bucket directory that has nothing left in it.
    ///
    /// Deliberately narrow. It refuses anything that is not *strictly inside*
    /// the managed replica root, so no path the user owns can be reached even
    /// if a caller passes the wrong directory, and it never removes the replica
    /// root itself — that folder existing is how the drive reads as one the app
    /// manages, and the copy path would recreate it anyway.
    ///
    /// Failure is silent: an empty directory left behind is untidy, and nothing
    /// about the archive is wrong because of it.
    static func pruneEmptyBucket(_ directory: URL, replicaRoot: URL) {
        let root = replicaRoot.standardizedFileURL.path
        let target = directory.standardizedFileURL.path
        guard target != root, target.hasPrefix(root + "/") else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        ) else { return }
        // `.DS_Store` and friends are not content worth keeping a directory
        // alive for, but removing them is the user's business, not the app's —
        // so a directory holding only hidden files is left alone.
        guard contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes every empty bucket under a drive's replica root.
    ///
    /// The sweep, for the directories that are already there: buckets emptied
    /// by migration cleanup before removal pruned as it went, and any left by a
    /// removal that could not finish. Bounded by the number of buckets (256),
    /// not by the number of files, so it is cheap enough to run after a sync.
    @discardableResult
    static func pruneEmptyBuckets(drive: ReplicationTarget, mountURL: URL) -> Int {
        let root = replicaRoot(drive: drive, mountURL: mountURL)
        guard let buckets = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return 0 }
        var removed = 0
        for bucket in buckets {
            let isDirectory = (try? bucket.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { continue }
            let before = FileManager.default.fileExists(atPath: bucket.path)
            pruneEmptyBucket(bucket, replicaRoot: root)
            if before, !FileManager.default.fileExists(atPath: bucket.path) { removed += 1 }
        }
        return removed
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
