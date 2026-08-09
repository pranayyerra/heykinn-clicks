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
    /// Whether a staged copy is released once the archive's own drives hold
    /// the content safely. On, because staging is transit and the alternative
    /// is a permanent second copy of everything on the boot disk that nothing
    /// ever counted as protection.
    @Published var reclaimStagingWhenSafe: Bool = true {
        didSet { defaults.set(reclaimStagingWhenSafe, forKey: "reclaimStagingWhenSafe") }
    }

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

    // A global `redundancyPolicy` used to live here: one copy count for the
    // whole archive, with a slider under Policies and a ceiling of "however
    // many devices are registered". Every one of those pieces was answering a
    // question that now belongs to the source — how many copies of *these*
    // photos, on *which* devices — and a single archive-wide number could only
    // ever contradict the sources it sat above. It is gone rather than demoted:
    // left as a default it would have kept being read as the real answer.
    //
    // `newSourceDefaults` below is what remains, and it is not a policy. It
    // remembers the last answer given so the add sheet opens prefilled; it
    // binds nothing, and changing it changes no photo's placement.

    /// An unmanaged external volume just appeared; the UI asks whether to use
    /// it as managed local storage (and/or scan it for Takeout).
    @Published var connectPrompt: VolumeInfo?

    /// A folder somebody chose that is really a Google export, held back so
    /// the app can offer to bring it in the way that keeps it whole.
    @Published var takeoutRedirect: TakeoutRedirect?

    /// A folder somebody chose that sits on a drive the app does not manage,
    /// held back long enough to offer the version of this that costs nothing.
    @Published var unmanagedSourceOffer: UnmanagedSourceOffer?

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

    /// What the user has already decided about each disk. Owns what used to be
    /// `ignoredVolumeKeys`, which could only say "stop asking" and had no way
    /// back — see `Services/AccessGrants.swift`.
    let accessGrants: AccessGrants

    /// Each thing the user added, with its own copy count and destinations.
    @Published private(set) var sources: [PhotoArchiveSource] = []
    /// Which source each asset came from. A side map rather than a field on
    /// `Asset` — see `CatalogStore.fetchSourceIDsByAsset`.
    @Published private(set) var sourceIDByAsset: [UUID: UUID] = [:]

    var sourcesByID: [UUID: PhotoArchiveSource] {
        Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// How each group of photos is kept: copies and named devices. Separate from
    /// the source, which records where they came from and never changes.
    @Published private(set) var storageGroups: [StorageGroup] = []
    /// Which group each asset is in. A strict partition — one group per asset,
    /// because a policy needs one answer.
    @Published private(set) var storageGroupIDByAsset: [UUID: UUID] = [:]

    /// Albums and people, by the photos carrying them.
    ///
    /// Published, unlike the payloads they are derived from. The distinction is
    /// size and purpose: a payload is 600 bytes of provider JSON read when
    /// somebody opens one photo, and a tag is two short strings the Library
    /// filters on while scrolling.
    @Published private(set) var assetIDsByTag: [TagKey: Set<UUID>] = [:]

    /// What each album says about itself, by title.
    ///
    /// Twenty-nine small structs, so published like the tags rather than read
    /// per redraw. The payloads they come from stay where they are.
    @Published private(set) var albumDetails: [String: AlbumDetail] = [:]

    /// A tag as a dictionary key — its kind and its value.
    struct TagKey: Hashable {
        var kind: AssetTag.Kind
        var value: String
    }

    /// Every album, commonest first, for the filter that browses them.
    func tagValues(ofKind kind: AssetTag.Kind) -> [(value: String, count: Int)] {
        assetIDsByTag
            .filter { $0.key.kind == kind }
            .map { (value: $0.key.value, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.value < $1.value : $0.count > $1.count }
    }

    var storageGroupsByID: [UUID: StorageGroup] {
        Dictionary(storageGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The group an asset belongs to, if it has one.
    func storageGroup(forAsset assetID: UUID) -> StorageGroup? {
        storageGroupIDByAsset[assetID].flatMap { storageGroupsByID[$0] }
    }

    /// What the next source starts with: whatever the last one used.
    ///
    /// The tenth folder going to the same two devices should cost a click, not
    /// a decision — asking the same question ten times is how a considered
    /// choice becomes a reflex.
    var newSourceDefaults: StorageGroup.Defaults {
        get {
            guard let data = defaults.data(forKey: "newSourceDefaults"),
                  let decoded = try? JSONDecoder().decode(
                    StorageGroup.Defaults.self, from: data
                  )
            else {
                // Before anything has been chosen: two copies where there are
                // two devices to put them on, otherwise as many as there are.
                // It is the setup most people describe when asked, and it
                // arrives in the sheet ticked and changeable rather than as a
                // hidden rule.
                let wanted = min(
                    StorageGroup.Defaults.initial.desiredCopies,
                    max(targets.count, 1)
                )
                return StorageGroup.Defaults(
                    desiredCopies: wanted,
                    destinationTargetIDs: Array(targets.map(\.id).prefix(wanted)),
                    destinationMode: .automatic
                )
            }
            // A device forgotten since the default was saved is dropped rather
            // than carried as a destination nothing can satisfy.
            let live = Set(targets.map(\.id))
            return StorageGroup.Defaults(
                desiredCopies: decoded.desiredCopies,
                destinationTargetIDs: decoded.destinationTargetIDs.filter(live.contains),
                destinationMode: decoded.destinationMode
            )
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "newSourceDefaults")
        }
    }

    /// The grants, republished through the store.
    ///
    /// `AccessGrants` is observable in its own right, but no view observes it:
    /// they observe `AppStore`, which is the orchestrator every screen already
    /// has. Reading `store.accessGrants.grants` from a view therefore renders
    /// correctly once and never updates — revoking a grant would leave its row
    /// on screen. Mirroring it here is what makes the Access list live.
    @Published private(set) var accessGrantList: [AccessGrant] = []

    private let defaults: UserDefaults
    /// Everything on this machine the app writes into. Staging, the export-part
    /// relay, the thumbnail cache, the catalog and this device's own copy all
    /// hang off it — so it is also the answer to "is this folder ours".
    private let appDirectory: URL
    let staging: StagingStore
    /// Where export parts wait while travelling between targets that are never
    /// plugged in at the same time.
    let relay: ExportPartRelay
    let targetMonitor: TargetMonitor
    let thumbnails: ThumbnailCache
    /// The catalog itself, for the tables the store deliberately never loads.
    ///
    /// Internal rather than private because provider payloads are off every hot
    /// path by design — never joined into `fetchAssets`, never in `loadAll`,
    /// never `@Published` — so there is no published property to read them
    /// from, and the code that legitimately wants them (diagnostics, the
    /// projection, asset detail) has to ask the catalog directly.
    let catalog: CatalogStore
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
        self.appDirectory = appDirectory
        let grants = AccessGrants(defaults: environment.defaults)
        accessGrants = grants
        accessGrantList = grants.grants
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
        reclaimStagingWhenSafe = stored.object(forKey: "reclaimStagingWhenSafe") as? Bool ?? true
        autoManageTakeout = stored.object(forKey: "autoManageTakeout") as? Bool ?? true
        backgroundRotPatrol = stored.object(forKey: "backgroundRotPatrol") as? Bool ?? true
        importFromApplePhotos = stored.object(forKey: "importFromApplePhotos") as? Bool ?? true
        iCloudPhotosEnabled = stored.object(forKey: "iCloudPhotosEnabled") as? Bool
        hostTargetDeclined = stored.object(forKey: "hostTargetDeclined") as? Bool ?? false
        // The old archive-wide copy count was read back here. Nothing reads it
        // now — each source carries its own — and the stored key is left where
        // it is rather than deleted: it costs nothing, and a downgrade to a
        // build that still honours it should find the user's answer intact.

        loadAll()

        // Above the background-work guard on purpose. Reading how a group's
        // devices were arrived at touches the catalog and nothing else — no
        // volume is enumerated and no drive is written to — and it is part of
        // opening a catalog correctly rather than part of running the machine.
        //
        // It was below the guard first, which meant it did not run in the one
        // harness built to check migrations against a real catalog. The check
        // passed and the groups were untouched.
        do {
            let marked = try catalog.markUnchosenStorageGroupsAutomatic()
            if marked > 0 {
                loadAll()
                audit(.system, "\(Formatters.count(marked, "storage group")) named every drive there was, so \(marked == 1 ? "it works its devices out" : "they work their devices out") from now on rather than keeping a fixed list. Nothing moved.")
            }
        } catch {
            lastError = "Could not read how storage groups chose their devices: \(error.localizedDescription)"
        }
        resolveAutomaticDestinations()

        targetMonitor.rescanRequested = { [weak self] in
            // A mount or unmount notification: nothing is waiting on the
            // answer, and the volume that just appeared is exactly the one
            // most likely to be slow to speak.
            Task { @MainActor in await self?.rescanTargetsOffMainThread() }
        }
        targetMonitor.volumeWillUnmount = { [weak self] url in
            self?.handleWillUnmount(volumeURL: url)
        }
        refreshApplePhotosState()

        // A test drives reachability itself, and enumerating the real machine's
        // volumes — or backing the catalog up onto the user's actual drives —
        // is exactly what it must not do.
        guard environment.runsBackgroundWork else { return }

        // Before the first sweep, so a disk that is already attached is
        // readable without the user re-granting anything. Failures here are
        // silent by design — the usual reason a bookmark will not resolve is
        // that its disk is simply not plugged in.
        accessGrants.resumeAccess()
        adoptHostDeviceIfNeeded()
        // After host adoption, so a first launch has a device to read
        // destinations from, and before the first placement audit, which needs
        // every asset to know which source it answers to.
        backfillSources()
        // After the backfill, so a source it has just created is linked in the
        // same launch rather than the next one.
        linkExportSourcesToTheirSets()
        // And after both, so it reads the settled sources. A device taken off a
        // source keeps the rows saying it is owed copies until something clears
        // them, and the only things that did were registering a device and
        // changing a source's settings — neither of which a user who has just
        // undone a change has any reason to do next. Cheap, and silent when
        // there is nothing to withdraw.
        withdrawUnnamedPlacements()

        // Off the main thread, and everything that needs its answer moved in
        // with it. The window is drawn before any drive has been asked
        // anything; the scan lands a moment later and the screens fill in.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rescanTargetsOffMainThread()
            // Runs after the drive scan so drive-resident leftovers are visible.
            self.reconcileAfterRestart()
            self.refreshCatalogSnapshots()
            self.backupCatalog()
        }

        let cache = thumbnails
        Task.detached(priority: .background) { cache.pruneDisk() }

        // Volume mount notifications cover the common case; a slow poll covers
        // anything they miss (e.g. network volumes, missed events).
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Off the main thread as well: this fires forever, and a drive
                // that has gone to sleep would otherwise stutter the whole UI
                // every ten seconds. Nothing here depends on the answer having
                // already arrived.
                await self?.rescanTargetsOffMainThread()
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
            audit(.replication, "Discarded \(Formatters.count(discarded, "incomplete part copy", "incomplete part copies")) left by an interrupted transfer.")
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
                audit(.replication, "\(Formatters.count(partTransferPlan.stranded.count, "export part")) still need another copy, but no drive holding one is connected. Connect the drive that has them to continue.")
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
            audit(.replication, "Export part transfer: \(Formatters.count(moved, "part")) moved, \(failed) failed\(transferCancelRequested ? ", stopped early at your request" : "").")
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
                    note: "Copied from \(step.donorDriveID.flatMap { targetsByID[$0]?.name } ?? "the Mac's holding area") so this export is kept on the drives its group works out.",
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
        archivePlan = makeArchivePlan()
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
                "Archive redundancy: \(archivePlan.partsMeetingPolicy.count) of \(Formatters.count(archivePlan.parts.count, "export part")) are on as many devices as their export asks for, covering \(Formatters.count(covered.count, "asset")). Recorded \(Formatters.count(claimed, "copy", "copies")) against the parts holding them, replacing \(Formatters.count(pendingCleared, "pending entry", "pending entries")), and withdrew \(cancelled) file copies that are no longer needed."
            )
            loadAll()
        } catch {
            lastError = "Could not record archive redundancy: \(error.localizedDescription)"
        }
    }

    // MARK: - Backfilling provider metadata

    /// How much of the export's metadata is held, and how much is still only
    /// in the zips.
    var exportMetadataProgress: (captured: Int, partsWithZipHere: Int, partsTotal: Int) {
        let captured = (try? catalog.metadataRecordCount()) ?? 0
        let parts = archivePlan.parts
        let here = parts.filter { part in
            part.copies.values.contains {
                $0.kind == .zip && FileManager.default.fileExists(atPath: $0.path)
            }
        }
        return (captured, here.count, parts.count)
    }

    /// Reads the metadata Google wrote beside the photos, out of the zips.
    ///
    /// Capture only began when it was built, so photos imported before that
    /// have their descriptions in the archive and nowhere else. This is the
    /// pass that fixes it, and the last piece that needs the zips to still
    /// exist.
    ///
    /// One drive at a time, by construction (invariant 12): it reads whatever
    /// part has a zip on a connected drive and leaves the rest. Run it again
    /// with the other drive and it does what is left — or nothing, if each
    /// drive holds the whole export, which is the usual case.
    ///
    /// Resumable, because a 127 GB read is not something anybody can promise
    /// not to interrupt. Progress is the records themselves: a sidecar already
    /// held is skipped, and `(source_id, origin_path)` uniqueness means a
    /// re-run cannot double anything even if the skip list is stale.
    func backfillExportMetadata() {
        guard takeoutActivity == nil, !isImporting, !isSyncing else { return }

        // Only parts whose zip is on a drive that is here.
        let readable = archivePlan.parts.compactMap { part -> (part: ExportPart, url: URL)? in
            guard let zip = part.copies.values.first(where: {
                $0.kind == .zip && FileManager.default.fileExists(atPath: $0.path)
            }) else { return nil }
            return (part, zip.url)
        }
        guard !readable.isEmpty else {
            lastError = "No part of your Google download is on a drive that is connected. Plug one in and try again."
            return
        }

        let workspace = staging.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("MetadataWork", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        Task { @MainActor in
            defer {
                takeoutActivity = nil
                try? FileManager.default.removeItem(at: workspace)
            }
            var captured = 0
            var alreadyHeld = 0
            var unreadable = 0
            var albums = 0
            var linked = 0

            for (index, entry) in readable.enumerated() {
                takeoutActivity = TakeoutActivity(
                    phase: .fingerprinting,
                    detail: entry.part.displayName,
                    stepIndex: index + 1,
                    stepCount: readable.count,
                    note: "reading what Google wrote beside the photos"
                )

                // Resolved per part, because both can change while this runs.
                let sourceID = sources.first { $0.exportSetID == entry.part.setID }?.id
                    ?? sourceIDByAsset.values.first
                guard let sourceID else { continue }
                let held = (try? catalog.capturedOriginPaths(forSource: sourceID)) ?? []
                let byFilename = unambiguousAssetIDsByFilename(forSource: sourceID)

                let zipURL = entry.url
                let result = await Task.detached(priority: .utility) {
                    TakeoutMetadataBackfill.capture(
                        fromZip: zipURL,
                        sourceID: sourceID,
                        skipping: held,
                        assetIDsByFilename: byFilename,
                        workspace: workspace
                    )
                }.value

                do {
                    try catalog.transaction {
                        for record in result.captured {
                            try catalog.upsertMetadataRecord(record)
                        }
                    }
                } catch {
                    lastError = "Could not store the metadata from \(entry.part.displayName): \(error.localizedDescription)"
                    return
                }
                captured += result.captured.count
                alreadyHeld += result.alreadyHeld
                unreadable += result.unreadable
                albums += result.captured.filter { $0.scope == .album }.count
                linked += result.captured.filter { $0.assetID != nil }.count
            }

            // A run that found nothing new is the ordinary outcome of the
            // second drive, and saying "0 could be matched to a photo; the
            // rest are held with the folder they came from" over nothing at
            // all describes an empty set at length.
            var message: String
            if captured == 0 {
                message = alreadyHeld > 0
                    ? "Nothing new to read: all \(alreadyHeld.formatted()) descriptions in \(Formatters.count(readable.count, "download file")) are already held."
                    : "Nothing to read: \(Formatters.count(readable.count, "download file")) held no metadata."
            } else {
                message = "Read what Google wrote beside your photos: \(Formatters.count(captured, "description")) kept whole, from \(Formatters.count(readable.count, "download file")) on the drives connected."
                if albums > 0 {
                    message += " \(Formatters.count(albums, "album")) among them."
                }
                message += " \(Formatters.count(linked, "description")) could be matched to a photo by name; the rest are held with the folder they came from, which is what a later pass matches on."
                if alreadyHeld > 0 {
                    message += " \(Formatters.count(alreadyHeld, "description")) \(alreadyHeld == 1 ? "was" : "were") already held and left alone."
                }
            }
            if unreadable > 0 {
                message += " \(Formatters.count(unreadable, "file")) could not be read."
            }
            audit(.importEvent, message)
            loadAll()
        }
    }

    /// Works out what the captured payloads are about.
    ///
    /// Separate from reading them, and re-runnable, which is the whole point of
    /// keeping payloads whole: capture is the expensive part that needs the
    /// zips, and this is the cheap part that can be done again whenever the app
    /// learns something. Bump `CatalogStore.currentProjectionVersion` and
    /// everything queues itself.
    @discardableResult
    func projectCapturedMetadata() -> Int {
        var resolved = 0
        var reclassified = 0
        var examined = 0
        var tagged = 0

        // Which directories are albums, and what each is called. Taken from the
        // album payloads themselves rather than from folder names, so
        // `Photos from 2017` is not an album and a renamed one still is.
        var albumTitlesByDirectory: [String: String] = [:]
        for source in sources {
            let albums = (try? catalog.fetchMetadataRecords(forSource: source.id, scope: .album)) ?? []
            for album in albums {
                guard let title = MetadataProjection.albumTitle(in: album.payload) else { continue }
                albumTitlesByDirectory[(album.originPath as NSString).deletingLastPathComponent] = title
            }
        }

        // Tags are derived, so a run that revisits everything rebuilds them
        // from scratch rather than layering new ones over stale. A partial run
        // — a fresh import, say — adds without disturbing what is there.
        let total = (try? catalog.metadataRecordCount()) ?? 0
        let awaiting = (try? catalog.metadataRecordsAwaitingProjection()) ?? 0
        if awaiting == total, total > 0 { try? catalog.deleteAllTags() }

        // Every photo, indexed by name, built once.
        //
        // Not scoped to the record's own source, which was the first version's
        // mistake. A description is about a *photograph*, and the archive keeps
        // one row per photograph however many imports found it — so a picture
        // that arrived from the Photos library and also sits in a Google export
        // has its Google description filed under a source its asset does not
        // belong to. Restricting to the source missed exactly the deduplicated
        // ones, which is the case worth catching.
        //
        // Indexed rather than filtered per record: 24,417 payloads against
        // 24,639 photos is a scan nobody should do 24,417 times.
        var candidatesByName: [String: [(id: UUID, filename: String, captureDate: Date?)]] = [:]
        for asset in assets {
            candidatesByName[asset.originalFilename, default: []].append(
                (asset.id, asset.originalFilename, asset.captureDate)
            )
        }

        do {
            while true {
                let batch = try catalog.fetchMetadataRecordsNeedingProjection()
                guard !batch.isEmpty else { break }
                try catalog.transaction {
                    for record in batch {
                        examined += 1
                        let sidecarName = (record.originPath as NSString).lastPathComponent
                        let assetID = record.scope == .album
                            ? nil
                            : MetadataProjection.resolveAsset(
                                forSidecarNamed: sidecarName,
                                payload: record.payload,
                                candidates: candidatesByName[
                                    TakeoutMetadataBackfill.mediaFilename(forSidecar: sidecarName)
                                ] ?? []
                              )
                        let scope = MetadataProjection.scope(
                            forSidecarNamed: sidecarName,
                            resolvedAsset: assetID,
                            currentScope: record.scope
                        )
                        if assetID != nil, record.assetID == nil { resolved += 1 }
                        if scope != record.scope { reclassified += 1 }
                        try catalog.applyProjection(
                            to: record.id, assetID: assetID ?? record.assetID, scope: scope
                        )

                        // What the photo is called, as opposed to where it is
                        // kept. Only possible once it is known which photo.
                        if let subject = assetID ?? record.assetID {
                            for tag in MetadataProjection.tags(
                                forRecordAt: record.originPath,
                                payload: record.payload,
                                assetID: subject,
                                albumTitlesByDirectory: albumTitlesByDirectory
                            ) {
                                try catalog.addTag(tag)
                                tagged += 1
                            }
                        }
                    }
                }
            }
        } catch {
            lastError = "Could not work out what the descriptions refer to: \(error.localizedDescription)"
            return resolved
        }

        guard examined > 0 else { return 0 }
        var message = "Worked out what \(Formatters.count(examined, "description")) refer to: \(Formatters.count(resolved, "description")) newly matched to a photo."
        if reclassified > 0 {
            message += " \(Formatters.count(reclassified, "description")) turned out to describe the download itself rather than a photo."
        }
        if tagged > 0 {
            let albums = (try? catalog.fetchTagSummary(kind: .album).count) ?? 0
            let people = (try? catalog.fetchTagSummary(kind: .person).count) ?? 0
            message += " Recovered \(Formatters.count(albums, "album")) and \(Formatters.count(people, "person", "people")) from what Google wrote."
        }
        let stillLoose = ((try? catalog.database.query(
            "SELECT count(*) FROM metadata_records WHERE asset_id IS NULL AND scope = 'asset';"
        ) { Int($0.int(0)) }) ?? []).first ?? 0
        if stillLoose > 0 {
            message += " \(Formatters.count(stillLoose, "description")) still \(stillLoose == 1 ? "names a photo" : "name photos") this archive cannot tell apart, and \(stillLoose == 1 ? "is" : "are") held rather than guessed at."
        }
        audit(.system, message)
        loadAll()
        return resolved
    }

    /// Photos of one source by filename, keeping only names that identify
    /// exactly one.
    ///
    /// About a sixth of a real archive's filenames repeat, and the catalog does
    /// not record which folder inside an export a photo came from — so a
    /// repeated name cannot be resolved here and is left out rather than
    /// guessed. Its payload is still captured; only the link waits.
    private func unambiguousAssetIDsByFilename(forSource sourceID: UUID) -> [String: UUID] {
        var counts: [String: Int] = [:]
        var byName: [String: UUID] = [:]
        for asset in assets where sourceIDByAsset[asset.id] == sourceID {
            counts[asset.originalFilename, default: 0] += 1
            byName[asset.originalFilename] = asset.id
        }
        return byName.filter { counts[$0.key] == 1 }
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
        archivePlan = makeArchivePlan()
        // Being kept the way its export asks no longer implies more than one
        // copy — an export set to one copy is protected by the only copy there
        // is. That part is not a candidate: a comparison needs something to
        // compare to, and running one over a lone file would report agreement
        // with itself.
        let plan = archivePlan
        // Read what is here; compare when the other copy has been read too.
        //
        // This used to require every copy of a part to be readable at once,
        // which sounds like caution and is really an assumption about cabling.
        // With one cable and two drives — the ordinary case, not an exotic one
        // — no part ever qualified, so the check reported "nothing to compare"
        // for ever and the export could never be verified at all.
        //
        // Nothing weaker is being claimed. A fingerprint is taken from bytes
        // read off a disk, and two of them are compared only when both exist.
        // The change is that the two readings may happen in different sessions,
        // which is a fact about drives rather than about evidence.
        let candidates = plan.partsMeetingPolicy.filter { part in
            part.copies.count >= copiesNeededToCompare(
                forCopies: plan.copiesRequired(forSet: part.setID)
            )
                && part.copies.values.contains {
                    $0.kind == .zip && FileManager.default.fileExists(atPath: $0.path)
                }
        }
        guard !candidates.isEmpty else {
            audit(.replication, "Spot check: no copy of any export part is on a connected drive.")
            return
        }

        Task { @MainActor in
            var agreed = 0
            var disagreed: [String] = []
            var copiesConfirmed = 0
            var assetsConfirmed = Set<UUID>()
            var awaitingOtherCopy = 0

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
                        // Only a copy on a connected drive can be read. One
                        // that is away keeps whatever was recorded the last
                        // time it was here, which is what lets the two readings
                        // meet across sessions.
                        guard FileManager.default.fileExists(atPath: archive.path) else { continue }
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
                guard checksums.count >= copiesNeededToCompare(
                    forCopies: plan.copiesRequired(forSet: part.setID)
                ) else {
                    // Read here, with nothing yet to hold it against. Not a
                    // failure and not a pass: the other copy has simply not
                    // been plugged in since.
                    awaitingOtherCopy += 1
                    continue
                }

                if Set(checksums.values).count == 1 {
                    let verified = markPartVerified(part, onTargets: Set(checksums.keys))
                    copiesConfirmed += verified.copies
                    assetsConfirmed.formUnion(verified.assetIDs)
                    agreed += 1
                } else {
                    disagreed.append(part.displayName)
                    markPartMismatched(part, onTargets: Set(checksums.keys))
                }
            }

            var message = "Spot check: \(Formatters.count(agreed, "export part")) matched across targets on length and sampled content — \(Formatters.count(copiesConfirmed, "copy", "copies")) of \(Formatters.count(assetsConfirmed.count, "photo")) confirmed. This is a fast check, not a full byte-for-byte comparison."
            if awaitingOtherCopy > 0 {
                message += " \(Formatters.count(awaitingOtherCopy, "part")) \(awaitingOtherCopy == 1 ? "was" : "were") read on the drive that is here; connect the other and run this again to complete the comparison."
            }
            if !disagreed.isEmpty {
                message += " \(Formatters.count(disagreed.count, "part")) DIFFER and are flagged: \(disagreed.joined(separator: ", "))."
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
        archivePlan = makeArchivePlan()
        // Any part with a copy on a connected drive, and a second copy
        // somewhere to eventually hold it against. The two readings need not
        // happen in the same session — see `spotCheckExportParts`, which had
        // the same assumption about cabling baked into it.
        let plan = archivePlan
        let candidates = plan.partsMeetingPolicy.filter { part in
            part.copies.count >= copiesNeededToCompare(
                forCopies: plan.copiesRequired(forSet: part.setID)
            )
                && part.copies.values.contains {
                    $0.kind == .zip && FileManager.default.fileExists(atPath: $0.path)
                }
        }
        guard !candidates.isEmpty else {
            audit(.replication, "Checksum check: no copy of any export part is on a connected drive.")
            return
        }

        Task { @MainActor in
            var verifiedParts = 0
            var mismatchedParts: [String] = []
            var copiesConfirmed = 0
            var assetsConfirmed = Set<UUID>()
            var awaitingOtherCopy = 0

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
                    // A copy already hashed keeps its value whether or not its
                    // drive is here; one that is away and never hashed simply
                    // waits for the session it is plugged in.
                    if archive.contentHash == nil,
                       !FileManager.default.fileExists(atPath: archive.path) { continue }
                    guard let hash = await fingerprintZipIfNeeded(archive) else { continue }
                    hashes[targetID] = hash
                }
                guard hashes.count >= copiesNeededToCompare(
                    forCopies: plan.copiesRequired(forSet: part.setID)
                ) else {
                    awaitingOtherCopy += 1
                    continue
                }

                if Set(hashes.values).count == 1 {
                    let verified = markPartVerified(part, onTargets: Set(hashes.keys))
                    copiesConfirmed += verified.copies
                    assetsConfirmed.formUnion(verified.assetIDs)
                    verifiedParts += 1
                } else {
                    // Same name and size, different bytes: one copy is damaged
                    // or is not the part it claims to be. Say so rather than
                    // treating it as protection.
                    mismatchedParts.append(part.displayName)
                    markPartMismatched(part, onTargets: Set(hashes.keys))
                }
            }

            var message = "Checksum check: \(Formatters.count(verifiedParts, "export part")) confirmed identical across targets — \(Formatters.count(copiesConfirmed, "copy", "copies")) of \(Formatters.count(assetsConfirmed.count, "photo")) confirmed."
            if awaitingOtherCopy > 0 {
                message += " \(Formatters.count(awaitingOtherCopy, "part")) \(awaitingOtherCopy == 1 ? "was" : "were") read on the drive that is here; connect the other and run this again to complete the comparison."
            }
            if !mismatchedParts.isEmpty {
                message += " \(Formatters.count(mismatchedParts.count, "part")) DIFFER between targets and are flagged: \(mismatchedParts.joined(separator: ", "))."
            }
            audit(.replication, message)
            takeoutActivity = nil
            loadAll()
        }
    }

    /// What a verified part confirms: copies, and the photos they are copies of.
    ///
    /// Two numbers because they are two facts and the difference is large. A
    /// part held on two drives confirms two copies of each photo inside it, so
    /// counting rows and calling the total "assets" reported an archive of
    /// 24,639 photos as 49,236 of them — twice its own size, which is the sort
    /// of number a reader either disbelieves or, worse, believes.
    struct PartVerification {
        var copies = 0
        var assetIDs: Set<UUID> = []
    }

    /// Records that every replica backed by this part has been confirmed.
    @discardableResult
    private func markPartVerified(
        _ part: ExportPart, onTargets targetIDs: Set<UUID>
    ) -> PartVerification {
        let stem = part.displayName
        let now = Date()
        var result = PartVerification()
        do {
            try catalog.transaction {
                for replica in replicaStates where targetIDs.contains(replica.targetID)
                    && replica.state == .present
                    && (replica.relativePath?.contains(stem) ?? false) {
                    var updated = replica
                    updated.lastVerifiedAt = now
                    try catalog.upsertReplicaState(updated)
                    result.copies += 1
                    result.assetIDs.insert(replica.assetID)
                }
            }
        } catch {
            lastError = "Could not record checksum verification: \(error.localizedDescription)"
        }
        return result
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
            note: "\(Formatters.count(links.count, "edit")) to link, \(Formatters.count(needingDate.count, "date")) to recover, "
                + "\(Formatters.count(needingProvenance.count, "source")) to identify"
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
                takeoutActivity?.note = "\(Formatters.count(identified, "source")) identified from the catalog"

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
                        takeoutActivity?.note = "\(Formatters.count(recovered.values.reduce(0, +), "date")) recovered, "
                            + "\(Formatters.count(identified, "source")) identified"
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
            audit(.system, "Capture dates: linked \(Formatters.count(linked, "edited photo")) to their originals; "
                + "recovered \(Formatters.count(recovered.values.reduce(0, +), "date"))\(summary.isEmpty ? "" : " (\(summary))"); "
                + "identified \(Formatters.count(identified, "previously unrecorded source"))"
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
            audit(.system, "Reopened \(Formatters.count(reopened.count, "video")) for Live Photo matching: a newly imported still shares their name.")
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
            note: "checking \(Formatters.count(candidates.count, "candidate pair"))"
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
            audit(.system, "Live Photos: linked \(Formatters.count(linked, "pair")) — \(strongMatches) confirmed by matching Apple identifiers, \(inferredMatches) by the movie's identifier plus filename (Google had stripped the still's). \(Formatters.count(rejected, "same-name candidate")) were not Live Photos and were left alone.")
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

    /// How a set's photos physically exist, split by form.
    ///
    /// Two groups can ask for the same copies on the same drives and be in very
    /// different situations. On a real archive all three said "two copies on
    /// Owner's Back and My Passport" while one was twelve real files, one had
    /// 17,964 photos living inside .zip files, and one — named after the Photos
    /// library — was mostly held by a Google download, because the same picture
    /// arrived from both places and the archive keeps a single row for it.
    ///
    /// Origin and storage are different facts, and a name taken from the import
    /// says only the first. This says the second.
    struct StorageForm {
        /// Counted inside a download rather than copied out of it.
        var insideDownload = 0
        /// Written out as its own file somewhere.
        var copiedOut = 0
        /// Held *only* inside a download — the ones a deleted .zip would take.
        var onlyInsideDownload = 0
    }

    /// Counted in photos, not files — a Live Photo is one photo though it is a
    /// still and a movie on disk. Counting files here put "24,355 counted
    /// inside a Google download" directly under "21,117 photos", which reads as
    /// the app contradicting itself on one line.
    func storageForm(forStorageGroup groupID: UUID) -> StorageForm {
        var inside: Set<UUID> = []
        var out: Set<UUID> = []
        for replica in replicaStates where replica.state == .present {
            guard storageGroupIDByAsset[replica.assetID] == groupID,
                  assetsByID[replica.assetID]?.isLivePhotoMotion == false
            else { continue }
            if replica.relativePath?.hasPrefix(ReplicationService.archivePartPrefix) == true {
                inside.insert(replica.assetID)
            } else {
                out.insert(replica.assetID)
            }
        }
        return StorageForm(
            insideDownload: inside.count,
            copiedOut: out.count,
            onlyInsideDownload: inside.subtracting(out).count
        )
    }

    /// What each device actually holds of one group, and in what form.
    ///
    /// The archive-wide split cannot answer "where are the rest of them": it
    /// collapses across devices, so a photo counts as copied-out if *any* drive
    /// has a real file of it. On a real archive that hid a genuine difference —
    /// the Photos library group had 263 of its 272 counted inside the download
    /// on one drive and only 172 on the other, so one drive was carrying 91
    /// more of them as their own files than the other.
    struct GroupHolding: Identifiable {
        var targetID: UUID
        var photos: Int
        var insideDownload: Int
        var id: UUID { targetID }
    }

    func holdings(forStorageGroup groupID: UUID) -> [GroupHolding] {
        var byTarget: [UUID: (photos: Set<UUID>, inside: Int)] = [:]
        for replica in replicaStates where replica.state == .present {
            guard storageGroupIDByAsset[replica.assetID] == groupID,
                  assetsByID[replica.assetID]?.isLivePhotoMotion == false
            else { continue }
            var entry = byTarget[replica.targetID] ?? ([], 0)
            entry.photos.insert(replica.assetID)
            if replica.relativePath?.hasPrefix(ReplicationService.archivePartPrefix) == true {
                entry.inside += 1
            }
            byTarget[replica.targetID] = entry
        }
        // Named devices first and in the order the group names them, so the
        // list reads the same way the copies line above it does; anything else
        // holding some follows, because a device nobody named still has bytes.
        let named = storageGroupsByID[groupID]?.destinationTargetIDs ?? []
        let rest = byTarget.keys.filter { !named.contains($0) }.sorted {
            (targetsByID[$0]?.name ?? "") < (targetsByID[$1]?.name ?? "")
        }
        return (named + rest).compactMap { targetID in
            guard let entry = byTarget[targetID] else { return nil }
            return GroupHolding(
                targetID: targetID, photos: entry.photos.count, insideDownload: entry.inside
            )
        }
    }

    /// The download sets holding any of this group's photos, newest first.
    ///
    /// Lets a group show the part grid for the download that actually backs it,
    /// which is the only place that grid has ever belonged: it is a picture of
    /// where files are, wedged until now into a card about an import.
    func exportSetIDs(backingStorageGroup groupID: UUID) -> [String] {
        var stems: Set<String> = []
        for replica in replicaStates where replica.state == .present {
            guard storageGroupIDByAsset[replica.assetID] == groupID,
                  let path = replica.relativePath,
                  path.hasPrefix(ReplicationService.archivePartPrefix)
            else { continue }
            stems.insert(String(path.dropFirst(ReplicationService.archivePartPrefix.count)))
        }
        guard !stems.isEmpty else { return [] }
        let sets = takeoutArchives
            .filter { stems.contains($0.displayName) }
            .compactMap(\.exportSetID)
        return Array(Set(sets)).sorted(by: >)
    }

    /// Photos that would have no copy anywhere if this download's files went.
    ///
    /// The app counts photos *inside* the Takeout files rather than copying
    /// them out, so "stop tracking this download" is not the paperwork it
    /// sounds like — on a real archive it would drop 18,136 photos to nowhere
    /// while the button said "deletes nothing", which is true about files and
    /// badly wrong about photos.
    /// Matched against the export's own part names rather than a prefix built
    /// from the set id, because those are two different strings: a part is
    /// recorded as `archivepart:takeout-20260710T081521Z-2-001` while the set
    /// id is `20260710T081521Z-2`. Constructing the prefix matched nothing, so
    /// the count came out zero and the dialog said the download could be
    /// forgotten safely — the one answer it must never give wrongly.
    func photosHeldOnlyBy(exportSetID: String) -> Int {
        let stems = Set(
            takeoutArchives
                .filter { $0.exportSetID == exportSetID }
                .map { ReplicationService.archivePartPrefix + $0.displayName }
        )
        guard !stems.isEmpty else { return 0 }

        var elsewhere: Set<UUID> = []
        var here: Set<UUID> = []
        for replica in replicaStates where replica.state == .present {
            if let path = replica.relativePath, stems.contains(path) {
                here.insert(replica.assetID)
            } else {
                elsewhere.insert(replica.assetID)
            }
        }
        return here.subtracting(elsewhere).count
    }

    /// How many photos sit on how many drives, keyed by the number of drives.
    ///
    /// The distribution rather than a total, because a total cannot say whether
    /// the archive is safe: "49,278 copies" is the same number whether every
    /// photo has two or half of them have three and the rest one.
    @Published private(set) var copyCoverage: [Int: Int] = [:]

    /// Photos whose every copy is inside a Takeout file.
    ///
    /// These are not short of copies — on a real archive all 18,136 of them sit
    /// on both drives — which is exactly why nothing flagged them. What they
    /// share is a way of being lost: the copies are the *same* zip files on
    /// each drive, so deleting those, or one of them going bad in the same way,
    /// takes both at once. Two copies inside one failure is the thing this
    /// number exists to say out loud.
    @Published private(set) var archiveBackedOnlyCount: Int = 0

    /// The fewest drives any photo is on, or nil when the archive is empty.
    var leastCopiesAnywhere: Int? { copyCoverage.keys.min() }

    /// Snapshots per drive, newest first — surfaced under Keep safe.
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
                repairs.append("requeued \(Formatters.count(transientlyFailed.count, "copy task")) that had no reachable source")
            }

            let stuck = replicationTasks.filter { $0.state == .inProgress }
            for var task in stuck {
                task.state = .queued
                task.errorMessage = "Requeued after an interrupted run"
                try catalog.upsertReplicationTask(task)
            }
            if !stuck.isEmpty { repairs.append("requeued \(Formatters.count(stuck.count, "interrupted replication task"))") }

            // 2. Staged files no asset points at: bytes copied in just before
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
            if orphanedStaging > 0 { repairs.append("removed \(Formatters.count(orphanedStaging, "orphaned staged file"))") }

            // 3. Abandoned zip-extraction workspaces on the Mac (each can be
            // many GB) and half-written `.extracting` folders on targets.
            let workArea = staging.rootURL.deletingLastPathComponent()
                .appendingPathComponent("TakeoutWork", isDirectory: true)
            if let leftovers = try? FileManager.default.contentsOfDirectory(at: workArea, includingPropertiesForKeys: nil),
               !leftovers.isEmpty {
                for item in leftovers { try? FileManager.default.removeItem(at: item) }
                repairs.append("cleared \(Formatters.count(leftovers.count, "abandoned extraction workspace"))")
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
            if partials > 0 { repairs.append("removed \(Formatters.count(partials, "incomplete extraction folder"))") }

            // A transfer interrupted by a crash or an unplug leaves a
            // half-written part in the holding area. It is worthless and can
            // be many gigabytes.
            let abandoned = relay.discardIncompleteCopies()
            if abandoned > 0 { repairs.append("discarded \(Formatters.count(abandoned, "interrupted export-part copy", "interrupted export-part copies"))") }

            if !repairs.isEmpty {
                audit(.system, "Startup reconciliation: " + repairs.joined(separator: "; ") + ".")
                loadAll()
            }
            // Catches what an interrupted run left behind: content that
            // reached both drives before the app was quit, and staged files a
            // half-finished release stopped naming.
            reclaimStaging()
            // The sweep memo is keyed by path, so it accumulates notes about
            // folders on drives long since put away, and about files that no
            // longer exist. Nothing else would ever remove them.
            try catalog.pruneScanMemo(before: Date().addingTimeInterval(-Self.scanMemoLifetime))
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
            sources = try catalog.fetchSources()
            storageGroups = try catalog.fetchStorageGroups()
            storageGroupIDByAsset = try catalog.fetchStorageGroupIDsByAsset()
            assetIDsByTag = try catalog.fetchAllTags().reduce(into: [TagKey: Set<UUID>]()) {
                $0[TagKey(kind: $1.kind, value: $1.value), default: []].insert($1.assetID)
            }
            albumDetails = try sources.reduce(into: [String: AlbumDetail]()) { details, source in
                for record in try catalog.fetchMetadataRecords(forSource: source.id, scope: .album) {
                    guard let detail = MetadataProjection.albumDetail(in: record.payload) else { continue }
                    details[detail.title] = detail
                }
            }
            // Before `recomputeDerivedState`: every protection verdict is
            // judged against the copy count on the asset's own source, so the
            // source map has to be current before anything derived from it is
            // rebuilt.
            sourceIDByAsset = try catalog.fetchSourceIDsByAsset()
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
            desiredCopies: { [self] in desiredCopies(forAsset: $0) }
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
                if replica.lastVerifiedAt == nil {
                    breakdown.neverChecked += 1
                    if isPhoto { breakdown.neverCheckedPhotos += 1 }
                }
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

        // How many drives hold each photo, and how many photos have no copy
        // outside a Takeout file.
        //
        // Both are questions about photos rather than about drives, which is
        // why neither could be read off `driveBreakdowns`. "Every photo is on
        // all the drives it is meant to be on" is a bookkeeping answer — a
        // photo in one place satisfies a one-copy group and reads as fine.
        // "Every photo is on two drives" is the safety answer, and it is the
        // one somebody opens this screen to get.
        var drivesHolding: [UUID: Set<UUID>] = [:]
        var outsideAnArchive: Set<UUID> = []
        for replica in replicaStates where replica.state == .present {
            drivesHolding[replica.assetID, default: []].insert(replica.targetID)
            if replica.relativePath?.hasPrefix(ReplicationService.archivePartPrefix) != true {
                outsideAnArchive.insert(replica.assetID)
            }
        }
        copyCoverage = drivesHolding.values.reduce(into: [:]) { $0[$1.count, default: 0] += 1 }
        archiveBackedOnlyCount = drivesHolding.keys.filter { !outsideAnArchive.contains($0) }.count

        // A Merkle tree per target used to be built here so two targets could
        // be compared by their roots. Both trees took their leaf digests from
        // `asset.contentHash` — the catalog's hash — so a shared asset carried
        // an identical digest on both sides by construction, and the
        // comparison could only ever report which asset keys each target held.
        // Under k-of-n that difference is the design. Removed rather than
        // rescoped; the placement audit answers the membership question
        // exactly, off these same rows.

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
        archivePlan = makeArchivePlan()
        refreshPartTransferPlan()
    }

    func rescanTargets() {
        let previouslyConnected = Set(targetMonitor.reachablePaths.keys)
        targetMonitor.rescan(targets: targets)
        reactToRescan(previouslyConnected: previouslyConnected)
    }

    /// The same rescan without holding the main thread while drives answer.
    ///
    /// Used at startup, where the alternative is that a sleeping drive — or a
    /// permission prompt on a removable volume — stops the window appearing at
    /// all. Everywhere else the scan stays synchronous on purpose: those calls
    /// are somebody asking for it and are immediately followed by work that
    /// needs the answer, and registering a device already broke once by running
    /// the placement audit before the scan had happened.
    func rescanTargetsOffMainThread() async {
        let previouslyConnected = Set(targetMonitor.reachablePaths.keys)
        await targetMonitor.rescanOffMainThread(targets: targets)
        reactToRescan(previouslyConnected: previouslyConnected)
    }

    private func reactToRescan(previouslyConnected: Set<UUID>) {
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
            // Then put any part the app was holding for this drive in beside
            // its export. A rename within the volume, and it runs before the
            // presence checks so they read the paths the catalog now holds
            // rather than reporting everything this moved as gone.
            rehomeDeliveredParts(for: targetID)
            // Then: are the export archives this drive is credited with still
            // on it? One stat each, and it must come before the replica gate
            // so a part that survives only as its extracted twin is stat-ed
            // where the bytes actually are.
            checkArchivePresence(for: targetID)
            // Then the cheap look at what those paths now contain. Runs after
            // the repair so a moved file is stat-ed where it actually is.
            checkReplicaStats(for: targetID)
            // Reconcile before syncing. A drive that already holds this
            // content — the same Takeout export, say, or the folder somebody
            // imported from before this drive was registered — should claim it
            // in place; starting the backlog first would copy over the top of
            // files that are already there.
            Task {
                await autoTakeoutPipeline(targetID: targetID)
                await adoptContentAlreadyOnTarget(targetID)
                if autoSyncOnConnect && backlogCount(for: targetID) > 0 {
                    // The sync bridges for absent targets when it finishes,
                    // where the catalog is fresh and the disk is free again.
                    syncDrive(targetID)
                } else {
                    await relayForAbsentTargets(from: targetID)
                }
            }
        }

        promptForUnmanagedVolumes()
    }

    /// Acts on what the user already decided about a newly mounted volume, and
    /// only asks about the ones they have not.
    ///
    /// The old version could remember exactly one answer — "never ask about
    /// this drive" — so somebody who chose "scan it" was asked the same
    /// question at every mount forever. A remembered decision is now carried
    /// out here without a prompt, which is the whole point of having recorded
    /// it.
    private func promptForUnmanagedVolumes() {
        let unmanaged = targetMonitor.availableVolumes.filter { volume in
            volume.isRemovable
                && volume.url.path.hasPrefix("/Volumes/")
                && TargetMonitor.match(volume: volume, against: targets) == nil
        }
        for volume in unmanaged {
            let key = AccessGrants.key(forVolumeUUID: volume.volumeUUID, path: volume.url.path)

            if let decision = accessGrants.decision(forKey: key) {
                // Same disk, possibly a different mount point. Keep the record
                // pointing at where it actually is, so the Access list names a
                // place the user recognises and the bookmark stays fresh.
                accessGrants.noteSeen(key: key, displayName: volume.name, path: volume.url.path)
                // Acting is idempotent per session, not per mount: re-running
                // a sweep every time the monitor rescans would restart the
                // Takeout pipeline on a drive already being worked on.
                guard !promptedVolumeKeys.contains(key) else { continue }
                promptedVolumeKeys.insert(key)
                apply(decision, to: volume)
                continue
            }

            guard !promptedVolumeKeys.contains(key) else { continue }
            promptedVolumeKeys.insert(key)
            if connectPrompt == nil {
                connectPrompt = volume
            }
        }
    }

    /// Carries out a remembered decision. Registration is still gated on a
    /// free slot: the policy caps how many targets exist, and a grant made
    /// when a slot was free must not force one open later.
    private func apply(_ decision: VolumeDecision, to volume: VolumeInfo) {
        switch decision {
        case .manage:
            // No slot check: devices are unbounded, and the policy's number is
            // copies per photo rather than places in total.
            registerVolumeTarget(volume: volume, name: volume.name)
        case .scan:
            scanForTakeout(rootURL: volume.url, targetID: nil)
        case .ignore:
            break
        }
    }

    /// Records what the user chose in the connect prompt.
    ///
    /// `remember` off means the choice happens and is not written down — the
    /// disk is asked about again next time. That is what an unchecked
    /// "remember this" honestly means, as against a grant with a quiet expiry.
    func decide(_ decision: VolumeDecision, for volume: VolumeInfo, remember: Bool) {
        accessGrants.record(
            decision: decision,
            forVolumeUUID: volume.volumeUUID,
            path: volume.url.path,
            displayName: volume.name,
            remember: remember
        )
        if remember {
            accessGrantList = accessGrants.grants
            audit(
                .replication,
                "\(volume.name) will be \(decision.displayName.lowercased()) from now on, without asking. Change it under Settings → Access."
            )
        }
        apply(decision, to: volume)
        connectPrompt = nil
    }

    /// Forgets one disk's decision. Deletes nothing and unregisters nothing —
    /// the next time that disk appears, the app asks again.
    func revokeAccessGrant(_ key: String) {
        let name = accessGrants.grant(forKey: key)?.displayName ?? "A device"
        accessGrants.revoke(key)
        // So the prompt can fire again this session rather than waiting for a
        // relaunch, which would read as the revoke not having worked.
        promptedVolumeKeys.remove(key)
        accessGrantList = accessGrants.grants
        audit(.replication, "Forgot what to do with \(name). It will be asked about the next time it is connected; nothing on it was changed.")
    }

    /// Forgets every remembered answer at once. Same guarantee as one: disks
    /// are untouched and registered devices stay registered.
    func revokeAllAccessGrants() {
        guard !accessGrants.grants.isEmpty else { return }
        let count = accessGrants.grants.count
        for grant in accessGrants.grants { promptedVolumeKeys.remove(grant.volumeKey) }
        accessGrants.revokeAll()
        accessGrantList = accessGrants.grants
        audit(.replication, "Forgot what to do with \(Formatters.count(count, "device")). Each will be asked about again the next time it is connected; nothing on any of them was changed.")
    }

    /// Whether a grant's disk is attached right now, so the Access list can
    /// say so rather than listing everything identically.
    func isAccessGrantReachable(_ grant: AccessGrant) -> Bool {
        availableVolumes.contains { volume in
            AccessGrants.key(forVolumeUUID: volume.volumeUUID, path: volume.url.path) == grant.volumeKey
        }
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

    /// `offeringRegistration` is cleared by the prompt itself, so answering it
    /// does not walk back into it.
    func importFolders(_ urls: [URL], offeringRegistration: Bool = true) {
        guard beginFolderImport(urls, offeringRegistration: offeringRegistration) else {
            // Deferred — the registration offer intercepted it, or an import is
            // already running. The claim must not survive: left set, the next
            // import to start would file its photos under this source.
            importingIntoSourceID = nil
            return
        }
        Task {
            await runFolderImport(urls)
            // Only this import's assets belong to it. A later automatic sweep
            // must not inherit the claim, or a Takeout pipeline running after
            // a folder import would file its photos under the folder.
            importingIntoSourceID = nil
        }
    }

    /// The awaitable form, for callers that have to know the sweep finished
    /// before they do the next thing — connect-time adoption has to settle the
    /// backlog before the sync it precedes starts draining it.
    func performFolderImport(_ urls: [URL], offeringRegistration: Bool = true) async {
        guard beginFolderImport(urls, offeringRegistration: offeringRegistration) else { return }
        await runFolderImport(urls)
    }

    /// The decisions that must happen before the caller returns: whether this
    /// import runs at all, and claiming `isImporting`.
    ///
    /// Synchronous on purpose. `isImporting` is what stops a sync starting on
    /// top of an import and what greys the button that started it, and a flag
    /// raised one hop later is a flag that is wrong for a hop.
    private func beginFolderImport(_ urls: [URL], offeringRegistration: Bool) -> Bool {
        guard !urls.isEmpty else { return false }

        // The app's own folders are not a place photos came from. A sweep that
        // *descends* into one already steps over it — `HeykinnClicks` and
        // `Staging` are in `ImportService.excludedDirectoryNames` — but the
        // exclusion is checked against directories the enumerator yields, and
        // never against the root it was handed. Point the sweep straight at the
        // app's own copy folder and it reads every replica back as user
        // content, filing the archive's own output under a new source.
        //
        // Refused here rather than only at the caller that did it, because the
        // guard has to hold for the next caller too.
        if let owned = urls.first(where: { isAppOwnedFolder($0) }) {
            lastError = "\(owned.lastPathComponent) is where this app keeps its own copies. Everything in it is already in the archive, under the source it originally came from — importing it would record the app's own copies as photos you added."
            return false
        }

        // A Google export is not a folder of photos, whatever it looks like in
        // Finder. Brought in through the export machinery, one 10 GB zip backs
        // thousands of replicas and one read checks them all; brought in as a
        // folder, every photo becomes a replica of its own and the drive gets
        // tens of thousands of copies it did not need. The difference is too
        // large to let somebody walk into by picking the wrong menu item.
        if let export = urls.first(where: { TakeoutScanner.looksLikeTakeoutRoot($0) }) {
            takeoutRedirect = TakeoutRedirect(url: export)
            return false
        }

        // Reading from a drive the app does not manage means copying every
        // file onto the Mac, and the placement cannot be revised afterwards
        // without hashing all of it again. Registering the drive first makes
        // the same import free. Asked here because here is the only point at
        // which the cheaper answer is still available.
        // No device-count condition: there is no cap to be near, and the
        // saving this offer exists for — crediting the files where they sit
        // instead of copying every one onto the Mac — is worth the same
        // whether it is the first drive or the fifth.
        if offeringRegistration, let volume = unmanagedVolume(holding: urls) {
            unmanagedSourceOffer = UnmanagedSourceOffer(volume: volume, urls: urls)
            return false
        }

        isImporting = true
        return true
    }

    private func runFolderImport(_ urls: [URL]) async {
        let existing = assets
        let rules = policyRules
        let stagingStore = staging
        // The path, not the name. `sourcePath` promised one and got "Photos",
        // so the screen listing folders somebody added could not show where
        // any of them were, or offer to open one — and two folders called
        // Photos on two drives read as the same folder. A multi-root pick has
        // no single path to give, so it stays a label and says so by not
        // looking like one.
        let sourceDescription = urls.count == 1
            ? urls[0].path
            : urls.map(\.lastPathComponent).joined(separator: ", ")

        // Every reachable target, resolved per file. Deciding this once from
        // whichever file the sweep returned first made a batch's placement
        // depend on the order the picker handed back the roots.
        let placement = TargetPlacement(reachablePaths: reachablePaths)
        // Read once, off the catalog, so a re-sweep of a folder the app has
        // seen before costs a stat per file instead of a full read.
        let memo = (try? catalog.fetchScanMemo()) ?? [:]

        // Exports nested inside the swept tree are skipped for the same
        // reason: sweeping a whole drive must not explode an export that
        // happens to be sitting on it.
        let files = ImportService.mediaFileURLs(under: urls, skippingExports: true)
        let result = await ImportService.importFiles(
            files,
            sourceDescription: sourceDescription,
            existingAssets: existing,
            policyRules: rules,
            staging: stagingStore,
            placement: placement,
            scanMemo: memo
        )
        applyImportResult(result)
    }

    /// Folders somebody imported from that turn out to live on this target.
    ///
    /// Registering a drive seeds a copy of everything Local onto it — and in
    /// the order people actually do things, import from the drive and *then*
    /// register it, a good part of that content is already sitting on the drive
    /// under their own names. Nothing would notice, because registering does
    /// not read the drive: the backlog would copy the drive's own files back
    /// onto it and only a later sweep would take them off again.
    ///
    /// Which folders to look at is already recorded. Every folder import writes
    /// down where it came from, so the ones that resolve onto this target are
    /// exactly the places worth re-reading — rather than hashing a whole volume
    /// on the chance that something on it is familiar.
    private func priorImportRoots(on targetID: UUID) -> [URL] {
        guard let mount = reachablePaths[targetID] else { return [] }
        let placement = TargetPlacement(targetID: targetID, mountPath: mount.path)
        var seen = Set<String>()
        var roots: [URL] = []
        for batch in importBatches where batch.isFolderImport && batch.isFilesystemPath {
            let url = URL(fileURLWithPath: batch.sourcePath, isDirectory: true)
            guard placement.contains(url) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if seen.insert(url.standardizedFileURL.path).inserted { roots.append(url) }
        }
        return roots
    }

    /// Credits a target with content it already holds, before the backlog gets
    /// a chance to copy that content onto it.
    ///
    /// The connect sequence already did this for exports, with the reasoning
    /// spelled out where it is called: a drive that already holds the content
    /// should claim it in place, and starting the backlog first would copy over
    /// the top of files that are already there. That was true of every source,
    /// not only of Takeout, and this is the general form.
    private func adoptContentAlreadyOnTarget(_ targetID: UUID) async {
        guard !isImporting, !isSyncing else { return }
        // Nothing staged means nothing that could be copied redundantly: every
        // Local asset is either already credited in place or has no copy to
        // duplicate.
        guard assets.contains(where: { $0.stagingRelativePath != nil }) else { return }
        let roots = priorImportRoots(on: targetID)
        guard !roots.isEmpty else { return }

        let name = targetsByID[targetID]?.name ?? "drive"
        audit(
            .drive,
            "Re-reading \(Formatters.count(roots.count, "folder")) on \(name) that photos were imported from, to credit copies it already holds before sending it any.",
            targetID: targetID
        )
        await performFolderImport(roots, offeringRegistration: false)
    }

    // MARK: - Where a source's photos are




    /// How long a note about a path is worth keeping. Long enough that a drive
    /// swept every few months still benefits; short enough that the table does
    /// not grow forever on paths nothing will look at again.
    static let scanMemoLifetime: TimeInterval = 180 * 24 * 3600

    /// Whether every copy this archive holds of an asset is a file the user
    /// manages — adopted where it sat, under their own name, with nothing
    /// staged on the Mac behind it.
    ///
    /// Adoption is what stops the app duplicating a drive's own content, and
    /// its cost is this: the copy is in a folder somebody may reorganise or
    /// clear out. A rename is repaired automatically; a deletion is not, and
    /// the app will not have written a copy of its own to fall back on.
    func hasOnlyArchiveBackedCopies(_ assetID: UUID) -> Bool {
        guard let asset = assetsByID[assetID], asset.stagingRelativePath == nil else { return false }
        let present = (replicasByAssetID[assetID] ?? []).filter { $0.state == .present }
        guard !present.isEmpty else { return false }
        return present.allSatisfy { ReplicationService.isArchiveBacked($0) }
    }

    // MARK: - Bridging targets that are never present together

    /// Brings onto the Mac what an absent target is owed, while the target that
    /// holds it is here.
    ///
    /// Two drives that are never plugged in at the same time cannot copy to
    /// each other. The backlog is not wrong — the work is real and stays
    /// queued — but nothing can ever run it: whichever drive is present, the
    /// one holding the bytes is the other one. A target that falls behind stays
    /// behind, and the archive quietly stops being able to repair itself.
    ///
    /// Export parts already had the answer. A part that cannot go straight
    /// across goes to a holding area on the Mac and is delivered when the
    /// receiving drive appears. Ordinary photos had no such route, and once
    /// their staged copy is released — correctly, both targets have them — the
    /// last source both drives could reach is gone.
    ///
    /// The holding area for a photo is staging, because that is exactly what
    /// staging is: a copy on the Mac that exists to be a source and is never
    /// counted as protection. So this puts one back, and `StagingReclaimer`
    /// takes it away again the moment the target it was for is holding it.
    ///
    /// Bounded twice over — only what an absent target is actually owed, and
    /// never past the reserve the Mac keeps free for the export-part holding
    /// area. It bridges what it can and leaves the rest for next time.
    func relayForAbsentTargets(from targetID: UUID) async {
        guard !isSyncing, !isImporting, reachablePaths[targetID] != nil else { return }
        let absent = Set(targets.map(\.id)).subtracting(reachablePaths.keys)
        guard !absent.isEmpty else { return }

        var budget = (TakeoutExtractor.availableCapacity(onVolumeOf: staging.rootURL) ?? 0)
            - ExportPartTransferPlanner.holdingAreaReserveBytes
        guard budget > 0 else { return }

        // What the absent targets are owed and this one can supply. A source
        // has to be a file that can be read: content whose only copy is inside
        // a zip or an export part is the part relay's job, not this one, and
        // `localFileURL` already declines to name one.
        var plan: [(assetID: UUID, source: URL, ext: String, size: Int64)] = []
        var seen = Set<UUID>()
        for task in replicationTasks
        where task.state == .queued && task.action == .copy && absent.contains(task.targetID) {
            guard seen.insert(task.assetID).inserted else { continue }
            guard let asset = assetsByID[task.assetID] else { continue }
            guard !staging.exists(relativePath: asset.stagingRelativePath) else { continue }
            guard asset.fileSize <= budget else { continue }
            guard let source = localFileURL(for: asset) else { continue }
            plan.append((asset.id, source, asset.fileExtension, asset.fileSize))
            budget -= asset.fileSize
        }
        guard !plan.isEmpty else { return }

        let stagingStore = staging
        let staged = await Task.detached(priority: .utility) { () -> [(UUID, String)] in
            var written: [(UUID, String)] = []
            for item in plan {
                guard let relative = try? stagingStore.stage(
                    fileAt: item.source, assetID: item.assetID, fileExtension: item.ext
                ) else { continue }
                written.append((item.assetID, relative))
            }
            return written
        }.value

        var bytes: Int64 = 0
        for (assetID, relative) in staged {
            guard var asset = assetsByID[assetID] else { continue }
            asset.stagingRelativePath = relative
            do {
                try catalog.upsertAsset(asset)
                bytes += asset.fileSize
            } catch { continue }
        }
        guard !staged.isEmpty else { return }

        let name = targetsByID[targetID]?.name ?? "drive"
        let waiting = absent.compactMap { targetsByID[$0]?.name }.sorted().joined(separator: " and ")
        audit(
            .replication,
            "Held \(Formatters.count(staged.count, "photo")) — \(Formatters.bytes.string(fromByteCount: bytes)) — from \(name) on this Mac, so \(waiting.isEmpty ? "the other target" : waiting) can be given them without both being connected at once.",
            targetID: targetID
        )
        loadAll()
    }

    // MARK: - Staging reclamation

    /// What could be released from staging right now, for the UI to state
    /// before it happens rather than after.
    var stagingReclaimPlan: StagingReclaimer.Plan {
        StagingReclaimer.plan(assets: assets, protectionStates: protectionStates)
    }

    /// Releases staged copies of content the archive's own drives now hold
    /// safely, and sweeps up staged files nothing claims.
    ///
    /// The catalog is updated after each file goes, not before: a path
    /// recorded with no file behind it is a state the app already handles
    /// everywhere it matters — `localFileURL` checks before trusting it — and
    /// the reverse, a file nobody names, is invisible waste. Neither is
    /// avoidable in general, because a file deletion and a database write are
    /// not one operation; the orphan sweep is what makes the unavoidable one
    /// recoverable.
    @discardableResult
    func reclaimStaging(force: Bool = false) -> Int64 {
        guard force || reclaimStagingWhenSafe else { return 0 }
        let plan = stagingReclaimPlan
        var freed: Int64 = 0
        var released = 0

        for (assetID, relativePath) in plan.releasable {
            guard var asset = assetsByID[assetID] else { continue }
            do {
                try staging.remove(relativePath: relativePath)
                asset.stagingRelativePath = nil
                try catalog.upsertAsset(asset)
                freed += asset.fileSize
                released += 1
            } catch {
                // Leaving it costs space and nothing else; the next pass sees
                // the same asset and tries again.
                continue
            }
        }

        for orphan in StagingReclaimer.orphans(in: staging, claimedBy: assets) {
            if (try? staging.remove(relativePath: orphan)) != nil { released += 1 }
        }

        if released > 0 {
            audit(.replication, "Released \(Formatters.count(released, "staged file")) — \(Formatters.bytes.string(fromByteCount: freed)) — now that your own drives hold them safely.")
            loadAll()
        }
        return freed
    }

    /// The drive a chosen folder sits on, when that drive is one the app could
    /// manage but does not. Nil for anything on this Mac's own disk, for a
    /// drive already registered, and for one the user has said not to ask
    /// about again.
    /// Whether a folder is one the app writes its own copies into.
    ///
    /// Two families: everything under the app's directory on this machine —
    /// staging, the relay, and this device's own copy — and the single folder
    /// the app owns at the root of each registered drive.
    ///
    /// "At or inside" only. A folder that merely *contains* one of these is a
    /// legitimate thing to sweep — the home folder contains Application
    /// Support — and the enumerator steps over the app's directories on the way
    /// down. Refusing those too would turn a working import into an error.
    func isAppOwnedFolder(_ url: URL) -> Bool {
        var roots = [appDirectory]
        for target in targets {
            guard let mount = reachablePaths[target.id] else { continue }
            roots.append(
                mount.appendingPathComponent(ReplicationTarget.appFolderName, isDirectory: true)
            )
        }
        // Both spellings, for the same reason `unmanagedVolume` checks both: a
        // path handed over by the picker and the same path with its symlinks
        // resolved are the same folder and rarely the same string.
        let spellings = Set([
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path
        ])
        return roots.contains { rootURL in
            let root = rootURL.standardizedFileURL.path
            return spellings.contains { $0 == root || $0.hasPrefix(root + "/") }
        }
    }

    private func unmanagedVolume(holding urls: [URL]) -> VolumeInfo? {
        guard let first = urls.first else { return nil }
        let spellings = [first.path, first.resolvingSymlinksInPath().path]
        return availableVolumes.first { volume in
            guard volume.isRemovable, volume.url.path != "/" else { return false }
            guard TargetMonitor.match(volume: volume, against: targets) == nil else { return false }
            let key = AccessGrants.key(forVolumeUUID: volume.volumeUUID, path: volume.url.path)
            guard accessGrants.decision(forKey: key) == nil else { return false }
            return spellings.contains { $0.hasPrefix(volume.url.path + "/") }
        }
    }

    /// Registers the drive a chosen folder sits on, then imports from it — in
    /// that order, so the sweep finds the target already there and credits the
    /// files where they are instead of copying them.
    func registerAndImport(_ offer: UnmanagedSourceOffer) {
        unmanagedSourceOffer = nil
        registerVolumeTarget(volume: offer.volume, name: offer.volume.name)
        guard lastError == nil else { return }
        importFolders(offer.urls, offeringRegistration: false)
    }

    /// Persists imported assets and queues their replication backlog.
    /// A Local asset owes `desiredCopies` copies spread across the registered
    /// devices — **not** a copy on every one of them. Which devices are chosen
    /// is `PlacementPlanner`'s job: most free space after the write, preferring
    /// devices plugged in now.
    ///
    /// A device whose copy is already satisfied by the import source itself
    /// (archive-backed, e.g. a Takeout folder on that device) counts towards
    /// the `k` where it sits, and is never sent a duplicate onto the same disk.
    @discardableResult
    private func persistImportedAssets(
        _ imported: [Asset],
        archiveBacked: [UUID: TargetReplicaState] = [:],
        capturedMetadata: [CapturedMetadata] = []
    ) throws -> [TargetReplicaState] {
        var written: [TargetReplicaState] = []

        // Claim these for the source that started the import *first*: placement
        // below reads each asset's source to find its destinations, so an
        // assignment made after the planning would plan against the fallback
        // and put the photos somewhere the user did not choose.
        //
        // In memory only. The catalog's half of this is written after the rows
        // exist, further down — `assignSource` is an UPDATE, and running it
        // against assets that have not been inserted yet matched nothing at
        // all. Placement still saw the right answer from the map here, so the
        // photos went to the right devices; but the link was never stored, and
        // the `loadAll` at the end of every import replaced this map with what
        // the catalog held, which was nothing. Every folder added through the
        // sheet came out of its own import unattached to the source that
        // started it, falling back to the defaults for good.
        let claimedSourceID = imported.isEmpty ? nil : importingIntoSourceID
        let claimedGroupID = imported.isEmpty ? nil : importingIntoStorageGroupID
        if let claimedSourceID {
            for asset in imported { sourceIDByAsset[asset.id] = claimedSourceID }
        }
        // The group is what placement below actually reads.
        if let claimedGroupID {
            for asset in imported { storageGroupIDByAsset[asset.id] = claimedGroupID }
        }

        let local = imported.filter { $0.residency == .local }
        let sizes = Dictionary(
            local.map { ($0.id, $0.fileSize) }, uniquingKeysWith: { first, _ in first }
        )
        // A device that already holds the file counts and is sent nothing —
        // the Takeout zips already sitting on the drive you named are that
        // drive's copy, not something to transport onto it.
        let holders = local.reduce(into: [UUID: Set<UUID>]()) { holders, asset in
            if let backed = archiveBacked[asset.id] { holders[asset.id] = [backed.targetID] }
        }
        // Grouped by policy, then planned per group in one pass so bytes
        // promised to a device are counted against its room as the batch goes.
        var destinationsByAsset: [UUID: [UUID]] = [:]
        for group in groupedByPolicy(local.map(\.id)) {
            let plans = PlacementPlanner.plan(
                assets: group.assetIDs.map { (id: $0, sizeBytes: sizes[$0] ?? 0) },
                existingHolders: holders,
                destinations: group.destinations,
                desiredCopies: group.copies,
                candidates: placementCandidates
            )
            for plan in plans { destinationsByAsset[plan.assetID] = plan.destinations }
        }

        for asset in imported {
            try catalog.upsertAsset(asset)
            guard asset.residency == .local else { continue }

            if let backed = archiveBacked[asset.id] {
                try catalog.upsertReplicaState(backed)
                written.append(backed)
            }
            for targetID in destinationsByAsset[asset.id] ?? [] {
                try enqueueTask(assetID: asset.id, targetID: targetID, action: .copy)
                let pending = TargetReplicaState(
                    assetID: asset.id,
                    targetID: targetID,
                    state: .pending,
                    relativePath: nil,
                    lastVerifiedAt: nil
                )
                try catalog.upsertReplicaState(pending)
                written.append(pending)
            }
        }

        // Now that the rows are there for the UPDATE to find.
        if let claimedSourceID {
            try catalog.assignSource(claimedSourceID, toAssets: imported.map(\.id))

            // The provider's own metadata, kept whole. Written here rather than
            // in the importer because the importer runs detached and knows
            // nothing about which source claimed this import — and a payload
            // with no source is one nobody can explain later.
            for captured in capturedMetadata {
                let payload = captured.payload
                try catalog.upsertMetadataRecord(MetadataRecord(
                    id: UUID(),
                    assetID: captured.assetID,
                    sourceID: claimedSourceID,
                    scope: .asset,
                    provider: "google",
                    originPath: captured.originPath,
                    capturedAt: Date(),
                    schemaFingerprint: MetadataRecord.fingerprint(of: payload),
                    payload: payload
                ))
            }
        }
        if let claimedGroupID {
            try catalog.assignStorageGroup(claimedGroupID, toAssets: imported.map(\.id))
        }
        return written
    }

    // MARK: - Adding a source

    /// A folder chosen but not yet imported, waiting for its settings.
    ///
    /// Nothing is read until this is answered, because placement without a
    /// destination is the app guessing — and the guess would be silent and
    /// permanent-feeling, since re-deciding later costs a retarget.
    struct PendingSourceSetup: Identifiable {
        let id = UUID()
        var urls: [URL]
        var label: String
        var desiredCopies: Int
        var destinationTargetIDs: [UUID]
        /// Defaults to `chosen` for the same reason `StorageGroup.Defaults`
        /// does: building one of these with a list of devices is an explicit
        /// act, and a default of `automatic` throws that list away and works
        /// the devices out instead. `beginAddingSource` says `automatic` for
        /// itself, which is the path that means it.
        var destinationMode: StorageGroup.DestinationMode = .chosen
    }

    @Published var pendingSourceSetup: PendingSourceSetup?

    /// Opens the settings sheet for a folder the user just picked, prefilled
    /// with whatever they chose last time.
    func beginAddingSource(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let defaults = newSourceDefaults
        pendingSourceSetup = PendingSourceSetup(
            urls: urls,
            label: urls.count == 1
                ? first.lastPathComponent
                : urls.map(\.lastPathComponent).joined(separator: ", "),
            desiredCopies: defaults.desiredCopies,
            // A worked-out set is worked out here too, rather than prefilled
            // from `targets` — which included this Mac and would have opened
            // the sheet proposing the machine the drives exist to survive.
            destinationTargetIDs: defaults.destinationMode == .automatic
                ? StorageGroup.automaticDestinations(
                    copies: defaults.desiredCopies, among: automaticEligibleDeviceIDs
                  )
                : defaults.destinationTargetIDs,
            destinationMode: defaults.destinationMode
        )
    }

    /// Records the source, remembers the answer for next time, and starts the
    /// import.
    func confirmAddingSource(_ setup: PendingSourceSetup) {
        pendingSourceSetup = nil
        // Two rows, because they answer two questions. The source records that
        // this folder was added and where it was; the group records how its
        // photos are to be kept. They start life together and part company the
        // moment either is edited.
        let source = PhotoArchiveSource(
            id: UUID(),
            kind: .folder,
            label: setup.label,
            originPath: setup.urls.count == 1 ? setup.urls[0].path : nil,
            addedAt: Date()
        )
        // The source *is* its first group: same id, same starting name. A
        // person adding a folder should meet one thing with a name, a place it
        // came from and a rule — not two rows that happen to agree. "Group"
        // only becomes a separate idea when a second one exists, which is
        // exactly when it is worth learning.
        //
        // The migration and the export path already did this; the folder flow
        // minted a fresh id, so the same relationship was true in two places
        // and coincidental in the third.
        let group = StorageGroup(
            id: source.id,
            label: setup.label,
            desiredCopies: setup.desiredCopies,
            destinationTargetIDs: setup.destinationTargetIDs,
            destinationMode: setup.destinationMode,
            createdAt: Date()
        )
        do {
            try catalog.upsertSource(source)
            try catalog.upsertStorageGroup(group)
        } catch {
            lastError = "Could not save the settings for \(setup.label): \(error.localizedDescription)"
            return
        }
        newSourceDefaults = StorageGroup.Defaults(
            desiredCopies: setup.desiredCopies,
            destinationTargetIDs: setup.destinationTargetIDs,
            destinationMode: setup.destinationMode
        )
        sources.append(source)
        storageGroups.append(group)
        audit(
            .system,
            "Added \(setup.label), set to keep its photos on \(deviceNames(setup.destinationTargetIDs)) — \(Formatters.count(setup.desiredCopies, "copy", "copies")) each."
        )
        // The import claims both for everything it brings in.
        importingIntoSourceID = source.id
        importingIntoStorageGroupID = group.id
        importFolders(setup.urls)
    }

    /// The source an in-flight import should attribute its assets to. Cleared
    /// when the import finishes; nil means the fallback path applies.
    private var importingIntoSourceID: UUID?
    /// The group an in-flight import should put its assets in.
    private var importingIntoStorageGroupID: UUID?

    func deviceNames(_ ids: [UUID]) -> String {
        let names = ids.compactMap { targetsByID[$0]?.name }
        guard !names.isEmpty else { return "no device" }
        guard names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    // MARK: - Changing where a source lives

    /// What changing a source's settings would actually do, computed before
    /// anything happens.
    ///
    /// The separation between deleting and releasing is the point. A copy the
    /// app wrote into its own replica folder can be removed once the new copy
    /// verifies. A file the *user* put there — the Takeout zip they downloaded
    /// onto that drive — is only un-counted, because the app does not delete
    /// files it did not write. A sheet that added those together would either
    /// promise space it will not reclaim or threaten a deletion it will not
    /// perform.
    func retargetPlan(
        for group: StorageGroup,
        newDestinations: [UUID],
        newCopies: Int
    ) -> RetargetPlan {
        let assetIDs = assets.filter { storageGroupIDByAsset[$0.id] == group.id }
        let sizes = Dictionary(
            assetIDs.map { ($0.id, $0.fileSize) }, uniquingKeysWith: { first, _ in first }
        )
        let old = Set(group.destinationTargetIDs)
        let new = Set(newDestinations)

        var arriving: [RetargetPlan.DeviceChange] = []
        for targetID in newDestinations where !old.contains(targetID) {
            guard let target = targetsByID[targetID] else { continue }
            var count = 0
            var bytes: Int64 = 0
            for asset in assetIDs {
                let alreadyThere = (replicasByAssetID[asset.id] ?? []).contains {
                    $0.targetID == targetID && $0.state == .present
                }
                if !alreadyThere {
                    count += 1
                    bytes += sizes[asset.id] ?? 0
                }
            }
            arriving.append(RetargetPlan.DeviceChange(
                targetID: targetID, name: target.name,
                isReachable: reachablePaths[targetID] != nil,
                toCopy: count, bytesToCopy: bytes,
                toDelete: 0, bytesFreed: 0, toRelease: 0
            ))
        }

        var departing: [RetargetPlan.DeviceChange] = []
        for targetID in group.destinationTargetIDs where !new.contains(targetID) {
            guard let target = targetsByID[targetID] else { continue }
            var toDelete = 0
            var freed: Int64 = 0
            var toRelease = 0
            for asset in assetIDs {
                guard let replica = (replicasByAssetID[asset.id] ?? []).first(where: {
                    $0.targetID == targetID && $0.state == .present
                }) else { continue }
                if ReplicationService.isArchiveBacked(replica) {
                    // The user's own file. Released from the catalog's count,
                    // never removed.
                    toRelease += 1
                } else {
                    toDelete += 1
                    freed += sizes[asset.id] ?? 0
                }
            }
            departing.append(RetargetPlan.DeviceChange(
                targetID: targetID, name: target.name,
                isReachable: reachablePaths[targetID] != nil,
                toCopy: 0, bytesToCopy: 0,
                toDelete: toDelete, bytesFreed: freed, toRelease: toRelease
            ))
        }

        return RetargetPlan(
            sourceID: group.id, sourceLabel: group.label,
            arriving: arriving, departing: departing
        )
    }

    /// Applies new settings to a source and queues the work.
    ///
    /// Copies are queued now; removals are **not**. A remove enqueued alongside
    /// the copy would race it, and the whole guarantee of a move is that the
    /// new copy exists and has been read back before the old one goes. So the
    /// departing devices are recorded on the source and the removals are
    /// queued by `releaseDepartedDevices` once the arrivals verify.
    /// - Parameter mode: how the devices were arrived at, when the caller
    ///   knows. `nil` keeps whatever the group already says, so adjusting the
    ///   copy count does not quietly pin a worked-out group to the devices it
    ///   happens to hold today.
    ///
    ///   Deliberately not inferred from the devices themselves. Inference works
    ///   for a catalog written before the question existed, where nothing else
    ///   survives to read — but not here, because the two cases are genuinely
    ///   identical from the outside: picking "just Drive A" for a one-copy
    ///   group is character-for-character what working it out produces. Only
    ///   the caller knows whether a person opened the picker.
    func applyStorageGroupSettings(
        _ group: StorageGroup,
        desiredCopies: Int,
        destinations: [UUID],
        mode: StorageGroup.DestinationMode? = nil
    ) {
        var updated = group
        updated.desiredCopies = desiredCopies
        updated.destinationTargetIDs = destinations
        updated.destinationMode = mode ?? group.destinationMode
        do {
            try catalog.upsertStorageGroup(updated)
        } catch {
            lastError = "Could not save the settings for \(group.label): \(error.localizedDescription)"
            return
        }
        audit(
            .policy,
            "\(group.label) is now kept on \(deviceNames(destinations)) — \(Formatters.count(desiredCopies, "copy", "copies")) each. Copies to the new devices are queued; anything on a device it no longer uses stays until the new copy has been read back and matched."
        )
        loadAll()
        // A worked-out group asking for more copies wants more devices, and the
        // audit that follows can only place onto devices the group names.
        resolveAutomaticDestinations()
        auditPlacement()
    }

    /// Removes the app's own copies from devices a source has moved off, once
    /// the new copies are proven.
    ///
    /// Gated on proof rather than on a timer or a prompt: every asset must be
    /// present on the number of devices the source now asks for, and each of
    /// those copies must have been read back at least once. Archive-backed
    /// files are never queued for removal — releasing the catalog's claim on
    /// them is all that happens, and it happens by the placement audit no
    /// longer counting them.
    @discardableResult
    func releaseDepartedDevices(for groupID: UUID) -> Int {
        guard let group = storageGroupsByID[groupID] else { return 0 }
        let named = Set(group.destinationTargetIDs)
        var queued = 0

        do {
            try catalog.transaction {
                for asset in assets where storageGroupIDByAsset[asset.id] == groupID {
                    let replicas = replicasByAssetID[asset.id] ?? []
                    let proven = replicas.filter {
                        named.contains($0.targetID) && $0.state == .present && $0.lastVerifiedAt != nil
                    }
                    // Not proven yet — leave everything exactly where it is.
                    guard proven.count >= group.desiredCopies else { continue }

                    for replica in replicas
                    where !named.contains(replica.targetID) && replica.state == .present {
                        guard !ReplicationService.isArchiveBacked(replica) else { continue }
                        try enqueueTask(
                            assetID: asset.id, targetID: replica.targetID, action: .remove
                        )
                        queued += 1
                    }
                }
            }
        } catch {
            lastError = "Could not queue the cleanup for \(group.label): \(error.localizedDescription)"
            return queued
        }

        if queued > 0 {
            audit(
                .replication,
                "\(group.label): \(Formatters.count(queued, "copy", "copies")) on devices it no longer uses are queued for removal, now that the new copies have been read back and matched."
            )
            loadAll()
        }
        return queued
    }

    // MARK: - Sources

    /// Gives every asset that predates sources one to belong to.
    ///
    /// Runs once at startup and is a no-op afterwards. Existing archives were
    /// built before any of this existed, and an asset without a source would
    /// fall back to the *current* defaults — which for someone whose photos
    /// are on two drives today could mean the app deciding they belong
    /// somewhere else entirely.
    ///
    /// So the destinations are not guessed: they are read from where the
    /// copies already are. The archive already answered the question, and the
    /// backfill's only job is to write that answer down. A source whose assets
    /// live nowhere yet gets the defaults, because there is nothing to read.
    func backfillSources() {
        let unassigned: [UUID]
        do {
            unassigned = try catalog.fetchAssetIDsWithoutSource()
        } catch {
            lastError = "Could not check which photos still need a source: \(error.localizedDescription)"
            return
        }
        guard !unassigned.isEmpty else { return }

        let pending = Set(unassigned)
        let batchByID = Dictionary(
            importBatches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        // Grouped the way the user would group them: one folder is one source
        // however many times it was swept, and one export is one source
        // however many parts it arrived in.
        // Which export each batch belongs to, so a backfilled export links to
        // the same set id a fresh import would use — otherwise the settings on
        // its card would govern a source nothing points at.
        var setIDByBatchID: [UUID: String] = [:]
        for archive in takeoutArchives {
            guard let batchID = archive.importBatchID, let setID = archive.exportSetID else { continue }
            setIDByBatchID[batchID] = setID
        }

        var groups: [String: (kind: PhotoArchiveSource.Kind, label: String, path: String?, setID: String?, assetIDs: [UUID])] = [:]
        for asset in assets where pending.contains(asset.id) {
            let batch = asset.importBatchID.flatMap { batchByID[$0] }
            let kind: PhotoArchiveSource.Kind
            let label: String
            let path: String?
            var setID: String?

            if asset.providerLocalID != nil {
                kind = .applePhotos
                label = "Photos library"
                path = nil
            } else if let batch, batch.isFolderImport, batch.isFilesystemPath {
                kind = .folder
                label = (batch.sourcePath as NSString).lastPathComponent
                path = batch.sourcePath
            } else if let batch {
                kind = .takeoutExport
                label = batch.sourcePath
                path = batch.isFilesystemPath ? batch.sourcePath : nil
                setID = setIDByBatchID[batch.id]
            } else {
                // Imported by a version that wrote no batch row. Kept together
                // under one honest label rather than split into one source per
                // photo, which would be unmanageable and untrue.
                kind = .folder
                label = "Added before the app kept a record"
                path = nil
            }

            // Keyed by the export where there is one: one export is one
            // source however many batches its parts arrived in.
            let key = "\(kind.rawValue)|\(setID ?? path ?? label)"
            groups[key, default: (kind, label, path, setID, [])].assetIDs.append(asset.id)
        }

        guard !groups.isEmpty else { return }
        let fallback = newSourceDefaults
        var created = 0

        do {
            try catalog.transaction {
                for key in groups.keys.sorted() {
                    guard let group = groups[key] else { continue }

                    // Where these photos actually are. Present copies only —
                    // a queued copy is an intention, and adopting intentions as
                    // configuration would make a half-finished sync permanent.
                    var deviceCounts: [UUID: Int] = [:]
                    for assetID in group.assetIDs {
                        for replica in replicasByAssetID[assetID] ?? []
                        where replica.state == .present {
                            deviceCounts[replica.targetID, default: 0] += 1
                        }
                    }
                    let observed = deviceCounts
                        .sorted { $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value }
                        .map(\.key)

                    // What the archive is already doing, not what the current
                    // default says it should do. Split into named values: as
                    // one expression the type-checker gives up on it.
                    let copies: Int = observed.isEmpty ? fallback.desiredCopies : observed.count
                    let destinations: [UUID] = observed.isEmpty
                        ? fallback.destinationTargetIDs
                        : observed
                    let now = Date()

                    let source = PhotoArchiveSource(
                        id: UUID(),
                        kind: group.kind,
                        label: group.label,
                        originPath: group.path,
                        exportSetID: group.setID,
                        addedAt: now
                    )
                    let storage = StorageGroup(
                        id: UUID(),
                        label: group.label,
                        desiredCopies: copies,
                        destinationTargetIDs: destinations,
                        createdAt: now
                    )
                    try catalog.upsertSource(source)
                    try catalog.upsertStorageGroup(storage)
                    try catalog.assignSource(source.id, toAssets: group.assetIDs)
                    try catalog.assignStorageGroup(storage.id, toAssets: group.assetIDs)
                    created += 1
                }
            }
        } catch {
            lastError = "Could not record where your existing photos came from: \(error.localizedDescription)"
            return
        }

        audit(
            .system,
            "Recorded \(Formatters.count(created, "source")) for \(Formatters.count(unassigned.count, "photo")) added before the app tracked where they came from. Each is set to keep its photos on the devices already holding them — nothing was moved, and you can change any of it under Keep safe."
        )
        loadAll()
    }

    /// Where this asset's copies belong, and how many — read off its source.
    ///
    /// An asset with no source yet (imported before sources existed, and not
    /// backfilled) falls back to the current defaults rather than being placed
    /// nowhere. Placing nothing would quietly stop protecting content that was
    /// protected yesterday, which is the worse failure of the two.
    /// How many copies this asset owes, read off its source. The number every
    /// protection verdict in the app is judged against.
    func desiredCopies(forAsset assetID: UUID) -> Int {
        placementPolicy(forAsset: assetID).copies
    }

    /// The export-part picture, built from the archives the catalog knows
    /// about.
    ///
    /// One place, because it is built on every recompute and by each of the
    /// three checks over export parts, and four call sites disagreeing about
    /// how many copies a part owes is exactly the bug this model exists to
    /// prevent.
    func makeArchivePlan() -> ArchiveReplicationPlan {
        ArchiveReplicationPlanner.plan(
            archives: takeoutArchives,
            managedTargetIDs: Set(targets.map(\.id)),
            destinationsBySetID: destinationsByExportSet,
            copiesRequiredBySetID: copiesRequiredByExportSet,
            defaultCopiesRequired: newSourceDefaults.desiredCopies
        )
    }

    // MARK: - Managing storage groups

    /// A new group with nothing in it yet.
    ///
    /// The thing the single-row model could not do. A group born from an import
    /// inherits that import's name and its photos; this one has neither, and is
    /// the starting point for "these ten go somewhere different from the rest of
    /// the download they came in".
    @discardableResult
    func createStorageGroup(label: String, from defaults: StorageGroup.Defaults? = nil) -> StorageGroup? {
        let settings = defaults ?? newSourceDefaults
        let group = StorageGroup(
            id: UUID(),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "New group"
                : label.trimmingCharacters(in: .whitespacesAndNewlines),
            desiredCopies: settings.desiredCopies,
            destinationTargetIDs: settings.destinationMode == .automatic
                ? StorageGroup.automaticDestinations(
                    copies: settings.desiredCopies, among: automaticEligibleDeviceIDs
                  )
                : settings.destinationTargetIDs,
            destinationMode: settings.destinationMode,
            createdAt: Date()
        )
        do {
            try catalog.upsertStorageGroup(group)
        } catch {
            lastError = "Could not make that group: \(error.localizedDescription)"
            return nil
        }
        audit(
            .policy,
            "Added the group \(group.label), set to keep its photos on \(deviceNames(group.destinationTargetIDs)) — \(Formatters.count(group.desiredCopies, "copy", "copies")) each. It has no photos in it yet."
        )
        loadAll()
        return group
    }

    func renameStorageGroup(_ groupID: UUID, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var group = storageGroupsByID[groupID], !trimmed.isEmpty,
              trimmed != group.label else { return }
        let previous = group.label
        group.label = trimmed
        do {
            try catalog.upsertStorageGroup(group)
        } catch {
            lastError = "Could not rename \(previous): \(error.localizedDescription)"
            return
        }
        audit(.policy, "Renamed the group \(previous) to \(trimmed).")
        loadAll()
    }

    /// Moves photos into a group, and queues whatever that now owes.
    ///
    /// Membership is a partition, so this takes them out of wherever they were.
    /// Copies to the devices the new group names are queued; copies on devices
    /// only the old group named are **not** deleted here — that waits on proof,
    /// through `releaseDepartedDevices`, exactly as a retarget does. Moving a
    /// photo between groups must never be a faster route to deleting a copy
    /// than changing a group's settings is.
    @discardableResult
    func moveToStorageGroup(_ groupID: UUID, assetIDs: [UUID]) -> Int {
        guard let group = storageGroupsByID[groupID], !assetIDs.isEmpty else { return 0 }
        let moving = assetIDs.filter { storageGroupIDByAsset[$0] != groupID }
        guard !moving.isEmpty else { return 0 }
        let vacated = Set(moving.compactMap { storageGroupIDByAsset[$0] })

        do {
            try catalog.assignStorageGroup(groupID, toAssets: moving)
        } catch {
            lastError = "Could not move those photos into \(group.label): \(error.localizedDescription)"
            return 0
        }
        audit(
            .policy,
            "Moved \(Formatters.count(moving.count, "photo")) into \(group.label), which keeps its photos on \(deviceNames(group.destinationTargetIDs)) — \(Formatters.count(group.desiredCopies, "copy", "copies")) each. Copies to any new device are queued; nothing already on a device was deleted."
        )
        loadAll()
        auditPlacement()
        // The groups they left may now be owed removals, on the same proof the
        // retarget path requires.
        for groupID in vacated { releaseDepartedDevices(for: groupID) }
        return moving.count
    }

    /// Forgets a group. Its photos stay and fall back to the defaults.
    ///
    /// Refused while it still holds photos unless somewhere is named to put
    /// them: a group is how the app knows where a photo belongs, and dropping
    /// that silently would leave them answering to whatever the add sheet last
    /// remembered.
    func deleteStorageGroup(_ groupID: UUID, movingPhotosTo destinationID: UUID? = nil) {
        guard let group = storageGroupsByID[groupID] else { return }
        let members = assets.filter { storageGroupIDByAsset[$0.id] == groupID }.map(\.id)

        if !members.isEmpty, let destinationID, storageGroupsByID[destinationID] != nil {
            guard moveToStorageGroup(destinationID, assetIDs: members) > 0 else { return }
        } else if !members.isEmpty {
            lastError = "\(group.label) still holds \(Formatters.count(members.count, "photo")). Choose a group to move them to first — deleting it would leave them with no setting of their own."
            return
        }

        do {
            try catalog.deleteStorageGroup(id: groupID)
        } catch {
            lastError = "Could not remove \(group.label): \(error.localizedDescription)"
            return
        }
        audit(.policy, "Removed the group \(group.label). No photo was deleted.")
        loadAll()
    }

    /// Where a group's photos came from, in the words the Policies screen uses.
    ///
    /// Policies is the only place a group is edited now, so it has to carry the
    /// context the source's card used to supply. A group and the import that
    /// made it start with the same name, and stay indistinguishable until
    /// something is regrouped — at which point the name alone stops being
    /// enough to know what you are about to change.
    func provenanceSummary(forStorageGroup groupID: UUID) -> String? {
        var labels = Set<String>()
        var withoutSource = 0
        for asset in assets where storageGroupIDByAsset[asset.id] == groupID {
            if let sourceID = sourceIDByAsset[asset.id], let source = sourcesByID[sourceID] {
                labels.insert(source.label)
            } else {
                withoutSource += 1
            }
        }
        if labels.isEmpty {
            return withoutSource > 0 ? "from photos with no import recorded" : "nothing in it yet"
        }
        if labels.count == 1, withoutSource == 0 {
            // Nothing to say when the group still *is* the import it was born
            // as. "Recovered import (Google Takeout) — from Recovered import
            // (Google Takeout)" is an echo, and an echo reads as two things
            // that happen to share a name rather than one thing.
            let only = labels.first!
            return only == storageGroupsByID[groupID]?.label ? nil : "from \(only)"
        }
        return "from \(Formatters.count(labels.count, "import"))"
            + (withoutSource > 0 ? ", and some with none recorded" : "")
    }

    /// How many photos are in each group — the count the management UI shows.
    var photoCountByStorageGroup: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for asset in assets where !asset.isLivePhotoMotion {
            guard let groupID = storageGroupIDByAsset[asset.id] else { continue }
            counts[groupID, default: 0] += 1
        }
        return counts
    }

    /// Where a group's photos came from, when they all came from one place.
    ///
    /// The group carries no path of its own — it is policy, not history — so
    /// the sheet that edits it asks the sources behind its photos. A group made
    /// by hand out of several imports has no single answer, and gets none.
    func originPath(forStorageGroup groupID: UUID) -> String? {
        var paths = Set<String>()
        for asset in assets where storageGroupIDByAsset[asset.id] == groupID {
            guard let sourceID = sourceIDByAsset[asset.id],
                  let path = sourcesByID[sourceID]?.originPath else { continue }
            paths.insert(path)
            if paths.count > 1 { return nil }
        }
        return paths.first
    }

    /// The group behind one source's photos, when they are all in one.
    private func groupBehind(_ source: PhotoArchiveSource) -> StorageGroup? {
        var groupIDs = Set<UUID>()
        for asset in assets where sourceIDByAsset[asset.id] == source.id {
            guard let groupID = storageGroupIDByAsset[asset.id] else { continue }
            groupIDs.insert(groupID)
            if groupIDs.count > 1 { return nil }
        }
        return groupIDs.first.flatMap { storageGroupsByID[$0] }
    }

    /// Where one source's photos actually sit, and whether its card may offer
    /// to change that.
    ///
    /// Answered from membership rather than from the id a group happened to be
    /// created with. A group created alongside a source shares its id, which
    /// made it tempting to treat as "the source's group" — but membership moves
    /// and ids do not, so that shortcut goes wrong exactly when it matters.
    func groupPlacement(forSource sourceID: UUID) -> SourceGroupPlacement {
        var countsByGroup: [UUID: Int] = [:]
        var mine = 0
        for asset in assets where sourceIDByAsset[asset.id] == sourceID {
            guard let groupID = storageGroupIDByAsset[asset.id] else { continue }
            countsByGroup[groupID, default: 0] += 1
            mine += 1
        }
        guard let onlyGroupID = countsByGroup.keys.first, countsByGroup.count == 1 else {
            guard !countsByGroup.isEmpty else { return .none }
            let groups = countsByGroup.keys.compactMap { storageGroupsByID[$0] }
                .sorted { $0.createdAt < $1.createdAt }
            return .split(groups: groups, photoCount: mine)
        }
        guard let group = storageGroupsByID[onlyGroupID] else { return .none }
        let total = photoCountByStorageGroup[onlyGroupID] ?? 0
        let others = total - (countsByGroup[onlyGroupID] ?? 0)
        return others > 0
            ? .shared(group: group, otherPhotos: others)
            : .exclusive(group)
    }

    /// The same, for an export, which is reached by its set id.
    func groupPlacement(forExportSet setID: String) -> SourceGroupPlacement {
        guard let source = sources.first(where: { $0.exportSetID == setID }) else { return .none }
        let placement = groupPlacement(forSource: source.id)
        if case .none = placement {
            // Found but never imported: the group made with it is the only
            // answer there is, and it holds nothing, so editing it is safe.
            if let group = storageGroupsByID[source.id] { return .exclusive(group) }
        }
        return placement
    }

    /// The group one export's photos are in, when they are all in one.
    ///
    /// Membership moved onto the group, so an export's photos *can* be split
    /// across several — someone pulls ten out of a download into a group of
    /// their own. There is then no single answer to "how is this export kept",
    /// and inventing one by picking the biggest would be the app deciding. Nil
    /// says so, and the card reports the split rather than a number.
    func storageGroup(forExportSet setID: String) -> StorageGroup? {
        guard let source = sources.first(where: { $0.exportSetID == setID }) else { return nil }
        if let fromPhotos = groupBehind(source) { return fromPhotos }
        // No photos to read it from — an export found on a drive and not yet
        // imported. Its group is the one made with it, which shares its id.
        // Without this the export looks group-less right up until its first
        // photo lands, and every ask for its settings would make another group.
        return storageGroupsByID[source.id]
    }

    /// Where each export belongs, read off the group its photos are in.
    var destinationsByExportSet: [String: Set<UUID>] {
        var result: [String: Set<UUID>] = [:]
        for source in sources {
            guard let setID = source.exportSetID,
                  let group = storageGroup(forExportSet: setID) else { continue }
            result[setID] = Set(group.destinationTargetIDs)
        }
        return result
    }

    /// What each export set asks for, read off the source that is that export.
    ///
    /// A set with no source yet — discovered but never imported — is absent
    /// here and falls back to the defaults, which is the honest answer: nobody
    /// has been asked about it.
    var copiesRequiredByExportSet: [String: Int] {
        var result: [String: Int] = [:]
        for source in sources {
            guard let setID = source.exportSetID,
                  let group = storageGroup(forExportSet: setID) else { continue }
            result[setID] = group.desiredCopies
        }
        return result
    }

    /// Gives an export's source the set id it is identified by.
    ///
    /// Sources recorded before exports carried one have `exportSetID` nil, so
    /// nothing can find them: the export's card offers no settings, and the
    /// archive plan falls back to the defaults for a set the user may already
    /// have configured. Nothing needs to be re-read to fix it — the source's
    /// assets name their import batch, and the archives of that batch name the
    /// set — so this is arithmetic over rows the catalog already holds.
    ///
    /// Runs at launch beside the source backfill, and does nothing once every
    /// export source is linked.
    func linkExportSourcesToTheirSets() {
        let exportSources = sources.filter { $0.kind == .takeoutExport }
        guard exportSources.contains(where: { $0.exportSetID == nil }) else { return }

        var setIDByBatchID: [UUID: String] = [:]
        for archive in takeoutArchives {
            guard let batchID = archive.importBatchID,
                  let setID = archive.exportSetID else { continue }
            setIDByBatchID[batchID] = setID
        }
        guard !setIDByBatchID.isEmpty else { return }

        // Which set each source's photos actually came out of, and how many of
        // them. Counted rather than taken from the first match: a source
        // covering several batches should answer to the export most of it came
        // from.
        var assetIDsBySource: [UUID: [UUID]] = [:]
        var setCountsBySource: [UUID: [String: Int]] = [:]
        for asset in assets {
            guard let sourceID = sourceIDByAsset[asset.id] else { continue }
            assetIDsBySource[sourceID, default: []].append(asset.id)
            guard let batchID = asset.importBatchID,
                  let setID = setIDByBatchID[batchID] else { continue }
            setCountsBySource[sourceID, default: [:]][setID, default: 0] += 1
        }

        // Sources grouped by the export they belong to.
        var bySet: [String: [PhotoArchiveSource]] = [:]
        for source in exportSources {
            let setID = source.exportSetID
                ?? setCountsBySource[source.id]?
                    .max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }?.key
            guard let setID else { continue }
            bySet[setID, default: []].append(source)
        }

        var linked = 0
        var merged = 0
        var leftSplit: [String] = []

        do {
            try catalog.transaction {
                for setID in bySet.keys.sorted() {
                    guard var group = bySet[setID], !group.isEmpty else { continue }
                    // Most photos first: the keeper should be the row that
                    // already describes most of the export.
                    group.sort { a, b in
                        let countA = assetIDsBySource[a.id]?.count ?? 0
                        let countB = assetIDsBySource[b.id]?.count ?? 0
                        return countA == countB ? a.addedAt < b.addedAt : countA > countB
                    }
                    let keeper = group[0]
                    let rest = Array(group.dropFirst())

                    // One export is one source — but only where collapsing them
                    // throws nothing away. Two rows that ask for the same copies
                    // on the same devices in the same order say one thing twice,
                    // and merging them loses nothing. Two that disagree are two
                    // decisions the user made, and picking a winner would be the
                    // app quietly overruling one of them (invariant 4). Those
                    // are left exactly as they are and reported.
                    // Compared through the groups, which is where the settings
                    // are. Two sources with no group between them agree
                    // trivially — there is nothing to disagree about.
                    let keeperGroup = groupBehind(keeper)
                    let agree = rest.allSatisfy { other in
                        let mine = groupBehind(other)
                        return mine?.desiredCopies == keeperGroup?.desiredCopies
                            && mine?.destinationTargetIDs == keeperGroup?.destinationTargetIDs
                    }

                    if keeper.exportSetID != setID {
                        var updated = keeper
                        updated.exportSetID = setID
                        try catalog.upsertSource(updated)
                        linked += 1
                    }

                    guard !rest.isEmpty else { continue }
                    guard agree else {
                        leftSplit.append(setID)
                        continue
                    }
                    for loser in rest {
                        let moving = assetIDsBySource[loser.id] ?? []
                        if !moving.isEmpty {
                            try catalog.assignSource(keeper.id, toAssets: moving)
                        }
                        try catalog.deleteSource(id: loser.id)
                        merged += 1
                    }
                }
            }
        } catch {
            lastError = "Could not link your Google downloads to their settings: \(error.localizedDescription)"
            return
        }

        guard linked > 0 || merged > 0 || !leftSplit.isEmpty else { return }
        var message = ""
        if linked > 0 {
            message += "Linked \(Formatters.count(linked, "Google download")) to the settings recorded for \(Formatters.pluralise(linked, "it", "them")), so how many copies to keep and where can be changed from the download's own card. "
        }
        if merged > 0 {
            message += "\(Formatters.count(merged, "duplicate record")) of the same download were folded into one — they asked for the same copies on the same devices, so nothing changed about where anything is kept. "
        }
        if !leftSplit.isEmpty {
            message += "\(Formatters.count(leftSplit.count, "download")) is recorded more than once with different settings; both were left alone, because choosing between them is yours to do under Keep safe. "
        }
        audit(.system, message + "Nothing was moved.")
        loadAll()
    }

    /// The source for one Google export, creating it the first time.
    ///
    /// Exports had no source of their own, so their photos fell through to the
    /// add-sheet defaults and there was nothing for "change where these are
    /// kept" to change. One row per export set — its zips and the folders they
    /// unpack into are one source, not two, which is what stops somebody
    /// placing the zip on one drive and its contents on another and believing
    /// they have two copies.
    @discardableResult
    func sourceForExportSet(_ setID: String, label: String) -> (source: PhotoArchiveSource, group: StorageGroup)? {
        if let existing = sources.first(where: { $0.exportSetID == setID }) {
            // The source is there; the group may not be, if the export was
            // recorded before it had one.
            if let group = storageGroup(forExportSet: setID) { return (existing, group) }
            guard let group = makeStorageGroup(id: existing.id, label: label) else { return nil }
            return (existing, group)
        }

        let source = PhotoArchiveSource(
            id: UUID(),
            kind: .takeoutExport,
            label: label,
            originPath: nil,
            exportSetID: setID,
            addedAt: Date()
        )
        // Shares the source's id, the same convention the policy migration
        // uses, so the two halves of one export can find each other before any
        // photo exists to link them.
        guard let group = makeStorageGroup(id: source.id, label: label) else { return nil }
        do {
            try catalog.upsertSource(source)
        } catch {
            lastError = "Could not record settings for \(label): \(error.localizedDescription)"
            return nil
        }
        sources.append(source)
        return (source, group)
    }

    /// A new group carrying the last answer the user gave.
    ///
    /// The same starting point every other group gets when one is made without
    /// asking. The card offers the same settings sheet a folder has, so this is
    /// a starting point rather than a decision taken on the user's behalf and
    /// then hidden.
    private func makeStorageGroup(id: UUID = UUID(), label: String) -> StorageGroup? {
        let defaults = newSourceDefaults
        let destinations = defaults.destinationTargetIDs.isEmpty
            ? Array(targets.map(\.id).prefix(defaults.desiredCopies))
            : defaults.destinationTargetIDs
        let group = StorageGroup(
            id: id,
            label: label,
            desiredCopies: defaults.desiredCopies,
            destinationTargetIDs: destinations,
            createdAt: Date()
        )
        do {
            try catalog.upsertStorageGroup(group)
        } catch {
            lastError = "Could not record settings for \(label): \(error.localizedDescription)"
            return nil
        }
        storageGroups.append(group)
        return group
    }

    func placementPolicy(forAsset assetID: UUID) -> (destinations: [UUID], copies: Int) {
        guard let group = storageGroup(forAsset: assetID) else {
            // A photo in no group. The only policy that is not a group's, and
            // it is a stop-gap rather than a setting: placing nothing would
            // quietly stop protecting content that was protected yesterday,
            // which is the worse failure of the two.
            //
            // Reachable — an import that goes through no source flow (the
            // connect-time adoption sweep) names no group — so it is surfaced
            // by `ungroupedAssetIDs` and fixable on the Policies screen rather
            // than left as a silent answer nobody can see. Every photo owing
            // its copies to a group the user can read is the point of the
            // model; a preference standing in for one is not.
            let fallback = newSourceDefaults
            return (fallback.destinationTargetIDs, fallback.desiredCopies)
        }
        return (group.destinationTargetIDs, group.desiredCopies)
    }

    /// Photos in no group, and so following the add-sheet defaults rather than
    /// anything the user set. Nothing is wrong with them; nobody has said where
    /// they belong.
    var ungroupedAssetIDs: [UUID] {
        assets
            .filter { !$0.isLivePhotoMotion && storageGroupIDByAsset[$0.id] == nil }
            .map(\.id)
    }

    /// Groups assets by the policy that applies to them, so a batch is planned
    /// once per distinct destination set rather than once per asset.
    private func groupedByPolicy(_ assetIDs: [UUID]) -> [(destinations: [UUID], copies: Int, assetIDs: [UUID])] {
        var buckets: [String: (destinations: [UUID], copies: Int, assetIDs: [UUID])] = [:]
        for assetID in assetIDs {
            let policy = placementPolicy(forAsset: assetID)
            let key = "\(policy.copies)|" + policy.destinations.map(\.uuidString).joined(separator: ",")
            buckets[key, default: (policy.destinations, policy.copies, [])].assetIDs.append(assetID)
        }
        // Sorted so a batch plans in a reproducible order; dictionary order is
        // not, and placement that varies between runs cannot be tested.
        return buckets.keys.sorted().compactMap { buckets[$0] }
    }

    /// Every registered device, with the free space placement should reason
    /// about.
    ///
    /// An unreachable device reports nil rather than a remembered figure: a
    /// drive's free space when it was last seen is not evidence about its free
    /// space now, and `PlacementPlanner` ranks unknown last rather than
    /// treating it as empty.
    var placementCandidates: [PlacementPlanner.Candidate] {
        targets.map { target in
            let mount = reachablePaths[target.id]
            return PlacementPlanner.Candidate(
                targetID: target.id,
                freeBytes: mount.flatMap { TakeoutExtractor.availableCapacity(onVolumeOf: $0) },
                isReachable: mount != nil
            )
        }
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
            // The source map is only refreshed by `loadAll`, so mid-import this
            // falls back to the add-sheet defaults. That is the right answer
            // for a row the Library is showing provisionally, and the
            // `loadAll` at the end of the import replaces it with the source's
            // own number.
            protectionStates[asset.id] = ProtectionEvaluator.protectionState(
                for: asset,
                replicaStates: replicasByAsset[asset.id] ?? [],
                desiredCopies: desiredCopies(forAsset: asset.id)
            )
        }
    }

    /// What a sweep discovered the archive already had.
    private struct AdoptionOutcome {
        var adopted = 0
        var withdrawn = 0
        var reclaimedFiles = 0
        var reclaimedBytes: Int64 = 0

        var isEmpty: Bool { adopted == 0 && reclaimedFiles == 0 }
    }

    /// Records copies the app has just found out it already had, and withdraws
    /// the work it had queued to make them again.
    ///
    /// This is where a placement decision stops being final. An import used to
    /// settle where an asset's bytes live the first time it saw them and never
    /// revisit it, so registering a drive after importing from it left the app
    /// copying that drive's own files back onto it under different names. What
    /// the sweep proved is simple and worth writing down whenever it is
    /// learned: these exact bytes are on this target, read and hashed just now.
    private func applyAdoptedReplicas(_ adopted: [UUID: TargetReplicaState]) throws -> AdoptionOutcome {
        var outcome = AdoptionOutcome()
        var settleByTarget: [UUID: Set<UUID>] = [:]
        // Deleted only after the catalog commits to the user's own file, so an
        // interruption can strand bytes but never lose the last copy.
        var redundant: [(url: URL, size: Int64)] = []

        for (assetID, replica) in adopted {
            guard let asset = assetsByID[assetID] else { continue }
            let existing = replicasByAssetID[assetID]?.first { $0.targetID == replica.targetID }

            if let existing, existing.state == .present {
                if ReplicationService.isArchiveBacked(existing) {
                    // Already credited to content in place. If the recorded
                    // path differs this is the user's own second copy, which is
                    // theirs to keep and not ours to adjudicate.
                    continue
                }
                // The app's own copy under the replica root, and the user's
                // file holding the same bytes on the same drive: the
                // duplication this path exists to prevent, arrived at one step
                // late. Repoint to their file and take back ours.
                guard let mount = reachablePaths[replica.targetID],
                      let drive = targetsByID[replica.targetID],
                      let relative = existing.relativePath
                else {
                    // Not mounted, or nothing recorded to find. Repointing
                    // without being able to see the old file would strand bytes
                    // nobody can name; leave it for a pass with the drive there.
                    continue
                }
                let root = mount
                    .appendingPathComponent(drive.replicaRootComponent, isDirectory: true)
                    .standardizedFileURL
                let managed = root.appendingPathComponent(relative).standardizedFileURL
                // Only ever inside the app's own folder on that target.
                guard managed.path.hasPrefix(root.path + "/"),
                      FileManager.default.fileExists(atPath: managed.path)
                else { continue }
                redundant.append((managed, asset.fileSize))
            }

            try catalog.upsertReplicaState(replica)
            outcome.adopted += 1
            settleByTarget[replica.targetID, default: []].insert(assetID)
        }

        for (targetID, assetIDs) in settleByTarget {
            outcome.withdrawn += replicationTasks.filter {
                $0.targetID == targetID && $0.action == .copy
                    && $0.state == .queued && assetIDs.contains($0.assetID)
            }.count
            try settleQueuedCopyTasks(assetIDs: assetIDs, targetID: targetID)
        }

        for item in redundant {
            do {
                try FileManager.default.removeItem(at: item.url)
                outcome.reclaimedFiles += 1
                outcome.reclaimedBytes += item.size
            } catch {
                // An orphan under the replica root costs space and nothing
                // else — the catalog already points at the durable file, and
                // the next sweep of this drive sees it again.
            }
        }
        return outcome
    }

    private func applyImportResult(_ result: ImportResult) {
        do {
            try catalog.upsertImportBatch(result.batch)
            try persistImportedAssets(
                result.importedAssets,
                archiveBacked: result.archiveBackedReplicas,
                capturedMetadata: result.capturedMetadata
            )
            let adoption = try applyAdoptedReplicas(result.adoptedReplicas)
            // A cache, so a failure to write it must not fail the import.
            do {
                try catalog.upsertScanMemo(result.scanMemoEntries)
            } catch {
                audit(.importEvent, "Could not record what this sweep read; the next one will re-read it.")
            }
            audit(.importEvent, "Imported \(Formatters.count(result.importedAssets.count, "asset")) from \(result.batch.sourcePath) (\(Formatters.count(result.duplicateFilenames.count, "exact duplicate")) skipped, \(Formatters.count(result.failures.count, "failure"))).")
            if !adoption.isEmpty {
                var line = "\(Formatters.count(adoption.adopted, "file")) already in the archive were found in place and recorded as that drive's copy"
                if adoption.withdrawn > 0 {
                    line += "; \(Formatters.count(adoption.withdrawn, "queued copy", "queued copies")) withdrawn"
                }
                if adoption.reclaimedFiles > 0 {
                    line += "; removed \(Formatters.count(adoption.reclaimedFiles, "duplicate")) the app had written alongside them, freeing \(Formatters.bytes.string(fromByteCount: adoption.reclaimedBytes))"
                }
                audit(.replication, line + ".")
            }
            openPolicyMigrations(result.cloudPlacements)
            if !result.importedAssets.isEmpty {
                reopenLivePhotoChecks(forNewlyImported: result.importedAssets)
                recoverCaptureDates()
                pairLivePhotos()
            }
            if !result.failures.isEmpty {
                lastError = "Import finished with \(Formatters.count(result.failures.count, "failure")): \(result.failures.first!.error)"
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

    func performTakeoutScan(rootURL: URL, targetID: UUID?) async {
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
            audit(.importEvent, "Takeout scan of \(rootURL.path): \(Formatters.count(found.count, "archive")) found, \(newCount) new, \(refreshedCount) refreshed.", targetID: targetID)
        } catch {
            lastError = "Recording Takeout scan results failed: \(error.localizedDescription)"
        }
        takeoutActivity = nil
        loadAll()
        // Registering an archive is the only thing that can produce a folder
        // holding other exports, so this is where one is caught — before the
        // totals it would double-count are ever shown.
        dropContainerArchives()
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
            failedCount: 0,
            origin: .googleTakeout
        )
        do {
            try catalog.upsertImportBatch(batch)
        } catch {
            lastError = "Could not open import batch: \(error.localizedDescription)"
            isImporting = false
            return
        }

        // Claim everything this import brings in for the export it came out of,
        // the same way the add-a-source sheet claims a folder's photos. Without
        // it an export's photos answered to nobody: they fell through to the
        // defaults, and the settings on the export's card governed nothing.
        //
        // Set before the first chunk, because `persistImportedAssets` reads it
        // per chunk and placement inside it needs the export's destinations,
        // not the defaults'. Cleared in `defer` so a failure part-way through
        // cannot leave the claim standing for the next import to inherit.
        if let setID = targets[0].exportSetID,
           let claimed = sourceForExportSet(setID, label: setLabel) {
            importingIntoSourceID = claimed.source.id
            importingIntoStorageGroupID = claimed.group.id
        }
        defer {
            importingIntoSourceID = nil
            importingIntoStorageGroupID = nil
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
                // An extracted export sits on the drive that holds it, so its
                // workspace resolves against that one target; a zip unpacked
                // into a Mac temp workspace resolves against none.
                let placement = archive.kind == .folder
                    ? reachablePaths.first { archive.path.hasPrefix($0.value.path + "/") }
                        .map { TargetPlacement(targetID: $0.key, mountPath: $0.value.path) }
                        ?? TargetPlacement()
                    : TargetPlacement()
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
                    audit(.importEvent, "Resuming \(archive.displayName) after \(Formatters.count(resumeFrom, "already-processed file")); \(partFiles.count - resumeFrom) remain.")
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
                        audit(.importEvent, "Import of \(archive.displayName) stopped at \(processedFiles) of \(Formatters.count(partFiles.count, "file")): the drive is \(why). It will resume from here.")
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
                            placement: placement,
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
                            archiveBacked: result.archiveBackedReplicas,
                            capturedMetadata: result.capturedMetadata
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
                if partArchiveBackedCount > 0, let mount = placement.mounts.first {
                    let targetName = targetsByID[mount.targetID]?.name ?? "drive"
                    audit(.replication, "\(Formatters.count(partArchiveBackedCount, "asset")) from \(archive.displayName) use their Takeout files as the \(targetName) replica — no duplicate copy queued for that drive.", targetID: mount.targetID)
                }
                audit(.importEvent, "\(archive.displayName): imported \(Formatters.count(partImported, "asset")), \(Formatters.count(partDuplicates, "duplicate")) skipped.")
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
            var message = "Imported \(Formatters.count(allImported.count, "asset")) from \(setLabel) (\(Formatters.count(duplicateTotal, "duplicate")) skipped, \(Formatters.count(failureTotal, "failure")))."
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
                note: "\(Formatters.count(workers, "parallel worker"))"
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
                lastError = "Not deleting \(archive.displayName): its files are the \(targetsByID[targetID]?.name ?? "drive") replica for \(Formatters.count(backingCount, "asset")). It is storage, not a redundant copy."
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
            archive.note = "Reconciled: existing content on \(targetName) claimed as \(Formatters.count(result.claimedReplicas.count, "verified replica")); nothing was copied."
            try catalog.upsertTakeoutArchive(archive)
            let method = usedFastPath ? "checksum match with a known identical zip" : "in-place hashing"
            audit(.replication, "\(archive.displayName) on \(targetName): \(result.claimedReplicas.count) of \(Formatters.count(result.scannedFileCount, "file")) claimed as in-place replicas via \(method); queued copies cancelled.", targetID: targetID)
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
            repairs.append("withdrew \(Formatters.count(withdrawn, "unverified \(domain.displayName) presence claim")) recorded by an earlier version")
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
            audit(.violation, "Withdrew unverified \(domain.displayName) presence from \(Formatters.count(affected.count, "asset")) the app holds locally; it has no \(domain.displayName) connection and never confirmed the claim.")
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

    /// The folder this machine holds its copy in when nobody has chosen one.
    ///
    /// Beside the catalog rather than in Pictures or Documents: it is the app's
    /// own storage, it should not appear in the user's own folders uninvited,
    /// and putting it next to the database means one place to look and one
    /// place to move. It is outside `Staging/`, which the registration check
    /// enforces anyway — staging is transit and a target inside it would have
    /// the app counting its own waiting room as a copy.
    var defaultHostTargetURL: URL {
        staging.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("LocalCopy", isDirectory: true)
    }

    /// Set when the user forgets the host target, so the app does not silently
    /// re-adopt this Mac on the next launch and undo their decision. Forgetting
    /// is the supported way to run an archive that will not fit on the boot
    /// disk (SPEC invariant 4), and a default that reasserts itself is not a
    /// default, it is a policy.
    private var hostTargetDeclined: Bool = false

    /// Makes this machine a target on first launch.
    ///
    /// The Mac is a device like any other, and treating it only as a corridor
    /// meant a fresh install with no drive attached held nothing the policy
    /// counted — while a boot disk with room to spare sat unused. Under the
    /// default two-copy policy this is copy one, and the second is the first
    /// drive registered.
    ///
    /// Deliberately quiet, and deliberately conservative:
    ///
    /// - It runs once. Once the user has forgotten the host target, or
    ///   registered one themselves, this never acts again.
    /// - It defers rather than failing when the folder cannot be made.
    ///   Surfacing that as a startup error, on a launch the user did not ask
    ///   anything of, would be alarming and unactionable. A later launch, or an
    ///   explicit registration from the Drives screen, still works.
    /// - It does not require room for the whole archive. Under `k`-of-`n` the
    ///   Mac takes the share that fits and placement routes the rest to
    ///   drives, so the old "will the entire archive fit on the boot disk"
    ///   gate was asking a question that no longer decides anything.
    func adoptHostDeviceIfNeeded() {
        guard !hostTargetDeclined else { return }
        guard !targets.contains(where: { $0.kind == .hostDevice }) else { return }

        let url = defaultHostTargetURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return
        }

        // Still declines a boot disk with no room to spare: a device that
        // cannot take even the reserve is not somewhere copies can go, and
        // registering it would add a device that placement always skips.
        let available = TakeoutExtractor.availableCapacity(onVolumeOf: url) ?? 0
        guard available > PlacementPlanner.reserveBytes else { return }

        // The refusal path sets `lastError`, and this registration was the
        // app's idea rather than the user's, so it is not theirs to dismiss.
        // Restored rather than cleared: an error already on the store came
        // from something they did do, and swallowing it here would lose it.
        let existingError = lastError
        registerHostDeviceTarget(at: url, name: hostDeviceName)
        lastError = existingError
    }

    /// What this Mac is called, so the Drives screen and every source's copy
    /// status name the machine rather than saying "This device" twice.
    var hostDeviceName: String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "This Mac" : name
    }

    /// Whether this machine currently holds a counted copy.
    var hostTarget: ReplicationTarget? {
        targets.first { $0.kind == .hostDevice }
    }

    /// Records that the user does not want this Mac holding a copy, so the
    /// first-launch adoption does not put it back.
    func declineHostTarget() {
        hostTargetDeclined = true
        defaults.set(true, forKey: "hostTargetDeclined")
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
        // A device only has to have room for *something*, not for the whole
        // archive: placement gives it the share that fits and routes the rest
        // elsewhere. What is refused is a disk with no usable room at all,
        // which would be a device placement could never choose — a registered
        // target that silently does nothing is worse than a refusal.
        let available = TakeoutExtractor.availableCapacity(onVolumeOf: url) ?? 0
        if available <= PlacementPlanner.reserveBytes {
            lastError = """
            Not registering \(url.lastPathComponent): a device needs more than \
            \(Formatters.bytes.string(fromByteCount: PlacementPlanner.reserveBytes)) free to hold \
            anything, and this disk has \(Formatters.bytes.string(fromByteCount: available)) available.
            """
            return
        }

        // Registering this Mac on purpose overrides an earlier decision not to
        // have it — otherwise the flag from a previous "forget" would sit there
        // invisibly and un-register it on the next launch.
        hostTargetDeclined = false
        defaults.set(false, forKey: "hostTargetDeclined")

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

    /// Local photos, counted the way the Library counts them: a Live Photo is
    /// one photo though it is a still and a movie on disk. Files are what gets
    /// copied; photos are what the user thinks they own, and a device's share
    /// has to be stated in the same unit as the archive it is a share of.
    var localPhotoCount: Int {
        assets.filter { $0.residency == .local && !$0.isLivePhotoMotion }.count
    }

    /// Clears empty replica bucket directories from a connected device.
    ///
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
            // Forgetting this Mac is the supported way to run an archive the
            // boot disk cannot hold. Remember the decision, or first-launch
            // adoption puts the host target straight back on next launch and
            // the user has no way to make it stop.
            if target.kind == .hostDevice { declineHostTarget() }
            lastRotPatrol[targetID] = nil
            lastAnchorCheck[targetID] = nil
            loadAll()
            // Before the audit, not after: a worked-out group was naming this
            // device, and until it names a remaining one there is nothing for
            // the audit to place onto. Reversed, the drive's photos would read
            // as short with nowhere to go.
            resolveAutomaticDestinations()
            // Its replicas went with it, so assets it was holding are now
            // short. Re-place them onto the devices that remain — this is the
            // path back from a failed drive, and leaving it to a later launch
            // would mean sitting below the policy without saying so.
            let requeued = auditPlacement()
            if requeued > 0 {
                audit(
                    .replication,
                    "Re-placed \(Formatters.count(requeued, "copy", "copies")) that \(target.name) was holding onto your other devices."
                )
            }
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
            audit(.drive, "Registered \(kind.displayName.lowercased()) target \(target.name).", targetID: targetID)
            loadAll()
            // A new device does *not* owe a copy of everything. It owes a share
            // of whatever the archive is currently short — which, if every
            // photo already has its copies, is nothing at all.
            //
            // Seeding the whole archive onto every new device was the old
            // model's defining move, and it is what made a third drive
            // impossible: registering one queued a full copy of the archive
            // whether or not a single photo needed it.
            //
            // The scan comes first, and has to. Placement asks each candidate
            // how much room it has, and a device nobody has looked at yet
            // reports nil — which `PlacementPlanner` reads as no room, so every
            // photo came back with a `.noRoom` obstacle and the audit queued
            // nothing at all. Registering a drive therefore did nothing until
            // some later event happened to re-run the audit. Scanning first
            // also lets the connect sequence claim content the drive already
            // holds, so the audit that follows asks for what is genuinely
            // missing rather than queuing copies adoption then withdraws.
            // Deliberately the blocking form. The audit two lines down can
            // only place onto devices the scan has established are there, and
            // this path already broke once by running in the other order.
            rescanTargets()
            // And before the audit for the same reason the rescan is: a group
            // that works its devices out has to name this one before anything
            // can be owed to it.
            resolveAutomaticDestinations()
            let queued = auditPlacement()
            if queued > 0 {
                audit(
                    .drive,
                    "\(target.name) took \(Formatters.count(queued, "copy", "copies")) the archive was short.",
                    targetID: targetID
                )
            }
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
            var what = ["\(Formatters.count(repaired, "replica"))"]
            if repairedArchives > 0 { what.append("\(Formatters.count(repairedArchives, "export archive"))") }
            audit(.replication, "\(target.name): content had moved; repointed \(what.joined(separator: " and ")) to their new location. Nothing was copied.", targetID: targetID)
        }
        if unresolved > 0 {
            audit(.violation, "\(target.name): \(Formatters.count(unresolved, "replica")) are not where the catalog recorded them and were not found on the target.", targetID: targetID)
        }
        if repaired > 0 || unresolved > 0 || repairedArchives > 0 { loadAll() }
        return (repaired, unresolved)
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
    /// The move is a rename within one volume: instant, and it moves no bytes.
    /// Nothing is moved out of a directory the user chose — the only files
    /// this relocates are ones the app put where it did because it had no
    /// better idea, and the catalog is repointed in the same pass so no copy
    /// is ever lost track of.
    ///
    /// The destination usually already has a catalog row, and that is the
    /// normal case rather than an error: the part was delivered precisely
    /// *because* the copy that used to sit there was deleted, and the row for
    /// that copy outlived it. One path is one row — the archive path is
    /// unique — so the delivered copy moves *into* that row rather than beside
    /// it, and the row it came from goes away. It is not a lost copy; it is a
    /// copy this method itself moved.
    @discardableResult
    func rehomeDeliveredParts(for targetID: UUID) -> Int {
        guard let target = targetsByID[targetID], let mountURL = reachablePaths[targetID] else {
            return 0
        }
        guard !isBusy(targetID), !isQuiescing(targetID), !isTransferringParts else { return 0 }

        let targetName = target.name
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
                "\(targetName): moved \(Formatters.count(moved, "delivered export part")) (e.g. \(example ?? "one")) in beside the rest of their export, where this drive already keeps it. A rename within the drive; no bytes moved.",
                targetID: targetID
            )
            loadAll()
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
            "Stopped treating \(Formatters.count(containers.count, "folder")) as exports of their own (e.g. \(containers[0].0.displayName)): each one holds other exports rather than being one. Nothing on disk was touched, and the exports inside them are unaffected."
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
                "\(target.name): \(Formatters.count(vanished.count, "export archive")) the catalog recorded are no longer on the drive (e.g. \(vanished[0].displayName)). They no longer count as copies of their parts.",
                targetID: targetID
            )
        }
        if !returned.isEmpty {
            audit(
                .drive,
                "\(target.name): \(Formatters.count(returned.count, "export archive")) previously recorded as gone are back where the catalog expects them.",
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
                "\(target.name): \(Formatters.count(absent.count, "copy", "copies")) the catalog recorded are not on the drive (e.g. \(absentExample ?? "a file the catalog expected")), and were not found anywhere else on it. They no longer count towards the redundancy policy.",
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
                    "\(target.name): recorded the size and date of \(Formatters.count(baselines, "file")) across \(Formatters.count(subjects.count, "file")) on disk. Nothing was compared — there was nothing yet to compare against.",
                    targetID: targetID
                )
            }
            loadAll()
            return (subjects.count, 0, baselines, absent.count)
        }

        audit(
            .drive,
            "\(target.name): \(Formatters.count(changedAssetIDs.count, "file")) changed since the app last looked (e.g. \(firstReason ?? "size or date moved")). Reading them back to find out whether the content is still right.",
            targetID: targetID
        )
        loadAll()
        queueVerificationSweep(targetID, budget: .unlimited, restrictedTo: changedAssetIDs)
        return (subjects.count, changedAssetIDs.count, baselines, absent.count)
    }

    /// Assets not yet on all the drives their group is kept on.
    ///
    /// This is what replaced the cross-target tree comparison. That compared
    /// one device's recorded content against another's and called a difference
    /// divergence — a useful signal only while every device was supposed to
    /// hold everything. Devices now hold what their sources put there, so the
    /// question worth asking is not "do these two match" but "is this photo on
    /// the devices its source named", and that is answerable exactly from the
    /// replica rows with no tree, no false positives, and no disk access.
    func placementShortfall() -> [PlacementPlanner.Placement] {
        let localAssets = assets.filter { $0.residency == .local }
        guard !localAssets.isEmpty, !targets.isEmpty else { return [] }

        var holders: [UUID: Set<UUID>] = [:]
        var sizes: [UUID: Int64] = [:]
        for asset in localAssets {
            // Pending and in-flight count as held, so running the audit twice
            // does not queue the same copy twice.
            holders[asset.id] = Set(
                (replicasByAssetID[asset.id] ?? [])
                    .filter { $0.state == .present || $0.state == .pending || $0.state == .copying }
                    .map(\.targetID)
            )
            sizes[asset.id] = asset.fileSize
        }

        var result: [PlacementPlanner.Placement] = []
        for group in groupedByPolicy(localAssets.map(\.id)) {
            // Only assets actually short of one of their named devices.
            let short = group.assetIDs.filter { assetID in
                let held = holders[assetID] ?? []
                return held.filter(group.destinations.contains).count < group.copies
            }
            guard !short.isEmpty else { continue }
            result += PlacementPlanner.plan(
                assets: short.map { (id: $0, sizeBytes: sizes[$0] ?? 0) },
                existingHolders: holders,
                destinations: group.destinations,
                desiredCopies: group.copies,
                candidates: placementCandidates
            )
            .filter { !$0.destinations.isEmpty }
        }
        return result
    }

    /// Places and queues the copies the archive is short.
    ///
    /// Counts pending and in-flight copies as holders, so running it twice does
    /// not queue the same copy twice — the audit is meant to be safe to run on
    /// every connect and every launch.
    @discardableResult
    func auditPlacement() -> Int {
        // Before planning what is short: a device the user has just taken off a
        // source is not short of anything, and the rows saying otherwise would
        // otherwise sit there for good.
        withdrawUnnamedPlacements()

        let plans = placementShortfall()
        guard !plans.isEmpty else { return 0 }

        var queued = 0
        do {
            for plan in plans {
                for targetID in plan.destinations {
                    try enqueueTask(assetID: plan.assetID, targetID: targetID, action: .copy)
                    try catalog.upsertReplicaState(TargetReplicaState(
                        assetID: plan.assetID, targetID: targetID,
                        state: .pending, relativePath: nil, lastVerifiedAt: nil
                    ))
                    queued += 1
                }
            }
        } catch {
            lastError = "Could not queue the copies your archive is short: \(error.localizedDescription)"
            return queued
        }

        if queued > 0 {
            audit(
                .replication,
                "Queued \(Formatters.count(queued, "copy", "copies")) so \(Formatters.count(plans.count, "photo")) reach the drives they are meant to be on."
            )
            loadAll()
        }
        return queued
    }

    /// Re-works-out the devices of every group that is not choosing its own.
    ///
    /// Cheap and idempotent, so it runs after anything that changes the set of
    /// registered devices rather than being remembered about at each call site.
    /// Writes only where the answer actually moved, so an ordinary launch does
    /// no work and logs nothing.
    ///
    /// **Only external drives are eligible.** The host is the machine the
    /// drives exist to survive, so it is never somewhere a group is merely
    /// spread onto — counting it would let "2 copies" be satisfied by this Mac
    /// plus one drive and report that as safe. Naming it stays possible, but
    /// only as a `.chosen` device, which is a deliberate act.
    /// The devices a worked-out group draws from, in the order it draws them.
    var automaticEligibleDeviceIDs: [UUID] {
        targets
            .filter { $0.kind == .externalVolume }
            .sorted { $0.registeredAt < $1.registeredAt }
            .map(\.id)
    }

    @discardableResult
    func resolveAutomaticDestinations() -> Int {
        let eligible = automaticEligibleDeviceIDs
        var changed = 0
        for group in storageGroups where group.destinationMode == .automatic {
            let resolved = StorageGroup.automaticDestinations(
                copies: group.desiredCopies, among: eligible
            )
            guard resolved != group.destinationTargetIDs else { continue }
            var updated = group
            updated.destinationTargetIDs = resolved
            do { try catalog.upsertStorageGroup(updated) } catch {
                lastError = "Could not work out where \(group.label) is kept: \(error.localizedDescription)"
                continue
            }
            changed += 1
        }
        if changed > 0 { loadAll() }
        return changed
    }

    /// The devices a group would gain if it were allowed to use every drive.
    ///
    /// Drives a worked-out group is not using because it already has as many
    /// copies as it asked for. This is what lets the UI offer — "you have three
    /// drives and keep two copies" — instead of either guessing or saying
    /// nothing, which is what happens today.
    func idleDeviceCount(forStorageGroup group: StorageGroup) -> Int {
        guard group.destinationMode == .automatic else { return 0 }
        let externals = targets.filter { $0.kind == .externalVolume }.count
        return max(0, externals - group.destinationTargetIDs.count)
    }

    /// Leftover rows that may be withdrawn when no group names the device.
    ///
    /// Both of these assert the device holds nothing, which is the whole reason
    /// they are safe to drop: withdrawing them forgets an expectation, never a
    /// file. `present` and `drift` are excluded for the same reason inverted —
    /// a file really is on that disk, and forgetting the row would lose track
    /// of a copy that exists. `copying` and `stale` are mid-flight and left to
    /// finish or fail on their own.
    ///
    /// `missing` is here because gating on `pending` alone left a hole a real
    /// archive fell into. Withdrawal was written for placements the user
    /// revokes, and revoked copies start out `pending` — but a scan that runs
    /// first looks where the row claims, finds nothing, and marks it `missing`.
    /// From there withdrawal could never see it again, so twelve rows sat
    /// reading as absent files on a device that had correctly been told to hold
    /// nothing. What makes a row withdrawable is that nobody asked for it; the
    /// state it happens to be sitting in is incidental.
    static let withdrawableStates: Set<ReplicaFileState> = [.pending, .missing]

    /// Withdraws intentions to copy onto devices no group names.
    ///
    /// A `pending` replica row is not a copy — it is an intention, and an
    /// intention to put a photo on a device the user has since taken off its
    /// source is simply wrong. Nothing removed them: `applySourceSettings`
    /// queues the new copies and `releaseDepartedDevices` handles copies that
    /// actually exist, gated on proof, but a copy that was never made has
    /// nothing to prove and no reason to wait.
    ///
    /// `applyArchiveLevelRedundancy` opens the same gap from the other side. It
    /// withdraws the queued *task* for every asset an export part covers, on
    /// every device, but only rewrites the pending *rows* on devices that hold
    /// the part — so a device holding no part keeps rows whose tasks are gone,
    /// and reports work waiting that nothing will ever perform.
    ///
    /// Deliberately narrow: only rows asserting the device holds nothing, and
    /// only where the device is not named. A `present` row is bytes on a disk
    /// and is `releaseDepartedDevices`'s business; `copying` is in flight and
    /// belongs to the sync that started it. See `withdrawableStates`.
    @discardableResult
    func withdrawUnnamedPlacements() -> Int {
        var staleReplicas: [(assetID: UUID, targetID: UUID)] = []
        for replica in replicaStates where Self.withdrawableStates.contains(replica.state) {
            let named = Set(placementPolicy(forAsset: replica.assetID).destinations)
            guard !named.contains(replica.targetID) else { continue }
            staleReplicas.append((replica.assetID, replica.targetID))
        }
        let staleKeys = Set(staleReplicas.map { "\($0.assetID)|\($0.targetID)" })
        let staleTasks = replicationTasks.filter {
            $0.state == .queued && $0.action == .copy
                && staleKeys.contains("\($0.assetID)|\($0.targetID)")
        }
        guard !staleReplicas.isEmpty || !staleTasks.isEmpty else { return 0 }

        do {
            try catalog.transaction {
                for stale in staleReplicas {
                    try catalog.deleteReplicaState(assetID: stale.assetID, targetID: stale.targetID)
                }
                for task in staleTasks {
                    try catalog.deleteReplicationTask(id: task.id)
                }
            }
        } catch {
            lastError = "Could not withdraw copies to devices no longer in use: \(error.localizedDescription)"
            return 0
        }

        let devices = Set(staleReplicas.map(\.targetID))
            .compactMap { targetsByID[$0]?.name }
            .sorted()
        audit(
            .replication,
            "Withdrew \(Formatters.count(staleReplicas.count, "queued copy", "queued copies")) to \(devices.isEmpty ? "devices no group uses" : devices.joined(separator: " and ")) — no group keeps its photos there any more, so nothing was waiting to be done. Nothing was deleted from any device."
        )
        loadAll()
        return staleReplicas.count
    }

    /// How far the archive is from what its sources ask for: how many photos
    /// are short, and how many copies that adds up to.
    ///
    /// Counts pending and in-flight copies as held, so a sync in progress reads
    /// as on its way rather than as a shortfall — the number is meant to say
    /// "this needs a decision", not "this is busy".
    var placementShortfallSummary: (assetsShort: Int, copiesShort: Int) {
        var assetsShort = 0
        var copiesShort = 0
        for asset in assets where asset.residency == .local {
            let policy = placementPolicy(forAsset: asset.id)
            // Only copies on the devices the source actually named count.
            // Counting any copy anywhere would report a photo as satisfied
            // because it happens to sit on a drive nobody asked it to be on.
            let held = (replicasByAssetID[asset.id] ?? [])
                .filter {
                    ($0.state == .present || $0.state == .pending || $0.state == .copying)
                        && policy.destinations.contains($0.targetID)
                }
                .count
            let missing = policy.copies - held
            if missing > 0 {
                assetsShort += 1
                copiesShort += missing
            }
        }
        return (assetsShort, copiesShort)
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
        // Oldest first, except that content whose every copy is a file the user
        // manages goes to the front. Such an asset is one tidy-up away from
        // having no copy at all — the app will never delete an adopted file,
        // and cannot get it back either — so the copy that makes it
        // independent is the most valuable work in the queue.
        let queued = replicationTasks
            .filter { $0.targetID == targetID && $0.state == .queued }
            .sorted { lhs, rhs in
                let left = hasOnlyArchiveBackedCopies(lhs.assetID)
                let right = hasOnlyArchiveBackedCopies(rhs.assetID)
                if left != right { return left }
                return lhs.queuedAt < rhs.queuedAt
            }
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
            var summary = "Sync with \(drive.name): \(Formatters.count(completed, "task")) completed, \(failed) failed"
            if let reason = interruptionReason {
                summary += "; \(reason) with \(Formatters.count(remaining, "task")) still queued"
            }
            audit(.replication, summary + ".", targetID: targetID)
            syncProgress = nil
            loadAll()
            // A sync is the only thing that turns a queued copy into a proven
            // one, so it is the only moment a pending retarget can become
            // safe to finish. Checked here rather than on a timer: the
            // precondition changed exactly now.
            for source in sources { releaseDepartedDevices(for: source.id) }
            // Removals prune as they go, but a sync that removed files is also
            // the moment buckets left by earlier versions — and by migration
            // cleanup, which never pruned — become worth sweeping. Bounded by
            // the bucket count, not the file count.
            if let mount = reachablePaths[targetID], let drive = targetsByID[targetID] {
                let pruned = ReplicationService.pruneEmptyBuckets(drive: drive, mountURL: mount)
                if pruned > 0 {
                    audit(
                        .replication,
                        "Removed \(Formatters.count(pruned, "empty folder")) left behind on \(drive.name) where copies used to be. No files were touched.",
                        targetID: targetID
                    )
                }
            }
            // After the reload, so the verdicts this reads are the ones the
            // sync just established rather than the ones it started with.
            reclaimStaging()
            // Then hold, for any target that is not here, what this one could
            // give it. Runs after the release so it does not re-stage what was
            // just let go, and after the sync so it is not competing with it
            // for the same disk.
            await relayForAbsentTargets(from: targetID)
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
        let readable: (ReplicaFileState) -> Bool = {
            $0 == .present || $0 == .stale || $0 == .drift
        }
        let eligible = replicaStates.filter {
            $0.targetID == targetID
                && readable($0.state)
                && !alreadyQueued.contains($0.assetID)
                && (assetIDs?.contains($0.assetID) ?? true)
        }

        // Every readable copy of those assets, on every device — not just this
        // one. An asset's risk cannot be judged from the device being
        // patrolled: a copy here that was read a year ago is harmless if the
        // copy on the other drive was read yesterday, and that is exactly the
        // file the old "oldest replica first" rule would have gone for.
        let subjects = Set(eligible.map(\.assetID))
        var siblings: [UUID: [PatrolScheduler.Replica]] = [:]
        for replica in replicaStates
        where subjects.contains(replica.assetID) && readable(replica.state) {
            siblings[replica.assetID, default: []].append(PatrolScheduler.Replica(
                assetID: replica.assetID,
                targetID: replica.targetID,
                sizeBytes: assetsByID[replica.assetID]?.fileSize ?? 0,
                lastVerifiedAt: replica.lastVerifiedAt
            ))
        }

        let selection = PatrolScheduler.next(
            on: targetID,
            candidates: eligible.map { replica in
                PatrolScheduler.Replica(
                    assetID: replica.assetID,
                    targetID: replica.targetID,
                    sizeBytes: assetsByID[replica.assetID]?.fileSize ?? 0,
                    lastVerifiedAt: replica.lastVerifiedAt
                )
            },
            allReplicasByAsset: siblings,
            budget: budget
        )

        var queued = 0
        var bytes: Int64 = 0
        do {
            try catalog.transaction {
                for replica in selection {
                    try enqueueTask(assetID: replica.assetID, targetID: targetID, action: .verify)
                    queued += 1
                    bytes += replica.sizeBytes
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
            let remaining = eligible.count - queued
            audit(
                .drive,
                isPatrol
                    // Says what it aimed at, because the aim is the design.
                    // "Least recently checked" described the old rule and would
                    // now be a lie: these are the photos with no recently-read
                    // copy anywhere, which is a different and better set.
                    ? "Background check on \(drive.name): reading \(Formatters.count(queued, "file")) (~\(Formatters.bytes.string(fromByteCount: bytes))) — the photos no copy of which has been read back recently; \(remaining) still to come."
                    : "Queued a file check of \(Formatters.count(queued, "file")) (~\(Formatters.bytes.string(fromByteCount: bytes))) on \(drive.name)"
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
        audit(.system, "Apple Photos index: \(Formatters.count(items.count, "item")) in the library — \(added) added as \(label), \(linked) linked to photos the archive already holds.")
        lastApplePhotosCheckSummary = "\(added.formatted()) added · \(linked.formatted()) linked"
        isIndexingApplePhotos = false
        loadAll()
    }

    /// What reclamation would release if it existed, computed from evidence the
    /// app already holds. Nothing acts on this: it removes nothing, and it is
    /// here so the preconditions are visible rather than only written down.
    var reclamationPlan: ReclamationPlanner.Plan {
        ReclamationPlanner.plan(
            assets: assets,
            replicasByAssetID: replicasByAssetID,
            registeredTargetIDs: Set(targets.map(\.id)),
            desiredCopies: { [self] in desiredCopies(forAsset: $0) }
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
        if pairedCount > 0 { parts.append("\(Formatters.count(pairedCount, "Live Photo motion half", "Live Photo motion halves")) kept with their still") }
        if failures > 0 { parts.append("\(Formatters.count(failures, "original")) could not be exported") }
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

    /// Content the archive has just taken on owes `desiredCopies` copies, on
    /// the devices placement picks — the same path any other Local asset takes.
    ///
    /// Devices already holding it are excluded, so re-running this is harmless
    /// and a re-import never queues a copy of something already on the disk.
    private func queueReplicationOfNewlyHeld(_ assetID: UUID) throws {
        let held = Set(
            (replicasByAssetID[assetID] ?? [])
                .filter { $0.state == .present }
                .map(\.targetID)
        )
        let size = assetsByID[assetID]?.fileSize ?? 0
        let policy = placementPolicy(forAsset: assetID)
        let plans = PlacementPlanner.plan(
            assets: [(id: assetID, sizeBytes: size)],
            existingHolders: [assetID: held],
            destinations: policy.destinations,
            desiredCopies: policy.copies,
            candidates: placementCandidates
        )
        for targetID in plans.first?.destinations ?? [] {
            try enqueueTask(assetID: assetID, targetID: targetID, action: .copy)
            try catalog.upsertReplicaState(TargetReplicaState(
                assetID: assetID, targetID: targetID,
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
            line += " — recorded as verified presence; the Local coexistence is listed under Keep safe until migrated or reclaimed"
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
            audit(.policy, "Re-applied rules: \(Formatters.count(sourceUpdates, "asset")) changed between rule-assigned and default.")
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
                audit(.policy, "Policy rules queued \(Formatters.count(remaining.count, "asset")) for migration to \(domain.displayName) (pending).")
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
            audit(.migration, "Created migration \(source.displayName) → \(target.displayName) for \(Formatters.count(assetIDs.count, "asset")).")
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
