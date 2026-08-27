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
        XCTAssertEqual(source.id, group.id, "a source is its own first group")

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

    // MARK: - Managing groups

    /// The thing the single-row model could not do: a group with no import
    /// behind it.
    func testAGroupCanBeMadeFromNothing() throws {
        let (store, _) = try makeStoreReturningDirectory()
        let driveID = UUID()

        let group = try XCTUnwrap(store.createStorageGroup(
            label: "Cold storage",
            from: StorageGroup.Defaults(desiredCopies: 1, destinationTargetIDs: [driveID])
        ))

        XCTAssertEqual(store.storageGroupsByID[group.id]?.label, "Cold storage")
        XCTAssertEqual(group.desiredCopies, 1)
        XCTAssertEqual(store.photoCountByStorageGroup[group.id] ?? 0, 0, "and it starts empty")
    }

    /// Moving photos between groups changes what they owe, and takes them out
    /// of where they were — membership is a partition.
    func testMovingPhotosIntoAGroupChangesWhatTheyOwe() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let driveID = UUID()

        let origin = try XCTUnwrap(store.createStorageGroup(
            label: "Everything",
            from: StorageGroup.Defaults(desiredCopies: 1, destinationTargetIDs: [driveID])
        ))
        let cold = try XCTUnwrap(store.createStorageGroup(
            label: "Cold storage",
            from: StorageGroup.Defaults(desiredCopies: 3, destinationTargetIDs: [driveID])
        ))

        let moving = (0..<2).map { _ in UUID() }
        let staying = UUID()
        for id in moving + [staying] {
            try side.upsertAsset(asset(id: id))
            try side.assignStorageGroup(origin.id, toAssets: [id])
        }
        store.loadAll()

        XCTAssertEqual(store.moveToStorageGroup(cold.id, assetIDs: moving), 2)

        for id in moving {
            XCTAssertEqual(store.storageGroupIDByAsset[id], cold.id)
            XCTAssertEqual(store.desiredCopies(forAsset: id), 3)
        }
        XCTAssertEqual(store.storageGroupIDByAsset[staying], origin.id, "the rest stayed put")
        XCTAssertEqual(store.desiredCopies(forAsset: staying), 1)
        XCTAssertEqual(store.photoCountByStorageGroup[cold.id], 2)
        XCTAssertEqual(store.photoCountByStorageGroup[origin.id], 1)
    }

    /// Moving is idempotent: photos already in the group are not moved again.
    func testMovingPhotosAlreadyInTheGroupDoesNothing() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let group = try XCTUnwrap(store.createStorageGroup(label: "Only one"))
        let assetID = UUID()
        try side.upsertAsset(asset(id: assetID))
        try side.assignStorageGroup(group.id, toAssets: [assetID])
        store.loadAll()

        XCTAssertEqual(store.moveToStorageGroup(group.id, assetIDs: [assetID]), 0)
    }

    /// A group holding photos is not deleted out from under them.
    func testAGroupHoldingPhotosIsNotDeletedWithoutSomewhereToPutThem() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let group = try XCTUnwrap(store.createStorageGroup(label: "Busy"))
        let assetID = UUID()
        try side.upsertAsset(asset(id: assetID))
        try side.assignStorageGroup(group.id, toAssets: [assetID])
        store.loadAll()

        store.deleteStorageGroup(group.id)

        XCTAssertNotNil(store.storageGroupsByID[group.id], "refused")
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.storageGroupIDByAsset[assetID], group.id)
    }

    /// With somewhere named, the photos go there and the group goes.
    func testAGroupIsDeletedOnceItsPhotosHaveSomewhereToGo() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let doomed = try XCTUnwrap(store.createStorageGroup(label: "Doomed"))
        let keeper = try XCTUnwrap(store.createStorageGroup(label: "Keeper"))
        let assetID = UUID()
        try side.upsertAsset(asset(id: assetID))
        try side.assignStorageGroup(doomed.id, toAssets: [assetID])
        store.loadAll()

        store.deleteStorageGroup(doomed.id, movingPhotosTo: keeper.id)

        XCTAssertNil(store.storageGroupsByID[doomed.id])
        XCTAssertEqual(store.storageGroupIDByAsset[assetID], keeper.id)
        XCTAssertEqual(store.assets.count, 1, "the photo is still here")
    }

    /// An empty group goes without ceremony.
    func testAnEmptyGroupIsDeletedOutright() throws {
        let (store, _) = try makeStoreReturningDirectory()
        let group = try XCTUnwrap(store.createStorageGroup(label: "Spare"))

        store.deleteStorageGroup(group.id)

        XCTAssertNil(store.storageGroupsByID[group.id])
    }

    func testRenamingAGroupKeepsItsSettings() throws {
        let (store, _) = try makeStoreReturningDirectory()
        let driveID = UUID()
        let group = try XCTUnwrap(store.createStorageGroup(
            label: "Old name",
            from: StorageGroup.Defaults(desiredCopies: 2, destinationTargetIDs: [driveID])
        ))

        store.renameStorageGroup(group.id, to: "New name")

        let renamed = try XCTUnwrap(store.storageGroupsByID[group.id])
        XCTAssertEqual(renamed.label, "New name")
        XCTAssertEqual(renamed.desiredCopies, 2)
        XCTAssertEqual(renamed.destinationTargetIDs, [driveID])
    }

    // MARK: - A source does not own its group

    /// A group holding two exports' photos is reported as shared by both, and
    /// claimed as neither's own.
    ///
    /// While the source's card could edit, this was the shape that broke it:
    /// both exports resolved to the shared group, so "change where export A is
    /// kept" set export B's photos to 9 copies. The card only reports now, but
    /// the distinction still has to be drawn — it is what the card says.
    func testAGroupHoldingTwoExportsIsClaimedByNeither() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)

        let a = try XCTUnwrap(store.sourceForExportSet("A", label: "Export A"))
        let b = try XCTUnwrap(store.sourceForExportSet("B", label: "Export B"))
        let shared = try XCTUnwrap(store.createStorageGroup(label: "Cold storage"))

        let fromA = UUID(), fromB = UUID()
        for (assetID, sourceID) in [(fromA, a.source.id), (fromB, b.source.id)] {
            try side.upsertAsset(asset(id: assetID))
            try side.assignSource(sourceID, toAssets: [assetID])
        }
        store.loadAll()
        _ = store.moveToStorageGroup(shared.id, assetIDs: [fromA, fromB])

        // Neither card may offer the shortcut, and each says whose company its
        // photos are in.
        for setID in ["A", "B"] {
            guard case .shared(let group, let otherPhotos) = store.groupPlacement(forExportSet: setID) else {
                return XCTFail("\(setID) should report a shared group, got \(store.groupPlacement(forExportSet: setID))")
            }
            XCTAssertEqual(group.id, shared.id)
            XCTAssertEqual(otherPhotos, 1, "one photo in the group is not this export's")
            XCTAssertNil(store.groupPlacement(forExportSet: setID).soleGroup)
        }
    }

    /// A source whose photos are split across groups has no single setting, so
    /// its card must not present one.
    func testASourceSplitAcrossGroupsReportsTheSplit() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let source = try XCTUnwrap(store.sourceForExportSet("SET", label: "Export"))
        let cold = try XCTUnwrap(store.createStorageGroup(label: "Cold storage"))

        let staying = UUID(), leaving = UUID()
        for assetID in [staying, leaving] {
            try side.upsertAsset(asset(id: assetID))
            try side.assignSource(source.source.id, toAssets: [assetID])
            try side.assignStorageGroup(source.group.id, toAssets: [assetID])
        }
        store.loadAll()
        _ = store.moveToStorageGroup(cold.id, assetIDs: [leaving])

        guard case .split(let groups, let photoCount) = store.groupPlacement(forExportSet: "SET") else {
            return XCTFail("expected a split, got \(store.groupPlacement(forExportSet: "SET"))")
        }
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(photoCount, 2)
        XCTAssertNil(store.groupPlacement(forExportSet: "SET").soleGroup)
    }

    /// The ordinary case: one group, nothing else in it, so the card can state
    /// its settings as the source's own.
    func testASourceWithAGroupOfItsOwnReportsItAsSole() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let source = try XCTUnwrap(store.sourceForExportSet("SET", label: "Export"))

        let assetID = UUID()
        try side.upsertAsset(asset(id: assetID))
        try side.assignSource(source.source.id, toAssets: [assetID])
        try side.assignStorageGroup(source.group.id, toAssets: [assetID])
        store.loadAll()

        let editable = try XCTUnwrap(store.groupPlacement(forExportSet: "SET").soleGroup)
        XCTAssertEqual(editable.id, source.group.id)
    }

    /// And editing the group the source's photos are in never reaches photos
    /// that belong to another source — the guarantee under all of the above.
    func testEditingAGroupOnlyChangesThePhotosInIt() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let side = try catalog(at: directory)
        let driveID = UUID()

        let staying = UUID(), leaving = UUID()
        let source = try XCTUnwrap(store.sourceForExportSet("SET", label: "Export"))
        for assetID in [staying, leaving] {
            try side.upsertAsset(asset(id: assetID))
            try side.assignSource(source.source.id, toAssets: [assetID])
            try side.assignStorageGroup(source.group.id, toAssets: [assetID])
        }
        store.loadAll()
        let cold = try XCTUnwrap(store.createStorageGroup(
            label: "Cold storage",
            from: StorageGroup.Defaults(desiredCopies: 1, destinationTargetIDs: [driveID])
        ))
        _ = store.moveToStorageGroup(cold.id, assetIDs: [leaving])

        let origin = try XCTUnwrap(store.storageGroupsByID[source.group.id])
        store.applyStorageGroupSettings(origin, desiredCopies: 3, destinations: [driveID])

        XCTAssertEqual(store.desiredCopies(forAsset: staying), 3)
        XCTAssertEqual(store.desiredCopies(forAsset: leaving), 1, "the photo that left is untouched")
    }

    // MARK: - Nothing but a group carries policy

    /// An `Asset` has no copies and no destinations of its own. Policy is a
    /// group's, and only a group's — per-asset storage would make "what does
    /// this photo want" answerable one way per photograph.
    func testAnImportThatNamesNoGroupIsSurfacedRatherThanSilentlyDefaulted() async throws {
        let (store, _) = try makeStoreReturningDirectory()
        let folder = try makeDirectory("photos")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("p.jpg"))

        // The path connect-time adoption uses: no source flow, so nothing names
        // a group for what it brings in.
        store.importFolders([folder])
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let subject = try XCTUnwrap(store.assets.first)

        XCTAssertNil(store.storageGroupIDByAsset[subject.id])
        XCTAssertEqual(store.ungroupedAssetIDs, [subject.id], "and it is reported, not hidden")
        XCTAssertEqual(
            store.desiredCopies(forAsset: subject.id),
            store.newSourceDefaults.desiredCopies,
            "it still owes copies — placing nothing would stop protecting it"
        )
    }

    /// And putting them in a group clears the state and makes the group the
    /// answer.
    func testPuttingStrandedPhotosInAGroupClearsTheState() async throws {
        let (store, _) = try makeStoreReturningDirectory()
        let folder = try makeDirectory("photos")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("p.jpg"))
        store.importFolders([folder])
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }

        let driveID = UUID()
        let group = try XCTUnwrap(store.createStorageGroup(
            label: "Everything else",
            from: StorageGroup.Defaults(desiredCopies: 3, destinationTargetIDs: [driveID])
        ))
        _ = store.moveToStorageGroup(group.id, assetIDs: store.ungroupedAssetIDs)

        XCTAssertTrue(store.ungroupedAssetIDs.isEmpty)
        let subject = try XCTUnwrap(store.assets.first)
        XCTAssertEqual(store.desiredCopies(forAsset: subject.id), 3)
    }

    // MARK: - A source is its own first group

    /// Every route that makes a source makes its first group with the same id.
    /// It was true of the migration and of exports and coincidental for
    /// folders, which is the worst of the three states to be in.
    func testEveryRouteGivesASourceItsOwnIdForItsFirstGroup() async throws {
        let (store, _) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        // Route 1: a folder added through the sheet.
        let folder = try makeDirectory("scans")
        try Data("a photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        store.confirmAddingSource(AppStore.PendingSourceSetup(
            urls: [folder], label: "Scans", desiredCopies: 1, destinationTargetIDs: [driveID]
        ))
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let folderSource = try XCTUnwrap(store.sources.first { $0.label == "Scans" })
        XCTAssertNotNil(store.storageGroupsByID[folderSource.id])

        // Route 2: an export.
        let export = try XCTUnwrap(store.sourceForExportSet("SET", label: "Export"))
        XCTAssertEqual(export.source.id, export.group.id)
    }

    /// The group list says nothing about provenance while the group still *is*
    /// the import it was born as — an echo of its own name reads as two things
    /// that happen to agree rather than one thing.
    func testProvenanceIsOnlyReportedWhenItAddsSomething() async throws {
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
        let group = try XCTUnwrap(store.storageGroups.first { $0.label == "Scans" })

        XCTAssertNil(
            store.provenanceSummary(forStorageGroup: group.id),
            "still the import it was born as"
        )

        // Rename it and the line earns its place: the name no longer says
        // where these came from.
        store.renameStorageGroup(group.id, to: "Cold storage")
        XCTAssertEqual(store.provenanceSummary(forStorageGroup: group.id), "from Scans")

        // A group holding photos from nowhere in particular says so.
        let side = try catalog(at: directory)
        let orphan = UUID()
        try side.upsertAsset(asset(id: orphan))
        store.loadAll()
        let made = try XCTUnwrap(store.createStorageGroup(label: "Hand made"))
        _ = store.moveToStorageGroup(made.id, assetIDs: [orphan])
        XCTAssertEqual(
            store.provenanceSummary(forStorageGroup: made.id),
            "from photos with no import recorded"
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
