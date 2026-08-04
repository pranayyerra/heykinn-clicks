import Foundation
import SwiftUI

/// Single observable source of truth for the UI, backed by the on-Mac catalog.
/// The Mac is the control plane: everything here loads and works with zero
/// targets attached.
@MainActor
final class AppStore: ObservableObject {

    // Catalog-backed state
    @Published private(set) var assets: [Asset] = []
    @Published private(set) var targets: [ReplicationTarget] = []
    @Published private(set) var replicaStates: [TargetReplicaState] = []
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
    /// What each drive holds, tallied once per catalog change rather than
    /// re-filtered by every view that draws a drive.
    @Published private(set) var driveBreakdowns: [UUID: DriveContentBreakdown] = [:]
    /// A Merkle tree per target over what the catalog records it holding, so
    /// "do these two targets agree?" costs one comparison instead of a sweep.
    @Published private(set) var targetTrees: [UUID: MerkleTree] = [:]
    /// The few directories a target's recorded paths hang from.
    private var targetAnchors: [UUID: Set<String>] = [:]
    /// When each target's anchors were last confirmed present.
    private var lastAnchorCheck: [UUID: Date] = [:]
    /// Batches whose every asset is safe without its source archive.
    @Published private(set) var fullyReplicatedBatchIDs: Set<UUID> = []

    // Operational state
    @Published private(set) var syncProgress: SyncProgress?
    @Published var isImporting = false
    @Published private(set) var takeoutActivity: TakeoutActivity?
    @Published var lastError: String?
    @Published var autoSyncOnConnect: Bool = true {
        didSet { defaults.set(autoSyncOnConnect, forKey: "autoSyncOnConnect") }
    }
    /// When a managed drive connects, scan → extract → import its Takeout
    /// exports without any clicks, using the Takeout files as that drive's
    /// replicas.
    @Published var autoManageTakeout: Bool = true {
        didSet { defaults.set(autoManageTakeout, forKey: "autoManageTakeout") }
    }
    /// Reading a small ration of files in the background, which is the only way
    /// rot is ever found. On by default: an archive nobody reads is one whose
    /// damage is discovered when it is needed.
    @Published var backgroundRotPatrol: Bool = true {
        didSet { defaults.set(backgroundRotPatrol, forKey: "backgroundRotPatrol") }
    }

    var isSyncing: Bool { syncProgress != nil }

    /// How many targets should hold each Local asset. Read wherever redundancy
    /// is judged, so the number is stated once — and set by the user, because
    /// it governs how safe their archive is and how many targets they may
    /// register. A number the app enforces but never shows is worse than no
    /// rule at all.
    /// The most copies the policy may ask for: you cannot keep more copies
    /// than you have places to put them. Registering a target raises this.
    var maxSettableCopies: Int { max(targets.count, 1) }

    @Published var redundancyPolicy: LocalRedundancyPolicy = .default {
        didSet {
            defaults.set(redundancyPolicy.desiredCopies, forKey: "desiredCopies")
            // Protection is judged against this number, so every verdict in
            // the app changes the moment it does.
            recomputeDerivedState()
            audit(.policy, "Redundancy policy set to \(redundancyPolicy.description) per Local photo.")
        }
    }

    /// An unmanaged external volume just appeared; the UI asks whether to use
    /// it as managed local storage (and/or scan it for Takeout).
    @Published var connectPrompt: VolumeInfo?

    private var syncCancelRequested = false
    /// Drives waiting their turn while another drive syncs (syncs are serial).
    private var pendingSyncTargetIDs: [UUID] = []
    /// Volumes already prompted this session — one ask per appearance.
    private var promptedVolumeKeys: Set<String> = []
    /// Drives whose auto-Takeout pipeline is running or already finished this
    /// session. A transient volume-metadata hiccup can otherwise look like a
    /// reconnect and restart the whole (very expensive) pipeline.
    private var takeoutPipelineActiveTargetIDs: Set<UUID> = []
    private var takeoutPipelineCompletedTargetIDs: Set<UUID> = []
    /// Files per import chunk. Each chunk is scanned in parallel and then
    /// committed, so this also sets how often the Library and progress bar
    /// refresh — small enough to feel live, large enough to amortise the
    /// per-chunk commit.
    private static let importChunkSize = 100
    private var ignoredVolumeKeys: Set<String> = []

    private let defaults: UserDefaults
    let staging: StagingStore
    /// Where export parts wait while travelling between targets that are never
    /// plugged in at the same time.
    let relay: ExportPartRelay
    let targetMonitor: TargetMonitor
    let thumbnails: ThumbnailCache
    private let catalog: CatalogStore
    /// Thumbnail work already running, keyed by asset. Fast scrolling asks for
    /// the same image repeatedly; without this each ask would start its own
    /// read of the original off the drive.
    private var thumbnailTasks: [UUID: Task<NSImage?, Never>] = [:]

