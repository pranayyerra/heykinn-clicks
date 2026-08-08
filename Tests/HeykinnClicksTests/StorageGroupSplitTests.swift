import XCTest
@testable import HeykinnClicks

/// Provenance and policy are two rows now: `PhotoArchiveSource` records what
/// happened and never changes; `StorageGroup` records how photos are kept and
/// is the user's to change.
@MainActor
final class StorageGroupSplitTests: XCTestCase {

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

    private func makeStoreReturningDirectory() throws -> (store: AppStore, directory: URL) {
        let directory = try makeDirectory("store")
        let suiteName = "heykinn-split-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
        return (store, directory)
    }

    private func catalog(at directory: URL) throws -> CatalogStore {
        try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    // MARK: - Migrating a pre-split catalog

    /// A catalog written before the split carries the copy count and
    /// destinations on the source row. They are read straight across into a
    /// group — same numbers, same devices, nothing guessed.
    func testAPreSplitCatalogsPolicyMovesIntoAGroup() throws {
        let directory = try makeDirectory("store")
        let path = directory.appendingPathComponent("catalog.sqlite").path
        let sourceID = UUID()
        let driveA = UUID(), driveB = UUID()
        let assetIDs = (0..<3).map { _ in UUID() }

        do {
            let old = try CatalogStore(databasePath: path)
            // A source row the way the old schema held one, written straight to
            // SQL because the type no longer has these fields to set.
            try old.database.run("""
            INSERT INTO sources (id, kind, label, origin_path, desired_copies, destination_ids_json, added_at)
            VALUES (?,?,?,?,?,?,?);
            """, [
                .text(sourceID.uuidString), .text("folder"), .text("Scans"),
                .text("/Users/someone/Scans"), .int(3),
                .text("[\"\(driveA.uuidString)\",\"\(driveB.uuidString)\"]"),
                .real(Date().timeIntervalSince1970),
            ])
            for assetID in assetIDs {
                try old.upsertAsset(asset(id: assetID))
                try old.assignSource(sourceID, toAssets: [assetID])
            }
            // Undo the migration the open above already ran, so this test sees
            // the pre-split shape it means to.
            try old.database.run("DELETE FROM storage_groups;", [])
            try old.database.run("UPDATE assets SET storage_group_id = NULL;", [])
        }

        let migrated = try CatalogStore(databasePath: path)
        let groups = try migrated.fetchStorageGroups()

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.desiredCopies, 3, "the number came straight across")
        XCTAssertEqual(group.destinationTargetIDs, [driveA, driveB], "and the devices, in order")
        XCTAssertEqual(group.label, "Scans")

        let membership = try migrated.fetchStorageGroupIDsByAsset()
        XCTAssertEqual(membership.count, assetIDs.count)
        for assetID in assetIDs { XCTAssertEqual(membership[assetID], group.id) }

        // The source keeps its history and loses its opinion.
        let source = try XCTUnwrap(try migrated.fetchSources().first)
        XCTAssertEqual(source.id, sourceID)
        XCTAssertEqual(source.originPath, "/Users/someone/Scans")
        XCTAssertEqual(source.kind, .folder)
    }

