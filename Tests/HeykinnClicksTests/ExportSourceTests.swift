import XCTest
@testable import HeykinnClicks

/// A Google export is a source like any other: it carries its own copy count
/// and its own named devices, and the card that shows it can change them.
///
/// Until this, only folders had that. An export's photos answered to nobody —
/// they fell through to the add-sheet defaults, and there was nothing for
/// "change where these are kept" to change.
@MainActor
final class ExportSourceTests: XCTestCase {

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
        let suiteName = "heykinn-export-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
        return (store, directory)
    }

    /// A second connection onto the same catalog, for seeding rows the way an
    /// earlier version of the app would have left them.
    private func catalog(at directory: URL) throws -> CatalogStore {
        try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    /// One row per export set, found again rather than made twice — its zips
    /// and the folders they unpack into are one source, not two.
    func testAnExportGetsOneSourceAndKeepsIt() throws {
        let store = try makeStore()

        let first = try XCTUnwrap(store.sourceForExportSet("20260710T081521Z", label: "Export"))
        let again = try XCTUnwrap(store.sourceForExportSet("20260710T081521Z", label: "Export"))

        XCTAssertEqual(first.source.id, again.source.id)
        XCTAssertEqual(first.group.id, again.group.id, "and one group, not a second every time")
        XCTAssertEqual(store.sources.filter { $0.exportSetID == "20260710T081521Z" }.count, 1)
        XCTAssertEqual(first.source.kind, .takeoutExport)
    }

    /// Two exports on one device are entitled to different answers — the thing
    /// a single archive-wide number could never express.
    func testTwoExportsCanBeKeptDifferently() throws {
        let store = try makeStore()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let old = try XCTUnwrap(store.sourceForExportSet("20240101T000000Z", label: "Old export"))
        let new = try XCTUnwrap(store.sourceForExportSet("20260710T081521Z", label: "New export"))

        store.applyStorageGroupSettings(old.group, desiredCopies: 1, destinations: [driveID])
        store.applyStorageGroupSettings(new.group, desiredCopies: 2, destinations: [driveID])

        XCTAssertEqual(store.copiesRequiredByExportSet["20240101T000000Z"], 1)
        XCTAssertEqual(store.copiesRequiredByExportSet["20260710T081521Z"], 2)
    }

    /// And the plan reads those numbers per set rather than one figure for all
    /// of them.
    func testThePlanGradesEachSetAgainstItsOwnNumber() {
        let driveA = UUID(), driveB = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(setID: "modest", part: 1, drive: driveA),
                archive(setID: "demanding", part: 1, drive: driveA),
            ],
            managedTargetIDs: [driveA, driveB],
            copiesRequiredBySetID: ["modest": 1, "demanding": 2]
        )

        let modest = try? XCTUnwrap(plan.parts.first { $0.setID == "modest" })
        let demanding = try? XCTUnwrap(plan.parts.first { $0.setID == "demanding" })

        XCTAssertEqual(plan.redundancy(of: modest!), .singleCopyByPolicy)
        XCTAssertTrue(plan.redundancy(of: modest!).meetsPolicy, "one copy is what it asked for")
        XCTAssertEqual(plan.redundancy(of: demanding!), .singleCopy)
        XCTAssertFalse(plan.redundancy(of: demanding!).meetsPolicy)
    }

    /// A set nobody has been asked about falls back to the defaults rather than
    /// to nothing.
    func testAnUnknownSetFallsBackToTheDefault() {
        let plan = ArchiveReplicationPlan(
            parts: [], managedTargetIDs: [],
            copiesRequiredBySetID: ["known": 3], defaultCopiesRequired: 2
        )
        XCTAssertEqual(plan.copiesRequired(forSet: "known"), 3)
        XCTAssertEqual(plan.copiesRequired(forSet: "never seen"), 2)
    }

    /// The settings survive a relaunch, which is the whole point of them being
    /// a row rather than a field on a view.
    func testAnExportsSettingsAreStored() throws {
        let directory = try makeDirectory("store")
        let suiteName = "heykinn-export-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        func open() -> AppStore {
            AppStore(environment: AppEnvironment(
                appDirectory: directory, defaults: defaults, runsBackgroundWork: false
            ))
        }

        let store = open()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")
        let made = try XCTUnwrap(store.sourceForExportSet("20260710T081521Z", label: "Export"))
        store.applyStorageGroupSettings(made.group, desiredCopies: 3, destinations: [driveID])

        let reopened = open()
        let source = try XCTUnwrap(
            reopened.sources.first { $0.exportSetID == "20260710T081521Z" }
        )
        XCTAssertEqual(source.kind, .takeoutExport)
        let restored = try XCTUnwrap(reopened.storageGroupsByID[made.group.id])
        XCTAssertEqual(restored.desiredCopies, 3)
        XCTAssertEqual(restored.destinationTargetIDs, [driveID])
        XCTAssertFalse(restored.isSatisfiable, "three copies, one device named")
    }

    // MARK: - An export is kept where its source says

    /// The bug behind "Not yet on the MacBook Pro" that no change to the
    /// export's settings could clear: parts were graded against every
    /// registered device, so a device that holds none of the zips — and was never
    /// asked to — owed a copy of all of them for ever.
    func testADeviceTheExportDoesNotNameIsNotOwedACopy() {
        let driveA = UUID(), driveB = UUID(), host = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(setID: "set", part: 1, drive: driveA),
                archive(setID: "set", part: 1, drive: driveB),
            ],
            managedTargetIDs: [driveA, driveB, host],
            destinationsBySetID: ["set": [driveA, driveB]],
            copiesRequiredBySetID: ["set": 2]
        )
        let part = plan.parts[0]

        XCTAssertEqual(plan.targetsNeedingACopy(of: part), [], "the device was never named")
        XCTAssertTrue(plan.redundancy(of: part).meetsPolicy)
        XCTAssertTrue(plan.partsNeedingWork.isEmpty)
        XCTAssertEqual(plan.bytesOutstanding, 0)
    }

    /// And a device the export *does* name is still owed one, so the fix does
    /// not simply silence the report.
    func testANamedDeviceIsStillOwedACopy() {
        let driveA = UUID(), driveB = UUID(), host = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(setID: "set", part: 1, drive: driveA)],
            managedTargetIDs: [driveA, driveB, host],
            destinationsBySetID: ["set": [driveA, driveB]],
            copiesRequiredBySetID: ["set": 2]
        )
        XCTAssertEqual(plan.targetsNeedingACopy(of: plan.parts[0]), [driveB])
        XCTAssertFalse(plan.redundancy(of: plan.parts[0]).meetsPolicy)
    }

    /// Nothing is transported to a device the export does not name either.
    func testNothingIsTransportedToADeviceTheExportDoesNotName() {
        let driveA = UUID(), host = UUID()
        let replication = ArchiveReplicationPlanner.plan(
            archives: [archive(setID: "set", part: 1, drive: driveA)],
            managedTargetIDs: [driveA, host],
            destinationsBySetID: ["set": [driveA]],
            copiesRequiredBySetID: ["set": 1]
        )
        let transfers = ExportPartTransferPlanner.plan(
            replication: replication,
            connectedDriveIDs: [driveA, host],
            heldParts: [],
            availableHoldingBytes: 500 * 1024 * 1024 * 1024
        )
        XCTAssertTrue(transfers.isEmpty)
        XCTAssertEqual(transfers.stranded, [])
    }

    /// A download nobody has been asked about still falls back to every device,
    /// which is the honest answer before it has a source.
    func testASetWithNoSourceFallsBackToEveryDevice() {
        let driveA = UUID(), driveB = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(setID: "set", part: 1, drive: driveA)],
            managedTargetIDs: [driveA, driveB]
        )
        XCTAssertEqual(plan.destinations(forSet: "set"), [driveA, driveB])
    }

    // MARK: - Linking older catalogs

    /// Two rows describing one export, asking for the same thing: one export is
    /// one source, and folding them together throws nothing away.
    func testDuplicateRecordsOfOneExportAreMergedWhenTheyAgree() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let (keeper, loser) = try seedSplitExport(
            store, at: directory, driveID: driveID, agreeing: true
        )

        store.linkExportSourcesToTheirSets()

        let exports = store.sources.filter { $0.kind == .takeoutExport }
        XCTAssertEqual(exports.count, 1, "one export, one source")
        let survivor = try XCTUnwrap(exports.first)
        XCTAssertEqual(survivor.exportSetID, "20260710T081521Z")
        XCTAssertEqual(survivor.id, keeper.id, "the row describing most of it is kept")
        XCTAssertNil(store.sourcesByID[loser.id])

        // And the photos that answered to the row that went now answer to the
        // one that stayed — never to nothing.
        for asset in store.assets {
            XCTAssertEqual(store.sourceIDByAsset[asset.id], survivor.id)
        }
    }

    /// The same shape, with the two rows asking for different things. Those are
    /// two decisions the user made; picking a winner would be the app quietly
    /// overruling one of them, so both are left alone.
    func testDuplicateRecordsThatDisagreeAreLeftAlone() throws {
        let (store, directory) = try makeStoreReturningDirectory()
        let mount = try makeDirectory("target")
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        let driveID = try XCTUnwrap(store.targets.first?.id, store.lastError ?? "")

        let (keeper, loser) = try seedSplitExport(
            store, at: directory, driveID: driveID, agreeing: false
        )

        store.linkExportSourcesToTheirSets()

        XCTAssertEqual(store.sources.filter { $0.kind == .takeoutExport }.count, 2)
        XCTAssertNotNil(store.sourcesByID[keeper.id])
        XCTAssertNotNil(store.sourcesByID[loser.id], "nothing was collapsed")
        let stillThere = try XCTUnwrap(store.storageGroupsByID[loser.id])
        XCTAssertEqual(stillThere.desiredCopies, 3, "and its settings are untouched")
    }

    /// Seeds an export recorded as two sources, the way a catalog written
    /// before exports carried a set id has it: two import batches under one
    /// export, a source each, neither linked.
    private func seedSplitExport(
        _ store: AppStore, at directory: URL, driveID: UUID, agreeing: Bool
    ) throws -> (keeper: PhotoArchiveSource, loser: PhotoArchiveSource) {
        let side = try catalog(at: directory)
        let bigBatch = UUID(), smallBatch = UUID()
        for (batchID, label) in [(bigBatch, "Recovered import"), (smallBatch, "Takeout export")] {
            try side.upsertImportBatch(ImportBatch(
                id: batchID, sourcePath: label, startedAt: Date(), completedAt: nil,
                importedCount: 0, duplicateCount: 0, failedCount: 0, origin: .googleTakeout
            ))
            try side.upsertTakeoutArchive(archive(
                setID: "20260710T081521Z", part: batchID == bigBatch ? 1 : 2,
                drive: driveID, batchID: batchID
            ))
        }

        func makeSource(_ label: String, copies: Int) throws -> PhotoArchiveSource {
            let source = PhotoArchiveSource(
                id: UUID(), kind: .takeoutExport, label: label, originPath: nil,
                exportSetID: nil, addedAt: Date()
            )
            try side.upsertSource(source)
            // Sharing the source's id, as the policy migration does, so the two
            // halves are findable from each other.
            try side.upsertStorageGroup(StorageGroup(
                id: source.id, label: label, desiredCopies: copies,
                destinationTargetIDs: [driveID], createdAt: Date()
            ))
            return source
        }
        let keeper = try makeSource("Recovered import", copies: 2)
        let loser = try makeSource("Takeout export", copies: agreeing ? 2 : 3)

        // Three photos under the keeper's batch, one under the other's, so the
        // keeper is the row describing most of the export.
        for (batchID, sourceID, count) in [(bigBatch, keeper.id, 3), (smallBatch, loser.id, 1)] {
            for _ in 0..<count {
                let asset = Asset(
                    id: UUID(), kind: .photo, originalFilename: "p.jpg",
                    importOrigin: .googleTakeout, captureDate: nil, importDate: Date(),
                    updatedDate: Date(), fileSize: 1, pixelWidth: nil, pixelHeight: nil,
                    contentHash: UUID().uuidString, residency: .local,
                    residencySource: .importDefault, presence: .localOnly,
                    stagingRelativePath: nil, importBatchID: batchID, exifSummary: [:]
                )
                try side.upsertAsset(asset)
                try side.assignSource(sourceID, toAssets: [asset.id])
                try side.assignStorageGroup(sourceID, toAssets: [asset.id])
            }
        }
        store.loadAll()
        return (keeper, loser)
    }

    // MARK: - Fixtures

    private func archive(
        setID: String, part: Int, drive: UUID, batchID: UUID? = nil
    ) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(),
            path: "/Volumes/Drive/takeout-\(setID)-\(part).zip",
            kind: .zip,
            sizeBytes: 1_000,
            targetID: drive,
            discoveredAt: Date(),
            importedAt: nil,
            importBatchID: batchID,
            importedAssetCount: 0,
            skippedDuplicateCount: 0,
            note: nil,
            exportSetID: setID,
            partNumber: part
        )
    }
}