    /// Cached thumbnail, generating it from a reachable copy if needed.
    /// Returns nil only when nothing is cached and no source is reachable —
    /// e.g. a drive-resident asset, never viewed, with the drive unplugged.
    func thumbnail(for asset: Asset) async -> NSImage? {
        if let hit = thumbnails.cachedInMemory(asset.id) { return hit }
        if let running = thumbnailTasks[asset.id] { return await running.value }

        let cache = thumbnails
        let sourceURL = localFileURL(for: asset)
        let assetID = asset.id

        // Photos the app does not hold have no file to read: their pictures
        // come from the provider, which serves thumbnails locally without
        // downloading originals. Bytes the archive holds come first, though —
        // once a library photo has been brought in it has a file, and asking
        // PhotoKit instead would draw it as a placeholder in any build that
        // has not been granted Photos access.
        if sourceURL == nil, let providerLocalID = asset.providerLocalID {
            let task = Task<NSImage?, Never> {
                guard let image = await ApplePhotosVerifier.thumbnail(forLocalIdentifier: providerLocalID) else { return nil }
                cache.store(image, for: assetID)
                return image
            }
            thumbnailTasks[asset.id] = task
            let image = await task.value
            thumbnailTasks[asset.id] = nil
            return image
        }

        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            await cache.thumbnail(for: assetID, sourceURL: sourceURL)
        }
        thumbnailTasks[asset.id] = task
        let image = await task.value
        thumbnailTasks[asset.id] = nil
        return image
    }

    var reachablePaths: [UUID: URL] { targetMonitor.reachablePaths }
    var availableVolumes: [VolumeInfo] { targetMonitor.availableVolumes }

    /// Maintained alongside `assets`/`replicaStates` rather than rebuilt on
    /// access: these are read from view bodies, and rebuilding a
    /// tens-of-thousands-entry dictionary per read stalled rendering.
    @Published private(set) var assetsByID: [UUID: Asset] = [:]
    @Published private(set) var replicasByAssetID: [UUID: [TargetReplicaState]] = [:]

    var targetsByID: [UUID: ReplicationTarget] {
        Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
    }

    private func rebuildIndexes() {
        assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        replicasByAssetID = Dictionary(grouping: replicaStates, by: \.assetID)
        livePhotoMotionByStillID = Dictionary(
            assets.compactMap { asset in asset.livePhotoStillID.map { ($0, asset) } },
            uniquingKeysWith: { first, _ in first }
        )
        editsByOriginalID = Dictionary(
            grouping: assets.filter { $0.editedFromAssetID != nil },
            by: { $0.editedFromAssetID! }
        )
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
        for replica in replicasByAssetID[asset.id] ?? [] where replica.state == .present {
            guard let mountURL = reachablePaths[replica.targetID],
                  let drive = targetsByID[replica.targetID],
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

    convenience init() {
        self.init(environment: .production())
    }

    init(environment: AppEnvironment) {
        let appDirectory = environment.appDirectory
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        defaults = environment.defaults
        staging = StagingStore(rootURL: appDirectory.appendingPathComponent("Staging", isDirectory: true))
        relay = ExportPartRelay(rootURL: appDirectory.appendingPathComponent("ExportPartRelay", isDirectory: true))
        targetMonitor = TargetMonitor()
        thumbnails = environment.runsBackgroundWork
            ? ThumbnailCache.defaultCache()
            : ThumbnailCache(directory: appDirectory.appendingPathComponent("Thumbnails", isDirectory: true))

        do {
            catalog = try CatalogStore(databasePath: appDirectory.appendingPathComponent("catalog.sqlite").path)
        } catch {
            fatalError("Could not open catalog database: \(error)")
        }

        // Read before `loadAll`, which clamps the redundancy policy and so
        // needs the stored one. Assignments in an initialiser do not fire
        // `didSet`, so nothing is written back on the way in.
        let stored = environment.defaults
        autoSyncOnConnect = stored.object(forKey: "autoSyncOnConnect") as? Bool ?? true
        autoManageTakeout = stored.object(forKey: "autoManageTakeout") as? Bool ?? true
        backgroundRotPatrol = stored.object(forKey: "backgroundRotPatrol") as? Bool ?? true
        importFromApplePhotos = stored.object(forKey: "importFromApplePhotos") as? Bool ?? true
        iCloudPhotosEnabled = stored.object(forKey: "iCloudPhotosEnabled") as? Bool
        ignoredVolumeKeys = Set(stored.stringArray(forKey: "ignoredVolumeKeys") ?? [])
        redundancyPolicy = LocalRedundancyPolicy(
            desiredCopies: stored.object(forKey: "desiredCopies") as? Int
                ?? LocalRedundancyPolicy.default.desiredCopies
        )

        loadAll()

        targetMonitor.rescanRequested = { [weak self] in
            self?.rescanTargets()
        }
        targetMonitor.volumeWillUnmount = { [weak self] url in
            self?.handleWillUnmount(volumeURL: url)
        }
        refreshApplePhotosState()

        // A test drives reachability itself, and enumerating the real machine's
        // volumes — or backing the catalog up onto the user's actual drives —
        // is exactly what it must not do.
        guard environment.runsBackgroundWork else { return }

        rescanTargets()
        // Runs after the drive scan so drive-resident leftovers are visible.
        reconcileAfterRestart()
        refreshCatalogSnapshots()
        backupCatalog()

        let cache = thumbnails
        Task.detached(priority: .background) { cache.pruneDisk() }

        // Volume mount notifications cover the common case; a slow poll covers
        // anything they miss (e.g. network volumes, missed events).
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rescanTargets()
                // Content can move under a target that never unmounts, and
                // connect-time checks never fire for one left plugged in.
                self?.startDueSyncsIfIdle()
                self?.checkAnchorsIfDue()
                self?.runRotPatrolIfDue()
                self?.checkApplePhotosPresenceIfDue()
                self?.importFromApplePhotosIfDue()
            }
        }
    }

    // MARK: - Archive-level replication

    /// The export-part view of replication: what the archive is actually made
    /// of, and whether each part exists twice.
    @Published private(set) var archivePlan: ArchiveReplicationPlan =
        ArchiveReplicationPlan(parts: [], managedTargetIDs: [])

    /// What can be moved right now to get every part onto enough targets.
    /// Recomputed whenever targets connect or the archive changes, so the UI
    /// can say what is possible without starting anything.
    @Published private(set) var partTransferPlan = ExportPartTransferPlan()
    /// Parts currently parked on the Mac mid-journey.
    @Published private(set) var heldExportParts: [HeldExportPart] = []
    @Published private(set) var isTransferringParts = false
    private var transferCancelRequested = false
    /// Control handle for the copy currently running, so a cancel reaches it
    /// mid-file rather than only between parts.
    private var activeTransferControl: TransferControl?

    /// Recomputes the transfer plan from the targets connected at this moment.
    func refreshPartTransferPlan() {
        heldExportParts = relay.heldParts()
        partTransferPlan = ExportPartTransferPlanner.plan(
            replication: archivePlan,
            connectedDriveIDs: Set(reachablePaths.keys),
            heldParts: heldExportParts,
            availableHoldingBytes: relay.availableBytes
        )
    }

    func cancelExportPartTransfers() {
        transferCancelRequested = true
        activeTransferControl?.cancel()
    }

    /// Moves export parts until every part lives on as many targets as the
    /// policy asks for, using whatever targets are plugged in right now.
    ///
    /// The two-drive case is the whole point: a part that exists only on drive
    /// A can reach drive B directly when both are connected, and by way of the
    /// Mac's holding area when they never are. Parked parts are delivered and
    /// deleted on the next connection, so the corridor drains itself.
    func transferExportParts() {
        guard !isTransferringParts, !isImporting, !isSyncing, takeoutActivity == nil else { return }
        Task { await performExportPartTransfers() }
    }

    private func performExportPartTransfers() async {
        isTransferringParts = true
        transferCancelRequested = false
        defer {
            isTransferringParts = false
            takeoutActivity = nil
            refreshPartTransferPlan()
        }

        let discarded = relay.discardIncompleteCopies()
        if discarded > 0 {
            audit(.replication, "Discarded \(discarded) incomplete part cop(ies) left by an interrupted transfer.")
        }
        applyArchiveLevelRedundancy()
        refreshPartTransferPlan()

        // The corridor should hold nothing that is already safe elsewhere.
        for held in partTransferPlan.discardable {
            do {
                try relay.remove(held)
                audit(.replication, "\(held.displayName) is on every managed drive; cleared it from the Mac's holding area, freeing \(Formatters.bytes.string(fromByteCount: held.sizeBytes)).")
            } catch {
                lastError = "Could not clear \(held.displayName) from the holding area: \(error.localizedDescription)"
            }
        }

        let transfers = partTransferPlan.transfers
        guard !transfers.isEmpty else {
            if !partTransferPlan.stranded.isEmpty {
                audit(.replication, "\(partTransferPlan.stranded.count) export part(s) still need another copy, but no drive holding one is connected. Connect the drive that has them to continue.")
            }
            return
        }

        var moved = 0
        var failed = 0
        for (index, transfer) in transfers.enumerated() {
            if transferCancelRequested { break }
            guard let step = resolveTransfer(transfer) else {
                failed += 1
                continue
            }
            takeoutActivity = TakeoutActivity(
                phase: .transferring,
                detail: "\(transfer.displayName) → \(step.destinationLabel)",
                stepIndex: index + 1,
                stepCount: transfers.count,
                itemIndex: 0,
                itemCount: Int(max(transfer.sizeBytes, 1)),
                note: step.explanation
            )
            markBusy(step.donorDriveID, true)
            markBusy(transfer.route.recipient, true)
            do {
                let outcome = try await copyPartOffMainActor(step: step, transfer: transfer)
                try applyTransferOutcome(transfer, step: step, outcome: outcome)
                moved += 1
            } catch {
                failed += 1
                if case ExportPartRelay.TransferError.cancelled = error { }
                else {
                    lastError = "Could not copy \(transfer.displayName): \(error.localizedDescription)"
                    audit(.replication, "Copying \(transfer.displayName) to \(step.destinationLabel) failed: \(error.localizedDescription)")
                }
            }
            markBusy(step.donorDriveID, false)
            markBusy(transfer.route.recipient, false)
            if transferCancelRequested { break }
        }

        applyArchiveLevelRedundancy()
        loadAll()
        if moved > 0 || failed > 0 {
            audit(.replication, "Export part transfer: \(moved) part(s) moved, \(failed) failed\(transferCancelRequested ? ", stopped early at your request" : "").")
        }
        backupCatalog()
    }

    /// One transfer resolved against the filesystem: where the bytes are and
    /// where they are going. Returns nil when the move is no longer possible —
    /// the donor was unplugged, or the part vanished between planning and now.
    private struct ResolvedTransfer {
        var sourceURL: URL
        var destinationURL: URL
        var destinationLabel: String
        var donorDriveID: UUID?
        /// Recorded in the catalog when the copy lands, so the receiving drive
        /// keeps the part as a first-class archive.
        var recipientDriveID: UUID?
        /// The archive the bytes came from, when it is one the catalog knows.
        var sourceArchiveID: UUID?
        var heldPart: HeldExportPart?
        var explanation: String
    }

    private func resolveTransfer(_ transfer: ExportPartTransfer) -> ResolvedTransfer? {
        let partID = "\(transfer.setID)-\(transfer.partNumber)"
        let part = archivePlan.parts.first { $0.id == partID }

        // Beside the set's other parts on the receiving drive, and only in the
        // app's own folder when that drive holds none of them. A part arriving
        // to complete an export belongs with the export, not in a second pile
        // at the volume root.
        func driveDestination(_ targetID: UUID) -> URL? {
            guard let mount = reachablePaths[targetID] else { return nil }
            let directory = ExportSetLayout.home(
                forSet: transfer.setID, onMount: mount, archives: takeoutArchives
            ) ?? ExportPartRelay.destinationDirectory(onMount: mount)
            return directory.appendingPathComponent("\(transfer.displayName).zip")
        }

        switch transfer.route {
        case .driveToDrive(let from, let to):
            guard let source = part?.copies[from], FileManager.default.fileExists(atPath: source.path),
                  let destination = driveDestination(to)
            else { return nil }
            return ResolvedTransfer(
                sourceURL: source.url,
                destinationURL: destination,
                destinationLabel: targetsByID[to]?.name ?? "the other drive",
                donorDriveID: from,
                recipientDriveID: to,
                sourceArchiveID: source.id,
                heldPart: nil,
                explanation: "Both targets are connected, so the part goes straight across."
            )

        case .driveToHoldingArea(let from, let intendedFor):
            guard let source = part?.copies[from], FileManager.default.fileExists(atPath: source.path)
            else { return nil }
            return ResolvedTransfer(
                sourceURL: source.url,
                destinationURL: relay.url(setID: transfer.setID, partNumber: transfer.partNumber),
                destinationLabel: "the Mac's holding area",
                donorDriveID: from,
                recipientDriveID: nil,
                sourceArchiveID: source.id,
                heldPart: nil,
                explanation: "\(targetsByID[intendedFor]?.name ?? "The other drive") is not connected, so the part waits on the Mac and moves across when it is."
            )

        case .holdingAreaToDrive(let to):
            guard let held = heldExportParts.first(where: { $0.id == partID }),
                  FileManager.default.fileExists(atPath: held.path),
                  let destination = driveDestination(to)
            else { return nil }
            return ResolvedTransfer(
                sourceURL: held.url,
                destinationURL: destination,
                destinationLabel: targetsByID[to]?.name ?? "the drive",
                donorDriveID: nil,
                recipientDriveID: to,
                sourceArchiveID: nil,
                heldPart: held,
                explanation: "Delivering a part that has been waiting on the Mac; it is deleted from there once it lands."
            )
        }
    }

    /// Runs the copy off the main actor so the UI keeps painting during a
    /// multi-gigabyte transfer, reporting bytes back as they land.
    private func copyPartOffMainActor(
        step: ResolvedTransfer,
        transfer: ExportPartTransfer
    ) async throws -> ExportPartRelay.TransferOutcome {
        let source = step.sourceURL
        let destination = step.destinationURL
        let expected = transfer.sizeBytes
        let control = TransferControl { bytes in
            Task { @MainActor [weak self] in self?.takeoutActivity?.itemIndex = Int(bytes) }
        }
        activeTransferControl = control
        if transferCancelRequested { control.cancel() }
        defer { activeTransferControl = nil }
        return try await Task.detached(priority: .utility) {
            try ExportPartRelay.copyPart(
                from: source,
                to: destination,
                expectedBytes: expected,
                isCancelled: { control.isCancelled },
                progress: { control.report($0) }
            )
        }.value
    }

    /// Records what the transfer achieved: the receiving drive now holds the
    /// part, and the donor's whole-file hash — computed for free while
    /// reading — is worth keeping for a later byte-for-byte comparison.
    private func applyTransferOutcome(
        _ transfer: ExportPartTransfer,
        step: ResolvedTransfer,
        outcome: ExportPartRelay.TransferOutcome
    ) throws {
        try catalog.transaction {
            if let sourceArchiveID = step.sourceArchiveID,
               var source = takeoutArchives.first(where: { $0.id == sourceArchiveID }),
               source.contentHash == nil {
                source.contentHash = outcome.sourceHash
                try catalog.upsertTakeoutArchive(source)
            }
            if let recipient = step.recipientDriveID {
                // The landed copy gets the quick checksum that was actually
                // compared, and no content hash: nothing has read those bytes
                // back in full, and claiming otherwise would turn a spot check
                // into a proof it is not.
                let archive = TakeoutArchive(
                    id: UUID(),
                    path: outcome.destination.path,
                    kind: .zip,
                    sizeBytes: outcome.sizeBytes,
                    targetID: recipient,
                    discoveredAt: Date(),
                    importedAt: nil,
                    importBatchID: nil,
                    importedAssetCount: 0,
                    skippedDuplicateCount: 0,
                    note: "Copied from \(step.donorDriveID.flatMap { targetsByID[$0]?.name } ?? "the Mac's holding area") to satisfy the \(redundancyPolicy.description) policy.",
                    exportSetID: transfer.setID,
                    partNumber: transfer.partNumber,
                    quickChecksum: outcome.quickChecksum
                )
                try catalog.upsertTakeoutArchive(archive)
            }
        }
        // Only once the destination is recorded is the parked copy redundant.
        if let held = step.heldPart {
            try relay.remove(held)
        }
        takeoutArchives = try catalog.fetchTakeoutArchives()
        heldExportParts = relay.heldParts()
        audit(
            .replication,
            "\(transfer.displayName) copied to \(step.destinationLabel) (\(Formatters.bytes.string(fromByteCount: outcome.sizeBytes))). The copy's quick checksum matches its source; a byte-for-byte comparison has not been run.",
            targetID: step.recipientDriveID
        )
    }

    /// Which assets live inside which export part, keyed by part stem.
    ///
    /// Deliberately per-part rather than one combined set: an asset is only
    /// present on a drive that holds *its own* part. Treating every covered
    /// asset as present on every drive holding *any* satisfied part would
    /// claim redundancy that does not exist the moment the targets hold
    /// different subsets of the export.
    private func assetIDsByExportPart() -> [String: Set<UUID>] {
        // Identify a part by its stem — `takeout-<set>-<part>`. That appears
        // both in the zip's filename and in the path of the folder extracted
        // from it, so it matches a replica however that replica is stored.
        // Comparing full filenames fails: a replica extracted to a folder
        // records no `.zip`.
        let stems = archivePlan.parts.map(\.displayName)
        guard !stems.isEmpty else { return [:] }

        var byPart: [String: Set<UUID>] = [:]
        for replica in replicaStates where replica.state == .present {
            guard let relative = replica.relativePath else { continue }
            guard let stem = stems.first(where: { relative.contains($0) }) else { continue }
            byPart[stem, default: []].insert(replica.assetID)
        }
        return byPart
    }

    /// Cancels per-asset copies for content whose export part is already on
    /// two targets, and records the second copy. Twelve zips existing twice is
    /// the policy being met; re-copying 24,000 files into a drive that already
    /// holds them is not work, it is waste.
    func applyArchiveLevelRedundancy() {
        let managedIDs = Set(targets.map(\.id))
        archivePlan = ArchiveReplicationPlanner.plan(
            archives: takeoutArchives, managedTargetIDs: managedIDs, policy: redundancyPolicy
        )
        guard !archivePlan.partsMeetingPolicy.isEmpty else { return }

        let assetsByPart = assetIDsByExportPart()
        var covered: Set<UUID> = []

        // A drive holding a satisfied part holds the assets inside *that*
        // part. Record it against the part rather than inventing a per-file
        // path, and withdraw the copy work the per-asset model had queued.
        var claimed = 0
        var cancelled = 0
        var pendingCleared = 0
        do {
            try catalog.transaction {
                for part in archivePlan.partsMeetingPolicy {
                    guard let assetIDs = assetsByPart[part.displayName], !assetIDs.isEmpty else { continue }
                    covered.formUnion(assetIDs)
                    let backing = ReplicationService.archivePartPrefix + part.displayName
                    for targetID in part.targetIDs where managedIDs.contains(targetID) {
                        for assetID in assetIDs {
                            let existing = replicasByAssetID[assetID]?.first { $0.targetID == targetID }
                            // Never overwrite a replica already established by
                            // reading the bytes; this is the weaker claim.
                            if existing?.state == .present { continue }
                            if existing?.state == .pending { pendingCleared += 1 }
                            try catalog.upsertReplicaState(TargetReplicaState(
                                assetID: assetID,
                                targetID: targetID,
                                state: .present,
                                relativePath: backing,
                                lastVerifiedAt: nil
                            ))
                            claimed += 1
                        }
                    }
                }
                guard !covered.isEmpty else { return }
                for task in replicationTasks where task.state == .queued
                    && task.action == .copy && covered.contains(task.assetID) {
                    try catalog.deleteReplicationTask(id: task.id)
                    cancelled += 1
                }
            }
            guard !covered.isEmpty else { return }
            audit(
                .replication,
                "Archive redundancy: \(archivePlan.partsMeetingPolicy.count) of \(archivePlan.parts.count) export part(s) exist as \(redundancyPolicy.description), covering \(covered.count) asset(s). Recorded \(claimed) cop(ies) against the parts holding them, replacing \(pendingCleared) pending entr(ies), and withdrew \(cancelled) file copies that are no longer needed."
            )
            loadAll()
        } catch {
            lastError = "Could not record archive redundancy: \(error.localizedDescription)"
        }
    }

    /// Compares export parts by a fast partial checksum: a few megabytes
    /// sampled from each copy rather than every byte.
    ///
    /// Reading two 10 GB archives in full to compare them takes minutes;
    /// sampling takes seconds and still catches truncation, a partial
    /// transfer, or the wrong file under the right name. It is recorded as a
    /// spot check, never as proof — `verifyExportPartsByChecksum` remains for
    /// when certainty is wanted.
    func spotCheckExportParts() {
        guard takeoutActivity == nil, !isImporting else { return }
        let managedIDs = Set(targets.map(\.id))
        archivePlan = ArchiveReplicationPlanner.plan(
            archives: takeoutArchives, managedTargetIDs: managedIDs, policy: redundancyPolicy
        )
        // Meeting the policy no longer implies more than one copy — under a
        // one-copy policy a part is protected by the only copy there is. That
        // part is not a candidate: a comparison needs something to compare to,
        // and running one over a lone file would report agreement with itself.
        let candidates = archivePlan.partsMeetingPolicy.filter { part in
            part.copies.count >= redundancyPolicy.copiesNeededToCompare
                && part.copies.values.contains { $0.kind == .zip }
                && part.copies.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard !candidates.isEmpty else {
            audit(.replication, "Spot check: no export part has two connected copies to compare.")
            return
        }

        Task { @MainActor in
            var agreed = 0
            var disagreed: [String] = []
            var assetsConfirmed = 0

            for (index, part) in candidates.enumerated() {
                takeoutActivity = TakeoutActivity(
                    phase: .fingerprinting,
                    detail: part.displayName,
                    stepIndex: index + 1,
                    stepCount: candidates.count,
                    note: "quick comparison"
                )
                var checksums: [UUID: String] = [:]
                for (targetID, archiveConst) in part.copies where archiveConst.kind == .zip {
                    var archive = archiveConst
                    if archive.quickChecksum == nil {
                        guard let value = try? await Task.detached(priority: .utility, operation: {
                            try HashingService.quickChecksum(of: archive.url)
                        }).value else { continue }
                        archive.quickChecksum = value
                        try? catalog.upsertTakeoutArchive(archive)
                        if let at = takeoutArchives.firstIndex(where: { $0.id == archive.id }) {
                            takeoutArchives[at] = archive
                        }
                    }
                    checksums[targetID] = archive.quickChecksum
                }
                guard checksums.count >= redundancyPolicy.copiesNeededToCompare else { continue }

                if Set(checksums.values).count == 1 {
                    assetsConfirmed += markPartVerified(part, onTargets: Set(checksums.keys))
                    agreed += 1
                } else {
                    disagreed.append(part.displayName)
                    markPartMismatched(part, onTargets: Set(checksums.keys))
                }
            }

            var message = "Spot check: \(agreed) export part(s) matched across targets on length and sampled content, covering \(assetsConfirmed) asset(s). This is a fast check, not a full byte-for-byte comparison."
            if !disagreed.isEmpty {
                message += " \(disagreed.count) part(s) DIFFER and are flagged: \(disagreed.joined(separator: ", "))."
            }
            audit(.replication, message)
            takeoutActivity = nil
            loadAll()
        }
    }

    /// Confirms redundancy by comparing whole-file checksums of the export
    /// parts, rather than reading every asset inside them.
    ///
    /// If two targets hold byte-identical copies of a part, everything in that
    /// part is verifiably present on both — proved by a handful of file hashes
    /// instead of decompressing tens of thousands of entries. One sequential
    /// read per part replaces per-asset checking entirely.
    func verifyExportPartsByChecksum() {
        guard takeoutActivity == nil, !isImporting else { return }
        let managedIDs = Set(targets.map(\.id))
        archivePlan = ArchiveReplicationPlanner.plan(
            archives: takeoutArchives, managedTargetIDs: managedIDs, policy: redundancyPolicy
        )
        // Only parts whose copies are all reachable can be compared now — and
        // only parts that have a second copy to be compared against at all.
        let candidates = archivePlan.partsMeetingPolicy.filter { part in
            part.copies.count >= redundancyPolicy.copiesNeededToCompare
                && part.copies.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard !candidates.isEmpty else {
            audit(.replication, "Checksum check: no export part has two connected copies to compare.")
            return
        }

        Task { @MainActor in
            var verifiedParts = 0
            var mismatchedParts: [String] = []
            var assetsConfirmed = 0

            for (index, part) in candidates.enumerated() {
                takeoutActivity = TakeoutActivity(
                    phase: .fingerprinting,
                    detail: part.displayName,
                    stepIndex: index + 1,
                    stepCount: candidates.count,
                    note: "comparing copies by checksum"
                )
                var hashes: [UUID: String] = [:]
                for (targetID, archive) in part.copies {
                    // Folders have no single-file checksum; this compares parts
                    // stored as archives.
                    guard archive.kind == .zip else { continue }
                    guard let hash = await fingerprintZipIfNeeded(archive) else { continue }
                    hashes[targetID] = hash
                }
                guard hashes.count >= redundancyPolicy.copiesNeededToCompare else { continue }

                if Set(hashes.values).count == 1 {
                    assetsConfirmed += markPartVerified(part, onTargets: Set(hashes.keys))
                    verifiedParts += 1
                } else {
                    // Same name and size, different bytes: one copy is damaged
                    // or is not the part it claims to be. Say so rather than
                    // treating it as protection.
                    mismatchedParts.append(part.displayName)
                    markPartMismatched(part, onTargets: Set(hashes.keys))
                }
            }

            var message = "Checksum check: \(verifiedParts) export part(s) confirmed identical across targets, covering \(assetsConfirmed) asset(s)."
            if !mismatchedParts.isEmpty {
                message += " \(mismatchedParts.count) part(s) DIFFER between targets and are flagged: \(mismatchedParts.joined(separator: ", "))."
            }
            audit(.replication, message)
            takeoutActivity = nil
            loadAll()
        }
    }

    /// Records that every replica backed by this part has been confirmed.
    @discardableResult
    private func markPartVerified(_ part: ExportPart, onTargets targetIDs: Set<UUID>) -> Int {
        let stem = part.displayName
        let now = Date()
        var confirmed = 0
        do {
            try catalog.transaction {
                for replica in replicaStates where targetIDs.contains(replica.targetID)
                    && replica.state == .present
                    && (replica.relativePath?.contains(stem) ?? false) {
                    var updated = replica
                    updated.lastVerifiedAt = now
                    try catalog.upsertReplicaState(updated)
                    confirmed += 1
                }
            }
        } catch {
            lastError = "Could not record checksum verification: \(error.localizedDescription)"
        }
        return confirmed
    }

    /// Flags replicas whose part disagrees between targets, so the difference
    /// surfaces as a problem rather than silently passing as redundancy.
    private func markPartMismatched(_ part: ExportPart, onTargets targetIDs: Set<UUID>) {
        let stem = part.displayName
        try? catalog.transaction {
            for replica in replicaStates where targetIDs.contains(replica.targetID)
                && replica.state == .present
                && (replica.relativePath?.contains(stem) ?? false) {
                var updated = replica
                updated.state = .drift
                try catalog.upsertReplicaState(updated)
            }
        }
    }

    // MARK: - Capture dates

    /// Edited derivatives keyed by the original they came from.
    @Published private(set) var editsByOriginalID: [UUID: [Asset]] = [:]

    func originalOf(_ asset: Asset) -> Asset? {
        asset.editedFromAssetID.flatMap { assetsByID[$0] }
    }

    func editsOf(_ asset: Asset) -> [Asset] {
        editsByOriginalID[asset.id] ?? []
    }

    /// Recovers capture dates for assets already imported, using the same
    /// resolver the import pipeline uses, and links edited derivatives to the
    /// originals they came from so the two sit together in the timeline.
    ///
    /// Runs after imports and on drive connect. Only fills gaps: an asset that
    /// already has a date from the file or a sidecar is never overwritten.
    func recoverCaptureDates() {
        guard takeoutActivity == nil, !isImporting else { return }

        // 1. Link edits to their originals, by filename within the same folder.
        var originalByPath: [String: Asset] = [:]
        for asset in assets {
            guard let url = localFileURL(for: asset) else { continue }
            originalByPath[url.path] = asset
        }
        var links: [(edit: Asset, original: Asset)] = []
        for asset in assets where asset.editedFromAssetID == nil
            && CaptureDateResolver.isEditedDerivative(asset.originalFilename) {
            guard let url = localFileURL(for: asset),
                  let originalURL = CaptureDateResolver.originalURL(forEdited: url),
                  let original = originalByPath[originalURL.path]
            else { continue }
            links.append((asset, original))
        }

        // 2. Two different repairs, deliberately separated. A row with no date
        //    needs one found; a row that has a date but does not say where it
        //    came from needs only its provenance settled, and must keep the
        //    date it already has. Lumping them together is what left 16,284
        //    assets displaying an EXIF timestamp as an approximate year: they
        //    were selected as needing work and then skipped for having a date.
        let needingDate = assets.filter { $0.captureDate == nil }
        let needingProvenance = assets.filter {
            $0.captureDate != nil && $0.captureDateSource == .unknown
        }
        guard !links.isEmpty || !needingDate.isEmpty || !needingProvenance.isEmpty else { return }

        takeoutActivity = TakeoutActivity(
            phase: .reconciling, detail: "Capture dates",
            itemIndex: 0, itemCount: needingDate.count + needingProvenance.count,
            note: "\(links.count) edit(s) to link, \(needingDate.count) date(s) to recover, "
                + "\(needingProvenance.count) source(s) to identify"
        )

        Task { @MainActor in
            var linked = 0
            var recovered: [CaptureDateSource: Int] = [:]
            /// Dates that were already right and now say where they came from.
            var identified = 0
            do {
                for link in links {
                    var edit = link.edit
                    edit.editedFromAssetID = link.original.id
                    // An edit carries no metadata of its own; without the
                    // original's date it drifts to the wrong end of the
                    // timeline instead of sitting beside what it came from.
                    if edit.captureDate == nil, let date = link.original.captureDate {
                        edit.captureDate = date
                        edit.captureDateSource = .originalSidecar
                        recovered[.originalSidecar, default: 0] += 1
                    }
                    edit.updatedDate = Date()
                    try catalog.upsertAsset(edit)
                    assetsByID[edit.id] = edit
                    linked += 1
                }

                // 2a. Provenance the catalog can settle by itself. The raw
                //     DateTimeOriginal string is already stored beside the
                //     date, so most of this needs no drive connected and no
                //     file read — and doing it first leaves the disk pass
                //     below only the remainder. One transaction: at this scale
                //     a fsync per row is the difference between seconds and
                //     minutes.
                let settledFromCatalog: [Asset] = needingProvenance.compactMap { asset in
                    guard var updated = assetsByID[asset.id],
                          let date = updated.captureDate,
                          let source = CaptureDateResolver.provenance(
                              forStoredDate: date, exifSummary: updated.exifSummary
                          )
                    else { return nil }
                    updated.captureDateSource = source
                    updated.updatedDate = Date()
                    return updated
                }
                try catalog.transaction {
                    for updated in settledFromCatalog {
                        try catalog.upsertAsset(updated)
                    }
                }
                for updated in settledFromCatalog {
                    assetsByID[updated.id] = updated
                    identified += 1
                }
                takeoutActivity?.itemIndex = identified
                takeoutActivity?.note = "\(identified) source(s) identified from the catalog"

                // 2b. Whatever is left needs the file itself: a date to find,
                //     or a source the catalog could not evidence. One rule
                //     covers both — a date already held is never overwritten,
                //     and its source is adopted only if re-resolving lands on
                //     the same instant. A file that says something different
                //     now than at import settles nothing and stays unknown.
                let settledIDs = Set(settledFromCatalog.map(\.id))
                let needingDisk = needingDate
                    + needingProvenance.filter { !settledIDs.contains($0.id) }
                for (index, asset) in needingDisk.enumerated() {
                    guard var updated = assetsByID[asset.id] else { continue }
                    guard let url = localFileURL(for: updated) else { continue }

                    var metadataDate: Date?
                    if updated.kind == .video {
                        metadataDate = await CaptureDateResolver.movieCreationDate(url)
                    }
                    let located = CaptureDateResolver.sidecar(for: url)
                    let resolved = CaptureDateResolver.resolve(
                        fileURL: url,
                        metadataDate: metadataDate,
                        sidecarDate: located?.0.takenDate,
                        sidecarSource: located?.1
                    )
                    guard let date = resolved.date else { continue }
                    if let held = updated.captureDate {
                        guard CaptureDateResolver.reproduces(held, date) else { continue }
                        identified += 1
                    } else {
                        updated.captureDate = date
                        recovered[resolved.source, default: 0] += 1
                    }
                    updated.captureDateSource = resolved.source
                    updated.updatedDate = Date()
                    try catalog.upsertAsset(updated)
                    assetsByID[updated.id] = updated

                    if index % 50 == 0 {
                        takeoutActivity?.itemIndex = settledFromCatalog.count + index
                        takeoutActivity?.note = "\(recovered.values.reduce(0, +)) date(s) recovered, "
                            + "\(identified) source(s) identified"
                    }
                }
            } catch {
                lastError = "Capture date recovery failed: \(error.localizedDescription)"
            }
            let summary = recovered
                .sorted { $0.value > $1.value }
                .map { "\($0.value) \($0.key.displayName.lowercased())" }
                .joined(separator: ", ")
            // The declined count is worth saying out loud rather than leaving
            // as a silent shortfall: it is the honest part of the result, and
            // a run that identifies nothing new should look settled rather
            // than broken.
            let declined = needingProvenance.count - identified
            audit(.system, "Capture dates: linked \(linked) edited photo(s) to their originals; "
                + "recovered \(recovered.values.reduce(0, +)) date(s)\(summary.isEmpty ? "" : " (\(summary))"); "
                + "identified \(identified) previously unrecorded source(s)"
                + (declined > 0 ? ", left \(declined) unknown for want of evidence" : "") + ".")
            takeoutActivity = nil
            loadAll()
        }
    }

    // MARK: - Live Photos

    /// Motion halves keyed by the still they belong to.
    @Published private(set) var livePhotoMotionByStillID: [UUID: Asset] = [:]

    func livePhotoMotion(for asset: Asset) -> Asset? {
        livePhotoMotionByStillID[asset.id]
    }

    /// Reopens videos previously ruled out whose filename stem matches one of
    /// these newly imported stills. A video stays a plain video until its
    /// still turns up — which may be in a later import — so being ruled out
    /// must never be permanent when new content could change the answer.
    private func reopenLivePhotoChecks(forNewlyImported imported: [Asset]) {
        let newStillStems = LivePhotoPairer.stillStems(of: imported)
        guard !newStillStems.isEmpty else { return }

        let reopened = assets.filter {
            LivePhotoPairer.shouldReopenCheck(video: $0, newlyImportedStillStems: newStillStems)
        }
        guard !reopened.isEmpty else { return }
        do {
            try catalog.transaction {
                for var video in reopened {
                    video.livePhotoCheckedAt = nil
                    try catalog.upsertAsset(video)
                }
            }
            audit(.system, "Reopened \(reopened.count) video(s) for Live Photo matching: a newly imported still shares their name.")
            loadAll()
        } catch {
            lastError = "Could not reopen Live Photo checks: \(error.localizedDescription)"
        }
    }

    /// Finds Live Photo pairs among unpaired assets and links them. Each half
    /// keeps its own residency and replica tracking — the motion file is real
    /// content that still has to live somewhere and be checked — but the
    /// Library folds the movie into its still.
    func pairLivePhotos() {
        guard takeoutActivity == nil, !isImporting else { return }
        let snapshot = assets
        let resolve: (Asset) -> URL? = { [weak self] in self?.localFileURL(for: $0) }
        let candidates = LivePhotoPairer.candidates(from: snapshot, sourceURL: resolve)
        guard !candidates.isEmpty else {
            audit(.system, "Live Photo scan: no unpaired candidates with reachable files.")
            return
        }

        takeoutActivity = TakeoutActivity(
            phase: .reconciling, detail: "Live Photos",
            itemIndex: 0, itemCount: candidates.count,
            note: "checking \(candidates.count) candidate pair(s)"
        )

        // Positions so each confirmed pair can be published in O(1); waiting
        // for the whole scan to finish would leave the grid unchanged for
        // minutes while thousands of pairs were already linked in the catalog.
        var positionByID: [UUID: Int] = [:]
        for (index, asset) in assets.enumerated() { positionByID[asset.id] = index }

        Task { @MainActor in
            var linked = 0
            var rejected = 0
            var strongMatches = 0
            var inferredMatches = 0
            for (index, candidate) in candidates.enumerated() {
                // A stem can offer several combinations; once either half is
                // linked, the rest of that stem's combinations are moot.
                if assetsByID[candidate.motionAssetID]?.livePhotoStillID != nil { continue }
                if livePhotoMotionByStillID[candidate.stillAssetID] != nil { continue }
                let confidence = await LivePhotoPairer.confirm(candidate)
                if confidence == .identifiersMatch { strongMatches += 1 }
                if confidence == .motionIdentifierAndName { inferredMatches += 1 }
                if confidence.isPair {
                    do {
                        var updatedMotion: Asset?
                        var updatedStill: Asset?
                        try catalog.transaction {
                            if var motion = assetsByID[candidate.motionAssetID] {
                                motion.livePhotoStillID = candidate.stillAssetID
                                motion.updatedDate = Date()
                                try catalog.upsertAsset(motion)
                                updatedMotion = motion
                            }
                            if var still = assetsByID[candidate.stillAssetID] {
                                still.kind = .livePhoto
                                still.updatedDate = Date()
                                try catalog.upsertAsset(still)
                                updatedStill = still
                            }
                        }
                        // Publish immediately: the movie leaves the grid and the
                        // still gains its badge as each pair is confirmed.
                        if let motion = updatedMotion {
                            if let at = positionByID[motion.id] { assets[at] = motion }
                            assetsByID[motion.id] = motion
                            livePhotoMotionByStillID[candidate.stillAssetID] = motion
                        }
                        if let still = updatedStill {
                            if let at = positionByID[still.id] { assets[at] = still }
                            assetsByID[still.id] = still
                        }
                        linked += 1
                    } catch {
                        lastError = "Live Photo pairing failed: \(error.localizedDescription)"
                        break
                    }
                } else {
                    rejected += 1
                    if confidence.isConclusiveRejection,
                       var motion = assetsByID[candidate.motionAssetID],
                       motion.livePhotoCheckedAt == nil {
                        motion.livePhotoCheckedAt = Date()
                        try? catalog.upsertAsset(motion)
                        assetsByID[motion.id] = motion
                        if let at = positionByID[motion.id] { assets[at] = motion }
                    }
                }
                if index % 25 == 0 {
                    takeoutActivity?.itemIndex = index
                    takeoutActivity?.note = "\(linked) paired, \(rejected) not Live Photos"
                }
            }
            audit(.system, "Live Photos: linked \(linked) pair(s) — \(strongMatches) confirmed by matching Apple identifiers, \(inferredMatches) by the movie's identifier plus filename (Google had stripped the still's). \(rejected) same-name candidate(s) were not Live Photos and were left alone.")
            takeoutActivity = nil
            loadAll()
        }
    }

    // MARK: - Safe connect / disconnect

    /// Drives the app has been asked to stop touching — either because macOS
    /// announced an unmount, or because the user asked to eject. Long-running
    /// loops check this at their next safe boundary and stop cleanly, leaving
    /// resumable state behind rather than a wall of I/O errors.
    @Published private(set) var quiescingTargetIDs: Set<UUID> = []
    /// Drives with file work in flight right now. While true, the volume has
    /// open handles and will refuse to eject.
    @Published private(set) var busyTargetIDs: Set<UUID> = []

    func isQuiescing(_ targetID: UUID) -> Bool { quiescingTargetIDs.contains(targetID) }
    func isBusy(_ targetID: UUID) -> Bool { busyTargetIDs.contains(targetID) }

    private func markBusy(_ targetID: UUID?, _ busy: Bool) {
        guard let targetID else { return }
        if busy { busyTargetIDs.insert(targetID) } else { busyTargetIDs.remove(targetID) }
    }

    /// Which managed drive, if any, owns this path.
    ///
    /// Falls back to each drive's last known mount point so content recorded
    /// while a drive was attached is still attributed to it once unplugged —
    /// otherwise an archive on an absent drive counts towards no drive at all,
    /// and its copy silently stops counting towards the redundancy policy.
    func targetID(forPath path: String) -> UUID? {
        if let connected = reachablePaths.first(where: { path.hasPrefix($0.value.path + "/") })?.key {
            return connected
        }
        return targets.first { drive in
            guard let mount = drive.lastKnownPath else { return false }
            return path.hasPrefix(mount + "/")
        }?.id
    }

    /// Asks every running operation to let go of the drive. Returns without
    /// waiting; callers poll `isBusy` to know when the volume is releasable.
    func beginQuiesce(_ targetID: UUID, reason: String) {
        guard !quiescingTargetIDs.contains(targetID) else { return }
        quiescingTargetIDs.insert(targetID)
        if syncProgress?.targetID == targetID { cancelSync() }
        pendingSyncTargetIDs.removeAll { $0 == targetID }
        let name = targetsByID[targetID]?.name ?? "drive"
        audit(.drive, "Releasing \(name): \(reason). In-flight work will stop at its next safe point.", targetID: targetID)
    }

    func endQuiesce(_ targetID: UUID) {
        quiescingTargetIDs.remove(targetID)
    }

    /// macOS is about to unmount a volume: stop using it immediately so the
    /// eject can succeed instead of failing with "disk in use".
    private func handleWillUnmount(volumeURL: URL?) {
        guard let volumeURL else {
            for targetID in reachablePaths.keys { beginQuiesce(targetID, reason: "a volume is unmounting") }
            return
        }
        guard let targetID = reachablePaths.first(where: { $0.value.path == volumeURL.path })?.key else { return }
        beginQuiesce(targetID, reason: "macOS is unmounting the volume")
    }

    // MARK: - Catalog backup

    /// Snapshots per drive, newest first — surfaced in Drives & Health.
    @Published private(set) var catalogSnapshots: [UUID: [CatalogSnapshot]] = [:]

    /// A drive is due a snapshot if it has none or its newest is older than this.
    private static let catalogBackupInterval: TimeInterval = 3600

    /// Backs up the catalog to every connected managed drive, verifying each
    /// snapshot by reading it back. `force` bypasses the freshness check.
    ///
    /// Freshness is judged per drive from the snapshots actually present on
    /// that drive — not from a remembered timestamp. A drive that has never
    /// been backed up, or whose backups were deleted, is caught immediately
    /// instead of waiting out an interval that has nothing to do with it.
    func backupCatalog(force: Bool = false) {
        guard !reachablePaths.isEmpty else { return }
        let expected = assets.count
        var wrote = false

        for (targetID, mountURL) in reachablePaths {
            let targetName = targetsByID[targetID]?.name ?? "drive"
            if !force {
                let newest = CatalogBackupService.listSnapshots(onMount: mountURL, targetID: targetID).first
                if let newest, Date().timeIntervalSince(newest.createdAt) < Self.catalogBackupInterval {
                    continue
                }
            }
            do {
                let snapshot = try CatalogBackupService.writeSnapshot(
                    from: catalog, toMount: mountURL, targetID: targetID, expectedAssetCount: expected
                )
                wrote = true
                audit(
                    .system,
                    "Catalog snapshot written to \(targetName): \(snapshot.displayName) (\(expected) assets, \(Formatters.bytes.string(fromByteCount: snapshot.sizeBytes))), verified.",
                    targetID: targetID
                )
            } catch {
                // Recorded, not just shown: a backup that silently stopped
                // working is the failure mode that matters most here.
                audit(.system, "Catalog backup to \(targetName) FAILED: \(error.localizedDescription)", targetID: targetID)
                lastError = "Catalog backup to \(targetName) failed: \(error.localizedDescription)"
            }
        }
        if wrote { refreshCatalogSnapshots() }
    }

    func refreshCatalogSnapshots() {
        var found: [UUID: [CatalogSnapshot]] = [:]
        for (targetID, mountURL) in reachablePaths {
            found[targetID] = CatalogBackupService.listSnapshots(onMount: mountURL, targetID: targetID)
        }
        catalogSnapshots = found
    }

    var latestCatalogSnapshot: CatalogSnapshot? {
        catalogSnapshots.values.flatMap { $0 }.max { $0.createdAt < $1.createdAt }
    }

    // MARK: - Startup integrity

    /// Repairs whatever an abrupt termination left behind. Everything here is
    /// idempotent and safe to run on every launch: it only removes files the
    /// catalog does not reference, and only re-queues work that can be redone.
    /// Never deletes anything the catalog depends on.
    func reconcileAfterRestart() {
        var repairs: [String] = []
        withdrawUnverifiedCloudClaims(into: &repairs)
        do {
            // 1. Replication tasks interrupted mid-flight would otherwise sit
            // in a state the sync loop never picks up again.
            // Copies recorded as failed only because no drive holding the
            // bytes was connected are still owed; return them to the queue.
            let transientlyFailed = replicationTasks.filter {
                $0.state == .failed && ($0.errorMessage?.contains("No staged source copy") == true
                    || $0.errorMessage?.contains("Waiting for a drive") == true)
            }
            for var task in transientlyFailed {
                task.state = .queued
                task.errorMessage = nil
                try catalog.upsertReplicationTask(task)
            }
            if !transientlyFailed.isEmpty {
                repairs.append("requeued \(transientlyFailed.count) copy task(s) that had no reachable source")
            }

            let stuck = replicationTasks.filter { $0.state == .inProgress }
            for var task in stuck {
                task.state = .queued
                task.errorMessage = "Requeued after an interrupted run"
                try catalog.upsertReplicationTask(task)
            }
            if !stuck.isEmpty { repairs.append("requeued \(stuck.count) interrupted replication task(s)") }

            // 2. Archives recorded without a drive — scanned as a plain folder,
            // or discovered by an older build — count towards no drive at all,
            // so their copy silently stops satisfying the redundancy policy.
            // Attribute any whose path sits on a drive we know the mount of.
            let unattributed = takeoutArchives.filter { $0.targetID == nil }
            var attributed = 0
            for var archive in unattributed {
                guard let resolved = targetID(forPath: archive.path) else { continue }
                archive.targetID = resolved
                try catalog.upsertTakeoutArchive(archive)
                attributed += 1
            }
            if attributed > 0 {
                repairs.append("attributed \(attributed) archive(s) to the drive holding them")
            }

            // A folder registered as an export while holding other exports —
            // counted twice in every total, and shown as an export of its own.
            let containers = dropContainerArchives()
            if containers > 0 {
                repairs.append("stopped treating \(containers) folder(s) as exports when they only hold exports")
            }

            // 3. Assets can reference a batch row that never got written by an
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
            // many GB) and half-written `.extracting` folders on targets.
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

            // A transfer interrupted by a crash or an unplug leaves a
            // half-written part in the holding area. It is worthless and can
            // be many gigabytes.
            let abandoned = relay.discardIncompleteCopies()
            if abandoned > 0 { repairs.append("discarded \(abandoned) interrupted export-part cop(ies)") }

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
            targets = try catalog.fetchTargets()
            replicaStates = try catalog.fetchReplicaStates()
            replicationTasks = try catalog.fetchReplicationTasks()
            policyRules = try catalog.fetchPolicyRules()
            migrationJobs = try catalog.fetchMigrationJobs()
            importBatches = try catalog.fetchImportBatches()
            auditEvents = try catalog.fetchAuditEvents()
            takeoutArchives = try catalog.fetchTakeoutArchives()
            // A policy asking for more copies than there are targets can never
            // be met, and reports a healthy archive as 0% safe. Bound it to
            // what exists; registering a target raises the ceiling again.
            if redundancyPolicy.desiredCopies > maxSettableCopies {
                let clamped = maxSettableCopies
                audit(.policy, "Redundancy policy lowered to \(clamped) copy(s): that is how many targets are registered.")
                redundancyPolicy = LocalRedundancyPolicy(desiredCopies: clamped)
            }
            recomputeDerivedState()
        } catch {
            lastError = "Catalog load failed: \(error.localizedDescription)"
        }
    }

    func recomputeDerivedState() {
        rebuildIndexes()
        duplicateGroups = DuplicateDetector.groups(in: assets)
        violations = ViolationScanner.scan(
            assets: assets,
            replicaStates: replicaStates,
            migrationJobs: migrationJobs,
            targetsByID: targetsByID
        )
        protectionStates = ProtectionEvaluator.protectionStates(
            for: assets,
            replicaStates: replicaStates,
            policy: redundancyPolicy
        )

        var breakdowns: [UUID: DriveContentBreakdown] = [:]
        for replica in replicaStates {
            var breakdown = breakdowns[replica.targetID] ?? DriveContentBreakdown()
            let asset = assetsByID[replica.assetID]
            // A Live Photo's motion half is its own file to copy and verify,
            // but not its own photo to count.
            let isPhoto = !(asset?.isLivePhotoMotion ?? false)
            switch replica.state {
            case .present:
                breakdown.present += 1
                breakdown.presentBytes += asset?.fileSize ?? 0
                if isPhoto { breakdown.presentPhotos += 1 }
            case .pending, .copying, .stale:
                breakdown.pending += 1
                if isPhoto { breakdown.pendingPhotos += 1 }
            case .drift:
                breakdown.drift += 1
                if isPhoto { breakdown.driftPhotos += 1 }
            case .missing:
                breakdown.missing += 1
            }
            breakdowns[replica.targetID] = breakdown
        }
        driveBreakdowns = breakdowns

        // One tree per target, over what the catalog records each of them
        // holding. Built here so comparing two targets later is a single root
        // comparison rather than a scan.
        var leavesByTarget: [UUID: [MerkleTree.Leaf]] = [:]
        for replica in replicaStates where replica.state == .present {
            guard let asset = assetsByID[replica.assetID] else { continue }
            leavesByTarget[replica.targetID, default: []].append(
                MerkleTree.Leaf(key: replica.assetID.uuidString, digest: asset.contentHash)
            )
        }
        targetTrees = leavesByTarget.mapValues { MerkleTree(leaves: $0) }

        // The handful of directories every recorded path hangs from. Kept so
        // the periodic check can stat three paths instead of twenty-four
        // thousand: that is what makes checking often affordable at all.
        var anchors: [UUID: Set<String>] = [:]
        for replica in replicaStates where replica.state == .present {
            guard let path = replica.relativePath,
                  path.hasPrefix(ReplicaPathRepair.volumePrefix) else { continue }
            let relative = String(path.dropFirst(ReplicaPathRepair.volumePrefix.count))
            guard let anchor = ReplicaPathRepair.anchorPrefix(of: relative) else { continue }
            anchors[replica.targetID, default: []].insert(anchor)
        }
        targetAnchors = anchors

        var batchSafe: [UUID: Bool] = [:]
        for asset in assets {
            guard let batchID = asset.importBatchID else { continue }
            let safe = asset.residency != .local || protectionStates[asset.id] == .fullyReplicated
            batchSafe[batchID] = (batchSafe[batchID] ?? true) && safe
        }
        fullyReplicatedBatchIDs = Set(batchSafe.filter { $0.value }.keys)

        // Planning is pure arithmetic over a few dozen archives, so the
        // export-part picture stays current with the catalog rather than only
        // after an operation that happens to recompute it.
        archivePlan = ArchiveReplicationPlanner.plan(
            archives: takeoutArchives,
            managedTargetIDs: Set(targets.map(\.id)),
            policy: redundancyPolicy
        )
        refreshPartTransferPlan()
    }

    func rescanTargets() {
        let previouslyConnected = Set(targetMonitor.reachablePaths.keys)
        targetMonitor.rescan(targets: targets)
        let now = Date()
        for (targetID, mountURL) in targetMonitor.reachablePaths {
            if let index = targets.firstIndex(where: { $0.id == targetID }) {
                targets[index].lastSeenAt = now
                targets[index].lastKnownPath = mountURL.path
                try? catalog.upsertTarget(targets[index])
            }
        }
        // Availability-aware reaction: a drive that just appeared with pending
        // backlog starts syncing on its own (serially, behind any running sync),
        // and gets a Takeout sweep so newly landed archives surface unprompted.
        let newlyConnected = Set(targetMonitor.reachablePaths.keys).subtracting(previouslyConnected)
        // A target that went away has to be looked at properly when it comes
        // back: its content can have changed entirely while it was gone, which
        // is the whole reason connect-time work exists. Without this the
        // pipeline ran once per launch and a reconnect was a no-op.
        for targetID in previouslyConnected.subtracting(Set(targetMonitor.reachablePaths.keys)) {
            takeoutPipelineCompletedTargetIDs.remove(targetID)
        }
        for targetID in newlyConnected {
            let name = targetsByID[targetID]?.name ?? "drive"
            endQuiesce(targetID)
            busyTargetIDs.remove(targetID)
            audit(.drive, "\(name) connected.", targetID: targetID)
            // Before anything reads or copies: confirm the paths still resolve.
            // Content the user moved must be repointed, not copied again.
            repairReplicaPaths(for: targetID)
            // Then gather what the app has left lying around this drive into
            // one folder, and put delivered parts beside their export. Renames
            // within the volume, and it runs before the presence checks so
            // they read the paths the catalog now holds rather than reporting
            // everything this moved as gone.
            tidyAppFolders(for: targetID)
            // Then: are the export archives this drive is credited with still
            // on it? One stat each, and it must come before the replica gate
            // so a part that survives only as its extracted twin is stat-ed
            // where the bytes actually are.
            checkArchivePresence(for: targetID)
            // Then the cheap look at what those paths now contain. Runs after
            // the repair so a moved file is stat-ed where it actually is.
            checkReplicaStats(for: targetID)
            // Reconcile before syncing. A drive that already holds this
            // content — the same Takeout export, say — should claim it in
            // place; starting the backlog first would copy over the top of
            // files that are already there.
            Task {
                await autoTakeoutPipeline(targetID: targetID)
                if autoSyncOnConnect && backlogCount(for: targetID) > 0 {
                    syncDrive(targetID)
                }
            }
        }

        promptForUnmanagedVolumes()
    }

    /// Asks (once per appearance, never for ignored volumes) whether a newly
    /// mounted unmanaged external volume should become managed local storage.
    private func promptForUnmanagedVolumes() {
        let unmanaged = targetMonitor.availableVolumes.filter { volume in
            volume.isRemovable
                && volume.url.path.hasPrefix("/Volumes/")
                && TargetMonitor.match(volume: volume, against: targets) == nil
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
        defaults.set(Array(ignoredVolumeKeys), forKey: "ignoredVolumeKeys")
        connectPrompt = nil
    }

    private func audit(_ category: AuditCategory, _ message: String, assetID: UUID? = nil, targetID: UUID? = nil) {
        let event = AuditEvent(id: UUID(), at: Date(), category: category, message: message, assetID: assetID, targetID: targetID)
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
            // A folder chosen from a managed drive counts as that drive's copy.
            let replicaContext = files.first
                .flatMap { file in
                    reachablePaths.first { file.path.hasPrefix($0.value.path + "/") }
                }
                .map { (targetID: $0.key, mountPath: $0.value.path) }
            let result = await ImportService.importFiles(
                files,
                sourceDescription: sourceDescription,
                existingAssets: existing,
                policyRules: rules,
                staging: stagingStore,
                replicaContext: replicaContext
            )
            applyImportResult(result)
        }
    }

    /// Persists imported assets and queues their replication backlog.
    /// Local-resident assets owe a replica to every managed drive; sync
    /// happens whenever the targets appear. A drive whose replica is already
    /// satisfied by the import source itself (archive-backed, e.g. a Takeout
    /// folder on that drive) records the verified in-place replica instead of
    /// queuing a duplicate copy onto the same disk.
    @discardableResult
    private func persistImportedAssets(
        _ imported: [Asset],
        archiveBacked: [UUID: TargetReplicaState] = [:]
    ) throws -> [TargetReplicaState] {
        var written: [TargetReplicaState] = []
        for asset in imported {
            try catalog.upsertAsset(asset)
            if asset.residency == .local {
                for drive in targets {
                    if let backed = archiveBacked[asset.id], backed.targetID == drive.id {
                        try catalog.upsertReplicaState(backed)
                        written.append(backed)
                    } else {
                        try enqueueTask(assetID: asset.id, targetID: drive.id, action: .copy)
                        let pending = TargetReplicaState(
                            assetID: asset.id,
                            targetID: drive.id,
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
    private func publishImportedAssets(_ imported: [Asset], replicas: [TargetReplicaState]) {
        guard !imported.isEmpty else { return }
        assets.append(contentsOf: imported)
        replicaStates.append(contentsOf: replicas)
        for asset in imported { assetsByID[asset.id] = asset }
        for replica in replicas { replicasByAssetID[replica.assetID, default: []].append(replica) }
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
            try persistImportedAssets(result.importedAssets, archiveBacked: result.archiveBackedReplicas)
            audit(.importEvent, "Imported \(result.importedAssets.count) asset(s) from \(result.batch.sourcePath) (\(result.duplicateFilenames.count) exact duplicate(s) skipped, \(result.failures.count) failure(s)).")
            openPolicyMigrations(result.cloudPlacements)
            if !result.importedAssets.isEmpty {
                reopenLivePhotoChecks(forNewlyImported: result.importedAssets)
                recoverCaptureDates()
                pairLivePhotos()
            }
            if !result.failures.isEmpty {
                lastError = "Import finished with \(result.failures.count) failure(s): \(result.failures.first!.error)"
            }
        } catch {
            lastError = "Import persistence failed: \(error.localizedDescription)"
        }
        isImporting = false
        loadAll()
    }

    private func enqueueTask(assetID: UUID, targetID: UUID, action: ReplicationAction) throws {
        let task = ReplicationTask(
            id: UUID(),
            assetID: assetID,
            targetID: targetID,
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
    func scanForTakeout(rootURL: URL, targetID: UUID?) {
        Task { await performTakeoutScan(rootURL: rootURL, targetID: targetID) }
    }

    private func performTakeoutScan(rootURL: URL, targetID: UUID?) async {
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
                    // Attribute the archive to whichever managed drive its path
                    // sits on, rather than trusting what the caller passed.
                    // Scanning a folder rather than a drive passes no drive at
                    // all, and an archive with no drive is invisible to
                    // replication planning — its copy simply does not count.
                    let attributedDriveID = self.targetID(forPath: discovered.path) ?? targetID

                    if var existing = knownByPath[discovered.path] {
                        // Re-scan refreshes what detection can learn (size,
                        // export-set grouping added after first discovery)
                        // without touching import state.
                        let changed = existing.sizeBytes != discovered.sizeBytes
                            || existing.exportSetID != discovered.exportSetID
                            || existing.partNumber != discovered.partNumber
                            || (existing.targetID == nil && attributedDriveID != nil)
                            // The scan is looking straight at it, so whatever
                            // the catalog remembered about it being gone is
                            // out of date.
                            || existing.missingSince != nil
                        if changed {
                            existing.missingSince = nil
                            existing.sizeBytes = discovered.sizeBytes
                            existing.exportSetID = discovered.exportSetID
                            existing.partNumber = discovered.partNumber
                            existing.targetID = existing.targetID ?? attributedDriveID
                            try catalog.upsertTakeoutArchive(existing)
                            refreshedCount += 1
                        }
                    } else {
                        try catalog.upsertTakeoutArchive(TakeoutArchive(
                            id: UUID(),
                            path: discovered.path,
                            kind: discovered.kind,
                            sizeBytes: discovered.sizeBytes,
                            targetID: attributedDriveID,
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
            audit(.importEvent, "Takeout scan of \(rootURL.path): \(found.count) archive(s) found, \(newCount) new, \(refreshedCount) refreshed.", targetID: targetID)
        } catch {
            lastError = "Recording Takeout scan results failed: \(error.localizedDescription)"
        }
        takeoutActivity = nil
        loadAll()
    }

    func importTakeoutArchive(_ archiveID: UUID) {
        importTakeoutArchives([archiveID])
    }

    /// Imports one or more discovered archives — typically the parts of one
    /// split-download export set — serially, as a single import batch with
    /// cross-part duplicate detection. Imported assets record local presence
    /// only: the export proves the content was in Google when it was made, and
    /// the app has no account to ask about now.
    func importTakeoutArchives(_ archiveIDs: [UUID]) {
        Task { await performTakeoutImport(archiveIDs) }
    }

    private func performTakeoutImport(_ archiveIDs: [UUID]) async {
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
                let replicaContext: (targetID: UUID, mountPath: String)? = archive.kind == .folder
                    ? reachablePaths.first { archive.path.hasPrefix($0.value.path + "/") }
                        .map { (targetID: $0.key, mountPath: $0.value.path) }
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

                // The archive may live on a managed drive; if that drive is
                // unplugged or being released, stop at this chunk boundary.
                // The checkpoint written by the previous chunk makes the part
                // resumable, so stopping costs nothing but the current chunk.
                let sourceDriveID = targetID(forPath: archive.path)
                markBusy(sourceDriveID, true)
                defer { markBusy(sourceDriveID, false) }

                for chunk in stride(from: resumeFrom, to: partFiles.count, by: Self.importChunkSize).map({
                    Array(partFiles[$0..<min($0 + Self.importChunkSize, partFiles.count)])
                }) {
                    if let sourceDriveID,
                       reachablePaths[sourceDriveID] == nil || isQuiescing(sourceDriveID) {
                        let why = reachablePaths[sourceDriveID] == nil ? "disconnected" : "being released"
                        audit(.importEvent, "Import of \(archive.displayName) stopped at \(processedFiles) of \(partFiles.count) file(s): the drive is \(why). It will resume from here.")
                        abortedAt = archive.displayName
                        break
                    }
                    let hashSnapshot = knownHashes
                    let rulesSnapshot = policyRules
                    let result = await Task.detached(priority: .utility) {
                        await TakeoutImporter.importMedia(
                            from: workspace,
                            archiveName: archive.displayName,
                            knownContentHashes: hashSnapshot,
                            staging: stagingStore,
                            policyRules: rulesSnapshot,
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
                    let replicas = try catalog.transaction { () -> [TargetReplicaState] in
                        let written = try persistImportedAssets(
                            result.importedAssets,
                            archiveBacked: result.archiveBackedReplicas
                        )
                        try catalog.upsertImportBatch(batchSnapshot)
                        try catalog.upsertTakeoutArchive(checkpoint)
                        return written
                    }
                    archive = checkpoint
                    // Assets land Local-only — that is all hashing proves. A
                    // rule naming a cloud opens a pending migration instead.
                    openPolicyMigrations(result.cloudPlacements)
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
                    let targetName = targetsByID[context.targetID]?.name ?? "drive"
                    audit(.replication, "\(partArchiveBackedCount) asset(s) from \(archive.displayName) use their Takeout files as the \(targetName) replica — no duplicate copy queued for that drive.", targetID: context.targetID)
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
        // New assets are the only source of new pairs, so this is the natural
        // moment to reunite Live Photos — no user action required.
        reopenLivePhotoChecks(forNewlyImported: allImported)
        recoverCaptureDates()
        pairLivePhotos()
        backupCatalog(force: true)
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
            let archiveDriveID = targetID(forPath: archive.path)
            if let archiveDriveID, isQuiescing(archiveDriveID) || reachablePaths[archiveDriveID] == nil {
                audit(.importEvent, "Skipped extracting \(archive.displayName): its drive is unavailable.")
                break
            }
            let workers = ParallelZipExtraction.recommendedWorkerCount(destination: archive.url)
            takeoutActivity = TakeoutActivity(
                phase: .extracting,
                detail: archive.displayName,
                stepIndex: index + 1,
                stepCount: targets.count,
                note: "\(workers) parallel worker(s)"
            )
            do {
                markBusy(archiveDriveID, true)
                defer { markBusy(archiveDriveID, false) }
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
                    targetID: archive.targetID,
                    discoveredAt: Date(),
                    importedAt: nil,
                    importBatchID: nil,
                    importedAssetCount: 0,
                    skippedDuplicateCount: 0,
                    note: "Extracted in place from \(archive.displayName).",
                    exportSetID: components?.setID,
                    partNumber: components?.part
                ))
                audit(.importEvent, "Extracted \(archive.displayName) on its drive; imports will use the folder.", targetID: archive.targetID)
            } catch {
                // Keep going: a part that can't be extracted (e.g. space) can
                // still be imported from its zip via the Mac workspace.
                lastError = "Extraction failed at \(archive.displayName): \(error.localizedDescription)"
                audit(.importEvent, "Extraction of \(archive.displayName) failed (\(error.localizedDescription)); its zip will be imported the slower way.", targetID: archive.targetID)
            }
        }
        takeoutActivity = nil
        loadAll()
    }

    /// True when every asset of the batch is safe without its source archive:
    /// Local assets fully replicated to both targets (cloud-resident assets
    /// don't depend on local copies).
    /// O(1): the set is derived once per catalog change rather than scanning
    /// every asset per call — this is read from view bodies, once per row.
    func isBatchFullyReplicated(_ batchID: UUID?) -> Bool {
        guard let batchID else { return false }
        return fullyReplicatedBatchIDs.contains(batchID)
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
            lastError = "Not deleting \(archive.displayName): its imported assets are not yet fully replicated to both targets."
            return
        }
        // A folder whose files serve as a drive's archive-backed replicas is
        // load-bearing storage, not a redundant copy — deleting it would
        // destroy that drive's only copy of those assets.
        if let (targetID, mount) = reachablePaths.first(where: { archive.path.hasPrefix($0.value.path + "/") }) {
            let folderRelative = ReplicationService.volumeBackedPrefix
                + String(archive.path.dropFirst(mount.path.count + 1))
            let backingCount = replicaStates.filter {
                $0.targetID == targetID && $0.state == .present && ($0.relativePath?.hasPrefix(folderRelative) ?? false)
            }.count
            if backingCount > 0 {
                lastError = "Not deleting \(archive.displayName): its files are the \(targetsByID[targetID]?.name ?? "drive") replica for \(backingCount) asset(s). It is storage, not a redundant copy."
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
            audit(.system, "Deleted extracted folder \(archive.displayName) after verified replication; zip original retained.", targetID: archive.targetID)
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
    private func autoTakeoutPipeline(targetID: UUID) async {
        guard let mount = reachablePaths[targetID] else { return }
        guard !takeoutPipelineActiveTargetIDs.contains(targetID),
              !takeoutPipelineCompletedTargetIDs.contains(targetID)
        else { return }
        takeoutPipelineActiveTargetIDs.insert(targetID)
        defer {
            takeoutPipelineActiveTargetIDs.remove(targetID)
            takeoutPipelineCompletedTargetIDs.insert(targetID)
        }

        await performTakeoutScan(rootURL: mount, targetID: targetID)
        guard autoManageTakeout else { return }

        func onDrive() -> [TakeoutArchive] {
            takeoutArchives.filter { $0.path.hasPrefix(mount.path + "/") }
        }
        // Sets span targets: drive B's part 3 zip and drive A's imported part 3
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
                replicaStates.filter { $0.targetID == targetID && $0.state == .present }.map(\.assetID)
            )
            return assets.contains { $0.residency == .local && !present.contains($0.id) }
        }
        func partAlreadyBackedByThisDrive(_ archive: TakeoutArchive) -> Bool {
            guard let setID = archive.exportSetID else { return false }
            return takeoutArchives.contains { twin in
                twin.exportSetID == setID
                    && twin.partNumber == archive.partNumber
                    && twin.isImported
                    && twin.targetID == targetID
            }
        }

        // Cheapest evidence first. If this drive holds the same export parts
        // as another, the two-copy policy is already met and there is nothing
        // to reconcile or copy — checking that costs a directory listing,
        // whereas reconciling a zip means decompressing every entry inside it.
        applyArchiveLevelRedundancy()

        if driveIsMissingReplicas() {
            for archive in onDrive() where !archive.isImported
                && partImportedSomewhere(archive)
                && !partAlreadyBackedByThisDrive(archive) {
                await performTakeoutReconciliation(archive, targetID: targetID, mountURL: mount)
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
            await performTakeoutScan(rootURL: mount, targetID: targetID)
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
            await performTakeoutImport(toImport.map(\.id))
        }

        // Takeout splits Live Photos into a still and a movie; reunite them so
        // the motion halves do not sit in the grid as standalone videos.
        recoverCaptureDates()
        pairLivePhotos()
        // An import may have introduced parts that change the picture, so
        // re-evaluate which parts now exist twice.
        applyArchiveLevelRedundancy()

        // Parts the policy still wants elsewhere: move them while this drive
        // is here to give or receive them. Whether that means a direct copy,
        // parking a part on the Mac, or delivering one that has been waiting
        // depends on what else is plugged in, and is decided in the planner.
        refreshPartTransferPlan()
        if !partTransferPlan.isEmpty {
            await performExportPartTransfers()
        }

        // The catalog just changed materially (new assets, new replica
        // claims); snapshot it onto the drive it describes.
        backupCatalog()

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
    private func performTakeoutReconciliation(_ archiveConst: TakeoutArchive, targetID: UUID, mountURL: URL) async {
        guard takeoutActivity == nil, !isImporting else { return }
        var archive = archiveConst
        let targetName = targetsByID[targetID]?.name ?? "drive"
        takeoutActivity = TakeoutActivity(
            phase: .reconciling, detail: archive.displayName, note: "on \(targetName)"
        )

        let assetIDsByHash = Dictionary(assets.map { ($0.contentHash, $0.id) }, uniquingKeysWith: { first, _ in first })
        let present = Set(replicaStates.filter { $0.targetID == targetID && $0.state == .present }.map(\.assetID))
        let needing = Set(assets.filter { $0.residency == .local && !present.contains($0.id) }.map(\.id))

        var usedFastPath = false
        let result: TakeoutReconciler.Result
        if archive.kind == .folder {
            result = await Task.detached(priority: .utility) {
                TakeoutReconciler.reconcileFolder(
                    folderURL: archive.url, mountURL: mountURL, targetID: targetID,
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
                   targetID: targetID,
                   candidateDonors: donors,
                   folderTwins: folderTwins,
                   replicaStates: replicaStates,
                   assetsNeedingReplica: needing
               ) {
                result = fast
                usedFastPath = true
            } else {
                takeoutActivity = TakeoutActivity(
                    phase: .reconciling, detail: archive.displayName, note: "entry-by-entry on \(targetName)"
                )
                result = await Task.detached(priority: .utility) {
                    TakeoutReconciler.reconcileZip(
                        zipURL: archive.url, mountURL: mountURL, targetID: targetID,
                        assetIDsByHash: assetIDsByHash, assetsNeedingReplica: needing
                    )
                }.value
            }
        }

        do {
            for replica in result.claimedReplicas {
                try catalog.upsertReplicaState(replica)
            }
            try settleQueuedCopyTasks(assetIDs: Set(result.claimedReplicas.map(\.assetID)), targetID: targetID)
            archive.importedAt = Date()
            archive.importedAssetCount = result.claimedReplicas.count
            archive.note = "Reconciled: existing content on \(targetName) claimed as \(result.claimedReplicas.count) verified replica(s); nothing was copied."
            try catalog.upsertTakeoutArchive(archive)
            let method = usedFastPath ? "checksum match with a known identical zip" : "in-place hashing"
            audit(.replication, "\(archive.displayName) on \(targetName): \(result.claimedReplicas.count) of \(result.scannedFileCount) file(s) claimed as in-place replicas via \(method); queued copies cancelled.", targetID: targetID)
        } catch {
            lastError = "Reconciliation persistence failed: \(error.localizedDescription)"
        }
        takeoutActivity = nil
        loadAll()
    }

    /// Marks queued copy tasks for these assets on this drive as completed —
    /// their replica is satisfied in place, so nothing needs copying.
    private func settleQueuedCopyTasks(assetIDs: Set<UUID>, targetID: UUID) throws {
        let settled = replicationTasks.filter {
            $0.targetID == targetID && $0.action == .copy && $0.state == .queued && assetIDs.contains($0.assetID)
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
    /// Drops cloud-presence claims recorded by earlier versions, which asked
    /// the user to assert presence the app could not check.
    ///
    /// Migrating them away rather than leaving them behind a manual purge is
    /// the point: a claim with nothing behind it is not data worth keeping, and
    /// parking it behind an extra click leaves the same unfounded claim in the
    /// catalog for anything that reads it. Runs on every install, not just the
    /// one whose catalog was patched by hand.
    /// Deletes the cloud-resident placeholders seeded by earlier builds.
    ///
    /// Deleting assets is not something reconciliation does lightly, and this
    /// is the one case where it is right: these rows describe no file on any
    /// target, name a cloud the app has no way to ask about, and were written
    /// by a seeder that no longer exists. They cannot be reconciled into
    /// anything true, so leaving them means three permanent violations about
    /// content that was never real.
    private func withdrawUnverifiedCloudClaims(into repairs: inout [String]) {
        for domain in ResidencyDomain.allCases where domain != .local {
            let withdrawn = clearUnverifiedCloudPresence(domain: domain)
            guard withdrawn > 0 else { continue }
            repairs.append("withdrew \(withdrawn) unverified \(domain.displayName) presence claim(s) recorded by an earlier version")
        }
    }

    /// Returns how many claims were actually withdrawn — which is not every
    /// unverified claim: one with no local copy behind it is left alone.
    @discardableResult
    func clearUnverifiedCloudPresence(domain: ResidencyDomain) -> Int {
        guard domain != .local else { return 0 }
        let affected = assets.filter { CloudClaimWithdrawal.isWithdrawable($0, domain: domain) }
        guard !affected.isEmpty else { return 0 }
        do {
            for asset in affected {
                guard let updated = CloudClaimWithdrawal.withdraw(domain, from: asset) else { continue }
                try catalog.upsertAsset(updated)
            }
            let affectedIDs = Set(affected.map(\.id))
            for job in migrationJobs where job.state.isActive
                && job.fromDomain == domain
                && job.assetIDs.allSatisfy({ affectedIDs.contains($0) }) {
                try catalog.upsertMigrationJob(
                    MigrationService.fail(job, reason: "\(domain.displayName) presence was never verified and has been withdrawn")
                )
            }
            audit(.violation, "Withdrew unverified \(domain.displayName) presence from \(affected.count) asset(s) the app holds locally; it has no \(domain.displayName) connection and never confirmed the claim.")
            loadAll()
            return affected.count
        } catch {
            lastError = "Could not clear unverified cloud presence: \(error.localizedDescription)"
            return 0
        }
    }

    /// Assets carrying a cloud claim the app never verified.
    func unverifiedCloudPresenceCount(domain: ResidencyDomain) -> Int {
        assets.filter { CloudClaimWithdrawal.isUnverifiedClaim($0, domain: domain) }.count
    }

    func forgetTakeoutArchive(_ archiveID: UUID) {
        do {
            try catalog.deleteTakeoutArchive(id: archiveID)
            loadAll()
        } catch {
            lastError = "Could not forget archive: \(error.localizedDescription)"
        }
    }

    // MARK: - Targets

    /// Registers a mounted external volume as a target.
    func registerVolumeTarget(volume: VolumeInfo, name: String) {
        if let storage = TargetStorage.of(volume.url),
           let clash = existingTarget(sharing: storage) {
            lastError = "\(clash.name) is already on this storage. Two copies on one device do not survive that device failing, so they count as one."
            return
        }
        register(
            name: name.isEmpty ? volume.name : name,
            kind: .externalVolume,
            rootURL: volume.url,
            volumeUUID: volume.volumeUUID,
            configuredPath: nil
        )
    }

    /// Registers this machine as a target, holding its copy in the folder the
    /// user picked. The folder says where; the device is what is being
    /// registered — so a folder that turns out to live on an external drive is
    /// refused, because that drive is a target in its own right and would
    /// otherwise end up registered twice under two identities.
    func registerHostDeviceTarget(at url: URL, name: String) {
        let path = url.standardizedFileURL.path

        guard let storage = TargetStorage.of(url) else {
            lastError = "Could not work out which disk that folder is on, so it cannot be registered as a target."
            return
        }
        guard storage.isHostDevice else {
            lastError = "That folder is on \(storage.volumeURL.lastPathComponent), not on this machine's own disk. Register that drive as an external target instead — otherwise it would be registered twice under two identities."
            return
        }
        // Staging is transit: content sitting only there is replicated nowhere,
        // so a target inside it would have the app counting its own waiting
        // room as a copy.
        let stagingPath = staging.rootURL.standardizedFileURL.path
        if path == stagingPath || path.hasPrefix(stagingPath + "/") || stagingPath.hasPrefix(path + "/") {
            lastError = "That folder overlaps the app's staging area, which holds content no target has yet. Pick a folder outside it."
            return
        }
        if TargetMonitor.readMarker(at: url) != nil {
            lastError = "That folder already holds a target marker. Registering it again would give one place two identities."
            return
        }
        // Redundancy means surviving a device failing, so two targets on one
        // device are one copy — and the policy would count them as two.
        if let clash = existingTarget(sharing: storage) {
            lastError = "\(clash.name) is already on this storage. Two copies on one device do not survive that device failing, so they count as one."
            return
        }
        // Registering seeds a copy task for every Local asset, so this is not a
        // bookkeeping change: it is a decision to write the whole archive onto
        // this disk. Say the size, and refuse rather than fill the boot volume.
        let needed = localArchiveBytes
        let available = TakeoutExtractor.availableCapacity(onVolumeOf: url) ?? 0
        let reserve = ExportPartTransferPlanner.holdingAreaReserveBytes
        if needed + reserve > available {
            lastError = """
            Not registering \(url.lastPathComponent): holding a copy here needs \
            \(Formatters.bytes.string(fromByteCount: needed)) plus \
            \(Formatters.bytes.string(fromByteCount: reserve)) kept free, and this disk has \
            \(Formatters.bytes.string(fromByteCount: available)) available.
            """
            return
        }

        register(
            name: name.isEmpty ? url.lastPathComponent : name,
            kind: .hostDevice,
            rootURL: url,
            volumeUUID: nil,
            configuredPath: path
        )
    }

    /// What one full copy of the Local domain weighs. Live Photo motion halves
    /// are their own files on disk, so they count here even though the Library
    /// shows them as part of their still.
    var localArchiveBytes: Int64 {
        assets.filter { $0.residency == .local }.reduce(0) { $0 + $1.fileSize }
    }

    /// Drops a target from the registry, freeing its slot.
    ///
    /// Nothing on the target is deleted — forgetting says what the app manages,
    /// not what exists, and registering it again re-adopts the content in
    /// place. This is the way out of the registration cap: without it, a failed
    /// drive would leave the archive unable to restore its own redundancy.
    func forgetTarget(_ targetID: UUID) {
        guard let target = targetsByID[targetID] else { return }
        do {
            try catalog.deleteTarget(id: targetID)
            audit(.drive, "Forgot \(target.name). Its files were left untouched and the slot is free for a replacement.")
            lastRotPatrol[targetID] = nil
            lastAnchorCheck[targetID] = nil
            loadAll()
            rescanTargets()
        } catch {
            lastError = "Could not forget \(target.name): \(error.localizedDescription)"
        }
    }

    /// A registered target already living on the same storage, if any. Checked
    /// against where each target is reachable now, falling back to where it was
    /// last seen so an absent drive is not quietly forgotten.
    private func existingTarget(sharing storage: TargetStorage) -> ReplicationTarget? {
        targets.first { target in
            let candidate = reachablePaths[target.id]
                ?? target.configuredPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? target.lastKnownPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            guard let candidate,
                  let existing = TargetStorage.of(candidate) else { return false }
            return existing.isSamePlace(as: storage)
        }
    }

    private func register(
        name: String,
        kind: TargetKind,
        rootURL: URL,
        volumeUUID: String?,
        configuredPath: String?
    ) {
        let targetID = UUID()
        let token = UUID().uuidString
        let marker = TargetMarker(targetID: targetID, markerToken: token, appName: "heykinn-clicks")
        do {
            try TargetMonitor.writeMarker(marker, to: rootURL)
            let target = ReplicationTarget(
                id: targetID,
                name: name,
                kind: kind,
                volumeUUID: volumeUUID,
                markerToken: token,
                registeredAt: Date(),
                lastSeenAt: Date(),
                lastKnownPath: rootURL.path,
                configuredPath: configuredPath,
                replicaRootComponent: ReplicationTarget.defaultReplicaRoot
            )
            try catalog.upsertTarget(target)
            // Every existing Local asset owes this new target a replica.
            for asset in assets where asset.residency == .local {
                try enqueueTask(assetID: asset.id, targetID: targetID, action: .copy)
                try catalog.upsertReplicaState(TargetReplicaState(
                    assetID: asset.id,
                    targetID: targetID,
                    state: .pending,
                    relativePath: nil,
                    lastVerifiedAt: nil
                ))
            }
            audit(.drive, "Registered \(kind.displayName.lowercased()) target \(target.name); backlog seeded for existing Local assets.", targetID: targetID)
            loadAll()
            rescanTargets()
        } catch {
            lastError = "Target registration failed: \(error.localizedDescription)"
        }
    }

    /// Starts a sync for any reachable target that has work waiting.
    ///
    /// Auto-sync used to hang off the *connect* event alone, so work queued
    /// while a target was already connected — an import finishing, a target
    /// being registered, photos arriving from the Photos library — sat in the
    /// queue until the next unplug and replug. The trigger belongs on the work
    /// existing, not on the moment the target appeared.
    func startDueSyncsIfIdle() {
        guard autoSyncOnConnect, !isSyncing, !isImporting, !isTransferringParts else { return }
        guard takeoutActivity == nil else { return }
        for (targetID, _) in reachablePaths {
            guard !isBusy(targetID), !isQuiescing(targetID) else { continue }
            guard backlogCount(for: targetID) > 0 else { continue }
            syncDrive(targetID)
            return
        }
    }

    /// How often the patrol reads a ration of files from a reachable target.
    private static let rotPatrolInterval: TimeInterval = 30 * 60
    private var lastRotPatrol: [UUID: Date] = [:]

    /// Reads a small ration of the least recently checked replicas, in the
    /// background, on a target that is otherwise idle.
    ///
    /// This is the only thing in the system that can find bit rot: comparing
    /// trees compares recorded hashes, and a file whose bytes decayed still
    /// matches everything the catalog knows about it. Nothing else will ever
    /// notice, however long it sits there.
    ///
    /// Deliberately slow and small. It is not the basis for the verdict — an
    /// asset the patrol has not reached still meets the policy — it is what
    /// stops "meets the policy" from quietly ageing into a claim nobody has
    /// checked in a year. It yields to any real work, because a background
    /// check that competes with an import is worse than one that waits.
    func runRotPatrolIfDue(now: Date = Date()) {
        guard backgroundRotPatrol else { return }
        guard !isSyncing, !isImporting, !isTransferringParts, takeoutActivity == nil else { return }

        for (targetID, _) in reachablePaths {
            guard !isBusy(targetID), !isQuiescing(targetID) else { continue }
            if let last = lastRotPatrol[targetID],
               now.timeIntervalSince(last) < Self.rotPatrolInterval { continue }
            // Never queue behind work already waiting: the backlog is the
            // user's copies, and those matter more than a re-read.
            guard backlogCount(for: targetID) == 0 else { continue }

            lastRotPatrol[targetID] = now
            queueVerificationSweep(targetID, budget: .patrol, isPatrol: true)
            // One target per pass; two drives reading at once is exactly the
            // kind of background cost that gets noticed.
            return
        }
    }

    /// How often a reachable target's anchors are re-checked. Frequent enough
    /// that content moved under a drive left plugged in is noticed in about a
    /// minute; slow enough not to keep an external drive spinning for the sake
    /// of three `stat` calls.
    private static let anchorCheckInterval: TimeInterval = 60

    /// The cheap periodic check: are the few directories the recorded paths
    /// hang from still there?
    ///
    /// Comparing Merkle roots would not do this. Those roots are built from the
    /// hashes the catalog recorded, so they cannot change because something
    /// happened on disk — only because the catalog did. Answering "has anything
    /// moved?" needs to touch the disk, and this is the cheapest touch there
    /// is: a handful of `stat` calls, whatever the archive's size.
    ///
    /// Anything more thorough — a file gone from inside an intact directory, or
    /// bytes edited in place — costs an enumeration or a read, which is the
    /// sweep this design exists to avoid running on a timer.
    func checkAnchorsIfDue(now: Date = Date()) {
        for (targetID, mountURL) in reachablePaths {
            if let last = lastAnchorCheck[targetID],
               now.timeIntervalSince(last) < Self.anchorCheckInterval { continue }
            lastAnchorCheck[targetID] = now

            // A whole export part deleted under an intact directory is
            // invisible to the anchor check, and there are a handful of these
            // files against tens of thousands of replicas — so confirming they
            // are still there fits the same budget, and is the difference
            // between a lost copy noticed in a minute and one noticed at the
            // next reconnect. The replica pass is only worth its stats once
            // something has actually gone.
            if checkArchivePresence(for: targetID).vanished > 0 {
                checkReplicaStats(for: targetID)
            }

            guard let anchors = targetAnchors[targetID], !anchors.isEmpty else { continue }
            let moved = anchors.contains { anchor in
                !FileManager.default.fileExists(atPath: mountURL.appendingPathComponent(anchor).path)
            }
            guard moved else { continue }
            repairReplicaPaths(for: targetID)
        }
    }

    /// Checks that a reachable target's recorded paths still resolve, and
    /// repairs them when the content has simply moved.
    ///
    /// The trees cannot see this: a rename changes no hash, so two targets go
    /// on agreeing while one of them has no resolvable copy at all. A `stat`
    /// per directory catches it for microseconds, which is why it runs whenever
    /// a target is looked at rather than on a schedule.
    ///
    /// Every rewrite is confirmed to resolve before it is written. A rewrite is
    /// a guess about where content went, and an unverified guess in the catalog
    /// is worse than the broken path it replaces.
    @discardableResult
    func repairReplicaPaths(for targetID: UUID) -> (repaired: Int, unresolved: Int) {
        guard let target = targetsByID[targetID], let mountURL = reachablePaths[targetID] else {
            return (0, 0)
        }
        let mine = replicaStates.filter { $0.targetID == targetID && $0.state == .present }
        // Archives record absolute paths into the same content, so they move
        // with it. Planning from both means one pass repairs the replicas and
        // the export parts together, rather than leaving redundancy checks
        // reading a directory that is no longer there.
        let prefix = mountURL.path.hasSuffix("/") ? mountURL.path : mountURL.path + "/"
        let archivesHere = takeoutArchives.filter { $0.path.hasPrefix(prefix) }
        let recorded = mine.compactMap(\.relativePath)
            + archivesHere.map { ReplicaPathRepair.volumePrefix + $0.path.dropFirst(prefix.count) }
        guard !recorded.isEmpty else { return (0, 0) }

        let plan = ReplicaPathRepair.plan(recordedPaths: recorded, mountURL: mountURL)
        guard !plan.isEmpty else { return (0, 0) }

        var repaired = 0
        var unresolved = 0
        var repairedArchives = 0
        do {
            try catalog.transaction {
                for replica in mine {
                    guard let recordedPath = replica.relativePath,
                          recordedPath.hasPrefix(ReplicaPathRepair.volumePrefix) else { continue }
                    let absolute = mountURL.appendingPathComponent(
                        String(recordedPath.dropFirst(ReplicaPathRepair.volumePrefix.count))
                    )
                    guard !FileManager.default.fileExists(atPath: absolute.path) else { continue }

                    if let rewritten = ReplicaPathRepair.apply(plan, to: recordedPath) {
                        let candidate = mountURL.appendingPathComponent(
                            String(rewritten.dropFirst(ReplicaPathRepair.volumePrefix.count))
                        )
                        if FileManager.default.fileExists(atPath: candidate.path) {
                            var updated = replica
                            updated.relativePath = rewritten
                            try catalog.upsertReplicaState(updated)
                            repaired += 1
                            continue
                        }
                    }
                    // Not where the catalog says, and not found elsewhere. Say
                    // so rather than leaving a copy counted that is not there.
                    var updated = replica
                    updated.state = .missing
                    try catalog.upsertReplicaState(updated)
                    unresolved += 1
                }

                for archive in archivesHere {
                    guard !FileManager.default.fileExists(atPath: archive.path) else { continue }
                    let recordedPath = ReplicaPathRepair.volumePrefix + archive.path.dropFirst(prefix.count)
                    guard let rewritten = ReplicaPathRepair.apply(plan, to: recordedPath) else { continue }
                    let candidate = mountURL.appendingPathComponent(
                        String(rewritten.dropFirst(ReplicaPathRepair.volumePrefix.count))
                    )
                    guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                    var updated = archive
                    updated.path = candidate.path
                    try catalog.upsertTakeoutArchive(updated)
                    repairedArchives += 1
                }
            }
        } catch {
            lastError = "Could not repair moved replica paths: \(error.localizedDescription)"
            return (repaired, unresolved)
        }

        if repaired > 0 || repairedArchives > 0 {
            var what = ["\(repaired) replica(s)"]
            if repairedArchives > 0 { what.append("\(repairedArchives) export archive(s)") }
            audit(.replication, "\(target.name): content had moved; repointed \(what.joined(separator: " and ")) to their new location. Nothing was copied.", targetID: targetID)
        }
        if unresolved > 0 {
            audit(.violation, "\(target.name): \(unresolved) replica(s) are not where the catalog recorded them and were not found on the target.", targetID: targetID)
        }
        if repaired > 0 || unresolved > 0 || repairedArchives > 0 { loadAll() }
        return (repaired, unresolved)
    }

    /// Gathers what the app has scattered over a target into one folder, and
    /// puts delivered export parts beside the export they belong to.
    ///
    /// The app used to write three directories at a volume root —
    /// `HeykinnClicksReplicas`, `HeykinnClicksCatalogBackups`, and
    /// `HeykinnClicks Export Parts` — which reads as three unrelated
    /// applications having helped themselves to a drive that belongs to the
    /// user. One folder, `HeykinnClicks/`, and what is theirs stays theirs.
    ///
    /// Every move here is a rename within one volume: instant, and it moves no
    /// bytes. Nothing is moved out of a directory the user chose — the only
    /// files this relocates are ones the app put where it did because it had
    /// no better idea, and the catalog is repointed in the same pass so no
    /// copy is ever lost track of.
    @discardableResult
    func tidyAppFolders(for targetID: UUID) -> (folders: Int, parts: Int) {
        guard var target = targetsByID[targetID], let mountURL = reachablePaths[targetID] else {
            return (0, 0)
        }
        guard !isBusy(targetID), !isQuiescing(targetID), !isTransferringParts else { return (0, 0) }

        let fileManager = FileManager.default
        var movedFolders: [String] = []

        /// Renames a legacy directory under the app's folder, but only when
        /// there is nothing already at the destination — a half-migrated drive
        /// is worse than an untidy one.
        func relocate(legacy: String, to modern: String) -> Bool {
            let from = mountURL.appendingPathComponent(legacy, isDirectory: true)
            let to = mountURL.appendingPathComponent(modern, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: from.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !fileManager.fileExists(atPath: to.path) else { return false }
            do {
                try fileManager.createDirectory(
                    at: to.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: from, to: to)
                return true
            } catch {
                lastError = "Could not tidy \(legacy) on \(target.name): \(error.localizedDescription)"
                return false
            }
        }

        // Replicas are recorded relative to the target's replica root, so
        // moving the directory and updating that one stored value repoints
        // every replica under it at once — no per-file catalog write.
        if target.replicaRootComponent == ReplicationTarget.legacyReplicaRoot {
            if relocate(legacy: ReplicationTarget.legacyReplicaRoot, to: ReplicationTarget.defaultReplicaRoot) {
                target.replicaRootComponent = ReplicationTarget.defaultReplicaRoot
                do {
                    try catalog.upsertTarget(target)
                    movedFolders.append("replicas")
                } catch {
                    lastError = "Could not record \(target.name)'s replica root: \(error.localizedDescription)"
                }
            } else if !fileManager.fileExists(
                atPath: mountURL.appendingPathComponent(ReplicationTarget.legacyReplicaRoot).path
            ) {
                // Nothing was ever written to the old root on this target, so
                // the new one is simply where its replicas go from now on.
                target.replicaRootComponent = ReplicationTarget.defaultReplicaRoot
                try? catalog.upsertTarget(target)
            }
        }

        // Snapshots are found by listing the directory rather than recorded in
        // the catalog, so moving it is the whole migration.
        if relocate(legacy: CatalogBackupService.legacyDirectoryName, to: CatalogBackupService.directoryName) {
            movedFolders.append("catalog backups")
        }

        // Export parts record absolute paths, so these rows move with the file.
        let legacyParts = mountURL
            .appendingPathComponent(ExportPartRelay.legacyOnDriveDirectoryName, isDirectory: true).path
        if relocate(legacy: ExportPartRelay.legacyOnDriveDirectoryName, to: ExportPartRelay.onDriveDirectoryName) {
            movedFolders.append("delivered export parts")
            let modernParts = ExportPartRelay.destinationDirectory(onMount: mountURL).path
            do {
                try catalog.transaction {
                    for var archive in takeoutArchives where archive.path.hasPrefix(legacyParts + "/") {
                        archive.path = modernParts + archive.path.dropFirst(legacyParts.count)
                        try catalog.upsertTakeoutArchive(archive)
                    }
                }
            } catch {
                lastError = "Could not repoint moved export parts on \(target.name): \(error.localizedDescription)"
            }
        }
        if !movedFolders.isEmpty {
            targets = (try? catalog.fetchTargets()) ?? targets
            takeoutArchives = (try? catalog.fetchTakeoutArchives()) ?? takeoutArchives
            audit(
                .drive,
                "\(target.name): gathered the app's \(movedFolders.joined(separator: ", ")) into one \(ReplicationTarget.appFolderName) folder. Files were renamed within the drive; nothing was copied and none of your own folders were touched.",
                targetID: targetID
            )
        }

        let parts = rehomeDeliveredParts(for: targetID, mountURL: mountURL, targetName: target.name)
        if !movedFolders.isEmpty || parts > 0 { loadAll() }
        return (movedFolders.count, parts)
    }

    /// Moves a delivered export part out of the app's folder and in beside the
    /// rest of its export, once the drive shows where that export lives.
    ///
    /// A part is delivered to the app's folder only when the receiving drive
    /// held none of its set — a genuine "nowhere better to put this". That
    /// answer expires: the moment the drive does hold the rest of the set, the
    /// part has somewhere it belongs, and leaving it at the root is what split
    /// a twelve-part export across two directories.
    ///
    /// The destination usually already has a catalog row, and that is the
    /// normal case rather than an error: the part was delivered precisely
    /// *because* the copy that used to sit there was deleted, and the row for
    /// that copy outlived it. One path is one row — the archive path is
    /// unique — so the delivered copy moves *into* that row rather than beside
    /// it, and the row it came from goes away. It is not a lost copy; it is a
    /// copy this method itself moved.
    private func rehomeDeliveredParts(for targetID: UUID, mountURL: URL, targetName: String) -> Int {
        let appParts = ExportPartRelay.destinationDirectory(onMount: mountURL).path + "/"
        let strays = takeoutArchives.filter {
            $0.targetID == targetID && $0.holdsBytes && $0.path.hasPrefix(appParts)
        }

        var moved = 0
        var example: String?
        for archive in strays {
            guard let setID = archive.exportSetID,
                  let home = ExportSetLayout.home(
                      forSet: setID, onMount: mountURL, archives: takeoutArchives
                  )
            else { continue }
            let destination = home.appendingPathComponent((archive.path as NSString).lastPathComponent)
            // Never write over something already sitting there. Two files with
            // this name means a question the app cannot answer by guessing.
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }

            let source = URL(fileURLWithPath: archive.path)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                lastError = "Could not move \(archive.displayName) beside its export: \(error.localizedDescription)"
                continue
            }
            do {
                try catalog.transaction {
                    if var occupant = takeoutArchives.first(
                        where: { $0.path == destination.path && $0.id != archive.id }
                    ) {
                        // The row that already describes this path keeps its
                        // import history — what was imported out of this part
                        // happened, whichever copy of it is sitting here now.
                        // What it takes from the arriving copy is everything
                        // that describes the bytes, and it takes the *absence*
                        // of a content hash too: nobody has read these bytes
                        // in full, and the hash of the file that used to be
                        // here would be a claim about a different file.
                        occupant.sizeBytes = archive.sizeBytes
                        occupant.contentHash = archive.contentHash
                        occupant.quickChecksum = archive.quickChecksum
                        occupant.kind = archive.kind
                        occupant.missingSince = nil
                        try catalog.upsertTakeoutArchive(occupant)
                        try catalog.deleteTakeoutArchive(id: archive.id)
                    } else {
                        var updated = archive
                        updated.path = destination.path
                        try catalog.upsertTakeoutArchive(updated)
                    }
                }
                if example == nil { example = archive.displayName }
                moved += 1
            } catch {
                // The catalog is the record of where things are. If it would
                // not take the move, the move did not happen: put the file
                // back rather than leave the two disagreeing.
                try? FileManager.default.moveItem(at: destination, to: source)
                lastError = "Could not record the move of \(archive.displayName): \(error.localizedDescription)"
            }
        }

        let pruned = pruneMovedPartRecords(for: targetID, mountURL: mountURL)
        guard moved > 0 || pruned > 0 else { return 0 }
        takeoutArchives = (try? catalog.fetchTakeoutArchives()) ?? takeoutArchives
        if moved > 0 {
            audit(
                .drive,
                "\(targetName): moved \(moved) delivered export part(s) (e.g. \(example ?? "one")) in beside the rest of their export, where this drive already keeps it. A rename within the drive; no bytes moved.",
                targetID: targetID
            )
        }
        return moved
    }

    /// Drops archives that merely *contain* other archives.
    ///
    /// A folder somebody made to keep their exports in is not an export. When
    /// one gets registered as an archive, it is the sum of everything beneath
    /// it: its size double-counts every part inside it in any total, it shows
    /// up as an export of its own belonging to no set, and it reports importing
    /// nothing because everything in it was already imported as the parts it is
    /// made of.
    ///
    /// The rule needs no heuristic. One archive's path containing another's
    /// says it outright, and the containing one is the one that is wrong: a zip
    /// holds no rows, and an export folder inside an export folder is not a
    /// shape Takeout produces.
    @discardableResult
    func dropContainerArchives() -> Int {
        let byPath = takeoutArchives.map { ($0, $0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
        let containers = byPath.filter { candidate, prefix in
            candidate.kind == .folder
                && byPath.contains { other, _ in other.id != candidate.id && other.path.hasPrefix(prefix) }
        }
        guard !containers.isEmpty else { return 0 }
        do {
            try catalog.transaction {
                for (container, _) in containers { try catalog.deleteTakeoutArchive(id: container.id) }
            }
        } catch {
            lastError = "Could not tidy nested export records: \(error.localizedDescription)"
            return 0
        }
        audit(
            .importEvent,
            "Stopped treating \(containers.count) folder(s) as export(s) of their own (e.g. \(containers[0].0.displayName)): each one holds other exports rather than being one. Nothing on disk was touched, and the exports inside them are unaffected."
        )
        loadAll()
        return containers.count
    }

    /// Drops rows for parts recorded as gone from the app's own delivery
    /// folder while the same part is present elsewhere on the same target.
    ///
    /// Such a row is not a lost copy. The app's folder is the app's own
    /// waiting room, and a part that left it while still being on the drive
    /// left because the app moved it. Reporting that as a missing copy is the
    /// app describing its own tidying as data loss — and unlike a real
    /// absence, it can never resolve, because nothing will ever put a file
    /// back at that path.
    private func pruneMovedPartRecords(for targetID: UUID, mountURL: URL) -> Int {
        let appParts = ExportPartRelay.destinationDirectory(onMount: mountURL).path + "/"
        let presentStems = Set(
            takeoutArchives
                .filter { $0.targetID == targetID && $0.holdsBytes && !$0.path.hasPrefix(appParts) }
                .compactMap(\.exportPartStem)
        )
        let phantoms = takeoutArchives.filter {
            $0.targetID == targetID
                && !$0.holdsBytes
                && $0.path.hasPrefix(appParts)
                && $0.exportPartStem.map(presentStems.contains) == true
        }
        guard !phantoms.isEmpty else { return 0 }
        do {
            try catalog.transaction {
                for phantom in phantoms { try catalog.deleteTakeoutArchive(id: phantom.id) }
            }
        } catch {
            lastError = "Could not clear moved-part records: \(error.localizedDescription)"
            return 0
        }
        return phantoms.count
    }

    /// Re-confirms the target is still the thing sitting at this path, checked
    /// immediately before an absence is written down.
    ///
    /// A drive pulled mid-pass makes every `stat` fail at once, and the marker
    /// is what separates "the file is gone" from "the drive is gone". Without
    /// it an unplug would be recorded as data loss across the whole target —
    /// the loudest possible way to be wrong.
    private func targetIsStillMounted(_ targetID: UUID) -> Bool {
        guard let target = targetsByID[targetID], let mountURL = reachablePaths[targetID] else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mountURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        // A marker naming a different target means another volume is mounted
        // where this one was; absences measured against it are about the wrong
        // disk. No marker at all is not disqualifying — a volume matched by
        // UUID after its marker was deleted is still that volume.
        if let marker = TargetMonitor.readMarker(at: mountURL) {
            return marker.targetID == target.id && marker.markerToken == target.markerToken
        }
        return true
    }

    /// Confirms the export archives recorded on a connected target are still
    /// there, and records the ones that are not.
    ///
    /// The scan that discovers archives only ever adds, and path repair only
    /// looks at whole directories moving — so a zip deleted from inside a
    /// folder that still exists was invisible to both, and the catalog went on
    /// counting it as one of the part's copies. That is the archive claiming
    /// redundancy it does not have, which is the one thing it may never do.
    ///
    /// Only ever run against a target that is reachable right now. An archive
    /// on an unplugged drive is not missing, it is out of reach, and the two
    /// must never be confused: absent targets still count.
    @discardableResult
    func checkArchivePresence(for targetID: UUID) -> (vanished: Int, returned: Int) {
        guard let target = targetsByID[targetID], let mountURL = reachablePaths[targetID] else {
            return (0, 0)
        }
        // Only archives whose recorded path is under this target's *current*
        // mount. One recorded at a mount point the volume no longer has is not
        // missing, it is being looked for in the wrong place — repointing that
        // is path repair's job, and calling it loss here would be a claim made
        // from the wrong address.
        let prefix = mountURL.path.hasSuffix("/") ? mountURL.path : mountURL.path + "/"
        let mine = takeoutArchives.filter { $0.path.hasPrefix(prefix) }
        guard !mine.isEmpty else { return (0, 0) }

        var vanished: [TakeoutArchive] = []
        var returned: [TakeoutArchive] = []
        for archive in mine {
            let exists = FileManager.default.fileExists(atPath: archive.path)
            if !exists, archive.holdsBytes {
                vanished.append(archive)
            } else if exists, !archive.holdsBytes {
                returned.append(archive)
            }
        }
        guard !vanished.isEmpty || !returned.isEmpty else { return (0, 0) }

        // Absence is only news if the drive is still here to be absent from.
        if !vanished.isEmpty, !targetIsStillMounted(targetID) { return (0, 0) }

        do {
            try catalog.transaction {
                for var archive in vanished {
                    archive.missingSince = Date()
                    try catalog.upsertTakeoutArchive(archive)
                }
                for var archive in returned {
                    archive.missingSince = nil
                    try catalog.upsertTakeoutArchive(archive)
                }
            }
        } catch {
            lastError = "Could not record what \(target.name) still holds: \(error.localizedDescription)"
            return (0, 0)
        }

        if !vanished.isEmpty {
            audit(
                .violation,
                "\(target.name): \(vanished.count) export archive(s) the catalog recorded are no longer on the drive (e.g. \(vanished[0].displayName)). They no longer count as copies of their parts.",
                targetID: targetID
            )
        }
        if !returned.isEmpty {
            audit(
                .drive,
                "\(target.name): \(returned.count) export archive(s) previously recorded as gone are back where the catalog expects them.",
                targetID: targetID
            )
        }
        loadAll()
        return (vanished.count, returned.count)
    }

    /// How one target compares with every other, by root. No reads: this is
    /// the comparison the trees exist for.
    ///
    /// A match means the two targets record the same content, which is a
    /// different and weaker statement than "the bytes on both are good" — only
    /// reading them back says that.
    /// The size/mtime gate: stat everything this target holds, and aim a read
    /// at whatever moved.
    ///
    /// Runs on connect, after path repair. A file edited in place is invisible
    /// to the anchor check and to the trees, so without this it waits for the
    /// rot patrol — and the patrol reads about forty files every half hour,
    /// which on an archive this size is a lap measured in weeks.
    ///
    /// Nothing here records damage. A changed stat says the file is not what
    /// the app last saw, not that its bytes are wrong; the queued read is what
    /// settles that. Marking the replica stale instead would report drift
    /// nobody checked.
    ///
    /// A file that is not there at all is the exception, and it is not a claim
    /// about bytes — it is the file's absence, which is exactly what a stat
    /// establishes. Path repair has already run by this point and found
    /// nowhere else on the target for it to be, so the honest record is
    /// `missing`. Nothing else in the app sees a single file deleted from
    /// inside a directory that still exists: the trees hold recorded hashes
    /// and go on agreeing, the anchor check only watches whole directories,
    /// and path repair never looks at archive-backed replicas at all.
    @discardableResult
    func checkReplicaStats(for targetID: UUID) -> (files: Int, changed: Int, baselines: Int, missing: Int) {
        guard let target = targetsByID[targetID], let mountURL = reachablePaths[targetID] else {
            return (0, 0, 0, 0)
        }
        let mine = replicaStates.filter { $0.targetID == targetID && $0.state == .present }
        guard !mine.isEmpty else { return (0, 0, 0, 0) }

        // Where each export part sits on this target, so the thousands of
        // replicas it backs cost one stat between them.
        //
        // Taken from the archives themselves rather than the replication plan:
        // the plan drops an archive already known to be gone, and that is
        // precisely the archive whose replicas still need stat-ing. Preference
        // goes to a copy that holds bytes, then to the pristine zip over the
        // folder extracted from it — and when every copy of a part on this
        // target is gone, the preferred path is still named, so the stat can
        // report it absent rather than the part being quietly skipped.
        var archivePartPaths: [String: String] = [:]
        let ranked = takeoutArchives
            .filter { $0.targetID == targetID }
            .sorted { a, b in
                func rank(_ archive: TakeoutArchive) -> Int {
                    (archive.holdsBytes ? 0 : 2) + (archive.kind == .zip ? 0 : 1)
                }
                return rank(a) < rank(b)
            }
        for archive in ranked {
            guard let stem = archive.exportPartStem else { continue }
            if archivePartPaths[stem] == nil { archivePartPaths[stem] = archive.path }
        }

        let subjects = ReplicaStatGate.subjects(
            replicas: mine,
            assetsByID: assetsByID,
            target: target,
            mountURL: mountURL,
            archivePartPaths: archivePartPaths
        )

        var updated: [TargetReplicaState] = []
        var changedAssetIDs: Set<UUID> = []
        var absent: [TargetReplicaState] = []
        var firstReason: String?
        var absentExample: String?
        var baselines = 0

        for subject in subjects {
            let observed = ReplicaStatGate.observe(subject.url)
            for replica in subject.replicas {
                let expectedSize = subject.isOwnFile ? assetsByID[replica.assetID]?.fileSize : nil
                switch ReplicaStatGate.finding(
                    for: replica, expectedSize: expectedSize, observed: observed
                ) {
                case .unchanged:
                    continue
                case .absent:
                    // Path repair ran first and had its chance to find where
                    // this went. Still not there means it did not move, it is
                    // gone — and leaving it counted as present is the app
                    // claiming a copy nobody has.
                    absent.append(replica)
                    if absentExample == nil { absentExample = subject.url.lastPathComponent }
                    continue
                case .changed(let reason):
                    // Deliberately *not* re-baselined here. The read that
                    // settles this is what may write a new baseline; recording
                    // one now would mean a quit before the queue drained left
                    // the file looking untouched forever.
                    changedAssetIDs.insert(replica.assetID)
                    if firstReason == nil { firstReason = reason }
                    continue
                case .baselineRecorded:
                    baselines += 1
                }
                guard let observed else { continue }
                var replica = replica
                replica.observedSize = observed.size
                replica.observedModifiedAt = observed.modifiedAt
                updated.append(replica)
            }
        }

        // Every stat fails alike when the drive is pulled mid-pass, so an
        // absence is only worth recording if the target is still there to be
        // absent from. Silence is the right answer to an unplug; writing
        // "missing" across a whole target because it went away is not.
        if !absent.isEmpty, !targetIsStillMounted(targetID) {
            absent = []
            absentExample = nil
        }

        guard !updated.isEmpty || !changedAssetIDs.isEmpty || !absent.isEmpty else {
            return (subjects.count, 0, 0, 0)
        }
        do {
            try catalog.transaction {
                for replica in updated { try catalog.upsertReplicaState(replica) }
                for var replica in absent {
                    replica.state = .missing
                    try catalog.upsertReplicaState(replica)
                }
            }
        } catch {
            lastError = "Could not record what \(target.name) holds: \(error.localizedDescription)"
            return (subjects.count, changedAssetIDs.count, baselines, 0)
        }

        if !absent.isEmpty {
            audit(
                .violation,
                "\(target.name): \(absent.count) cop(ies) the catalog recorded are not on the drive (e.g. \(absentExample ?? "a file the catalog expected")), and were not found anywhere else on it. They no longer count towards the redundancy policy.",
                targetID: targetID
            )
        }

        if changedAssetIDs.isEmpty {
            // A first pass over a target that predates this check writes
            // baselines and finds nothing, which is the truthful outcome and
            // worth saying once so the next connect's findings mean something.
            if baselines > 0 {
                audit(
                    .drive,
                    "\(target.name): recorded the size and date of \(baselines) file(s) across \(subjects.count) file(s) on disk. Nothing was compared — there was nothing yet to compare against.",
                    targetID: targetID
                )
            }
            loadAll()
            return (subjects.count, 0, baselines, absent.count)
        }

        audit(
            .drive,
            "\(target.name): \(changedAssetIDs.count) file(s) changed since the app last looked (e.g. \(firstReason ?? "size or date moved")). Reading them back to find out whether the content is still right.",
            targetID: targetID
        )
        loadAll()
        queueVerificationSweep(targetID, budget: .unlimited, restrictedTo: changedAssetIDs)
        return (subjects.count, changedAssetIDs.count, baselines, absent.count)
    }

    func agreement(for targetID: UUID) -> [(other: ReplicationTarget, agrees: Bool, divergentCount: Int)] {
        guard let mine = targetTrees[targetID] else { return [] }
        return targets.filter { $0.id != targetID }.compactMap { other in
            guard let theirs = targetTrees[other.id] else { return nil }
            if mine.agrees(with: theirs) {
                return (other, true, 0)
            }
            return (other, false, mine.divergentKeys(from: theirs).count)
        }
    }

    func backlogCount(for targetID: UUID) -> Int {
        backlogSummary(for: targetID).total
    }

    /// Describes the drive's pending work by action and estimated bytes, so
    /// the UI can say "22,880 to verify (~120 GB)" instead of a bare number.
    func backlogSummary(for targetID: UUID) -> BacklogSummary {
        var summary = BacklogSummary()
        for task in replicationTasks where task.targetID == targetID && task.state == .queued {
            switch task.action {
            case .copy: summary.copyCount += 1
            case .verify: summary.verifyCount += 1
            case .remove: summary.removeCount += 1
            }
            // Removals move no data; copies and verifies read the whole file.
            if task.action != .remove, let asset = assetsByID[task.assetID] {
                summary.estimatedBytes += asset.fileSize
            }
        }
        return summary
    }

    /// Drops queued tasks of one action for a drive. Only ever discards work
    /// that can be re-queued on demand — never replica state or files.
    func clearQueuedTasks(for targetID: UUID, action: ReplicationAction) {
        let doomed = replicationTasks.filter {
            $0.targetID == targetID && $0.state == .queued && $0.action == action
        }
        guard !doomed.isEmpty else { return }
        do {
            try catalog.transaction {
                for task in doomed { try catalog.deleteReplicationTask(id: task.id) }
            }
            let targetName = targetsByID[targetID]?.name ?? "drive"
            audit(.replication, "Cleared \(doomed.count) queued \(action.rawValue) task(s) for \(targetName); they can be re-queued at any time.", targetID: targetID)
            loadAll()
        } catch {
            lastError = "Could not clear queued tasks: \(error.localizedDescription)"
        }
    }

    func lastCompletedSync(for targetID: UUID) -> Date? {
        replicationTasks
            .filter { $0.targetID == targetID && $0.state == .completed }
            .compactMap(\.completedAt)
            .max()
    }

    /// Requests a backlog sync for one connected drive. If another drive is
    /// already syncing, the request queues behind it (syncs stay serial).
    func syncDrive(_ targetID: UUID) {
        if isSyncing {
            if syncProgress?.targetID != targetID && !pendingSyncTargetIDs.contains(targetID) {
                pendingSyncTargetIDs.append(targetID)
            }
            return
        }
        runSync(targetID)
    }

    /// Stops the running sync after the current task finishes. Remaining tasks
    /// stay queued, so the next sync resumes exactly where this one stopped.
    func cancelSync() {
        syncCancelRequested = true
    }

    private func runSync(_ targetID: UUID) {
        guard syncProgress == nil else { return }
        guard let drive = targetsByID[targetID], let mountURL = reachablePaths[targetID] else {
            lastError = "Drive is not connected."
            startNextPendingSync()
            return
        }
        let queued = replicationTasks
            .filter { $0.targetID == targetID && $0.state == .queued }
            .sorted { $0.queuedAt < $1.queuedAt }
        guard !queued.isEmpty else {
            startNextPendingSync()
            return
        }

        syncCancelRequested = false
        syncProgress = SyncProgress(
            targetID: targetID,
            targetName: drive.name,
            totalTasks: queued.count,
            completedTasks: 0,
            failedTasks: 0,
            currentItem: nil
        )
        let assetsSnapshot = assetsByID
        let replicasByKey = Dictionary(uniqueKeysWithValues: replicaStates.map { ($0.id, $0) })

        Task { @MainActor in
            markBusy(targetID, true)
            defer { markBusy(targetID, false) }
            var completed = 0
            var failed = 0
            var interruptionReason: String?

            for task in queued {
                if syncCancelRequested {
                    interruptionReason = "cancelled"
                    break
                }
                // Mount events update reachablePaths on the main actor between
                // tasks, so an unplug mid-sync is noticed here.
                guard reachablePaths[targetID] != nil else {
                    interruptionReason = "drive disconnected"
                    break
                }
                if isQuiescing(targetID) {
                    interruptionReason = "drive is being released"
                    break
                }
                let asset = assetsSnapshot[task.assetID]
                let existingReplica = replicasByKey["\(task.assetID.uuidString)/\(task.targetID.uuidString)"]
                syncProgress?.currentItem = asset?.originalFilename
                // Source can be Mac staging or any readable copy on another
                // connected drive, so drive-only assets replicate drive-to-drive.
                let sourceURL = asset.flatMap { localFileURL(for: $0) }
                let result = await Task.detached(priority: .utility) {
                    ReplicationService.perform(task, drive: drive, mountURL: mountURL, asset: asset, sourceURL: sourceURL, existingReplica: existingReplica)
                }.value
                do {
                    if !result.isTransient {
                        try catalog.upsertReplicationTask(result.task)
                        if let replica = result.replica {
                            try catalog.upsertReplicaState(replica)
                        }
                    }
                } catch {
                    lastError = "Sync persistence failed: \(error.localizedDescription)"
                }
                if result.isTransient {
                    // Every following task needs the same missing source, so
                    // there is nothing to gain by grinding through them.
                    interruptionReason = "no drive holding the source files is connected"
                    break
                }
                if result.task.state == .completed { completed += 1 } else { failed += 1 }
                syncProgress?.completedTasks = completed
                syncProgress?.failedTasks = failed
            }

            if var updatedDrive = targetsByID[targetID] {
                updatedDrive.lastSeenAt = Date()
                try? catalog.upsertTarget(updatedDrive)
            }
            let remaining = queued.count - completed - failed
            var summary = "Sync with \(drive.name): \(completed) task(s) completed, \(failed) failed"
            if let reason = interruptionReason {
                summary += "; \(reason) with \(remaining) task(s) still queued"
            }
            audit(.replication, summary + ".", targetID: targetID)
            syncProgress = nil
            loadAll()
            startNextPendingSync()
        }
    }

    private func startNextPendingSync() {
        while !pendingSyncTargetIDs.isEmpty {
            let next = pendingSyncTargetIDs.removeFirst()
            if reachablePaths[next] != nil && backlogCount(for: next) > 0 {
                runSync(next)
                return
            }
        }
    }

    /// Checks this drive's content for damage.
    ///
    /// Content held as export parts is confirmed by comparing whole-file
    /// checksums between targets — a handful of reads that settles everything
    /// inside those parts at once. Only what is not covered that way falls
    /// back to reading files one at a time.
    func verifyDrive(_ targetID: UUID) {
        guard reachablePaths[targetID] != nil else {
            lastError = "Drive is not connected."
            return
        }
        if archiveChecksumCheckWouldHelp(targetID) {
            // Fast comparison first: seconds rather than minutes, and enough
            // to catch the failures that actually befall archive copies. A
            // full byte-for-byte comparison stays available in the menu.
            spotCheckExportParts()
            return
        }
        queueVerificationSweep(targetID, budget: .sweep)
    }

    /// Whether this drive holds export parts whose copies could be compared by
    /// checksum right now, covering replicas not yet confirmed.
    func archiveChecksumCheckWouldHelp(_ targetID: UUID) -> Bool {
        let unconfirmed = Set(
            replicaStates
                .filter { $0.targetID == targetID && $0.state == .present && $0.lastVerifiedAt == nil }
                .compactMap(\.relativePath)
        )
        guard !unconfirmed.isEmpty else { return false }
        return archivePlan.partsMeetingPolicy.contains { part in
            part.copies.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                && unconfirmed.contains { $0.contains(part.displayName) }
        }
    }

    /// Queues a bounded verification sweep: the stalest replicas first, up to
    /// a file and byte budget. Re-hashing a whole archive in one go can mean
    /// hours of drive reads, so a sweep takes a slice and the next sweep picks
    /// up where this one left off. Replicas already queued are not re-queued.
    /// Queues reads against only the assets the trees say disagree.
    ///
    /// This is what the trees buy: a divergence found by comparing roots costs
    /// nothing to find, and re-reading it costs only the files responsible
    /// rather than a sweep of the whole target. Falls back to nothing when the
    /// targets agree — there is no work to do, and reading anyway would be the
    /// timer this replaced.
    func queueDivergenceCheck(_ targetID: UUID) {
        guard reachablePaths[targetID] != nil else {
            lastError = "That target is not reachable."
            return
        }
        let divergent = Set(
            agreement(for: targetID)
                .filter { !$0.agrees }
                .flatMap { comparison -> [UUID] in
                    guard let mine = targetTrees[targetID],
                          let theirs = targetTrees[comparison.other.id] else { return [] }
                    return mine.divergentKeys(from: theirs).compactMap(UUID.init(uuidString:))
                }
        )
        guard !divergent.isEmpty else {
            audit(.replication, "\(targetsByID[targetID]?.name ?? "Target") holds the same content as every other target; nothing to re-read.", targetID: targetID)
            return
        }
        queueVerificationSweep(targetID, budget: .unlimited, restrictedTo: divergent)
    }

    func queueVerificationSweep(
        _ targetID: UUID,
        budget: VerificationBudget = .sweep,
        restrictedTo assetIDs: Set<UUID>? = nil,
        isPatrol: Bool = false
    ) {
        guard let drive = targetsByID[targetID], reachablePaths[targetID] != nil else {
            lastError = "Drive is not connected."
            return
        }
        let alreadyQueued = Set(
            replicationTasks
                .filter { $0.targetID == targetID && $0.state == .queued && $0.action == .verify }
                .map(\.assetID)
        )
        // Oldest verification first; never-verified replicas come first of all.
        let candidates = replicaStates
            .filter {
                $0.targetID == targetID
                    && ($0.state == .present || $0.state == .stale || $0.state == .drift)
                    && !alreadyQueued.contains($0.assetID)
                    && (assetIDs?.contains($0.assetID) ?? true)
            }
            .sorted { ($0.lastVerifiedAt ?? .distantPast) < ($1.lastVerifiedAt ?? .distantPast) }

        var queued = 0
        var bytes: Int64 = 0
        do {
            try catalog.transaction {
                for replica in candidates {
                    if queued >= budget.maxFiles || bytes >= budget.maxBytes { break }
                    try enqueueTask(assetID: replica.assetID, targetID: targetID, action: .verify)
                    queued += 1
                    bytes += assetsByID[replica.assetID]?.fileSize ?? 0
                }
            }
            guard queued > 0 else {
                // The patrol runs on a timer and finding nothing due is its
                // normal state; saying so every half hour is just noise.
                if !isPatrol {
                    audit(.drive, "File check on \(drive.name): nothing due.", targetID: targetID)
                }
                return
            }
            let remaining = candidates.count - queued
            audit(
                .drive,
                isPatrol
                    ? "Background check on \(drive.name): reading \(queued) file(s) (~\(Formatters.bytes.string(fromByteCount: bytes))) least recently checked; \(remaining) still to come."
                    : "Queued a file check of \(queued) file(s) (~\(Formatters.bytes.string(fromByteCount: bytes))) on \(drive.name)"
                        + (remaining > 0 ? "; \(remaining) more will follow in later sweeps." : "."),
                targetID: targetID
            )
            loadAll()
            syncDrive(targetID)
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

    // MARK: - Cloud connectors

    /// The verifier seam, populated as connectors come alive. Everything that
    /// asks about cloud presence goes through this — never straight to a
    /// provider — so nothing can bypass the refuse-to-guess default.
    private(set) var cloudVerifiers = CloudVerifierRegistry.unconnected
    @Published private(set) var applePhotosState: ApplePhotosConnectionState = .notDetermined
    /// Whether the connected Photos library syncs to iCloud. PhotoKit cannot
    /// report this, so it is asked once and stored as topology — a statement
    /// about the user's setup, verifiable by them in seconds, and never a
    /// claim about any individual photo. Nil means unanswered.
    @Published var iCloudPhotosEnabled: Bool? {
        didSet {
            if let iCloudPhotosEnabled {
                defaults.set(iCloudPhotosEnabled, forKey: "iCloudPhotosEnabled")
            }
        }
    }
    @Published private(set) var isIndexingApplePhotos = false
    @Published private(set) var isImportingFromApplePhotos = false
    @Published private(set) var applePhotosImportSummary: String?
    /// Copying indexed Photos-library originals into the archive so they gain
    /// the same protection as everything else. On by default: a photo the app
    /// can see but not protect is the problem this app exists to solve.
    @Published var importFromApplePhotos: Bool = true {
        didSet { defaults.set(importFromApplePhotos, forKey: "importFromApplePhotos") }
    }
    private var lastApplePhotosImport: Date?
    @Published private(set) var applePhotosLibraryCount = 0
    @Published private(set) var isCheckingApplePhotos = false
    @Published private(set) var lastApplePhotosCheckSummary: String?

    /// Photos found in the library that the archive does not hold. Only ever
    /// labelled AppleCloud when the user has told us the library syncs;
    /// otherwise they are a local library's contents, which is a different
    /// fact and must not be dressed up as a cloud one.
    var applePhotosResidency: ResidencyDomain { iCloudPhotosEnabled == true ? .appleCloud : .local }

    func refreshApplePhotosState() {
        applePhotosState = ApplePhotosVerifier.connectionState
        applePhotosLibraryCount = ApplePhotosVerifier.libraryAssetCount
        if applePhotosState == .connected {
            cloudVerifiers.verifiers[.appleCloud] = ApplePhotosVerifier()
        } else {
            cloudVerifiers.verifiers[.appleCloud] = UnconnectedCloudVerifier(domain: .appleCloud)
        }
    }

    func connectApplePhotos() async {
        let state = await ApplePhotosVerifier.requestAccess()
        refreshApplePhotosState()
        switch state {
        case .connected:
            audit(.system, "Apple Photos connected. Presence is now verified in the background by hashing originals — checked, not assumed.")
            checkApplePhotosPresence()
        case .denied:
            lastError = "Photos access was declined. Grant it under System Settings → Privacy & Security → Photos, then try again."
        case .unavailable(let reason):
            lastError = reason
        case .notDetermined:
            break
        }
    }

    /// Reads the whole Photos library from metadata — no downloads — and
    /// merges it into the catalog so the Library shows one archive rather than
    /// two.
    ///
    /// A library photo that matches one the archive already holds becomes a
    /// **counterpart link** on the existing asset, not a second row: the same
    /// photograph in two encodings is one picture. Only photos the archive has
    /// never seen become rows of their own, carrying the provider's identifier
    /// so re-indexing updates them instead of duplicating them.
    func indexApplePhotos() {
        guard applePhotosState == .connected, !isIndexingApplePhotos else { return }
        mergeLibraryIndex(ApplePhotosVerifier.indexLibrary())
    }

    /// The catalog side of indexing, kept apart from PhotoKit so the
    /// link-or-add decision can be exercised against a library that does not
    /// exist on this machine.
    func mergeLibraryIndex(_ items: [ApplePhotosVerifier.LibraryItem]) {
        guard !isIndexingApplePhotos else { return }
        applePhotosLibraryCount = items.count
        guard !items.isEmpty else {
            lastApplePhotosCheckSummary = CloudVerificationError.libraryUnavailable(.appleCloud).localizedDescription
            return
        }
        isIndexingApplePhotos = true

        // Index the archive by capture second so matching is a lookup rather
        // than a scan of everything for every library item.
        var localByInstant: [Int: [Asset]] = [:]
        for asset in assets where asset.providerLocalID == nil {
            guard let date = asset.captureDate else { continue }
            localByInstant[Int(date.timeIntervalSince1970), default: []].append(asset)
        }
        let alreadyIndexed = Set(assets.compactMap(\.providerLocalID))

        var linked = 0
        var added = 0
        let residency = applePhotosResidency
        let now = Date()
        do {
            try catalog.transaction {
                for item in items where !alreadyIndexed.contains(item.localIdentifier) {
                    var nearby: [Asset] = []
                    if let captureDate = item.captureDate {
                        let instant = Int(captureDate.timeIntervalSince1970)
                        for offset in -1...1 {
                            nearby.append(contentsOf: localByInstant[instant + offset] ?? [])
                        }
                    }
                    let unclaimed = nearby.filter { $0.providerLocalID == nil }
                    if var match = ApplePhotosVerifier.counterpart(for: item, among: unclaimed) {
                        // Same photograph, different file. A link, not presence.
                        match.providerLocalID = item.localIdentifier
                        match.updatedDate = now
                        try catalog.upsertAsset(match)
                        linked += 1
                        continue
                    }
                    try catalog.upsertAsset(Asset(
                        id: UUID(),
                        kind: item.kind,
                        originalFilename: item.filename,
                        importOrigin: .appleExport,
                        captureDate: item.captureDate,
                        importDate: now,
                        updatedDate: now,
                        fileSize: 0,
                        pixelWidth: item.pixelWidth,
                        pixelHeight: item.pixelHeight,
                        // Not a content hash: the bytes were never read. Scoped
                        // by the provider id so it can never collide with a
                        // real hash and never groups as a duplicate.
                        contentHash: Asset.providerIndexHashPrefix + item.localIdentifier,
                        residency: residency,
                        residencySource: .importDefault,
                        presence: residency == .appleCloud
                            ? DomainPresence(local: false, appleCloud: true, googleCloud: false)
                            : DomainPresence(local: true, appleCloud: false, googleCloud: false),
                        stagingRelativePath: nil,
                        importBatchID: nil,
                        exifSummary: [:],
                        // Enumerating the library *is* checking it: these rows
                        // exist because the provider listed them.
                        cloudPresenceEvidence: residency == .appleCloud ? .verified : .none,
                        cloudPresenceCheckedAt: residency == .appleCloud ? now : nil,
                        providerLocalID: item.localIdentifier
                    ))
                    added += 1
                }
            }
        } catch {
            lastError = "Could not index Apple Photos: \(error.localizedDescription)"
            isIndexingApplePhotos = false
            return
        }
        let label = residency == .appleCloud ? "Apple Cloud" : "this device's Photos library"
        audit(.system, "Apple Photos index: \(items.count) item(s) in the library — \(added) added as \(label), \(linked) linked to photos the archive already holds.")
        lastApplePhotosCheckSummary = "\(added.formatted()) added · \(linked.formatted()) linked"
        isIndexingApplePhotos = false
        loadAll()
    }

    /// What reclamation would release if it existed, computed from evidence the
    /// app already holds. Nothing acts on this: it removes nothing, and it is
    /// here so the preconditions are visible rather than only written down.
    var reclamationPlan: ReclamationPlanner.Plan {
        let agreeing = Set(targets.map(\.id).filter { targetID in
            agreement(for: targetID).allSatisfy(\.agrees)
        })
        return ReclamationPlanner.plan(
            assets: assets,
            replicasByAssetID: replicasByAssetID,
            registeredTargetIDs: Set(targets.map(\.id)),
            agreeingTargetIDs: agreeing,
            policy: redundancyPolicy
        )
    }

    /// Assets indexed from the Photos library whose bytes the app does not yet
    /// hold. These are visible to the app and protected by nothing.
    var applePhotosAwaitingImport: [Asset] {
        assets.filter { $0.providerLocalID != nil && $0.isIndexedOnly }
    }

    /// Starts draining the backlog if it is not already running.
    ///
    /// This is a finite job the user asked for, not perpetual maintenance, so
    /// it runs to completion rather than trickling: rationing it to a batch a
    /// minute turned two minutes of work into half an hour of waiting. It
    /// still yields to real work — an import or a sync stops it until they are
    /// done — and each batch is small enough to stay responsive.
    func importFromApplePhotosIfDue(now: Date = Date()) {
        guard importFromApplePhotos, applePhotosState == .connected else { return }
        guard !isSyncing, !isImporting, !isTransferringParts, takeoutActivity == nil else { return }
        guard !isImportingFromApplePhotos else { return }
        guard !applePhotosAwaitingImport.isEmpty else { return }
        importOriginalsFromApplePhotos()
    }

    /// How originals leave the Photos library. A property rather than a call
    /// straight into PhotoKit, so what this import decides about each item —
    /// merge, stage, or pair — can be tested against a library that does not
    /// exist on the machine running the tests.
    var exportOriginalFromPhotos: (String, URL) async throws -> ApplePhotosVerifier.ExportedOriginal =
        { try await ApplePhotosVerifier.exportOriginal(localIdentifier: $0, to: $1) }

    /// A file pulled out of the library and put into staging.
    private struct StagedOriginal {
        var assetID: UUID
        var filename: String
        var relativePath: String
        var hash: String
        var size: Int64
    }

    /// What the archive should do about one indexed library item, once its
    /// bytes have been read.
    private struct PhotosImportOutcome {
        var indexed: Asset
        /// The staged still — nil when the bytes turned out to be a file the
        /// archive already held.
        var still: StagedOriginal?
        /// Set instead of `still`: the asset the indexed row folds into.
        var mergedInto: UUID?
        /// The movie half of a Live Photo, when it is content the archive does
        /// not already hold.
        var motion: StagedOriginal?
        /// An asset already in the catalog that turns out to *be* this item's
        /// motion half. Not new content — a link Photos can confirm and the
        /// content-identifier pairer would otherwise have to guess at.
        var existingMotionID: UUID?
    }

    /// Copies a batch of indexed originals into staging and queues them for
    /// replication, so photos the Photos library holds become photos the
    /// archive protects.
    ///
    /// Bytes decide what happens to each one. If the exported original hashes
    /// to something the archive already holds, this was the *same file* all
    /// along — the indexed row is folded into the existing asset rather than
    /// stored twice, and that asset gains verified Apple presence, because
    /// hashing just proved it. Only genuinely new content is staged.
    ///
    /// A Live Photo arrives as two files and is stored as two assets, linked.
    /// Taking only the still would have handed the archive a flattened
    /// photograph and left the motion behind in a library the whole point is
    /// to stop depending on.
    func importOriginalsFromApplePhotos(limit: Int = 25) {
        guard !isImportingFromApplePhotos else { return }
        let batch = Array(applePhotosAwaitingImport.prefix(limit))
        guard !batch.isEmpty else { return }
        isImportingFromApplePhotos = true

        let staging = self.staging
        let scratch = staging.rootURL.appendingPathComponent("apple-export", isDirectory: true)
        let existingHashes = Dictionary(assets.filter { !$0.isIndexedOnly }
            .map { ($0.contentHash, $0.id) }, uniquingKeysWith: { first, _ in first })
        let export = exportOriginalFromPhotos

        Task { [weak self] in
            func stage(_ url: URL, as assetID: UUID, hash: String) throws -> StagedOriginal {
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
                let relativePath = try staging.stage(
                    fileAt: url, assetID: assetID, fileExtension: url.pathExtension.lowercased()
                )
                return StagedOriginal(
                    assetID: assetID,
                    filename: url.lastPathComponent,
                    relativePath: relativePath,
                    hash: hash,
                    size: size
                )
            }

            var outcomes: [PhotosImportOutcome] = []
            var failures = 0

            for asset in batch {
                guard let providerLocalID = asset.providerLocalID else { continue }
                do {
                    let exported = try await export(providerLocalID, scratch)
                    defer {
                        for url in exported.all { try? FileManager.default.removeItem(at: url) }
                    }

                    var outcome = PhotosImportOutcome(indexed: asset)
                    let stillHash = try HashingService.sha256(of: exported.still)
                    if let existing = existingHashes[stillHash] {
                        outcome.mergedInto = existing
                    } else {
                        outcome.still = try stage(exported.still, as: asset.id, hash: stillHash)
                    }

                    if let motionURL = exported.motion {
                        let motionHash = try HashingService.sha256(of: motionURL)
                        if let existing = existingHashes[motionHash] {
                            outcome.existingMotionID = existing
                        } else {
                            outcome.motion = try stage(motionURL, as: UUID(), hash: motionHash)
                        }
                    }
                    outcomes.append(outcome)
                } catch {
                    failures += 1
                }
            }
            await MainActor.run {
                self?.recordApplePhotosImport(outcomes: outcomes, failures: failures)
            }
        }
    }

    private func recordApplePhotosImport(outcomes: [PhotosImportOutcome], failures: Int) {
        var stagedCount = 0
        var mergedCount = 0
        var pairedCount = 0
        let now = Date()
        do {
            try catalog.transaction {
                for outcome in outcomes {
                    // The asset the still ends up as, whether it was staged
                    // fresh or folded into one already held. The motion half
                    // hangs off it either way.
                    var stillAsset: Asset?

                    if let still = outcome.still {
                        var updated = outcome.indexed
                        updated.contentHash = still.hash
                        updated.fileSize = still.size
                        updated.stagingRelativePath = still.relativePath
                        updated.presence.local = true
                        updated.updatedDate = now
                        try catalog.upsertAsset(updated)
                        try queueReplicationOfNewlyHeld(updated.id)
                        stillAsset = updated
                        stagedCount += 1
                    } else if let existingID = outcome.mergedInto {
                        // Byte-identical to something already held: one
                        // photograph, one row. The survivor gains proven Apple
                        // presence.
                        if var existing = assetsByID[existingID] {
                            existing.presence.appleCloud = iCloudPhotosEnabled == true
                            existing.cloudPresenceEvidence = iCloudPhotosEnabled == true ? .verified : .none
                            existing.cloudPresenceCheckedAt = now
                            existing.providerLocalID = outcome.indexed.providerLocalID
                            existing.updatedDate = now
                            try catalog.upsertAsset(existing)
                            stillAsset = existing
                        }
                        try catalog.deleteAsset(id: outcome.indexed.id)
                        mergedCount += 1
                    }

                    guard let stillID = stillAsset?.id else { continue }
                    // One still holds one motion half; a re-run must not add a
                    // second.
                    guard livePhotoMotionByStillID[stillID] == nil else { continue }

                    if let motion = outcome.motion {
                        try catalog.upsertAsset(Asset(
                            id: motion.assetID,
                            kind: .video,
                            originalFilename: motion.filename,
                            importOrigin: .appleExport,
                            captureDate: outcome.indexed.captureDate,
                            importDate: now,
                            updatedDate: now,
                            fileSize: motion.size,
                            pixelWidth: nil,
                            pixelHeight: nil,
                            contentHash: motion.hash,
                            residency: outcome.indexed.residency,
                            residencySource: .importDefault,
                            presence: DomainPresence(local: true, appleCloud: false, googleCloud: false),
                            stagingRelativePath: motion.relativePath,
                            importBatchID: nil,
                            exifSummary: [:],
                            livePhotoStillID: stillID
                        ))
                        try queueReplicationOfNewlyHeld(motion.assetID)
                        pairedCount += 1
                    } else if let existingMotionID = outcome.existingMotionID,
                              var existingMotion = assetsByID[existingMotionID],
                              existingMotion.livePhotoStillID == nil,
                              existingMotionID != stillID {
                        // The archive already held the movie, unlinked. Photos
                        // says which still it belongs to, which is stronger
                        // than the identifier match the pairer would make.
                        existingMotion.livePhotoStillID = stillID
                        existingMotion.updatedDate = now
                        try catalog.upsertAsset(existingMotion)
                        pairedCount += 1
                    } else {
                        continue
                    }

                    if var still = stillAsset, still.kind != .livePhoto {
                        still.kind = .livePhoto
                        still.updatedDate = now
                        try catalog.upsertAsset(still)
                    }
                }
            }
        } catch {
            lastError = "Could not bring Photos originals into the archive: \(error.localizedDescription)"
            isImportingFromApplePhotos = false
            return
        }
        var parts: [String] = []
        if stagedCount > 0 { parts.append("\(stagedCount) copied in and queued for replication") }
        if mergedCount > 0 { parts.append("\(mergedCount) already held byte-for-byte, merged") }
        if pairedCount > 0 { parts.append("\(pairedCount) Live Photo motion half(s) kept with their still") }
        if failures > 0 { parts.append("\(failures) original(s) could not be exported") }
        if !parts.isEmpty {
            audit(.importEvent, "Photos library: " + parts.joined(separator: "; ") + ".")
        }
        let remaining = max(applePhotosAwaitingImport.count - stagedCount - mergedCount, 0)
        applePhotosImportSummary = remaining > 0
            ? "\(remaining.formatted()) still to bring in"
            : "all indexed photos are in the archive"
        isImportingFromApplePhotos = false
        loadAll()
        // Straight on to the next batch while there is a backlog: the job is
        // finite and the user is waiting for it, not for a schedule.
        if remaining > 0 { importFromApplePhotosIfDue() }
    }

    /// Every target owes a copy of content the archive has just taken on — the
    /// same path any other Local asset takes.
    private func queueReplicationOfNewlyHeld(_ assetID: UUID) throws {
        for target in targets {
            try enqueueTask(assetID: assetID, targetID: target.id, action: .copy)
            try catalog.upsertReplicaState(TargetReplicaState(
                assetID: assetID, targetID: target.id,
                state: .pending, relativePath: nil, lastVerifiedAt: nil
            ))
        }
    }

    /// Checks a small batch of Local assets against Apple Photos, oldest
    /// checks first, and records what hashing actually established.
    ///
    /// A found asset gains *verified* Apple presence — which, alongside Local
    /// residency, is a two-domain coexistence the Violations screen surfaces
    /// rather than hides. That is the model working: the overlap is real, and
    /// resolving it is a migration or (eventually) reclamation, never a
    /// silent edit.
    /// How often the background presence scan takes a batch, and how old a
    /// check must be before an asset is worth re-checking. Connecting is the
    /// consent; after that the scan paces itself — a manual "check 25 now"
    /// button would be 850 clicks of the same thing.
    private static let applePhotosScanInterval: TimeInterval = 10 * 60
    private static let applePhotosRecheckAge: TimeInterval = 30 * 24 * 3600
    private var lastApplePhotosScan: Date?

    /// Runs off the periodic tick, like the rot patrol: only when connected,
    /// only when the app is otherwise idle, one batch at a time, oldest
    /// checks first. Goes quiet by itself once everything eligible has been
    /// checked within the re-check window.
    func checkApplePhotosPresenceIfDue(now: Date = Date()) {
        guard applePhotosState == .connected else { return }
        guard !isSyncing, !isImporting, !isTransferringParts, takeoutActivity == nil else { return }
        if let last = lastApplePhotosScan, now.timeIntervalSince(last) < Self.applePhotosScanInterval { return }
        lastApplePhotosScan = now
        checkApplePhotosPresence()
    }

    func checkApplePhotosPresence(limit: Int = 25) {
        guard !isCheckingApplePhotos else { return }
        guard let verifier = cloudVerifiers.verifier(for: .appleCloud), verifier.isConnected else {
            return
        }
        let staleBefore = Date().addingTimeInterval(-Self.applePhotosRecheckAge)
        let batch = Array(
            assets
                .filter {
                    $0.residency == .local && !$0.isLivePhotoMotion && $0.captureDate != nil
                        && ($0.cloudPresenceCheckedAt ?? .distantPast) < staleBefore
                }
                .sorted { ($0.cloudPresenceCheckedAt ?? .distantPast) < ($1.cloudPresenceCheckedAt ?? .distantPast) }
                .prefix(limit)
        )
        guard !batch.isEmpty else { return }
        isCheckingApplePhotos = true
        Task { [weak self] in
            do {
                let results = try await verifier.verifyPresence(of: batch)
                await MainActor.run { self?.recordApplePhotosResults(results, requested: batch.count) }
            } catch {
                await MainActor.run {
                    // Not an error the user caused, and not a result: say so
                    // in the status line rather than recording anything.
                    self?.lastApplePhotosCheckSummary = error.localizedDescription
                    self?.isCheckingApplePhotos = false
                }
            }
        }
    }

    private func recordApplePhotosResults(_ results: [UUID: Bool], requested: Int) {
        var found = 0
        var absent = 0
        do {
            try catalog.transaction {
                for (id, present) in results {
                    guard var asset = assetsByID[id] else { continue }
                    asset.presence.appleCloud = present
                    asset.cloudPresenceEvidence = present ? .verified : .none
                    asset.cloudPresenceCheckedAt = Date()
                    asset.updatedDate = Date()
                    try catalog.upsertAsset(asset)
                    if present { found += 1 } else { absent += 1 }
                }
            }
        } catch {
            lastError = "Could not record Apple Photos results: \(error.localizedDescription)"
            isCheckingApplePhotos = false
            return
        }
        let unsearchable = requested - results.count
        var line = "Apple Photos check: \(found) of \(results.count) byte-identical in the Photos library on this Mac"
        if results.isEmpty && unsearchable > 0 {
            line = "Apple Photos check: none of \(requested) could be compared — their originals are not on this Mac (an optimised library with iCloud Photos off keeps previews, not originals)"
        }
        if found > 0 {
            line += " — recorded as verified presence; the Local coexistence shows in Violations until migrated or reclaimed"
        }
        if unsearchable > 0 { line += "; \(unsearchable) had no capture date to search by" }
        audit(.system, line + ".")
        lastApplePhotosCheckSummary = results.isEmpty && unsearchable > 0
            ? "originals not on this Mac — nothing could be compared"
            : "\(found) found · \(absent) not found"
                + (unsearchable > 0 ? " · \(unsearchable) originals unavailable" : "")
        isCheckingApplePhotos = false
        loadAll()
    }

    func savePolicyRule(_ rule: PolicyRule) {
        do {
            try catalog.upsertPolicyRule(rule)
            audit(.policy, "Saved policy rule \(rule.name) → \(rule.targetResidency.displayName).")
            loadAll()
            // Acting by default: a saved rule applies to the archive that
            // exists, not only to files that arrive later.
            applyPolicyRules()
        } catch {
            lastError = "Policy save failed: \(error.localizedDescription)"
        }
    }

    /// Re-evaluates the rules against every asset a rule may govern.
    ///
    /// Manual overrides and migration-assigned residency always win, so they
    /// are never touched. For everything else the winning rule updates the
    /// recorded *source* (policy vs import default); residency itself never
    /// changes here — an asset's residency is what its presence supports, and
    /// a rule naming a cloud opens a pending migration rather than a label.
    func applyPolicyRules() {
        var sourceUpdates = 0
        var placements: [ResidencyDomain: [UUID]] = [:]
        do {
            try catalog.transaction {
                for asset in assets {
                    guard asset.residency == .local,
                          asset.residencySource == .policy || asset.residencySource == .importDefault,
                          !asset.isLivePhotoMotion else { continue }
                    let decision = PolicyEngine.assignResidency(
                        kind: asset.kind,
                        origin: asset.importOrigin,
                        fileSize: asset.fileSize,
                        rules: policyRules
                    )
                    if decision.source != asset.residencySource {
                        var updated = asset
                        updated.residencySource = decision.source
                        updated.updatedDate = Date()
                        try catalog.upsertAsset(updated)
                        sourceUpdates += 1
                    }
                    if let target = decision.pendingCloudTarget {
                        placements[target, default: []].append(asset.id)
                    }
                }
            }
        } catch {
            lastError = "Could not re-apply policy rules: \(error.localizedDescription)"
            return
        }
        openPolicyMigrations(placements)
        if sourceUpdates > 0 {
            audit(.policy, "Re-applied rules: \(sourceUpdates) asset(s) changed between rule-assigned and default.")
        }
        if sourceUpdates > 0 { loadAll() }
    }

    /// Turns rule intents into pending Local → cloud migration jobs — the only
    /// legal doorway to a cloud residency. Jobs stay pending; execution is
    /// manual until a connector can carry it out. Assets already covered by an
    /// active job to the same domain are skipped, so re-running rules never
    /// stacks duplicate jobs.
    private func openPolicyMigrations(_ placements: [ResidencyDomain: [UUID]]) {
        for (domain, assetIDs) in placements where domain != .local {
            let covered = Set(migrationJobs
                .filter { $0.state.isActive && $0.toDomain == domain }
                .flatMap(\.assetIDs))
            let remaining = assetIDs.filter { !covered.contains($0) }
            guard !remaining.isEmpty else { continue }
            do {
                let job = try MigrationService.createJob(
                    assetIDs: remaining,
                    from: .local,
                    to: domain,
                    note: "Queued by policy rule. Content stays Local until the migration runs; cloud-side execution is manual until a connector exists."
                )
                try catalog.upsertMigrationJob(job)
                migrationJobs.insert(job, at: 0)
                audit(.policy, "Policy rules queued \(remaining.count) asset(s) for migration to \(domain.displayName) (pending).")
            } catch {
                lastError = "Could not queue policy migration: \(error.localizedDescription)"
            }
        }
    }

    func deletePolicyRule(_ rule: PolicyRule) {
        do {
            try catalog.deletePolicyRule(id: rule.id)
            audit(.policy, "Deleted policy rule \(rule.name).")
            loadAll()
            applyPolicyRules()
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
                targets: targets,
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

}
