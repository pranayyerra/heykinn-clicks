import XCTest
@testable import HeykinnClicks

/// Every photo is judged against what its own source asks for.
///
/// There is no archive-wide copy count any more. The interesting case — the one
/// a single global number could never express — is two sources on one device
/// wanting different things, and both being right at the same time.
@MainActor
final class PerSourceCopiesTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []; suiteNames = []
        super.tearDown()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func makeStore() throws -> AppStore {
        try makeStoreReturningDirectory().store
    }

    private func makeStoreReturningDirectory() throws -> (store: AppStore, directory: URL) {
        let directory = try makeDirectory("store")
        let suiteName = "heykinn-persource-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
        return (store, directory)
    }

    /// A second connection onto the same catalog, for seeding a device the way
    /// an earlier session would have left it.
    private func catalog(at directory: URL) throws -> CatalogStore {
        try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    // MARK: - The evaluator

    /// The same two present copies, two different verdicts, because the two
    /// photos came from sources that asked for different things.
    func testTwoCopiesIsEnoughForOneSourceAndNotForAnother() {
        let modest = asset()
        let demanding = asset()
        let replicas = [modest, demanding].flatMap { subject in
            (0..<2).map { _ in
                TargetReplicaState(
                    assetID: subject.id, targetID: UUID(), state: .present,
                    relativePath: "volume:x", lastVerifiedAt: Date()
                )
            }
        }

        let states = ProtectionEvaluator.protectionStates(
            for: [modest, demanding],
            replicaStates: replicas,
            desiredCopies: { $0 == demanding.id ? 3 : 2 }
        )

        XCTAssertEqual(states[modest.id], .fullyReplicated)
        XCTAssertEqual(states[demanding.id], .replicatedToOneDrive)
    }

    /// A source asking for one copy is satisfied by one copy. Under the old
    /// global default of two this photo read as permanently behind.
    func testOneCopySatisfiesASourceThatAsksForOne() {
        let subject = asset()
        let state = ProtectionEvaluator.protectionState(
            for: subject,
            replicaStates: [
                TargetReplicaState(
                    assetID: subject.id, targetID: UUID(), state: .present,
                    relativePath: "volume:x", lastVerifiedAt: Date()
                )
            ],
            desiredCopies: 1
        )
        XCTAssertEqual(state, .fullyReplicated)
    }

    // MARK: - Through the store

    /// End to end: a source's number is what its photos are judged against, and
    /// changing that number changes every verdict under it.
    func testChangingASourcesCopyCountChangesItsPhotosVerdicts() async throws {
        let store = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))

        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder],
            label: "Scans",
            desiredCopies: 1,
            destinationTargetIDs: [driveID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let subject = try XCTUnwrap(store.assets.first)
        let group = try XCTUnwrap(store.storageGroups.first { $0.label == "Scans" })

        store.syncDrive(driveID)
        try await waitUntil("the sync to drain") { !store.isSyncing }

        XCTAssertEqual(
            store.storageGroupIDByAsset[subject.id], group.id,
            "the import files its photos into the group that started it"
        )
        XCTAssertEqual(store.desiredCopies(forAsset: subject.id), 1)
        XCTAssertEqual(
            store.protectionStates[subject.id]?.verdict, .meetsPolicy,
            "one copy is what this source asked for"
        )

        // The user asks for two. Nothing about the photo changed; the answer
        // does, because the question did.
        store.applyStorageGroupSettings(group, desiredCopies: 2, destinations: [driveID])

        XCTAssertEqual(store.desiredCopies(forAsset: subject.id), 2)
        XCTAssertEqual(store.protectionStates[subject.id]?.verdict, .shortOfPolicy)
    }

    /// An asset with no source recorded falls back to the add-sheet defaults
    /// rather than being judged against nothing. Placing nothing would stop
    /// protecting content that was protected yesterday, which is the worse
    /// failure of the two.
    func testAnAssetWithNoSourceFallsBackToTheDefaults() throws {
        let store = try makeStore()
        let orphan = UUID()

        XCTAssertEqual(
            store.desiredCopies(forAsset: orphan),
            store.newSourceDefaults.desiredCopies
        )
    }

    // MARK: - Taking a device off a source

    /// Adding a device to a source and then taking it off again must leave
    /// nothing behind.
    ///
    /// It did: the queued copies became `pending` replica rows, and nothing
    /// removed them — `releaseDepartedDevices` only handles copies that exist,
    /// gated on proof, and a copy that was never made has nothing to prove. The
    /// device then reported thousands of photos "waiting" for work no longer
    /// queued anywhere.
    func testTakingADeviceOffASourceWithdrawsTheCopiesItWasOwed() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let keep = try makeDirectory("keep")
        store.registerHostDeviceTarget(at: keep, name: "Keeper")
        let keepID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans",
            desiredCopies: 1, destinationTargetIDs: [keepID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let subject = try XCTUnwrap(store.assets.first)
        let group = try XCTUnwrap(store.storageGroups.first { $0.label == "Scans" })
        store.syncDrive(keepID)
        try await waitUntil("the sync to drain") { !store.isSyncing }
        XCTAssertEqual(store.protectionStates[subject.id]?.verdict, .meetsPolicy)

        // A second device, added to the source and then taken off again.
        let extra = UUID()
        try catalog(at: directory).upsertTarget(ReplicationTarget(
            id: extra, name: "Second thoughts", kind: .externalVolume, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: "/Volumes/Second", configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        store.loadAll()

        store.applyStorageGroupSettings(group, desiredCopies: 2, destinations: [keepID, extra])
        XCTAssertTrue(
            store.replicaStates.contains { $0.targetID == extra && $0.state == .pending },
            "the copy it was owed is queued"
        )

        store.applyStorageGroupSettings(group, desiredCopies: 1, destinations: [keepID])

        XCTAssertFalse(
            store.replicaStates.contains { $0.targetID == extra },
            "and withdrawn once the device is no longer named"
        )
        XCTAssertEqual(store.backlogCount(for: extra), 0)
        XCTAssertEqual(
            store.protectionStates[subject.id]?.verdict, .meetsPolicy,
            "the photo is exactly as safe as before"
        )
    }

    /// The withdrawal is narrow: a copy that actually exists is not forgotten,
    /// because losing the record of it is how the app ends up unable to find,
    /// check, or reclaim it.
    func testACopyThatExistsIsNotForgotten() async throws {
        let store = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans",
            desiredCopies: 1, destinationTargetIDs: [driveID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let group = try XCTUnwrap(store.storageGroups.first { $0.label == "Scans" })
        store.syncDrive(driveID)
        try await waitUntil("the sync to drain") { !store.isSyncing }
        XCTAssertTrue(store.replicaStates.contains { $0.targetID == driveID && $0.state == .present })

        // Take the device off the source entirely. The bytes are still there.
        store.applyStorageGroupSettings(group, desiredCopies: 1, destinations: [])

        XCTAssertTrue(
            store.replicaStates.contains { $0.targetID == driveID && $0.state == .present },
            "the record of a copy that exists survives"
        )
    }

    /// Releasing the same departed device twice must not queue the removal
    /// twice. Every sync calls this, so a standing duplicate grew the queue on
    /// each pass and wrote the same "queued for removal" line into the log
    /// every ten seconds.
    func testADepartedDeviceIsOnlyQueuedForRemovalOnce() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let keep = try makeDirectory("keep")
        store.registerHostDeviceTarget(at: keep, name: "Keeper")
        let keepID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans",
            desiredCopies: 1, destinationTargetIDs: [keepID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let subject = try XCTUnwrap(store.assets.first)
        let group = try XCTUnwrap(store.storageGroups.first { $0.label == "Scans" })
        store.syncDrive(keepID)
        try await waitUntil("the sync to drain") { !store.isSyncing }

        // A drive the source no longer names, still holding a copy it was once
        // given — the state this cleanup exists for.
        let departed = UUID()
        let db = try catalog(at: directory)
        try db.upsertTarget(ReplicationTarget(
            id: departed, name: "Departed", kind: .externalVolume, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: "/Volumes/Departed", configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        try db.upsertReplicaState(TargetReplicaState(
            assetID: subject.id, targetID: departed,
            state: .present, relativePath: "ab/photo.jpg", lastVerifiedAt: Date()
        ))
        store.loadAll()
        XCTAssertEqual(store.storageGroupsByID[group.id]?.destinationTargetIDs, [keepID])

        let first = store.releaseDepartedDevices(for: group.id)
        let second = store.releaseDepartedDevices(for: group.id)

        XCTAssertEqual(first, 1, "the copy on the departed device is queued for removal")
        XCTAssertEqual(second, 0, "and asking again queues nothing further")
        XCTAssertEqual(
            store.replicationTasks.filter {
                $0.state == .queued && $0.action == .remove && $0.targetID == departed
            }.count,
            1,
            "one instruction, however many times the sync asks"
        )
    }

    /// Copies queued for deletion must read as leaving, not arriving. The grid
    /// tinted them the same colour as work in progress, so a drive the app was
    /// about to erase photos from looked like a drive still receiving them.
    func testCopiesQueuedForRemovalAreCountedAsLeavingRatherThanArriving() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let keep = try makeDirectory("keep")
        store.registerHostDeviceTarget(at: keep, name: "Keeper")
        let keepID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans",
            desiredCopies: 1, destinationTargetIDs: [keepID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let subject = try XCTUnwrap(store.assets.first)
        let group = try XCTUnwrap(store.storageGroups.first { $0.label == "Scans" })
        store.syncDrive(keepID)
        try await waitUntil("the sync to drain") { !store.isSyncing }

        let departed = UUID()
        let db = try catalog(at: directory)
        try db.upsertTarget(ReplicationTarget(
            id: departed, name: "Departed", kind: .externalVolume, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: "/Volumes/Departed", configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        try db.upsertReplicaState(TargetReplicaState(
            assetID: subject.id, targetID: departed,
            state: .present, relativePath: "ab/photo.jpg", lastVerifiedAt: Date()
        ))
        store.loadAll()
        let before = try XCTUnwrap(store.cell(group: group.id, place: departed))
        XCTAssertEqual(before.leaving, 0, "nothing is queued for removal yet")

        store.releaseDepartedDevices(for: group.id)

        let after = try XCTUnwrap(store.cell(group: group.id, place: departed))
        XCTAssertEqual(after.photos, 1, "the copy is still on the drive until the sync runs")
        XCTAssertEqual(after.leaving, 1, "and it is counted as on its way out")
        XCTAssertEqual(after.waiting, 0, "never as something still arriving")
    }

    /// A group holding no photos is not waiting for anything, so its cells must
    /// not read as work outstanding.
    func testAGroupWithNoPhotosHasNoCellsWaitingOnIt() throws {
        let store = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let group = try XCTUnwrap(store.createStorageGroup(label: "Nothing in here"))
        store.applyStorageGroupSettings(group, desiredCopies: 1, destinations: [driveID])

        XCTAssertNil(
            store.cell(group: group.id, place: driveID),
            "an empty group owes the drive nothing, so there is no cell of work to draw"
        )
    }

    /// A Live Photo's movie half must be kept exactly as well as its still.
    /// Filed into a group of its own it followed that group's copy count, so
    /// the motion of a photo kept on two drives was being kept on one — and the
    /// grid could not show it, because motion halves are not counted as photos.
    func testALivePhotoMotionHalfIsKeptWithItsStill() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans",
            desiredCopies: 2, destinationTargetIDs: [driveID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let still = try XCTUnwrap(store.assets.first)
        let keeper = try XCTUnwrap(store.storageGroups.first { $0.label == "Scans" })

        // A movie half filed somewhere else entirely, the way the fallback did.
        let db = try catalog(at: directory)
        let stray = try XCTUnwrap(store.createStorageGroup(label: "Somewhere else"))
        store.applyStorageGroupSettings(stray, desiredCopies: 1, destinations: [driveID])
        var motion = asset()
        motion.kind = .video
        motion.originalFilename = "photo.mov"
        motion.livePhotoStillID = still.id
        try db.upsertAsset(motion)
        try db.assignStorageGroup(stray.id, toAssets: [motion.id])
        store.loadAll()
        XCTAssertEqual(store.desiredCopies(forAsset: motion.id), 1, "kept worse than its still")

        XCTAssertEqual(store.reuniteLivePhotoHalves(), 1)

        XCTAssertEqual(store.storageGroupIDByAsset[motion.id], keeper.id)
        XCTAssertEqual(
            store.desiredCopies(forAsset: motion.id),
            store.desiredCopies(forAsset: still.id),
            "the movie is kept exactly as well as the photograph it belongs to"
        )
    }

    /// And it is a no-op once everything already sits with its still, so it can
    /// run at every launch without churning records.
    func testReunitingIsANoOpWhenHalvesAlreadySitWithTheirStill() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")
        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans", desiredCopies: 2, destinationTargetIDs: [driveID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let still = try XCTUnwrap(store.assets.first)

        var motion = asset()
        motion.kind = .video
        motion.originalFilename = "photo.mov"
        motion.livePhotoStillID = still.id
        let db = try catalog(at: directory)
        try db.upsertAsset(motion)
        try db.assignSource(try XCTUnwrap(store.sourceIDByAsset[still.id]), toAssets: [motion.id])
        try db.assignStorageGroup(
            try XCTUnwrap(store.storageGroupIDByAsset[still.id]), toAssets: [motion.id]
        )
        store.loadAll()

        XCTAssertEqual(store.reuniteLivePhotoHalves(), 0)
    }

    /// The headline sentence counts photographs, so its numerator must too. It
    /// read its total from the per-photograph counts and its shortfall from the
    /// raw per-row states, which include Live Photo movie halves — so the app
    /// said "25 of 23,121 photos" about 25 things the same sentence does not
    /// call photos. A photograph is only as safe as its worse-off half, so the
    /// movie's shortfall now lands on the photograph it belongs to.
    func testAShortLivePhotoMovieMakesItsPhotographShortRatherThanItsOwnRow() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")
        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans", desiredCopies: 1, destinationTargetIDs: [driveID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let still = try XCTUnwrap(store.assets.first)
        store.syncDrive(driveID)
        try await waitUntil("the sync to drain") { !store.isSyncing }
        XCTAssertEqual(store.safetyFacts.short, 0, "the photograph is where it belongs")

        // Its movie half arrives, held nowhere yet.
        var motion = asset()
        motion.kind = .video
        motion.originalFilename = "photo.mov"
        motion.livePhotoStillID = still.id
        let db = try catalog(at: directory)
        try db.upsertAsset(motion)
        try db.assignSource(try XCTUnwrap(store.sourceIDByAsset[still.id]), toAssets: [motion.id])
        try db.assignStorageGroup(
            try XCTUnwrap(store.storageGroupIDByAsset[still.id]), toAssets: [motion.id]
        )
        store.loadAll()

        XCTAssertEqual(
            store.countedPhotoTotal, 1,
            "a Live Photo is one photograph however many files it is made of"
        )
        XCTAssertEqual(
            store.safetyFacts.short, 1,
            "and it is short, because half of it is — counted against the photograph, not as an extra row"
        )
        XCTAssertLessThanOrEqual(
            store.safetyFacts.short, store.safetyFacts.photos,
            "the numerator can never exceed the total it is quoted against"
        )
    }

    /// Photos arriving from a place the archive already knows must join that
    /// source, not start a second one. The backfill minted a new source every
    /// time, so a Photos library the user had set to two copies on two drives
    /// gained a second "Photos library" source whose copy count was read off
    /// wherever the new bytes happened to be — one drive. The photos were then
    /// kept to a standard nobody chose.
    func testPhotosFromAKnownSourceJoinItRatherThanStartingASecondOne() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let keep = try makeDirectory("keep")
        store.registerHostDeviceTarget(at: keep, name: "Keeper")
        let keepID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("first".utf8).write(to: folder.appendingPathComponent("one.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans", desiredCopies: 2, destinationTargetIDs: [keepID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let known = try XCTUnwrap(store.sources.first { $0.label == "Scans" })
        let knownGroup = try XCTUnwrap(store.storageGroupIDByAsset[
            try XCTUnwrap(store.assets.first).id
        ])
        let sourcesBefore = store.sources.count

        // A photo from the same folder, recorded with no source — what an
        // import that predates sources, or an indexing pass, leaves behind.
        let db = try catalog(at: directory)
        let batch = try XCTUnwrap(store.importBatches.first { $0.isFolderImport })
        var orphan = asset()
        orphan.importBatchID = batch.id
        try db.upsertAsset(orphan)
        store.loadAll()

        store.backfillSources()

        XCTAssertEqual(store.sources.count, sourcesBefore, "no second source for the same folder")
        XCTAssertEqual(store.sourceIDByAsset[orphan.id], known.id)
        XCTAssertEqual(
            store.storageGroupIDByAsset[orphan.id], knownGroup,
            "and it is kept the way that source is already set to keep things"
        )
        XCTAssertEqual(store.desiredCopies(forAsset: orphan.id), 2)
    }

    /// A second source for one place is folded back into the first, and its
    /// photos take the settings the user actually chose there — not the ones
    /// the backfill guessed from wherever the newer bytes happened to sit.
    func testASecondSourceForOnePlaceIsFoldedIntoTheFirst() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let keep = try makeDirectory("keep")
        store.registerHostDeviceTarget(at: keep, name: "Keeper")
        let keepID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("first".utf8).write(to: folder.appendingPathComponent("one.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans", desiredCopies: 2, destinationTargetIDs: [keepID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let keeper = try XCTUnwrap(store.sources.first { $0.label == "Scans" })
        let keeperGroup = try XCTUnwrap(
            store.storageGroupIDByAsset[try XCTUnwrap(store.assets.first).id]
        )

        // The duplicate the backfill used to mint: same kind, same label, added
        // later, with a weaker policy read off one drive.
        let db = try catalog(at: directory)
        let later = PhotoArchiveSource(
            id: UUID(), kind: keeper.kind, label: keeper.label,
            originPath: keeper.originPath, exportSetID: keeper.exportSetID,
            addedAt: keeper.addedAt.addingTimeInterval(3600)
        )
        try db.upsertSource(later)
        let weak = try XCTUnwrap(store.createStorageGroup(label: "Scans"))
        store.applyStorageGroupSettings(weak, desiredCopies: 1, destinations: [keepID])
        let stray = asset()
        try db.upsertAsset(stray)
        try db.assignSource(later.id, toAssets: [stray.id])
        try db.assignStorageGroup(weak.id, toAssets: [stray.id])
        store.loadAll()
        XCTAssertEqual(store.desiredCopies(forAsset: stray.id), 1, "kept to a policy nobody chose")

        XCTAssertEqual(store.mergeDuplicateSources(), 1)

        XCTAssertEqual(store.sources.filter { $0.label == "Scans" }.count, 1)
        XCTAssertEqual(store.sourceIDByAsset[stray.id], keeper.id, "the older source wins")
        XCTAssertEqual(store.storageGroupIDByAsset[stray.id], keeperGroup)
        XCTAssertEqual(store.desiredCopies(forAsset: stray.id), 2)
        XCTAssertFalse(
            store.storageGroups.contains { $0.id == weak.id },
            "the emptied group goes with it"
        )
        XCTAssertEqual(store.mergeDuplicateSources(), 0, "and running again finds nothing to do")
    }

    /// The row subtitle on Keep safe reads "N photos · M short of two copies".
    /// Both numbers must count the same thing. They did not: the total excluded
    /// Live Photo movie halves and the shortfall counted them, so a group whose
    /// every photograph was where it belonged still announced "25 short" — 25
    /// movie halves, against a total of 21,117 that did not include one of them.
    func testAGroupWhoseEveryPhotographIsKeptReportsNothingShort() async throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")
        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans", desiredCopies: 1, destinationTargetIDs: [driveID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let still = try XCTUnwrap(store.assets.first)
        store.syncDrive(driveID)
        try await waitUntil("the sync to drain") { !store.isSyncing }
        let group = try XCTUnwrap(store.storageGroups.first { $0.label == "Scans" })

        // Its movie half, held nowhere yet — the shape that produced the 25.
        var motion = asset()
        motion.kind = .video
        motion.originalFilename = "photo.mov"
        motion.livePhotoStillID = still.id
        let db = try catalog(at: directory)
        try db.upsertAsset(motion)
        try db.assignSource(try XCTUnwrap(store.sourceIDByAsset[still.id]), toAssets: [motion.id])
        try db.assignStorageGroup(group.id, toAssets: [motion.id])
        store.loadAll()

        XCTAssertEqual(store.photoCountByStorageGroup[group.id], 1, "one photograph in the group")
        XCTAssertEqual(
            store.photosShortByGroup[group.id] ?? 0, 1,
            "and it is short, because the movie that belongs to it is — counted once, not twice"
        )
        XCTAssertLessThanOrEqual(
            store.photosShortByGroup[group.id] ?? 0,
            store.photoCountByStorageGroup[group.id] ?? 0,
            "the two numbers on one row are drawn from one population"
        )
    }

    // MARK: - Fixtures

    private func asset() -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "p.jpg", importOrigin: .localFolder,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString,
            residency: .local, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
        )
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
