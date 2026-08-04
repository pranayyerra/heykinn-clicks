import XCTest
@testable import HeykinnClicks

/// The orchestration `AppStore` performs — when a sync starts, what happens to
/// content that moved, what the policy is allowed to ask for, and what an
/// original pulled out of the Photos library becomes.
///
/// None of this could be tested before: the store's only initialiser opened the
/// user's real catalog, so every one of these behaviours was verified by
/// running the app by hand and reading the audit log.
@MainActor
final class AppStoreOrchestrationTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []
        suiteNames = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    /// A store over a throwaway archive: its own catalog, its own staging, its
    /// own preferences, and none of the background work that would otherwise
    /// scan the machine's real volumes.
    private func makeStore(
        preferences: [String: Any] = [:]
    ) throws -> (store: AppStore, directory: URL) {
        let directory = try makeDirectory("store")
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        for (key, value) in preferences { defaults.set(value, forKey: key) }

        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory, defaults: defaults, runsBackgroundWork: false
        ))
        return (store, directory)
    }

    /// A second connection onto the same catalog, for seeding rows the way an
    /// earlier session would have left them.
    private func catalog(at directory: URL) throws -> CatalogStore {
        try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func makeAsset(
        hash: String,
        filename: String = "photo.jpg",
        kind: AssetKind = .photo,
        captureDate: Date? = Date(timeIntervalSince1970: 1_600_000_000),
        size: Int64 = 5,
        stagingRelativePath: String? = nil,
        providerLocalID: String? = nil
    ) -> Asset {
        Asset(
            id: UUID(),
            kind: kind,
            originalFilename: filename,
            importOrigin: .localFolder,
            captureDate: captureDate,
            importDate: Date(),
            updatedDate: Date(),
            fileSize: size,
            pixelWidth: 100,
            pixelHeight: 100,
            contentHash: hash,
            residency: .local,
            residencySource: .importDefault,
            presence: DomainPresence(local: true, appleCloud: false, googleCloud: false),
            stagingRelativePath: stagingRelativePath,
            importBatchID: nil,
            exifSummary: [:],
            providerLocalID: providerLocalID
        )
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 15,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Policy clamping

    /// A policy asking for more copies than there are targets can never be met,
    /// and reports a healthy archive as unsafe. It is bound to what exists.
    func testPolicyIsClampedToTheNumberOfRegisteredTargets() throws {
        let (store, _) = try makeStore(preferences: ["desiredCopies": 3])

        XCTAssertEqual(
            store.redundancyPolicy.desiredCopies, 1,
            "With no targets registered, three copies is a promise the app cannot keep"
        )
    }

    /// The ceiling is the target count, so registering one raises it — the
    /// clamp must not be a one-way ratchet down.
    func testRegisteringATargetRaisesTheCeiling() throws {
        let (store, _) = try makeStore(preferences: ["desiredCopies": 3])
        let mount = try makeDirectory("target")

        store.registerHostDeviceTarget(at: mount, name: "Test target")

        XCTAssertEqual(store.targets.count, 1, store.lastError ?? "")
        XCTAssertEqual(store.maxSettableCopies, 1)

        let second = try makeDirectory("target-2")
        store.registerHostDeviceTarget(at: second, name: "Second")
        // Both folders are on this Mac's own disk, and one device holds one
        // copy — so the second is refused and the ceiling does not move.
        XCTAssertEqual(store.targets.count, 1)
        XCTAssertEqual(store.maxSettableCopies, 1)
    }

    // MARK: - Sync trigger

    /// The trigger belongs on the work existing, not on the moment a target
    /// appeared: content imported while a drive is already plugged in must not
    /// wait for an unplug and replug.
    func testWorkAppearingOnAnAlreadyConnectedTargetStartsASync() async throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Always plugged in")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        XCTAssertNotNil(store.reachablePaths[targetID], "The folder target should resolve by its marker")
        XCTAssertFalse(store.isSyncing, "Nothing to do yet")

        // Content arrives while the target is already connected.
        let source = try makeDirectory("source")
        try Data("bytes".utf8).write(to: source.appendingPathComponent("photo.jpg"))
        store.importFolders([source])
        try await waitUntil("the import to finish") { !store.isImporting && store.assets.count == 1 }

        XCTAssertEqual(store.backlogCount(for: targetID), 1, "The new photo owes this target a copy")
        store.startDueSyncsIfIdle()
        XCTAssertTrue(store.isSyncing, "Queued work on a connected target must start on its own")

        try await waitUntil("the sync to drain") { !store.isSyncing }
        let replica = try XCTUnwrap(store.replicaStates.first { $0.targetID == targetID })
        XCTAssertEqual(replica.state, .present)
        XCTAssertEqual(store.backlogCount(for: targetID), 0)
    }

    /// Syncing is not the app's only job. A sync that starts on top of an
    /// import competes with it for the same disk.
    func testNoSyncStartsWhileAnImportIsRunning() throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")

        store.isImporting = true
        store.startDueSyncsIfIdle()
        XCTAssertFalse(store.isSyncing)
    }

    // MARK: - Replica path repair

    /// A folder the user renamed on the target invalidates every path recorded
    /// beneath it. The content is still there, so it is repointed — copying it
    /// again would write a second copy of what the target already holds.
    func testMovedContentIsRepointedRatherThanRecopied() async throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)

        // A replica the catalog records under one folder, sitting under another:
        // the ancestor was renamed and everything beneath it came along.
        try FileManager.default.createDirectory(
            at: mount.appendingPathComponent("Owner/Backup_2024/takeout-001/Google Photos"),
            withIntermediateDirectories: true
        )
        try Data("bytes".utf8).write(
            to: mount.appendingPathComponent("Owner/Backup_2024/takeout-001/Google Photos/a.jpg")
        )
        let asset = makeAsset(hash: "hash-a", filename: "a.jpg")
        let seed = try catalog(at: directory)
        try seed.upsertAsset(asset)
        try seed.upsertReplicaState(TargetReplicaState(
            assetID: asset.id, targetID: targetID, state: .present,
            relativePath: "volume:Owner/Backup/takeout-001/Google Photos/a.jpg",
            lastVerifiedAt: Date()
        ))
        store.loadAll()

        let outcome = store.repairReplicaPaths(for: targetID)

        XCTAssertEqual(outcome.repaired, 1)
        XCTAssertEqual(outcome.unresolved, 0)
        let replica = try XCTUnwrap(store.replicaStates.first { $0.assetID == asset.id })
        XCTAssertEqual(
            replica.relativePath,
            "volume:Owner/Backup_2024/takeout-001/Google Photos/a.jpg"
        )
        XCTAssertEqual(replica.state, .present, "Repointing is not a loss of the copy")
        XCTAssertEqual(
            store.replicationTasks.filter { $0.action == .copy && $0.state == .queued }.count, 0,
            "Content that merely moved must never be queued for copying again"
        )
    }

    /// A path that resolves nowhere is not quietly left counted. A copy the app
    /// cannot find is not a copy.
    func testAReplicaThatIsGoneIsRecordedMissingRatherThanCounted() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)

        // One replica really moved, one is simply gone — so there is a rename
        // to plan from, and the missing file cannot ride along on it.
        try FileManager.default.createDirectory(
            at: mount.appendingPathComponent("Owner/Backup_2024/takeout-001/Google Photos"),
            withIntermediateDirectories: true
        )
        try Data("bytes".utf8).write(
            to: mount.appendingPathComponent("Owner/Backup_2024/takeout-001/Google Photos/a.jpg")
        )

        let moved = makeAsset(hash: "hash-a", filename: "a.jpg")
        let vanished = makeAsset(hash: "hash-b", filename: "b.jpg")
        let seed = try catalog(at: directory)
        for (asset, path) in [
            (moved, "volume:Owner/Backup/takeout-001/Google Photos/a.jpg"),
            (vanished, "volume:Owner/Backup/takeout-001/Google Photos/b.jpg"),
        ] {
            try seed.upsertAsset(asset)
            try seed.upsertReplicaState(TargetReplicaState(
                assetID: asset.id, targetID: targetID, state: .present,
                relativePath: path, lastVerifiedAt: Date()
            ))
        }
        store.loadAll()

        let outcome = store.repairReplicaPaths(for: targetID)

        XCTAssertEqual(outcome.repaired, 1)
        XCTAssertEqual(outcome.unresolved, 1)
        let gone = try XCTUnwrap(store.replicaStates.first { $0.assetID == vanished.id })
        XCTAssertEqual(gone.state, .missing)
    }

    // MARK: - Size/mtime gate

    /// The whole loop: a file rewritten in place while the target was away is
    /// noticed on connect, read back, and found to have drifted. Nothing else
    /// in the system can see this — the recorded hash did not change, so the
    /// trees still agree, and the directory is still there.
    func testAFileEditedInPlaceIsCaughtOnConnectAndReadBack() async throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)

        let bytes = Data("original bytes".utf8)
        let file = mount.appendingPathComponent("Archive/a.jpg")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bytes.write(to: file)
        let asset = makeAsset(
            hash: try HashingService.sha256(of: file), filename: "a.jpg", size: Int64(bytes.count)
        )
        let seed = try catalog(at: directory)
        try seed.upsertAsset(asset)
        try seed.upsertReplicaState(TargetReplicaState(
            assetID: asset.id, targetID: targetID, state: .present,
            relativePath: "volume:Archive/a.jpg", lastVerifiedAt: Date()
        ))
        store.loadAll()

        // First look: nothing had been recorded, so a baseline is written and
        // nothing is claimed about the bytes.
        let first = store.checkReplicaStats(for: targetID)
        XCTAssertEqual(first.files, 1)
        XCTAssertEqual(first.changed, 0)
        XCTAssertEqual(first.baselines, 1)
        XCTAssertEqual(
            store.replicationTasks.filter { $0.action == .verify }.count, 0,
            "A first look reads nothing: there was nothing to compare against"
        )

        // The file is rewritten under an intact path while nothing is watching.
        try Data("tampered with, and a different length".utf8).write(to: file)

        let second = store.checkReplicaStats(for: targetID)
        XCTAssertEqual(second.changed, 1)

        try await waitUntil("the aimed read to finish") { !store.isSyncing }
        let replica = try XCTUnwrap(store.replicaStates.first { $0.assetID == asset.id })
        XCTAssertEqual(replica.state, .drift, "Reading it back is what makes the claim")

        // Re-baselined, so the same change is not re-reported forever.
        let third = store.checkReplicaStats(for: targetID)
        XCTAssertEqual(third.changed, 0)
    }

    /// A change the app has noticed but not yet read must survive a quit. If
    /// the gate re-baselined on sight, an app closed before the queue drained
    /// would come back believing the file had never moved.
    func testAChangeSurvivesAQuitBeforeTheReadHappens() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)

        let file = mount.appendingPathComponent("Archive/a.jpg")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("bytes".utf8).write(to: file)
        let asset = makeAsset(hash: "hash-a", filename: "a.jpg")
        let seed = try catalog(at: directory)
        try seed.upsertAsset(asset)
        try seed.upsertReplicaState(TargetReplicaState(
            assetID: asset.id, targetID: targetID, state: .present,
            relativePath: "volume:Archive/a.jpg", lastVerifiedAt: Date()
        ))
        store.loadAll()
        store.checkReplicaStats(for: targetID)
        XCTAssertEqual(
            store.replicaStates.first { $0.assetID == asset.id }?.observedSize, 5,
            "The first look records what the file is"
        )

        try Data("edited in place, and longer".utf8).write(to: file)
        XCTAssertEqual(store.checkReplicaStats(for: targetID).changed, 1)

        XCTAssertEqual(
            store.replicaStates.first { $0.assetID == asset.id }?.observedSize, 5,
            "The baseline stays until a read settles it: seeing a change is not checking it"
        )
        XCTAssertEqual(store.replicationTasks.filter { $0.action == .verify }.count, 1)
    }

    /// A target whose files are all where the app left them costs a handful of
    /// stats and queues no reads at all.
    func testAnUntouchedTargetQueuesNoReads() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)

        let file = mount.appendingPathComponent("Archive/a.jpg")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("bytes".utf8).write(to: file)
        let asset = makeAsset(hash: "hash-a", filename: "a.jpg")
        let seed = try catalog(at: directory)
        try seed.upsertAsset(asset)
        try seed.upsertReplicaState(TargetReplicaState(
            assetID: asset.id, targetID: targetID, state: .present,
            relativePath: "volume:Archive/a.jpg", lastVerifiedAt: Date()
        ))
        store.loadAll()

        store.checkReplicaStats(for: targetID)
        let outcome = store.checkReplicaStats(for: targetID)

        XCTAssertEqual(outcome.changed, 0)
        XCTAssertEqual(outcome.baselines, 0, "The baseline was already written")
        XCTAssertEqual(store.replicationTasks.filter { $0.action == .verify }.count, 0)
    }

    // MARK: - Apple Photos: index

    private func libraryItem(
        id: String = "PHOTO-1/L0/001",
        filename: String = "IMG_0001.HEIC",
        captureDate: Date? = Date(timeIntervalSince1970: 1_600_000_000),
        kind: AssetKind = .photo,
        width: Int = 100,
        height: Int = 100
    ) -> ApplePhotosVerifier.LibraryItem {
        ApplePhotosVerifier.LibraryItem(
            localIdentifier: id, filename: filename, captureDate: captureDate,
            pixelWidth: width, pixelHeight: height, kind: kind, isMotionHalf: false
        )
    }

    /// The same photograph in two encodings is one picture: a library item that
    /// matches an asset already held becomes a link on it, not a second row.
    func testALibraryItemMatchingAHeldPhotoIsLinkedRatherThanAdded() throws {
        let (store, directory) = try makeStore()
        let held = makeAsset(hash: "held-hash", filename: "IMG_0001.HEIC")
        try catalog(at: directory).upsertAsset(held)
        store.loadAll()

        store.mergeLibraryIndex([libraryItem()])

        XCTAssertEqual(store.assets.count, 1, "One photograph, one row")
        XCTAssertEqual(store.assets.first?.id, held.id)
        XCTAssertEqual(store.assets.first?.providerLocalID, "PHOTO-1/L0/001")
        XCTAssertEqual(
            store.assets.first?.contentHash, "held-hash",
            "A link is not a claim about bytes; the held hash must stand"
        )
    }

    /// A photo the archive has never seen becomes a row of its own, carrying
    /// the provider's identifier so re-indexing updates it rather than
    /// duplicating it.
    func testAnUnknownLibraryItemIsAddedOnceAcrossRepeatedIndexing() throws {
        let (store, _) = try makeStore()

        store.mergeLibraryIndex([libraryItem()])
        store.mergeLibraryIndex([libraryItem()])

        XCTAssertEqual(store.assets.count, 1)
        let indexed = try XCTUnwrap(store.assets.first)
        XCTAssertEqual(indexed.providerLocalID, "PHOTO-1/L0/001")
        XCTAssertTrue(
            indexed.isIndexedOnly,
            "Nothing read the bytes, so nothing may look like a content hash"
        )
        XCTAssertEqual(store.applePhotosAwaitingImport.count, 1)
    }

    /// "The archive does not hold this" is drawn on the content hash, never on
    /// the absence of a staged copy: a Takeout asset living only on a drive has
    /// no staging path either, and the archive holds that one.
    func testContentHeldOnlyOnADriveIsNotMistakenForSomethingTheArchiveLacks() throws {
        let (store, directory) = try makeStore()
        let onDriveOnly = makeAsset(
            hash: "a-real-hash", stagingRelativePath: nil, providerLocalID: "PHOTO-1/L0/001"
        )
        try catalog(at: directory).upsertAsset(onDriveOnly)
        store.loadAll()

        XCTAssertFalse(try XCTUnwrap(store.assets.first).isIndexedOnly)
        XCTAssertEqual(store.applePhotosAwaitingImport.count, 0)
    }

    /// With iCloud Photos off, the library is this Mac's — recording its
    /// contents as cloud presence would be a claim nobody checked.
    func testAnUnsyncedLibraryIsRecordedLocalWithNoCloudEvidence() throws {
        let (store, _) = try makeStore()
        store.iCloudPhotosEnabled = false

        store.mergeLibraryIndex([libraryItem()])

        let indexed = try XCTUnwrap(store.assets.first)
        XCTAssertEqual(indexed.residency, .local)
        XCTAssertFalse(indexed.presence.appleCloud)
        XCTAssertEqual(indexed.cloudPresenceEvidence, .none)
    }

    // MARK: - Apple Photos: bringing originals in

    /// Writes files the fake exporter will hand back, and returns their hashes.
    private func makeExport(
        _ store: AppStore, still: String, motion: String? = nil
    ) throws -> (still: String, motion: String?) {
        let scratch = try makeDirectory("export")
        let stillURL = scratch.appendingPathComponent("IMG_0001.HEIC")
        try Data(still.utf8).write(to: stillURL)
        var motionURL: URL?
        if let motion {
            let url = scratch.appendingPathComponent("IMG_0001.MOV")
            try Data(motion.utf8).write(to: url)
            motionURL = url
        }
        store.exportOriginalFromPhotos = { _, directory in
            // The real exporter writes into the directory it is given; copy so
            // the fixture survives the caller deleting what it exported.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            func place(_ source: URL) throws -> URL {
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            }
            return ApplePhotosVerifier.ExportedOriginal(
                still: try place(stillURL), motion: try motionURL.map(place)
            )
        }
        return (try HashingService.sha256(of: stillURL), try motionURL.map { try HashingService.sha256(of: $0) })
    }

    /// New content is staged, gains a real content hash, and owes every target
    /// a copy — the same path any other Local asset takes.
    func testAnOriginalTheArchiveDoesNotHoldIsStagedAndQueued() async throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        store.mergeLibraryIndex([libraryItem()])
        let hashes = try makeExport(store, still: "original bytes")

        store.importOriginalsFromApplePhotos()
        try await waitUntil("the Photos import to finish") { !store.isImportingFromApplePhotos }

        XCTAssertEqual(store.assets.count, 1)
        let imported = try XCTUnwrap(store.assets.first)
        XCTAssertEqual(imported.contentHash, hashes.still)
        XCTAssertNotNil(imported.stagingRelativePath)
        XCTAssertTrue(store.staging.exists(relativePath: imported.stagingRelativePath))
        XCTAssertTrue(imported.presence.local)
        XCTAssertEqual(store.applePhotosAwaitingImport.count, 0)
        XCTAssertEqual(store.backlogCount(for: targetID), 1, "Held bytes owe the target a copy")
    }

    /// If the exported original hashes to something already held, this was the
    /// same file all along: one row survives, and it gains the provider link.
    func testAnOriginalTheArchiveAlreadyHoldsIsMergedRatherThanStoredTwice() async throws {
        let (store, directory) = try makeStore()
        let hashes = try makeExport(store, still: "original bytes")
        // Held already, and far enough from the library item in time that it is
        // no metadata counterpart — the bytes are what decide this.
        let held = makeAsset(
            hash: hashes.still, filename: "IMG_0001.jpg",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        try catalog(at: directory).upsertAsset(held)
        store.loadAll()
        store.mergeLibraryIndex([libraryItem()])
        XCTAssertEqual(store.assets.count, 2, "Indexed as its own row until the bytes are read")

        store.importOriginalsFromApplePhotos()
        try await waitUntil("the Photos import to finish") { !store.isImportingFromApplePhotos }

        XCTAssertEqual(store.assets.count, 1, "Byte-identical is one photograph, one row")
        let survivor = try XCTUnwrap(store.assets.first)
        XCTAssertEqual(survivor.id, held.id)
        XCTAssertEqual(survivor.providerLocalID, "PHOTO-1/L0/001")
    }

    /// With iCloud Photos off, proving the same file sits in a *local* Photos
    /// library says nothing about Apple's cloud. Writing verified presence here
    /// would be exactly the claim the evidence model exists to prevent.
    func testMergingAgainstAnUnsyncedLibraryWritesNoCloudPresence() async throws {
        let (store, directory) = try makeStore()
        store.iCloudPhotosEnabled = false
        let hashes = try makeExport(store, still: "original bytes")
        let held = makeAsset(
            hash: hashes.still, captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        try catalog(at: directory).upsertAsset(held)
        store.loadAll()
        store.mergeLibraryIndex([libraryItem()])

        store.importOriginalsFromApplePhotos()
        try await waitUntil("the Photos import to finish") { !store.isImportingFromApplePhotos }

        let survivor = try XCTUnwrap(store.assets.first)
        XCTAssertFalse(survivor.presence.appleCloud)
        XCTAssertEqual(survivor.cloudPresenceEvidence, .none)
    }

    /// A Live Photo is two files. Taking only the still hands the archive a
    /// flattened photograph and leaves the motion in a library the whole point
    /// is to stop depending on.
    func testALivePhotoArrivesAsAStillAndItsMotionHalfLinked() async throws {
        let (store, _) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        store.mergeLibraryIndex([libraryItem(kind: .livePhoto)])
        let hashes = try makeExport(store, still: "still bytes", motion: "motion bytes")

        store.importOriginalsFromApplePhotos()
        try await waitUntil("the Photos import to finish") { !store.isImportingFromApplePhotos }

        XCTAssertEqual(store.assets.count, 2, "Still and motion are two files and two assets")
        let still = try XCTUnwrap(store.assets.first { !$0.isLivePhotoMotion })
        let motion = try XCTUnwrap(store.assets.first { $0.isLivePhotoMotion })
        XCTAssertEqual(motion.livePhotoStillID, still.id)
        XCTAssertEqual(still.kind, .livePhoto)
        XCTAssertEqual(motion.contentHash, hashes.motion)
        XCTAssertTrue(store.staging.exists(relativePath: motion.stagingRelativePath))
        XCTAssertEqual(
            store.backlogCount(for: targetID), 2,
            "The motion half is content that still has to live somewhere"
        )
        XCTAssertEqual(store.livePhotoMotion(for: still)?.id, motion.id)
    }

    /// The motion half may already be in the archive from a Takeout import,
    /// sitting there unlinked. Photos says which still it belongs to, which is
    /// better evidence than the identifier match the pairer would have to make
    /// — and it is a link, not a second copy.
    func testAMotionHalfAlreadyHeldIsLinkedRatherThanStoredAgain() async throws {
        let (store, directory) = try makeStore()
        let hashes = try makeExport(store, still: "still bytes", motion: "motion bytes")
        let heldMotion = makeAsset(
            hash: try XCTUnwrap(hashes.motion), filename: "IMG_0001.MOV", kind: .video,
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        try catalog(at: directory).upsertAsset(heldMotion)
        store.loadAll()
        store.mergeLibraryIndex([libraryItem(kind: .livePhoto)])

        store.importOriginalsFromApplePhotos()
        try await waitUntil("the Photos import to finish") { !store.isImportingFromApplePhotos }

        XCTAssertEqual(store.assets.count, 2, "The movie was already held; nothing was stored twice")
        let motion = try XCTUnwrap(store.assets.first { $0.id == heldMotion.id })
        let still = try XCTUnwrap(store.assets.first { $0.id != heldMotion.id })
        XCTAssertEqual(motion.livePhotoStillID, still.id)
        XCTAssertEqual(still.kind, .livePhoto)
    }

    /// Re-running the import must not attach a second movie to the same still.
    func testReimportingDoesNotAttachASecondMotionHalf() async throws {
        let (store, _) = try makeStore()
        store.mergeLibraryIndex([libraryItem(kind: .livePhoto)])
        _ = try makeExport(store, still: "still bytes", motion: "motion bytes")

        store.importOriginalsFromApplePhotos()
        try await waitUntil("the Photos import to finish") { !store.isImportingFromApplePhotos }
        let after = store.assets.count

        store.mergeLibraryIndex([libraryItem(kind: .livePhoto)])
        store.importOriginalsFromApplePhotos()
        try await waitUntil("the second pass to finish") { !store.isImportingFromApplePhotos }

        XCTAssertEqual(store.assets.count, after)
        XCTAssertEqual(store.assets.filter(\.isLivePhotoMotion).count, 1)
    }
}