    /// Opening the catalog again must not make a second group.
    func testTheMigrationIsIdempotent() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [], label: "Scans", desiredCopies: 1, destinationTargetIDs: [driveID]
        ))
        let before = try catalog(at: directory).fetchStorageGroups().count

        _ = try catalog(at: directory)
        _ = try catalog(at: directory)

        XCTAssertEqual(try catalog(at: directory).fetchStorageGroups().count, before)
    }

    // MARK: - The two halves are independent

    /// The point of the split: editing where photos are kept does not touch the
    /// record of where they came from.
    func testChangingPolicyLeavesProvenanceAlone() async throws {
        let (store, _) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans", desiredCopies: 1, destinationTargetIDs: [driveID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }

        let subject = try XCTUnwrap(store.assets.first)
        let source = try XCTUnwrap(store.sources.first { $0.label == "Scans" })
        let group = try XCTUnwrap(store.storageGroup(forAsset: subject.id))
        XCTAssertNotEqual(source.id, group.id, "two rows, not one wearing two hats")

        store.applyStorageGroupSettings(group, desiredCopies: 2, destinations: [driveID])

        let sourceAfter = try XCTUnwrap(store.sourcesByID[source.id])
        XCTAssertEqual(sourceAfter.originPath, source.originPath, "history is untouched")
        XCTAssertEqual(sourceAfter.label, source.label)
        XCTAssertEqual(store.sourceIDByAsset[subject.id], source.id)
        XCTAssertEqual(store.desiredCopies(forAsset: subject.id), 2, "policy moved")
    }

    /// A group made by hand has policy and no provenance to borrow, which is
    /// the case the single-row model could not represent.
    func testAGroupCanExistWithNoProvenance() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let driveID = UUID()
        let orphanAsset = UUID()

        let side = try catalog(at: directory)
        let group = StorageGroup(
            id: UUID(), label: "Ten I picked out", desiredCopies: 2,
            destinationTargetIDs: [driveID], createdAt: Date()
        )
        try side.upsertStorageGroup(group)
        try side.upsertAsset(asset(id: orphanAsset))
        try side.assignStorageGroup(group.id, toAssets: [orphanAsset])
        store.loadAll()

        XCTAssertNil(store.sourceIDByAsset[orphanAsset], "it came from no import")
        XCTAssertEqual(store.storageGroupIDByAsset[orphanAsset], group.id)
        XCTAssertEqual(store.desiredCopies(forAsset: orphanAsset), 2)
        XCTAssertEqual(store.placementPolicy(forAsset: orphanAsset).destinations, [driveID])
    }

    /// Membership stays a strict partition: putting an asset in a group takes
    /// it out of whatever it was in.
    func testAnAssetIsInExactlyOneGroup() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let assetID = UUID()
        try side.upsertAsset(asset(id: assetID))

        let first = StorageGroup(
            id: UUID(), label: "A", desiredCopies: 1,
            destinationTargetIDs: [], createdAt: Date()
        )
        let second = StorageGroup(
            id: UUID(), label: "B", desiredCopies: 2,
            destinationTargetIDs: [], createdAt: Date()
        )
        try side.upsertStorageGroup(first)
        try side.upsertStorageGroup(second)
        try side.assignStorageGroup(first.id, toAssets: [assetID])
        try side.assignStorageGroup(second.id, toAssets: [assetID])
        store.loadAll()

        XCTAssertEqual(store.storageGroupIDByAsset[assetID], second.id)
        XCTAssertEqual(store.desiredCopies(forAsset: assetID), 2)
    }

    /// Deleting a group leaves its photos, which fall back to the defaults
    /// rather than to nothing. Forgetting a setting must never be the same
    /// action as forgetting the photos.
    func testDeletingAGroupKeepsItsPhotos() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let assetID = UUID()
        let group = StorageGroup(
            id: UUID(), label: "Doomed", desiredCopies: 3,
            destinationTargetIDs: [], createdAt: Date()
        )
        try side.upsertAsset(asset(id: assetID))
        try side.upsertStorageGroup(group)
        try side.assignStorageGroup(group.id, toAssets: [assetID])
        store.loadAll()
        XCTAssertEqual(store.desiredCopies(forAsset: assetID), 3)

        try side.deleteStorageGroup(id: group.id)
        store.loadAll()

        XCTAssertEqual(store.assets.count, 1, "the photo is still here")
        XCTAssertNil(store.storageGroupIDByAsset[assetID])
        XCTAssertEqual(
            store.desiredCopies(forAsset: assetID),
            store.newSourceDefaults.desiredCopies,
            "and falls back rather than being placed nowhere"
        )
    }

    // MARK: - Fixtures

    private func asset(id: UUID) -> Asset {
        Asset(
            id: id, kind: .photo, originalFilename: "p.jpg", importOrigin: .localFolder,
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
