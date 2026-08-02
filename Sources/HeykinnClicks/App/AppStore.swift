import Foundation
import SwiftUI

/// Single observable source of truth for the UI, backed by the on-Mac catalog.
/// The Mac is the control plane: everything here loads and works with zero
/// drives attached.
@MainActor
final class AppStore: ObservableObject {

    // Catalog-backed state
    @Published private(set) var assets: [Asset] = []
    @Published private(set) var drives: [ManagedDrive] = []
    @Published private(set) var replicaStates: [DriveReplicaState] = []
    @Published private(set) var replicationTasks: [ReplicationTask] = []
    @Published private(set) var policyRules: [PolicyRule] = []
    @Published private(set) var migrationJobs: [MigrationJob] = []
    @Published private(set) var importBatches: [ImportBatch] = []
    @Published private(set) var auditEvents: [AuditEvent] = []
    @Published private(set) var takeoutArchives: [TakeoutArchive] = []

    // Derived state
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published private(set) var violations: [Violation] = []
    @Published private(set) var protectionStates: [UUID: ProtectionState] = [:]

    // Operational state
    @Published private(set) var syncProgress: SyncProgress?
    @Published var isImporting = false
    @Published private(set) var takeoutActivity: TakeoutActivity?
    @Published var lastError: String?
    @Published var autoSyncOnConnect: Bool = UserDefaults.standard.object(forKey: "autoSyncOnConnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSyncOnConnect, forKey: "autoSyncOnConnect") }
    }
    /// When a managed drive connects, scan → extract → import its Takeout
    /// exports without any clicks, using the Takeout files as that drive's
    /// replicas.
    @Published var autoManageTakeout: Bool = UserDefaults.standard.object(forKey: "autoManageTakeout") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoManageTakeout, forKey: "autoManageTakeout") }
    }

    var isSyncing: Bool { syncProgress != nil }

    /// An unmanaged external volume just appeared; the UI asks whether to use
    /// it as managed local storage (and/or scan it for Takeout).
    @Published var connectPrompt: VolumeInfo?

    private var syncCancelRequested = false
    /// Drives waiting their turn while another drive syncs (syncs are serial).
    private var pendingSyncDriveIDs: [UUID] = []
    /// Volumes already prompted this session — one ask per appearance.
    private var promptedVolumeKeys: Set<String> = []
    /// Drives whose auto-Takeout pipeline is running or already finished this
    /// session. A transient volume-metadata hiccup can otherwise look like a
    /// reconnect and restart the whole (very expensive) pipeline.
    private var takeoutPipelineActiveDriveIDs: Set<UUID> = []
    private var takeoutPipelineCompletedDriveIDs: Set<UUID> = []
    /// Files per import chunk. Each chunk is scanned in parallel and then
    /// committed, so this also sets how often the Library and progress bar
    /// refresh — small enough to feel live, large enough to amortise the
    /// per-chunk commit.
    private static let importChunkSize = 100
    private var ignoredVolumeKeys: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "ignoredVolumeKeys") ?? [])

    let staging: StagingStore
    let driveMonitor: DriveMonitor
    private let catalog: CatalogStore

    var connectedMounts: [UUID: URL] { driveMonitor.connectedMounts }
    var availableVolumes: [VolumeInfo] { driveMonitor.availableVolumes }

    var assetsByID: [UUID: Asset] {
        Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    }

    var drivesByID: [UUID: ManagedDrive] {
        Dictionary(uniqueKeysWithValues: drives.map { ($0.id, $0) })
    }

    /// Where this asset's bytes can be read right now, for previews and
    /// thumbnails: Mac staging first, then any present replica on a connected
    /// drive — including archive-backed Takeout files, which makes
    /// drive-resident content viewable in the Library whenever the drive is
    /// attached. (Zip-member replicas are skipped: not directly readable.)
    func localFileURL(for asset: Asset) -> URL? {
        if let relative = asset.stagingRelativePath, staging.exists(relativePath: relative) {
            return staging.url(forRelativePath: relative)
        }
        for replica in replicaStates where replica.assetID == asset.id && replica.state == .present {
            guard let mountURL = connectedMounts[replica.driveID],
                  let drive = drivesByID[replica.driveID],
                  !ReplicationService.isZipMemberBacked(replica)
            else { continue }
            let url = ReplicationService.resolveReplicaURL(
                asset: asset, drive: drive, mountURL: mountURL, existingReplica: replica
            )
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = support.appendingPathComponent("HeykinnClicks", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        staging = StagingStore(rootURL: appDirectory.appendingPathComponent("Staging", isDirectory: true))
        driveMonitor = DriveMonitor()

        do {
            catalog = try CatalogStore(databasePath: appDirectory.appendingPathComponent("catalog.sqlite").path)
        } catch {
            fatalError("Could not open catalog database: \(error)")
        }

        loadAll()
        if assets.isEmpty && drives.isEmpty && policyRules.isEmpty {
            SampleData.seed(into: self)
            loadAll()
        }

        driveMonitor.rescanRequested = { [weak self] in
            self?.rescanDrives()
        }
        rescanDrives()
        // Runs after the drive scan so drive-resident leftovers are visible.
        reconcileAfterRestart()

        // Volume mount notifications cover the common case; a slow poll covers
        // anything they miss (e.g. network volumes, missed events).
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rescanDrives()
            }
        }
    }

    // MARK: - Startup integrity

    /// Repairs whatever an abrupt termination left behind. Everything here is
    /// idempotent and safe to run on every launch: it only removes files the
    /// catalog does not reference, and only re-queues work that can be redone.
    /// Never deletes anything the catalog depends on.
    func reconcileAfterRestart() {
        var repairs: [String] = []
        do {
            // 1. Replication tasks interrupted mid-flight would otherwise sit
            // in a state the sync loop never picks up again.
            let stuck = replicationTasks.filter { $0.state == .inProgress }
            for var task in stuck {
                task.state = .queued
                task.errorMessage = "Requeued after an interrupted run"
                try catalog.upsertReplicationTask(task)
            }
            if !stuck.isEmpty { repairs.append("requeued \(stuck.count) interrupted replication task(s)") }

            // 2. Assets can reference a batch row that never got written by an
            // older build; synthesise it so import history is not lost.
            let knownBatchIDs = Set(importBatches.map(\.id))
            let orphanBatchIDs = Set(assets.compactMap(\.importBatchID)).subtracting(knownBatchIDs)
            for batchID in orphanBatchIDs {
                let members = assets.filter { $0.importBatchID == batchID }
                guard let earliest = members.map(\.importDate).min() else { continue }
                try catalog.upsertImportBatch(ImportBatch(
                    id: batchID,
                    sourcePath: "Recovered import (\(members.first?.importOrigin.displayName ?? "unknown"))",
                    startedAt: earliest,
                    completedAt: members.map(\.updatedDate).max(),
                    importedCount: members.count,
                    duplicateCount: 0,
                    failedCount: 0
                ))
            }
            if !orphanBatchIDs.isEmpty {
                repairs.append("recovered \(orphanBatchIDs.count) import batch record(s) covering \(assets.filter { $0.importBatchID.map(orphanBatchIDs.contains) ?? false }.count) asset(s)")
            }

            // 3. Staged files no asset points at: bytes copied in just before
            // the process died. Reclaimable, and nothing references them.
            let referenced = Set(assets.compactMap(\.stagingRelativePath))
            var orphanedStaging = 0
            if let enumerator = FileManager.default.enumerator(
                at: staging.rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    let relative = fileURL.path.replacingOccurrences(of: staging.rootURL.path + "/", with: "")
                    if !referenced.contains(relative) {
                        try? FileManager.default.removeItem(at: fileURL)
                        orphanedStaging += 1
                    }
                }
            }
            if orphanedStaging > 0 { repairs.append("removed \(orphanedStaging) orphaned staged file(s)") }

            // 4. Abandoned zip-extraction workspaces on the Mac (each can be
            // many GB) and half-written `.extracting` folders on drives.
            let workArea = staging.rootURL.deletingLastPathComponent()
                .appendingPathComponent("TakeoutWork", isDirectory: true)
            if let leftovers = try? FileManager.default.contentsOfDirectory(at: workArea, includingPropertiesForKeys: nil),
               !leftovers.isEmpty {
                for item in leftovers { try? FileManager.default.removeItem(at: item) }
                repairs.append("cleared \(leftovers.count) abandoned extraction workspace(s)")
            }
            // Only look where extractions actually happen — beside a known
            // archive. Walking whole volumes at launch would cost a full-drive
            // directory traversal on every start.
            var partials = 0
            let extractionParents = Set(
                takeoutArchives.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
            )
            for parent in extractionParents {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent) else { continue }
                for entry in entries where entry.hasSuffix(".extracting") {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: parent).appendingPathComponent(entry))
                    partials += 1
                }
            }
            if partials > 0 { repairs.append("removed \(partials) incomplete extraction folder(s)") }

            if !repairs.isEmpty {
                audit(.system, "Startup reconciliation: " + repairs.joined(separator: "; ") + ".")
                loadAll()
            }
        } catch {
            lastError = "Startup reconciliation failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Loading and derivation

    func loadAll() {
        do {
            assets = try catalog.fetchAssets()
            drives = try catalog.fetchDrives()
            replicaStates = try catalog.fetchReplicaStates()
            replicationTasks = try catalog.fetchReplicationTasks()
            policyRules = try catalog.fetchPolicyRules()
            migrationJobs = try catalog.fetchMigrationJobs()
            importBatches = try catalog.fetchImportBatches()
            auditEvents = try catalog.fetchAuditEvents()
            takeoutArchives = try catalog.fetchTakeoutArchives()
            recomputeDerivedState()
        } catch {
            lastError = "Catalog load failed: \(error.localizedDescription)"
        }
    }

    func recomputeDerivedState() {
        duplicateGroups = DuplicateDetector.groups(in: assets)
        violations = ViolationScanner.scan(
            assets: assets,
            replicaStates: replicaStates,
            migrationJobs: migrationJobs,
            drivesByID: drivesByID
        )
        var protection: [UUID: ProtectionState] = [:]
        for asset in assets {
            protection[asset.id] = ProtectionEvaluator.protectionState(
                for: asset,
                replicaStates: replicaStates
            )
        }
        protectionStates = protection
    }

    func rescanDrives() {
        let previouslyConnected = Set(driveMonitor.connectedMounts.keys)
        driveMonitor.rescan(managedDrives: drives)
        let now = Date()
        for driveID in driveMonitor.connectedMounts.keys {
            if let index = drives.firstIndex(where: { $0.id == driveID }) {
                drives[index].lastSeenAt = now
                try? catalog.upsertDrive(drives[index])
            }
        }
        // Availability-aware reaction: a drive that just appeared with pending
        // backlog starts syncing on its own (serially, behind any running sync),
        // and gets a Takeout sweep so newly landed archives surface unprompted.
        let newlyConnected = Set(driveMonitor.connectedMounts.keys).subtracting(previouslyConnected)
        for driveID in newlyConnected {
            let name = drivesByID[driveID]?.name ?? "drive"
            audit(.drive, "\(name) connected.", driveID: driveID)
            if autoSyncOnConnect && backlogCount(for: driveID) > 0 {
                syncDrive(driveID)
            }
            Task { await autoTakeoutPipeline(driveID: driveID) }
        }

        promptForUnmanagedVolumes()
    }

    /// Asks (once per appearance, never for ignored volumes) whether a newly
    /// mounted unmanaged external volume should become managed local storage.
    private func promptForUnmanagedVolumes() {
        let unmanaged = driveMonitor.availableVolumes.filter { volume in
            volume.isRemovable
                && volume.url.path.hasPrefix("/Volumes/")
                && DriveMonitor.match(volume: volume, against: drives) == nil
        }
        for volume in unmanaged {
            let key = volume.volumeUUID ?? volume.url.path
            guard !promptedVolumeKeys.contains(key), !ignoredVolumeKeys.contains(key) else { continue }
            promptedVolumeKeys.insert(key)
            if connectPrompt == nil {
                connectPrompt = volume
            }
        }
    }

    func ignoreVolumePermanently(_ volume: VolumeInfo) {
        let key = volume.volumeUUID ?? volume.url.path
        ignoredVolumeKeys.insert(key)
        UserDefaults.standard.set(Array(ignoredVolumeKeys), forKey: "ignoredVolumeKeys")
        connectPrompt = nil
    }

    private func audit(_ category: AuditCategory, _ message: String, assetID: UUID? = nil, driveID: UUID? = nil) {
        let event = AuditEvent(id: UUID(), at: Date(), category: category, message: message, assetID: assetID, driveID: driveID)
        do {
            try catalog.appendAuditEvent(event)
        } catch {
            // The audit log is the record of what the app did to the archive;
            // losing entries silently would hide exactly the history a user
            // needs after an interrupted run.
            lastError = "Could not record audit event: \(error.localizedDescription)"
        }
        auditEvents.insert(event, at: 0)
    }

    // MARK: - Import

    func importFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        let existing = assets
        let rules = policyRules
        let stagingStore = staging
        let sourceDescription = urls.map(\.lastPathComponent).joined(separator: ", ")

        Task {
            let files = ImportService.mediaFileURLs(under: urls)
            let result = ImportService.importFiles(
                files,
                sourceDescription: sourceDescription,
                existingAssets: existing,
                policyRules: rules,
                staging: stagingStore
            )
            applyImportResult(result)
        }
    }

    /// Persists imported assets and queues their replication backlog.
    /// Local-resident assets owe a replica to every managed drive; sync
    /// happens whenever the drives appear. A drive whose replica is already
    /// satisfied by the import source itself (archive-backed, e.g. a Takeout
    /// folder on that drive) records the verified in-place replica instead of
    /// queuing a duplicate copy onto the same disk.
    @discardableResult
    private func persistImportedAssets(
        _ imported: [Asset],
        archiveBacked: [UUID: DriveReplicaState] = [:]
    ) throws -> [DriveReplicaState] {
        var written: [DriveReplicaState] = []
        for asset in imported {
            try catalog.upsertAsset(asset)
            if asset.residency == .local {
                for drive in drives {
                    if let backed = archiveBacked[asset.id], backed.driveID == drive.id {
                        try catalog.upsertReplicaState(backed)
                        written.append(backed)
                    } else {
                        try enqueueTask(assetID: asset.id, driveID: drive.id, action: .copy)
                        let pending = DriveReplicaState(
                            assetID: asset.id,
                            driveID: drive.id,
                            state: .pending,
                            relativePath: nil,
                            lastVerifiedAt: nil
                        )
                        try catalog.upsertReplicaState(pending)
                        written.append(pending)
                    }
                }
            }
        }
        return written
    }

    /// Publishes freshly imported assets to the UI immediately, without the
    /// full `loadAll()` round trip. A long import persists in chunks, and
    /// re-reading (and re-deriving over) the entire catalog after every chunk
    /// would be quadratic — this appends just what was added, so the Library
    /// fills in as files are hashed. Canonical ordering and full derived state
    /// are restored by the `loadAll()` at the end of the import.
    private func publishImportedAssets(_ imported: [Asset], replicas: [DriveReplicaState]) {
        guard !imported.isEmpty else { return }
        assets.append(contentsOf: imported)
        replicaStates.append(contentsOf: replicas)
        let replicasByAsset = Dictionary(grouping: replicas, by: \.assetID)
        for asset in imported {
            protectionStates[asset.id] = ProtectionEvaluator.protectionState(
                for: asset,
                replicaStates: replicasByAsset[asset.id] ?? []
            )
        }
    }

    private func applyImportResult(_ result: ImportResult) {
        do {
            try catalog.upsertImportBatch(result.batch)
            try persistImportedAssets(result.importedAssets)
            audit(.importEvent, "Imported \(result.importedAssets.count) asset(s) from \(result.batch.sourcePath) (\(result.duplicateFilenames.count) exact duplicate(s) skipped, \(result.failures.count) failure(s)).")
            if !result.failures.isEmpty {
                lastError = "Import finished with \(result.failures.count) failure(s): \(result.failures.first!.error)"
            }
        } catch {
            lastError = "Import persistence failed: \(error.localizedDescription)"
        }
        isImporting = false
        loadAll()
    }

    private func enqueueTask(assetID: UUID, driveID: UUID, action: ReplicationAction) throws {
        let task = ReplicationTask(
            id: UUID(),
            assetID: assetID,
            driveID: driveID,
            action: action,
            state: .queued,
            queuedAt: Date(),
            completedAt: nil,
            errorMessage: nil
        )
        try catalog.upsertReplicationTask(task)
    }

    // MARK: - Google Takeout

    /// Scans a root (drive mount or chosen folder) for Takeout exports and
    /// records new finds in the catalog. The archives themselves are left
    /// untouched wherever they live.
    func scanForTakeout(rootURL: URL, driveID: UUID?) {
        Task { await performTakeoutScan(rootURL: rootURL, driveID: driveID) }
    }

    private func performTakeoutScan(rootURL: URL, driveID: UUID?) async {
        guard takeoutActivity == nil else { return }
        takeoutActivity = TakeoutActivity(phase: .scanning, detail: rootURL.lastPathComponent)
        let knownByPath = Dictionary(uniqueKeysWithValues: takeoutArchives.map { ($0.path, $0) })

        // Reuse folder sizes recorded at discovery: re-measuring means walking
        // every file of every extracted Takeout folder (tens of thousands each).
        let knownFolderSizes = Dictionary(
            takeoutArchives.filter { $0.kind == .folder && $0.sizeBytes > 0 }.map { ($0.path, $0.sizeBytes) },
            uniquingKeysWith: { first, _ in first }
        )
        let found = await Task.detached(priority: .utility) {
            TakeoutScanner.scan(rootURL: rootURL, knownFolderSizes: knownFolderSizes)
        }.value
        var newCount = 0
        var refreshedCount = 0
        do {
            for discovered in found {
                    if var existing = knownByPath[discovered.path] {
                        // Re-scan refreshes what detection can learn (size,
                        // export-set grouping added after first discovery)
                        // without touching import state.
                        let changed = existing.sizeBytes != discovered.sizeBytes
                            || existing.exportSetID != discovered.exportSetID
                            || existing.partNumber != discovered.partNumber
                        if changed {
                            existing.sizeBytes = discovered.sizeBytes
                            existing.exportSetID = discovered.exportSetID
                            existing.partNumber = discovered.partNumber
                            try catalog.upsertTakeoutArchive(existing)
                            refreshedCount += 1
                        }
                    } else {
                        try catalog.upsertTakeoutArchive(TakeoutArchive(
                            id: UUID(),
                            path: discovered.path,
                            kind: discovered.kind,
                            sizeBytes: discovered.sizeBytes,
                            driveID: driveID,
                            discoveredAt: Date(),
                            importedAt: nil,
                            importBatchID: nil,
                            importedAssetCount: 0,
                            skippedDuplicateCount: 0,
                            note: nil,
                            exportSetID: discovered.exportSetID,
                            partNumber: discovered.partNumber
                        ))
                        newCount += 1
                    }
                }
            audit(.importEvent, "Takeout scan of \(rootURL.path): \(found.count) archive(s) found, \(newCount) new, \(refreshedCount) refreshed.", driveID: driveID)
        } catch {
            lastError = "Recording Takeout scan results failed: \(error.localizedDescription)"
        }
        takeoutActivity = nil
        loadAll()
    }

    func importTakeoutArchive(_ archiveID: UUID, assumeStillInGoogle: Bool) {
        importTakeoutArchives([archiveID], assumeStillInGoogle: assumeStillInGoogle)
    }

    /// Imports one or more discovered archives — typically the parts of one
    /// split-download export set — serially, as a single import batch with
    /// cross-part duplicate detection. When `assumeStillInGoogle` is true, the
    /// imported assets are marked present in Google Cloud too, and one
    /// GoogleCloud → Local migration job (already at Verifying Target) covers
    /// the whole set until the user confirms deletion from Google Photos.
    func importTakeoutArchives(_ archiveIDs: [UUID], assumeStillInGoogle: Bool) {
        Task { await performTakeoutImport(archiveIDs, assumeStillInGoogle: assumeStillInGoogle) }
    }

    private func performTakeoutImport(_ archiveIDs: [UUID], assumeStillInGoogle: Bool) async {
        guard !isImporting, takeoutActivity == nil else { return }
        let targets = takeoutArchives
            .filter { archiveIDs.contains($0.id) && !$0.isImported }
            .sorted { ($0.partNumber ?? Int.max) < ($1.partNumber ?? Int.max) }
        guard !targets.isEmpty else { return }

        let inaccessible = targets.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard inaccessible.isEmpty else {
            lastError = "Not accessible: \(inaccessible.map(\.displayName).joined(separator: ", ")) — connect the drive holding them first."
            return
        }

        isImporting = true
        let batchID = UUID()
        let setLabel = targets.count == 1
            ? "Takeout: \(targets[0].displayName)"
            : "Takeout export \(targets[0].exportSetID ?? "set") (\(targets.count) parts)"
        let stagingStore = staging
        let workArea = staging.rootURL.deletingLastPathComponent().appendingPathComponent("TakeoutWork", isDirectory: true)
        let startedAt = Date()

        // Maintained incrementally across chunks: rebuilding it per chunk from
        // the whole library made import cost quadratic in catalog size.
        var knownHashes = Set(assets.map(\.contentHash))
        var allImported: [Asset] = []
        var duplicateTotal = 0
        var failureTotal = 0
        var abortedAt: String?
        /// Covers the temporary Google+Local overlap; grown chunk by chunk.
        var overlapJobID: UUID?

        // Write the batch row before any asset references it. Previously this
        // happened only after every part finished, so an interrupted import
        // left thousands of assets pointing at a batch that did not exist.
        var batch = ImportBatch(
            id: batchID,
            sourcePath: setLabel,
            startedAt: startedAt,
            completedAt: nil,
            importedCount: 0,
            duplicateCount: 0,
            failedCount: 0
        )
        do {
            try catalog.upsertImportBatch(batch)
        } catch {
            lastError = "Could not open import batch: \(error.localizedDescription)"
            isImporting = false
            return
        }

        for (index, archiveConst) in targets.enumerated() {
            var archive = archiveConst
            takeoutActivity = TakeoutActivity(
                phase: archive.kind == .zip ? .extracting : .importing,
                detail: archive.displayName,
                stepIndex: index + 1,
                stepCount: targets.count,
                note: archive.kind == .zip ? "preparing workspace" : "reading from drive"
            )
            do {
                let workspace = try await Task.detached(priority: .utility) {
                    try TakeoutImporter.prepareWorkspace(for: archive, workArea: workArea)
                }.value
                // An extracted folder on a connected managed drive doubles as
                // that drive's replica — the disk already holds the bytes.
                let replicaContext: (driveID: UUID, mountPath: String)? = archive.kind == .folder
                    ? connectedMounts.first { archive.path.hasPrefix($0.value.path + "/") }
                        .map { (driveID: $0.key, mountPath: $0.value.path) }
                    : nil
                // Import the part in chunks so assets reach the catalog — and
                // the Library — while the rest of the part is still hashing.
                // A part can hold tens of thousands of files; waiting for the
                // whole part (let alone all parts) would leave the UI empty
                // for hours.
                let partFiles = await Task.detached(priority: .utility) {
                    TakeoutImporter.mediaFileURLs(in: workspace)
                }.value
                var partImported = archive.importedAssetCount
                var partDuplicates = archive.skippedDuplicateCount
                var partArchiveBackedCount = 0
                // Resume from the checkpoint when the part's file list is
                // unchanged; otherwise start over rather than trust an index
                // into a list that may have shifted.
                let resumeFrom = (archive.importedFileTotal == partFiles.count)
                    ? min(archive.importedThroughIndex, partFiles.count)
                    : 0
                if resumeFrom > 0 {
                    audit(.importEvent, "Resuming \(archive.displayName) after \(resumeFrom) already-processed file(s); \(partFiles.count - resumeFrom) remain.")
                }
                var processedFiles = resumeFrom

                for chunk in stride(from: resumeFrom, to: partFiles.count, by: Self.importChunkSize).map({
                    Array(partFiles[$0..<min($0 + Self.importChunkSize, partFiles.count)])
                }) {
                    let hashSnapshot = knownHashes
                    let result = await Task.detached(priority: .utility) {
                        TakeoutImporter.importMedia(
                            from: workspace,
                            archiveName: archive.displayName,
                            knownContentHashes: hashSnapshot,
                            staging: stagingStore,
                            assumeStillInGoogle: assumeStillInGoogle,
                            batchID: batchID,
                            replicaContext: replicaContext,
                            fileURLs: chunk
                        )
                    }.value

                    processedFiles += chunk.count
                    partImported += result.importedAssets.count
                    partDuplicates += result.duplicateFilenames.count

                    // One transaction per chunk: assets, their replica states,
                    // the batch counters, and the resume checkpoint either all
                    // land or none do. A crash mid-chunk can then only lose
                    // that chunk's work, never leave a half-written record.
                    var checkpoint = archive
                    checkpoint.importedThroughIndex = processedFiles
                    checkpoint.importedFileTotal = partFiles.count
                    checkpoint.importedAssetCount = partImported
                    checkpoint.skippedDuplicateCount = partDuplicates
                    batch.importedCount = allImported.count + result.importedAssets.count
                    batch.duplicateCount = duplicateTotal + result.duplicateFilenames.count
                    batch.failedCount = failureTotal + result.failures.count
                    let batchSnapshot = batch
                    let replicas = try catalog.transaction { () -> [DriveReplicaState] in
                        let written = try persistImportedAssets(
                            result.importedAssets,
                            archiveBacked: result.archiveBackedReplicas
                        )
                        try catalog.upsertImportBatch(batchSnapshot)
                        try catalog.upsertTakeoutArchive(checkpoint)
                        return written
                    }
                    archive = checkpoint
                    // When the user has stated the content is still in Google,
                    // the two-domain overlap must be covered by a migration job
                    // from the moment the first asset lands — otherwise an
                    // interrupted import strands assets in a state the
                    // violation scanner (correctly) calls illegal.
                    if assumeStillInGoogle, !result.importedAssets.isEmpty {
                        extendTakeoutMigration(
                            jobID: &overlapJobID,
                            with: result.importedAssets,
                            label: setLabel
                        )
                    }
                    publishImportedAssets(result.importedAssets, replicas: replicas)

                    knownHashes.formUnion(result.importedAssets.map(\.contentHash))
                    allImported.append(contentsOf: result.importedAssets)
                    partArchiveBackedCount += result.archiveBackedReplicas.count
                    duplicateTotal += result.duplicateFilenames.count
                    failureTotal += result.failures.count

                    takeoutActivity = TakeoutActivity(
                        phase: .importing,
                        detail: archive.displayName,
                        stepIndex: index + 1,
                        stepCount: targets.count,
                        itemIndex: processedFiles,
                        itemCount: partFiles.count,
                        note: "\(processedFiles) of \(partFiles.count) files · \(allImported.count) imported so far"
                    )
                }

                await Task.detached(priority: .utility) {
                    TakeoutImporter.cleanup(workspace)
                }.value

                archive.importedAt = Date()
                archive.importBatchID = batchID
                archive.importedAssetCount = partImported
                archive.skippedDuplicateCount = partDuplicates
                try catalog.upsertTakeoutArchive(archive)
                if partArchiveBackedCount > 0, let context = replicaContext {
                    let driveName = drivesByID[context.driveID]?.name ?? "drive"
                    audit(.replication, "\(partArchiveBackedCount) asset(s) from \(archive.displayName) use their Takeout files as the \(driveName) replica — no duplicate copy queued for that drive.", driveID: context.driveID)
                }
                audit(.importEvent, "\(archive.displayName): imported \(partImported) asset(s), \(partDuplicates) duplicate(s) skipped.")
            } catch {
                lastError = "Takeout import failed at \(archive.displayName): \(error.localizedDescription)"
                abortedAt = archive.displayName
                break
            }
        }

        do {
            // Finalise the batch opened before the first chunk.
            batch.completedAt = Date()
            batch.importedCount = allImported.count
            batch.duplicateCount = duplicateTotal
            batch.failedCount = failureTotal
            try catalog.upsertImportBatch(batch)
            var message = "Imported \(allImported.count) asset(s) from \(setLabel) (\(duplicateTotal) duplicate(s) skipped, \(failureTotal) failure(s))."
            if let abortedAt {
                message += " Aborted at \(abortedAt); already-imported parts are kept."
            }
            audit(.importEvent, message)
        } catch {
            lastError = "Import batch persistence failed: \(error.localizedDescription)"
        }

        isImporting = false
        takeoutActivity = nil
        loadAll()
    }

    /// Creates the covering GoogleCloud → Local job on the first chunk and
    /// extends it on every later chunk, so every asset carrying a stated
    /// cloud overlap is covered the instant it enters the catalog.
    private func extendTakeoutMigration(jobID: inout UUID?, with imported: [Asset], label: String) {
        do {
            if let existingID = jobID,
               var job = migrationJobs.first(where: { $0.id == existingID })
                   ?? (try? catalog.fetchMigrationJobs())?.first(where: { $0.id == existingID }) {
                job.assetIDs.append(contentsOf: imported.map(\.id))
                job.updatedAt = Date()
                try catalog.upsertMigrationJob(job)
                if let index = migrationJobs.firstIndex(where: { $0.id == job.id }) {
                    migrationJobs[index] = job
                } else {
                    migrationJobs.insert(job, at: 0)
                }
                return
            }
            var job = try MigrationService.createJob(
                assetIDs: imported.map(\.id),
                from: .googleCloud,
                to: .local,
                note: "Takeout import (\(label)). You stated these are still in Google Photos — the app cannot check that itself. Verify the local copies replicate to both drives, then delete the originals from Google to finish."
            )
            job = try MigrationService.start(job)
            let effect = try MigrationService.markTargetCopyComplete(job, assets: imported)
            try catalog.upsertMigrationJob(effect.job)
            migrationJobs.insert(effect.job, at: 0)
            jobID = effect.job.id
        } catch {
            lastError = "Could not track the Google overlap: \(error.localizedDescription)"
        }
    }

    /// Extracts zip parts in place on their drive (folder named
    /// zip-name-minus-.zip, joining the same export set). The zips stay
    /// untouched as pristine originals.
    func extractTakeoutZips(_ archiveIDs: [UUID]) {
        Task { await performTakeoutExtraction(archiveIDs) }
    }

    private func performTakeoutExtraction(_ archiveIDs: [UUID]) async {
        guard !isImporting, takeoutActivity == nil else { return }
        let targets = takeoutArchives.filter {
            archiveIDs.contains($0.id) && $0.kind == .zip && FileManager.default.fileExists(atPath: $0.path)
        }
        guard !targets.isEmpty else { return }

        for (index, archive) in targets.enumerated() {
            let workers = ParallelZipExtraction.recommendedWorkerCount(destination: archive.url)
            takeoutActivity = TakeoutActivity(
                phase: .extracting,
                detail: archive.displayName,
                stepIndex: index + 1,
                stepCount: targets.count,
                note: "\(workers) parallel worker(s)"
            )
            do {
                let folderURL = try await Task.detached(priority: .utility) {
                    try TakeoutExtractor.extractInPlace(zipURL: archive.url)
                }.value
                let size = await Task.detached(priority: .utility) {
                    TakeoutScanner.directorySize(of: folderURL)
                }.value
                let components = TakeoutArchive.parseExportComponents(filename: folderURL.lastPathComponent)
                try catalog.upsertTakeoutArchive(TakeoutArchive(
                    id: UUID(),
                    path: folderURL.path,
                    kind: .folder,
                    sizeBytes: size,
                    driveID: archive.driveID,
                    discoveredAt: Date(),
                    importedAt: nil,
                    importBatchID: nil,
                    importedAssetCount: 0,
                    skippedDuplicateCount: 0,
                    note: "Extracted in place from \(archive.displayName).",
                    exportSetID: components?.setID,
                    partNumber: components?.part
                ))
                audit(.importEvent, "Extracted \(archive.displayName) on its drive; imports will use the folder.", driveID: archive.driveID)
            } catch {
                // Keep going: a part that can't be extracted (e.g. space) can
                // still be imported from its zip via the Mac workspace.
                lastError = "Extraction failed at \(archive.displayName): \(error.localizedDescription)"
                audit(.importEvent, "Extraction of \(archive.displayName) failed (\(error.localizedDescription)); its zip will be imported the slower way.", driveID: archive.driveID)
            }
        }
        takeoutActivity = nil
        loadAll()
    }

    /// True when every asset of the batch is safe without its source archive:
    /// Local assets fully replicated to both drives (cloud-resident assets
    /// don't depend on local copies).
    func isBatchFullyReplicated(_ batchID: UUID?) -> Bool {
        guard let batchID else { return false }
        let batchAssets = assets.filter { $0.importBatchID == batchID }
        guard !batchAssets.isEmpty else { return false }
        return batchAssets.allSatisfy { asset in
            asset.residency != .local || protectionStates[asset.id] == .fullyReplicated
        }
    }

    /// Deletes an imported, fully-replicated extracted folder from its drive
    /// to reclaim space. The zip original is kept; if a zip twin exists for
    /// the same part, the import state transfers to it so the export set
    /// still reads as imported. Destructive — the UI confirms first.
    func deleteExtractedTakeoutFolder(_ archiveID: UUID) {
        guard let archive = takeoutArchives.first(where: { $0.id == archiveID }),
              archive.kind == .folder, archive.isImported else { return }
        guard FileManager.default.fileExists(atPath: archive.path) else {
            lastError = "Folder is not accessible — is the drive connected?"
            return
        }
        guard isBatchFullyReplicated(archive.importBatchID) else {
            lastError = "Not deleting \(archive.displayName): its imported assets are not yet fully replicated to both drives."
            return
        }
        // A folder whose files serve as a drive's archive-backed replicas is
        // load-bearing storage, not a redundant copy — deleting it would
        // destroy that drive's only copy of those assets.
        if let (driveID, mount) = connectedMounts.first(where: { archive.path.hasPrefix($0.value.path + "/") }) {
            let folderRelative = ReplicationService.volumeBackedPrefix
                + String(archive.path.dropFirst(mount.path.count + 1))
            let backingCount = replicaStates.filter {
                $0.driveID == driveID && $0.state == .present && ($0.relativePath?.hasPrefix(folderRelative) ?? false)
            }.count
            if backingCount > 0 {
                lastError = "Not deleting \(archive.displayName): its files are the \(drivesByID[driveID]?.name ?? "drive") replica for \(backingCount) asset(s). It is storage, not a redundant copy."
                return
            }
        }
        do {
            try FileManager.default.removeItem(at: archive.url)
            if archive.exportSetID != nil,
               var twin = takeoutArchives.first(where: {
                   $0.exportSetID == archive.exportSetID && $0.partNumber == archive.partNumber && $0.kind == .zip
               }),
               !twin.isImported {
                twin.importedAt = archive.importedAt
                twin.importBatchID = archive.importBatchID
                twin.importedAssetCount = archive.importedAssetCount
                twin.skippedDuplicateCount = archive.skippedDuplicateCount
                twin.note = "Imported via its extracted folder (folder deleted after replication)."
                try catalog.upsertTakeoutArchive(twin)
            }
            try catalog.deleteTakeoutArchive(id: archive.id)
            audit(.system, "Deleted extracted folder \(archive.displayName) after verified replication; zip original retained.", driveID: archive.driveID)
            loadAll()
        } catch {
            lastError = "Folder deletion failed: \(error.localizedDescription)"
        }
    }

    /// The zero-button path, run whenever a managed drive connects:
    /// 1. Scan it for Takeout exports.
    /// 2. Reconcile content the catalog already knows, where this drive lacks
    ///    replicas of it.
    /// 3. Extract zips for genuinely new parts (space permitting).
    /// 4. Import whatever the catalog has never seen, the drive's own Takeout
    ///    files serving as its replicas.
    private func autoTakeoutPipeline(driveID: UUID) async {
        guard let mount = connectedMounts[driveID] else { return }
        guard !takeoutPipelineActiveDriveIDs.contains(driveID),
              !takeoutPipelineCompletedDriveIDs.contains(driveID)
        else { return }
        takeoutPipelineActiveDriveIDs.insert(driveID)
        defer {
            takeoutPipelineActiveDriveIDs.remove(driveID)
            takeoutPipelineCompletedDriveIDs.insert(driveID)
        }

        await performTakeoutScan(rootURL: mount, driveID: driveID)
        guard autoManageTakeout else { return }

        func onDrive() -> [TakeoutArchive] {
            takeoutArchives.filter { $0.path.hasPrefix(mount.path + "/") }
        }
        // Sets span drives: drive B's part 3 zip and drive A's imported part 3
        // folder are the same content.
        func globalSets() -> [String: [TakeoutArchive]] {
            Dictionary(grouping: takeoutArchives.filter { $0.exportSetID != nil }) { $0.exportSetID! }
        }
        func partImportedSomewhere(_ archive: TakeoutArchive) -> Bool {
            guard let setID = archive.exportSetID else { return false }
            return globalSets()[setID]?.contains {
                $0.partNumber == archive.partNumber && $0.isImported
            } ?? false
        }

        // 2. Reconcile known content present on this drive — but only where it
        // could actually claim something. Reconciliation exists for a drive
        // that LACKS replicas of content the catalog already knows; when this
        // drive is the one the content was imported from, its files already
        // back those replicas and re-hashing them (or fingerprinting a 10 GB
        // zip twin) would claim nothing at great cost.
        func driveIsMissingReplicas() -> Bool {
            let present = Set(
                replicaStates.filter { $0.driveID == driveID && $0.state == .present }.map(\.assetID)
            )
            return assets.contains { $0.residency == .local && !present.contains($0.id) }
        }
        func partAlreadyBackedByThisDrive(_ archive: TakeoutArchive) -> Bool {
            guard let setID = archive.exportSetID else { return false }
            return takeoutArchives.contains { twin in
                twin.exportSetID == setID
                    && twin.partNumber == archive.partNumber
                    && twin.isImported
                    && twin.driveID == driveID
            }
        }

        if driveIsMissingReplicas() {
            for archive in onDrive() where !archive.isImported
                && partImportedSomewhere(archive)
                && !partAlreadyBackedByThisDrive(archive) {
                await performTakeoutReconciliation(archive, driveID: driveID, mountURL: mount)
                if !driveIsMissingReplicas() { break }
            }
        }

        // 3. Extract zips for new parts only.
        let extractable = onDrive().filter { archive in
            guard archive.kind == .zip, !archive.isImported, !partImportedSomewhere(archive) else { return false }
            if FileManager.default.fileExists(atPath: TakeoutExtractor.destinationURL(forZip: archive.url).path) {
                return false
            }
            if let setID = archive.exportSetID,
               let siblings = globalSets()[setID],
               siblings.contains(where: { $0.partNumber == archive.partNumber && $0.kind == .folder }) {
                return false
            }
            return true
        }
        if !extractable.isEmpty {
            await performTakeoutExtraction(extractable.map(\.id))
            await performTakeoutScan(rootURL: mount, driveID: driveID)
        }

        // 4. Import genuinely new content, folders preferred per part.
        let currentSets = Dictionary(grouping: onDrive().filter { $0.exportSetID != nil }) { $0.exportSetID! }
            .map { TakeoutExportSet(setID: $0.key, parts: $0.value) }
        var toImport = currentSets.flatMap(\.unimportedPreferredParts)
            .filter { !partImportedSomewhere($0) }
        toImport += onDrive().filter { $0.exportSetID == nil && !$0.isImported }
        if !toImport.isEmpty {
            // Never assume cloud presence: the app has no Google or Apple
            // account connection and cannot check. Automatic imports record
            // Local presence only — which is the one thing hashing proves.
            await performTakeoutImport(toImport.map(\.id), assumeStillInGoogle: false)
        }

        // Zips are deliberately NOT fingerprinted here: hashing every zip on a
        // drive is ~128 GB of reads for a benefit only a future second drive
        // might need. Fingerprints are computed lazily, for the one or two
        // candidate donors involved in an actual reconciliation.
        loadAll()
    }

    /// Fingerprints a zip on demand (one sequential read), caching the hash.
    @discardableResult
    private func fingerprintZipIfNeeded(_ archive: TakeoutArchive) async -> String? {
        if let existing = archive.contentHash { return existing }
        guard archive.kind == .zip, FileManager.default.fileExists(atPath: archive.path) else { return nil }
        var updated = archive
        let previousActivity = takeoutActivity
        takeoutActivity = TakeoutActivity(
            phase: .fingerprinting, detail: archive.displayName, note: "one sequential read"
        )
        let hash = try? await Task.detached(priority: .utility, operation: {
            try HashingService.sha256(of: updated.url)
        }).value
        takeoutActivity = previousActivity
        guard let hash else { return nil }
        updated.contentHash = hash
        try? catalog.upsertTakeoutArchive(updated)
        if let index = takeoutArchives.firstIndex(where: { $0.id == updated.id }) {
            takeoutArchives[index] = updated
        }
        return hash
    }

    /// Claims a drive's existing Takeout content as its replicas (hash-verified
    /// in place, read-only) and settles the now-redundant copy backlog.
    private func performTakeoutReconciliation(_ archiveConst: TakeoutArchive, driveID: UUID, mountURL: URL) async {
        guard takeoutActivity == nil, !isImporting else { return }
        var archive = archiveConst
        let driveName = drivesByID[driveID]?.name ?? "drive"
        takeoutActivity = TakeoutActivity(
            phase: .reconciling, detail: archive.displayName, note: "on \(driveName)"
        )

        let assetIDsByHash = Dictionary(assets.map { ($0.contentHash, $0.id) }, uniquingKeysWith: { first, _ in first })
        let present = Set(replicaStates.filter { $0.driveID == driveID && $0.state == .present }.map(\.assetID))
        let needing = Set(assets.filter { $0.residency == .local && !present.contains($0.id) }.map(\.id))

        var usedFastPath = false
        let result: TakeoutReconciler.Result
        if archive.kind == .folder {
            result = await Task.detached(priority: .utility) {
                TakeoutReconciler.reconcileFolder(
                    folderURL: archive.url, mountURL: mountURL, driveID: driveID,
                    assetIDsByHash: assetIDsByHash, assetsNeedingReplica: needing
                )
            }.value
        } else {
            // Checksum fast path: fingerprint this zip and only the handful of
            // plausible donors (same export set and part), rather than every
            // zip the catalog knows about.
            archive.contentHash = await fingerprintZipIfNeeded(archive)
            let zipRelative = String(archive.path.dropFirst(mountURL.path.count + 1))
            let folderTwins = takeoutArchives.filter {
                $0.kind == .folder && $0.exportSetID != nil
                    && $0.exportSetID == archive.exportSetID && $0.partNumber == archive.partNumber
            }
            var donors: [TakeoutArchive] = []
            for candidate in takeoutArchives where candidate.id != archive.id
                && candidate.kind == .zip
                && candidate.exportSetID == archive.exportSetID
                && candidate.partNumber == archive.partNumber {
                var donor = candidate
                donor.contentHash = await fingerprintZipIfNeeded(candidate)
                donors.append(donor)
            }
            if let zipHash = archive.contentHash,
               let fast = TakeoutReconciler.fastReconcileZip(
                   zipHash: zipHash,
                   zipRelativePath: zipRelative,
                   driveID: driveID,
                   candidateDonors: donors,
                   folderTwins: folderTwins,
                   replicaStates: replicaStates,
                   assetsNeedingReplica: needing
               ) {
                result = fast
                usedFastPath = true
            } else {
                takeoutActivity = TakeoutActivity(
                    phase: .reconciling, detail: archive.displayName, note: "entry-by-entry on \(driveName)"
                )
                result = await Task.detached(priority: .utility) {
                    TakeoutReconciler.reconcileZip(
                        zipURL: archive.url, mountURL: mountURL, driveID: driveID,
                        assetIDsByHash: assetIDsByHash, assetsNeedingReplica: needing
                    )
                }.value
            }
        }

        do {
            for replica in result.claimedReplicas {
                try catalog.upsertReplicaState(replica)
            }
            try settleQueuedCopyTasks(assetIDs: Set(result.claimedReplicas.map(\.assetID)), driveID: driveID)
            archive.importedAt = Date()
            archive.importedAssetCount = result.claimedReplicas.count
            archive.note = "Reconciled: existing content on \(driveName) claimed as \(result.claimedReplicas.count) verified replica(s); nothing was copied."
            try catalog.upsertTakeoutArchive(archive)
            let method = usedFastPath ? "checksum match with a known identical zip" : "in-place hashing"
            audit(.replication, "\(archive.displayName) on \(driveName): \(result.claimedReplicas.count) of \(result.scannedFileCount) file(s) claimed as in-place replicas via \(method); queued copies cancelled.", driveID: driveID)
        } catch {
            lastError = "Reconciliation persistence failed: \(error.localizedDescription)"
        }
        takeoutActivity = nil
        loadAll()
    }

    /// Marks queued copy tasks for these assets on this drive as completed —
    /// their replica is satisfied in place, so nothing needs copying.
    private func settleQueuedCopyTasks(assetIDs: Set<UUID>, driveID: UUID) throws {
        let settled = replicationTasks.filter {
            $0.driveID == driveID && $0.action == .copy && $0.state == .queued && assetIDs.contains($0.assetID)
        }
        for var task in settled {
            task.state = .completed
            task.completedAt = Date()
            try catalog.upsertReplicationTask(task)
        }
    }

    /// Withdraws unverified cloud presence from Takeout-imported assets.
    /// Earlier builds assumed content was still in Google and wrote that onto
    /// every import; nothing ever checked it. This clears the claim (and any
    /// migration job that only existed to cover it), leaving Local presence —
    /// the one thing hashing proves.
    func clearUnverifiedCloudPresence(domain: ResidencyDomain) {
        guard domain != .local else { return }
        let affected = assets.filter {
            $0.presence.contains(domain) && $0.cloudPresenceEvidence != .verified
        }
        guard !affected.isEmpty else { return }
        do {
            for var asset in affected {
                asset.presence.set(domain, false)
                asset.cloudPresenceEvidence = .none
                asset.cloudPresenceCheckedAt = nil
                if asset.residency == domain {
                    // Residency must follow the content that actually exists.
                    asset.residency = .local
                    asset.residencySource = .manual
                }
                asset.updatedDate = Date()
                try catalog.upsertAsset(asset)
            }
            let affectedIDs = Set(affected.map(\.id))
            for job in migrationJobs where job.state.isActive
                && job.fromDomain == domain
                && job.assetIDs.allSatisfy({ affectedIDs.contains($0) }) {
                try catalog.upsertMigrationJob(
                    MigrationService.fail(job, reason: "\(domain.displayName) presence was never verified and has been withdrawn")
                )
            }
            audit(.violation, "Withdrew unverified \(domain.displayName) presence from \(affected.count) asset(s); the app has no \(domain.displayName) connection and never confirmed it.")
            loadAll()
        } catch {
            lastError = "Could not clear unverified cloud presence: \(error.localizedDescription)"
        }
    }

    /// Assets carrying a cloud claim the app never verified.
    func unverifiedCloudPresenceCount(domain: ResidencyDomain) -> Int {
        assets.filter { $0.presence.contains(domain) && $0.cloudPresenceEvidence != .verified }.count
    }

    func forgetTakeoutArchive(_ archiveID: UUID) {
        do {
            try catalog.deleteTakeoutArchive(id: archiveID)
            loadAll()
        } catch {
            lastError = "Could not forget archive: \(error.localizedDescription)"
        }
    }

    // MARK: - Drives

    func registerDrive(volume: VolumeInfo, name: String) {
        let driveID = UUID()
        let token = UUID().uuidString
        let marker = DriveMarker(driveID: driveID, markerToken: token, appName: "heykinn-clicks")
        do {
            try DriveMonitor.writeMarker(marker, to: volume.url)
            let drive = ManagedDrive(
                id: driveID,
                name: name.isEmpty ? volume.name : name,
                volumeUUID: volume.volumeUUID,
                markerToken: token,
                registeredAt: Date(),
                lastSeenAt: Date(),
                replicaRootComponent: ManagedDrive.defaultReplicaRoot
            )
            try catalog.upsertDrive(drive)
            // Every existing Local asset owes this new drive a replica.
            for asset in assets where asset.residency == .local {
                try enqueueTask(assetID: asset.id, driveID: driveID, action: .copy)
                try catalog.upsertReplicaState(DriveReplicaState(
                    assetID: asset.id,
                    driveID: driveID,
                    state: .pending,
                    relativePath: nil,
                    lastVerifiedAt: nil
                ))
            }
            audit(.drive, "Registered drive \(drive.name); backlog seeded for existing Local assets.", driveID: driveID)
            loadAll()
            rescanDrives()
        } catch {
            lastError = "Drive registration failed: \(error.localizedDescription)"
        }
    }

    func backlogCount(for driveID: UUID) -> Int {
        replicationTasks.filter { $0.driveID == driveID && $0.state == .queued }.count
    }

    func lastCompletedSync(for driveID: UUID) -> Date? {
        replicationTasks
            .filter { $0.driveID == driveID && $0.state == .completed }
            .compactMap(\.completedAt)
            .max()
    }

    /// Requests a backlog sync for one connected drive. If another drive is
    /// already syncing, the request queues behind it (syncs stay serial).
    func syncDrive(_ driveID: UUID) {
        if isSyncing {
            if syncProgress?.driveID != driveID && !pendingSyncDriveIDs.contains(driveID) {
                pendingSyncDriveIDs.append(driveID)
            }
            return
        }
        runSync(driveID)
    }

    /// Stops the running sync after the current task finishes. Remaining tasks
    /// stay queued, so the next sync resumes exactly where this one stopped.
    func cancelSync() {
        syncCancelRequested = true
    }

    private func runSync(_ driveID: UUID) {
        guard syncProgress == nil else { return }
        guard let drive = drivesByID[driveID], let mountURL = connectedMounts[driveID] else {
            lastError = "Drive is not connected."
            startNextPendingSync()
            return
        }
        let queued = replicationTasks
            .filter { $0.driveID == driveID && $0.state == .queued }
            .sorted { $0.queuedAt < $1.queuedAt }
        guard !queued.isEmpty else {
            startNextPendingSync()
            return
        }

        syncCancelRequested = false
        syncProgress = SyncProgress(
            driveID: driveID,
            driveName: drive.name,
            totalTasks: queued.count,
            completedTasks: 0,
            failedTasks: 0,
            currentItem: nil
        )
        let assetsSnapshot = assetsByID
        let replicasByKey = Dictionary(uniqueKeysWithValues: replicaStates.map { ($0.id, $0) })

        Task { @MainActor in
            var completed = 0
            var failed = 0
            var interruptionReason: String?

            for task in queued {
                if syncCancelRequested {
                    interruptionReason = "cancelled"
                    break
                }
                // Mount events update connectedMounts on the main actor between
                // tasks, so an unplug mid-sync is noticed here.
                guard connectedMounts[driveID] != nil else {
                    interruptionReason = "drive disconnected"
                    break
                }
                let asset = assetsSnapshot[task.assetID]
                let existingReplica = replicasByKey["\(task.assetID.uuidString)/\(task.driveID.uuidString)"]
                syncProgress?.currentItem = asset?.originalFilename
                // Source can be Mac staging or any readable copy on another
                // connected drive, so drive-only assets replicate drive-to-drive.
                let sourceURL = asset.flatMap { localFileURL(for: $0) }
                let result = await Task.detached(priority: .utility) {
                    ReplicationService.perform(task, drive: drive, mountURL: mountURL, asset: asset, sourceURL: sourceURL, existingReplica: existingReplica)
                }.value
                do {
                    try catalog.upsertReplicationTask(result.task)
                    if let replica = result.replica {
                        try catalog.upsertReplicaState(replica)
                    }
                } catch {
                    lastError = "Sync persistence failed: \(error.localizedDescription)"
                }
                if result.task.state == .completed { completed += 1 } else { failed += 1 }
                syncProgress?.completedTasks = completed
                syncProgress?.failedTasks = failed
            }

            if var updatedDrive = drivesByID[driveID] {
                updatedDrive.lastSeenAt = Date()
                try? catalog.upsertDrive(updatedDrive)
            }
            let remaining = queued.count - completed - failed
            var summary = "Sync with \(drive.name): \(completed) task(s) completed, \(failed) failed"
            if let reason = interruptionReason {
                summary += "; \(reason) with \(remaining) task(s) still queued"
            }
            audit(.replication, summary + ".", driveID: driveID)
            syncProgress = nil
            loadAll()
            startNextPendingSync()
        }
    }

    private func startNextPendingSync() {
        while !pendingSyncDriveIDs.isEmpty {
            let next = pendingSyncDriveIDs.removeFirst()
            if connectedMounts[next] != nil && backlogCount(for: next) > 0 {
                runSync(next)
                return
            }
        }
    }

    /// Queues a verify pass over every replica expected on the drive, then runs it.
    func verifyDrive(_ driveID: UUID) {
        guard let drive = drivesByID[driveID], connectedMounts[driveID] != nil else {
            lastError = "Drive is not connected."
            return
        }
        do {
            let expected = replicaStates.filter {
                $0.driveID == driveID && ($0.state == .present || $0.state == .stale || $0.state == .drift)
            }
            for replica in expected {
                try enqueueTask(assetID: replica.assetID, driveID: driveID, action: .verify)
            }
            audit(.drive, "Queued verification of \(expected.count) replica(s) on \(drive.name).", driveID: driveID)
            loadAll()
            syncDrive(driveID)
        } catch {
            lastError = "Verification enqueue failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Residency

    func setManualResidency(assetID: UUID, to domain: ResidencyDomain) {
        guard var asset = assetsByID[assetID] else { return }
        let previous = asset.residency
        guard previous != domain else { return }
        // Direct manual reassignment only flips the logical domain; physical
        // presence is unchanged, so the violation scanner will surface the
        // resulting mismatch until a migration actually moves the bytes.
        asset.residency = domain
        asset.residencySource = .manual
        asset.updatedDate = Date()
        do {
            try catalog.upsertAsset(asset)
            audit(.policy, "Manual residency override for \(asset.originalFilename): \(previous.displayName) → \(domain.displayName).", assetID: assetID)
            loadAll()
        } catch {
            lastError = "Residency update failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Policies

    func savePolicyRule(_ rule: PolicyRule) {
        do {
            try catalog.upsertPolicyRule(rule)
            audit(.policy, "Saved policy rule \(rule.name) → \(rule.targetResidency.displayName).")
            loadAll()
        } catch {
            lastError = "Policy save failed: \(error.localizedDescription)"
        }
    }

    func deletePolicyRule(_ rule: PolicyRule) {
        do {
            try catalog.deletePolicyRule(id: rule.id)
            audit(.policy, "Deleted policy rule \(rule.name).")
            loadAll()
        } catch {
            lastError = "Policy delete failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Migrations

    func createMigration(assetIDs: [UUID], from source: ResidencyDomain, to target: ResidencyDomain, note: String?) {
        do {
            let job = try MigrationService.createJob(assetIDs: assetIDs, from: source, to: target, note: note)
            try catalog.upsertMigrationJob(job)
            audit(.migration, "Created migration \(source.displayName) → \(target.displayName) for \(assetIDs.count) asset(s).")
            loadAll()
        } catch {
            lastError = "Migration creation failed: \(error.localizedDescription)"
        }
    }

    func startMigration(_ job: MigrationJob) {
        applyJobTransition { try MigrationService.start(job) }
    }

    func markMigrationTargetCopied(_ job: MigrationJob) {
        do {
            let effect = try MigrationService.markTargetCopyComplete(job, assets: assets)
            try applyEffect(effect)
        } catch {
            lastError = "Migration transition failed: \(error.localizedDescription)"
        }
    }

    func markMigrationTargetVerified(_ job: MigrationJob) {
        applyJobTransition { try MigrationService.markTargetVerified(job) }
    }

    /// Destructive step — callers must confirm with the user first.
    func completeMigrationCleanup(_ job: MigrationJob) {
        do {
            let effect = try MigrationService.completeCleanup(
                job,
                assets: assets,
                managedDrives: drives,
                replicaStates: replicaStates
            )
            try applyEffect(effect)
        } catch {
            lastError = "Migration cleanup failed: \(error.localizedDescription)"
        }
    }

    func failMigration(_ job: MigrationJob, reason: String) {
        let failed = MigrationService.fail(job, reason: reason)
        do {
            try catalog.upsertMigrationJob(failed)
            audit(.migration, "Migration \(job.fromDomain.displayName) → \(job.toDomain.displayName) marked failed: \(reason)")
            loadAll()
        } catch {
            lastError = "Migration update failed: \(error.localizedDescription)"
        }
    }

    private func applyJobTransition(_ transition: () throws -> MigrationJob) {
        do {
            let updated = try transition()
            try catalog.upsertMigrationJob(updated)
            audit(.migration, "Migration \(updated.fromDomain.displayName) → \(updated.toDomain.displayName) advanced to \(updated.state.displayName).")
            loadAll()
        } catch {
            lastError = "Migration transition failed: \(error.localizedDescription)"
        }
    }

    private func applyEffect(_ effect: MigrationService.TransitionEffect) throws {
        try catalog.upsertMigrationJob(effect.job)
        for asset in effect.updatedAssets {
            try catalog.upsertAsset(asset)
        }
        for task in effect.replicationTasks {
            try catalog.upsertReplicationTask(task)
        }
        audit(.migration, effect.auditMessage)
        loadAll()
    }

    // MARK: - Sample-data hooks (used by SampleData seeding)

    func directCatalogAccess() -> CatalogStore { catalog }
}
