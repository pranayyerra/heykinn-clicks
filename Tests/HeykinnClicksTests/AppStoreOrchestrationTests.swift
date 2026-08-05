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

    // MARK: - Deleted export archives

    /// Seeds a target holding one export part as a zip, with the assets inside
    /// it recorded as zip-member replicas — the shape a Takeout drive actually
    /// has after reconciliation.
    private func seedExportZip(
        store: AppStore,
        directory: URL,
        mount: URL,
        targetID: UUID
    ) throws -> (asset: Asset, zip: URL, archiveID: UUID) {
        let zip = mount.appendingPathComponent("Exports/takeout-S1-001.zip")
        try FileManager.default.createDirectory(
            at: zip.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("a zip standing in for ten gigabytes".utf8).write(to: zip)

        let asset = makeAsset(hash: "hash-inside-the-zip", filename: "IMG_0001.jpg")
        let archiveID = UUID()
        let seed = try catalog(at: directory)
        try seed.upsertAsset(asset)
        try seed.upsertReplicaState(TargetReplicaState(
            assetID: asset.id, targetID: targetID, state: .present,
            relativePath: "zipmember:Exports/takeout-S1-001.zip!Takeout/Google Photos/IMG_0001.jpg",
            lastVerifiedAt: Date()
        ))
        try seed.upsertTakeoutArchive(TakeoutArchive(
            id: archiveID, path: zip.path, kind: .zip, sizeBytes: 34,
            targetID: targetID, discoveredAt: Date(), importedAt: Date(),
            importBatchID: nil, importedAssetCount: 1, skippedDuplicateCount: 0,
            note: nil, exportSetID: "S1", partNumber: 1
        ))
        store.loadAll()
        return (asset, zip, archiveID)
    }

    /// The reported bug: a Takeout zip deleted from a connected drive left the
    /// archive reading as fully protected. Nothing saw it — the recorded hashes
    /// did not change so the trees agreed, the directory holding the zip was
    /// still there so the anchor check was happy, and path repair never looks
    /// at archive-backed replicas at all.
    func testADeletedExportZipStopsCountingAsProtection() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        let seeded = try seedExportZip(
            store: store, directory: directory, mount: mount, targetID: targetID
        )

        store.checkReplicaStats(for: targetID)
        XCTAssertEqual(
            store.protectionStates[seeded.asset.id], .fullyReplicated,
            "While the zip is there, the copy inside it is real"
        )

        try FileManager.default.removeItem(at: seeded.zip)

        XCTAssertEqual(store.checkArchivePresence(for: targetID).vanished, 1)
        XCTAssertEqual(store.checkReplicaStats(for: targetID).missing, 1)

        XCTAssertEqual(
            store.replicaStates.first { $0.assetID == seeded.asset.id }?.state, .missing,
            "The bytes backing this copy are gone, so the copy is gone"
        )
        XCTAssertNotEqual(
            store.protectionStates[seeded.asset.id], .fullyReplicated,
            "An archive that lost its only copy of a photo is not fully replicated"
        )
        XCTAssertEqual(
            store.takeoutArchives.first { $0.id == seeded.archiveID }?.holdsBytes, false
        )
        XCTAssertTrue(
            store.archivePlan.partsNeedingWork.contains { $0.displayName == "takeout-S1-001" },
            "The part is now short a copy, which is the work the user needs offered"
        )
    }

    /// The row outlives the file: what was imported out of that part happened,
    /// and stays true. What must stop is the row counting as a copy.
    func testADeletedArchiveKeepsItsImportHistory() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        let seeded = try seedExportZip(
            store: store, directory: directory, mount: mount, targetID: targetID
        )

        try FileManager.default.removeItem(at: seeded.zip)
        store.checkArchivePresence(for: targetID)

        let archive = try XCTUnwrap(store.takeoutArchives.first { $0.id == seeded.archiveID })
        XCTAssertTrue(archive.isImported)
        XCTAssertEqual(archive.importedAssetCount, 1)
        XCTAssertNotNil(archive.missingSince)
    }

    /// A file put back is not a permanent verdict — the next look clears it,
    /// and the replicas it backs are claimable again.
    func testAnArchivePutBackIsNoLongerRecordedAsGone() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        let seeded = try seedExportZip(
            store: store, directory: directory, mount: mount, targetID: targetID
        )

        try FileManager.default.removeItem(at: seeded.zip)
        XCTAssertEqual(store.checkArchivePresence(for: targetID).vanished, 1)

        try Data("a zip standing in for ten gigabytes".utf8).write(to: seeded.zip)
        XCTAssertEqual(store.checkArchivePresence(for: targetID).returned, 1)
        XCTAssertNil(store.takeoutArchives.first { $0.id == seeded.archiveID }?.missingSince)
        XCTAssertEqual(
            store.archivePlan.parts.first { $0.displayName == "takeout-S1-001" }?.targetIDs,
            [targetID],
            "The drive holds the part again"
        )
    }

    /// A drive pulled mid-check makes every `stat` fail at once. Writing that
    /// down as loss would turn an unplug into a catalog full of missing copies
    /// — the loudest possible way for a check to be wrong.
    func testAnUnpluggedDriveIsNotRecordedAsDataLoss() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        let seeded = try seedExportZip(
            store: store, directory: directory, mount: mount, targetID: targetID
        )
        store.checkReplicaStats(for: targetID)

        // The whole volume goes away, not one file on it.
        try FileManager.default.removeItem(at: mount)

        XCTAssertEqual(store.checkArchivePresence(for: targetID).vanished, 0)
        XCTAssertEqual(store.checkReplicaStats(for: targetID).missing, 0)
        XCTAssertEqual(
            store.replicaStates.first { $0.assetID == seeded.asset.id }?.state, .present,
            "Out of reach is not gone"
        )
        XCTAssertNil(store.takeoutArchives.first { $0.id == seeded.archiveID }?.missingSince)
    }

    // MARK: - Drive layout

    /// A part restored to the app's folder because the drive held none of its
    /// set, on a drive that holds the rest of the set. It belongs with the
    /// export, and moving it is a rename.
    func testADeliveredPartMovesInBesideTheRestOfItsExport() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        let seed = try catalog(at: directory)

        // Eleven parts where the user keeps them.
        let home = mount.appendingPathComponent("Google_Photos_Backup_July2026", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for part in 1...11 {
            let url = home.appendingPathComponent("takeout-S1-\(String(format: "%03d", part)).zip")
            try Data("part".utf8).write(to: url)
            try seed.upsertTakeoutArchive(TakeoutArchive(
                id: UUID(), path: url.path, kind: .zip, sizeBytes: 4, targetID: targetID,
                discoveredAt: Date(), importedAt: nil, importBatchID: nil, importedAssetCount: 0,
                skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: part
            ))
        }
        // And the twelfth, delivered to the app's folder at the root.
        let strayDirectory = ExportPartRelay.destinationDirectory(onMount: mount)
        try FileManager.default.createDirectory(at: strayDirectory, withIntermediateDirectories: true)
        let stray = strayDirectory.appendingPathComponent("takeout-S1-012.zip")
        try Data("part".utf8).write(to: stray)
        let strayID = UUID()
        try seed.upsertTakeoutArchive(TakeoutArchive(
            id: strayID, path: stray.path, kind: .zip, sizeBytes: 4, targetID: targetID,
            discoveredAt: Date(), importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: 12
        ))
        store.loadAll()

        XCTAssertEqual(store.rehomeDeliveredParts(for: targetID), 1)

        let landed = home.appendingPathComponent("takeout-S1-012.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertEqual(
            store.takeoutArchives.first { $0.id == strayID }?.path, landed.path,
            "The catalog follows the file in the same pass"
        )
    }

    /// The destination almost always already has a row, and that is the normal
    /// case: the part was delivered *because* the copy that sat there was
    /// deleted, and the row for that copy outlived the file. One path is one
    /// row, so the arriving copy moves into it — colliding with it is what
    /// stopped the move on a real drive.
    func testAPartMovesIntoTheRowOfTheCopyItReplaces() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        let seed = try catalog(at: directory)

        let home = mount.appendingPathComponent("Google_Photos_Backup_July2026", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for part in 1...11 {
            let url = home.appendingPathComponent("takeout-S1-\(String(format: "%03d", part)).zip")
            try Data("part".utf8).write(to: url)
            try seed.upsertTakeoutArchive(TakeoutArchive(
                id: UUID(), path: url.path, kind: .zip, sizeBytes: 4, targetID: targetID,
                discoveredAt: Date(), importedAt: nil, importBatchID: nil, importedAssetCount: 0,
                skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: part
            ))
        }

        // Part 012's own copy was deleted from the user's folder: no file, but
        // the row survives, carrying what was imported out of it.
        let originalID = UUID()
        let originalPath = home.appendingPathComponent("takeout-S1-012.zip").path
        var original = TakeoutArchive(
            id: originalID, path: originalPath, kind: .zip, sizeBytes: 4, targetID: targetID,
            discoveredAt: Date(), importedAt: Date(), importBatchID: nil, importedAssetCount: 3_362,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: 12,
            contentHash: "hash-of-the-file-that-was-deleted"
        )
        original.missingSince = Date()
        try seed.upsertTakeoutArchive(original)

        // And a replacement was delivered into the app's folder.
        let strayDirectory = ExportPartRelay.destinationDirectory(onMount: mount)
        try FileManager.default.createDirectory(at: strayDirectory, withIntermediateDirectories: true)
        let stray = strayDirectory.appendingPathComponent("takeout-S1-012.zip")
        try Data("delivered".utf8).write(to: stray)
        let strayID = UUID()
        try seed.upsertTakeoutArchive(TakeoutArchive(
            id: strayID, path: stray.path, kind: .zip, sizeBytes: 9, targetID: targetID,
            discoveredAt: Date(), importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: 12,
            quickChecksum: "spot-checked-on-arrival"
        ))
        store.loadAll()

        XCTAssertEqual(store.rehomeDeliveredParts(for: targetID), 1)
        XCTAssertNil(store.lastError)

        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertNil(
            store.takeoutArchives.first { $0.id == strayID },
            "The delivered row moved into the destination's row rather than beside it"
        )

        let merged = try XCTUnwrap(store.takeoutArchives.first { $0.id == originalID })
        XCTAssertNil(merged.missingSince, "The part is here again")
        XCTAssertEqual(merged.importedAssetCount, 3_362, "What was imported out of this part still happened")
        XCTAssertEqual(merged.sizeBytes, 9, "The bytes described are the ones that arrived")
        XCTAssertEqual(merged.quickChecksum, "spot-checked-on-arrival")
        XCTAssertNil(
            merged.contentHash,
            "The old hash described the file that was deleted; nobody has read these bytes in full"
        )
        XCTAssertEqual(store.takeoutArchives.filter { $0.partNumber == 12 }.count, 1)
    }

    /// A row for a part recorded as gone from the app's own delivery folder,
    /// while the part is present on the drive, is the app describing its own
    /// tidying as data loss. It can never resolve, because nothing will put a
    /// file back at that path.
    func testARecordOfAPartTheAppItselfMovedIsNotKeptAsALostCopy() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        let seed = try catalog(at: directory)

        let home = mount.appendingPathComponent("Google_Photos_Backup_July2026", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let live = home.appendingPathComponent("takeout-S1-012.zip")
        try Data("part".utf8).write(to: live)
        try seed.upsertTakeoutArchive(TakeoutArchive(
            id: UUID(), path: live.path, kind: .zip, sizeBytes: 4, targetID: targetID,
            discoveredAt: Date(), importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: 12
        ))

        let phantomID = UUID()
        var phantom = TakeoutArchive(
            id: phantomID,
            path: ExportPartRelay.destinationDirectory(onMount: mount)
                .appendingPathComponent("takeout-S1-012.zip").path,
            kind: .zip, sizeBytes: 4, targetID: targetID, discoveredAt: Date(),
            importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: 12
        )
        phantom.missingSince = Date()
        try seed.upsertTakeoutArchive(phantom)
        store.loadAll()

        store.rehomeDeliveredParts(for: targetID)

        XCTAssertNil(store.takeoutArchives.first { $0.id == phantomID })
        XCTAssertEqual(store.takeoutArchives.filter { $0.partNumber == 12 }.count, 1)
    }

    /// A part genuinely deleted out of the app's folder, with no copy of it
    /// anywhere else on the drive, is a real lost copy and stays reported.
    func testAGenuinelyLostPartInTheAppsFolderIsStillReported() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)

        let lostID = UUID()
        var lost = TakeoutArchive(
            id: lostID,
            path: ExportPartRelay.destinationDirectory(onMount: mount)
                .appendingPathComponent("takeout-S1-007.zip").path,
            kind: .zip, sizeBytes: 4, targetID: targetID, discoveredAt: Date(),
            importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: 7
        )
        lost.missingSince = Date()
        try catalog(at: directory).upsertTakeoutArchive(lost)
        store.loadAll()

        store.rehomeDeliveredParts(for: targetID)

        XCTAssertNotNil(
            store.takeoutArchives.first { $0.id == lostID },
            "Nothing else on this drive holds part 7 — that copy really is gone"
        )
    }

    /// With nowhere better to put it, the app's own folder is the right answer
    /// and the part stays there.
    func testADeliveredPartStaysPutWhenTheDriveHoldsNoneOfItsSet() throws {
        let (store, directory) = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Target")
        let targetID = try XCTUnwrap(store.targets.first?.id)

        let strayDirectory = ExportPartRelay.destinationDirectory(onMount: mount)
        try FileManager.default.createDirectory(at: strayDirectory, withIntermediateDirectories: true)
        let stray = strayDirectory.appendingPathComponent("takeout-S1-001.zip")
        try Data("part".utf8).write(to: stray)
        try catalog(at: directory).upsertTakeoutArchive(TakeoutArchive(
            id: UUID(), path: stray.path, kind: .zip, sizeBytes: 4, targetID: targetID,
            discoveredAt: Date(), importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S1", partNumber: 1
        ))
        store.loadAll()

        XCTAssertEqual(store.rehomeDeliveredParts(for: targetID), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    /// Catalogs already hold these rows, so fixing the scanner is only half of
    /// it: an archive whose path contains another archive's is a container, and
    /// reconciliation drops it without a rescan.
    func testAnArchiveContainingOtherArchivesIsDropped() throws {
        let (store, directory) = try makeStore()
        let seed = try catalog(at: directory)
        let targetID = UUID()

        func archive(_ path: String, kind: TakeoutArchiveKind, part: Int?) -> TakeoutArchive {
            TakeoutArchive(
                id: UUID(), path: path, kind: kind, sizeBytes: 10, targetID: targetID,
                discoveredAt: Date(), importedAt: Date(), importBatchID: nil,
                importedAssetCount: part == nil ? 0 : 100, skippedDuplicateCount: 0,
                note: nil, exportSetID: part == nil ? nil : "S1", partNumber: part
            )
        }
        let container = archive("/V/Owner/Takeout_Archive_2026", kind: .folder, part: nil)
        try seed.upsertTakeoutArchive(container)
        try seed.upsertTakeoutArchive(archive("/V/Owner/Takeout_Archive_2026/takeout-S1-001.zip", kind: .zip, part: 1))
        try seed.upsertTakeoutArchive(archive("/V/Owner/Takeout_Archive_2026/takeout-S1-001", kind: .folder, part: 1))
        store.loadAll()

        XCTAssertEqual(store.dropContainerArchives(), 1)
        XCTAssertNil(store.takeoutArchives.first { $0.id == container.id })
        XCTAssertEqual(store.takeoutArchives.count, 2, "The exports inside it are untouched")
    }

    /// The rule runs where containers are made, so a scan never leaves one
    /// behind for the next launch to clean up.
    ///
    /// The shape that still reaches it: a `Google Photos` directory marks its
    /// parent as an export, and here that parent is a folder somebody keeps
    /// their zips in. Naming alone would not have registered it — this comes
    /// from the structural rule, which is why fixing the folder-name test was
    /// only ever half of it.
    func testAScanLeavesNoContainerBehind() async throws {
        let (store, _) = try makeStore()
        let root = try makeDirectory("scan")
        let export = root.appendingPathComponent("Google_Photos_Backup", isDirectory: true)
        try FileManager.default.createDirectory(
            at: export.appendingPathComponent("Google Photos", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("part".utf8).write(to: export.appendingPathComponent("takeout-S1-001.zip"))

        await store.performTakeoutScan(rootURL: root, targetID: nil)

        XCTAssertEqual(
            store.takeoutArchives.map { ($0.path as NSString).lastPathComponent },
            ["takeout-S1-001.zip"],
            "The folder holding the export is not itself an export"
        )
    }

    /// A zip holds no rows and an extracted folder is not nested inside another
    /// export, so an ordinary drive loses nothing to this rule.
    func testOrdinaryArchivesAreNotTreatedAsContainers() throws {
        let (store, directory) = try makeStore()
        let seed = try catalog(at: directory)
        let targetID = UUID()
        for part in 1...3 {
            for (suffix, kind) in [(".zip", TakeoutArchiveKind.zip), ("", .folder)] {
                try seed.upsertTakeoutArchive(TakeoutArchive(
                    id: UUID(), path: "/V/Exports/takeout-S1-00\(part)\(suffix)", kind: kind,
                    sizeBytes: 10, targetID: targetID, discoveredAt: Date(), importedAt: nil,
                    importBatchID: nil, importedAssetCount: 0, skippedDuplicateCount: 0,
                    note: nil, exportSetID: "S1", partNumber: part
                ))
            }
        }
        store.loadAll()

        XCTAssertEqual(store.dropContainerArchives(), 0)
        XCTAssertEqual(store.takeoutArchives.count, 6)
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

    // MARK: - Recovering capture-date provenance

    /// A row as an install from before the provenance column would have left
    /// it: a real date, no record of where it came from, and the raw EXIF
    /// string still sitting in the summary.
    private func legacyRow(
        _ filename: String,
        storedDate: Date,
        exifText: String?
    ) -> Asset {
        var asset = makeAsset(hash: UUID().uuidString, filename: filename, captureDate: storedDate)
        asset.captureDateSource = .unknown
        if let exifText { asset.exifSummary["DateTimeOriginal"] = exifText }
        return asset
    }

    /// The defect this fixes: 16,284 assets whose date was read from EXIF at
    /// import displayed as an approximate year, because the backfill selected
    /// them as needing work and then skipped every row that already had a
    /// date. No drive is connected here — the evidence is in the catalog.
    func testProvenanceIsRecoveredWithoutTouchingTheDateOrTheDisk() async throws {
        let (store, directory) = try makeStore()
        let text = "2016:05:08 14:22:07"
        let stored = try XCTUnwrap(MetadataExtractor.parseExifDate(text))
        let row = legacyRow("IMG_1.jpg", storedDate: stored, exifText: text)

        let seed = try catalog(at: directory)
        try seed.upsertAsset(row)
        store.loadAll()
        XCTAssertEqual(store.assetsByID[row.id]?.captureDateSource, .unknown, "Precondition")

        store.recoverCaptureDates()
        try await waitUntil("provenance recovery to finish") { store.takeoutActivity == nil }

        let after = try XCTUnwrap(store.assetsByID[row.id])
        XCTAssertEqual(after.captureDateSource, .fileMetadata)
        XCTAssertTrue(after.captureDateSource.isExact, "The UI can stop saying 'approximate'")
        XCTAssertEqual(after.captureDate, stored, "The date itself is never rewritten")
    }

    /// Invariant 2 at the row level. The EXIF string is there, but it no longer
    /// reparses to the stored instant — on the real catalog, 2,091 rows whose
    /// import happened under a different timezone. Declining is the correct
    /// outcome, not a shortfall to paper over.
    func testAnUnreproducibleDateKeepsItsUnknownSource() async throws {
        let (store, directory) = try makeStore()
        let text = "2016:05:08 14:22:07"
        let drifted = try XCTUnwrap(MetadataExtractor.parseExifDate(text)).addingTimeInterval(5.5 * 3600)
        let row = legacyRow("IMG_2.jpg", storedDate: drifted, exifText: text)

        let seed = try catalog(at: directory)
        try seed.upsertAsset(row)
        store.loadAll()

        store.recoverCaptureDates()
        try await waitUntil("provenance recovery to finish") { store.takeoutActivity == nil }

        let after = try XCTUnwrap(store.assetsByID[row.id])
        XCTAssertEqual(after.captureDateSource, .unknown, "A source that cannot be re-derived is a guess")
        XCTAssertEqual(after.captureDate, drifted, "And the date it does hold is still left alone")
    }

    /// Recovery must not change which assets read as impossibly dated — that
    /// verdict is drawn on the date and the import, and this pass moves
    /// neither.
    func testRecoveryDoesNotChangeTheImpossibleDateVerdict() async throws {
        let (store, directory) = try makeStore()
        // A GoPro still: EXIF the app really did read, dated after the import.
        let text = "2027:04:28 03:17:38"
        let stored = try XCTUnwrap(MetadataExtractor.parseExifDate(text))
        var row = legacyRow("GOPR1411.JPG", storedDate: stored, exifText: text)
        row.importDate = stored.addingTimeInterval(-86_400 * 269)

        let seed = try catalog(at: directory)
        try seed.upsertAsset(row)
        store.loadAll()
        let before = store.assetsByID[row.id]?.impossibleCaptureDate
        XCTAssertNotNil(before, "Precondition: flagged before recovery")

        store.recoverCaptureDates()
        try await waitUntil("provenance recovery to finish") { store.takeoutActivity == nil }

        let after = try XCTUnwrap(store.assetsByID[row.id])
        XCTAssertNotNil(after.impossibleCaptureDate, "Still flagged")
        XCTAssertEqual(after.impossibleCaptureDate?.claimed, before?.claimed)
        XCTAssertEqual(after.impossibleCaptureDate?.imported, before?.imported)
        // What changed is only that the detail screen can now name the source.
        XCTAssertEqual(after.impossibleCaptureDate?.source, .fileMetadata)
    }

    /// A row with a date and no evidence anywhere is left exactly as it was,
    /// and the pass still completes rather than reporting a failure.
    func testNoEvidenceLeavesTheRowUntouched() async throws {
        let (store, directory) = try makeStore()
        let stored = Date(timeIntervalSince1970: 1_462_710_127)
        let row = legacyRow("scan.jpg", storedDate: stored, exifText: nil)

        let seed = try catalog(at: directory)
        try seed.upsertAsset(row)
        store.loadAll()

        store.recoverCaptureDates()
        try await waitUntil("provenance recovery to finish") { store.takeoutActivity == nil }

        let after = try XCTUnwrap(store.assetsByID[row.id])
        XCTAssertEqual(after.captureDateSource, .unknown)
        XCTAssertEqual(after.captureDate, stored)
        XCTAssertNil(store.lastError)
    }
}

/// The redundancy policy has to be bounded by the drives that exist, or an
/// archive with no drives reports 0% safe. Bounding it by *overwriting* what
/// the user asked for made that permanent — and every install begins with no
/// drives, so every install was quietly pinned to one copy for good.
@MainActor
final class RedundancyPolicyBoundTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []; suiteNames = []
        super.tearDown()
    }

    private func makeStore(_ directory: URL? = nil) throws -> (AppStore, URL, UserDefaults) {
        let root = try directory ?? {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("heykinn-policy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            roots.append(url)
            return url
        }()
        let suiteName = "heykinn-policy-\(root.lastPathComponent)"
        if !suiteNames.contains(suiteName) { suiteNames.append(suiteName) }
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = AppStore(environment: AppEnvironment(
            appDirectory: root, defaults: defaults, runsBackgroundWork: false
        ))
        return (store, root, defaults)
    }

    func testWithNoDrivesThePolicyInForceIsBoundedToOne() throws {
        let (store, _, _) = try makeStore()
        XCTAssertEqual(store.redundancyPolicy.desiredCopies, 1, "Nowhere to put a second copy")
        XCTAssertEqual(store.requestedCopies, 2, "…but two is still what was asked for")
    }

    /// The bug, in one assertion: register a drive and the policy the user
    /// asked for comes back on its own.
    func testRegisteringDrivesRestoresTheRequestedPolicy() throws {
        let (store, _, _) = try makeStore()
        XCTAssertEqual(store.redundancyPolicy.desiredCopies, 1)

        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        roots.append(first)
        store.registerHostDeviceTarget(at: first, name: "One")

        XCTAssertEqual(
            store.redundancyPolicy.desiredCopies, 1,
            "One drive still only holds one copy"
        )
        XCTAssertEqual(store.requestedCopies, 2, "The request survived being bounded")
    }

    /// And it survives a relaunch: the bound was never written to preferences,
    /// so a second session does not inherit it as the new intent.
    func testTheBoundIsNotWrittenToPreferences() throws {
        let (first, root, defaults) = try makeStore()
        XCTAssertEqual(first.redundancyPolicy.desiredCopies, 1)
        XCTAssertNil(
            defaults.object(forKey: "desiredCopies"),
            "Bounding the policy must not write anything down"
        )

        let (second, _, _) = try makeStore(root)
        XCTAssertEqual(second.requestedCopies, 2, "A relaunch still wants two copies")
    }

    func testChangingThePolicyIsRemembered() throws {
        let (store, root, _) = try makeStore()
        store.redundancyPolicy = LocalRedundancyPolicy(desiredCopies: 3)
        XCTAssertEqual(store.requestedCopies, 3)

        let (reopened, _, _) = try makeStore(root)
        XCTAssertEqual(reopened.requestedCopies, 3)
    }
}
