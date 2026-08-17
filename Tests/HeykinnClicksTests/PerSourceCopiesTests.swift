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
