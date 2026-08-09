import XCTest
@testable import HeykinnClicks

/// How many places hold each photo — a question about photos, which no
/// drive-shaped count could answer.
@MainActor
final class CopyCoverageTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []; suiteNames = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-cov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func makeStore(in directory: URL) -> AppStore {
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
    }

    private func asset(_ name: String) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    private func hold(_ catalog: CatalogStore, _ assetID: UUID, on drive: UUID, path: String) throws {
        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: assetID, targetID: drive, state: .present,
            relativePath: path, lastVerifiedAt: Date()
        ))
    }

    /// The distribution, not the total. "49,278 copies" is the same number
    /// whether every photo has two or half have three and the rest have one,
    /// so a total cannot say whether an archive is safe.
    func testCoverageCountsPhotosByHowManyDrivesHoldThem() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let a = asset("safe.jpg"), b = asset("alone.jpg")
        let driveA = UUID(), driveB = UUID()
        for one in [a, b] { try catalog.upsertAsset(one) }
        try hold(catalog, a.id, on: driveA, path: "aa/safe.jpg")
        try hold(catalog, a.id, on: driveB, path: "aa/safe.jpg")
        try hold(catalog, b.id, on: driveA, path: "bb/alone.jpg")

        let store = makeStore(in: directory)
        XCTAssertEqual(store.copyCoverage, [2: 1, 1: 1])
        XCTAssertEqual(store.leastCopiesAnywhere, 1, "which is what the headline reports")
    }

    /// Two copies that one action takes.
    ///
    /// A photo counted inside a Takeout file on both drives is not short of
    /// anything, and every check the app runs says it is fine. But both copies
    /// are the *same* zip, so deleting that file on each drive loses it. This
    /// is the count that says so; nothing else can see it.
    func testPhotosWithNoCopyOutsideATakeoutFileAreCounted() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let inZip = asset("in-zip.jpg"), copiedOut = asset("copied-out.jpg")
        let driveA = UUID(), driveB = UUID()
        for one in [inZip, copiedOut] { try catalog.upsertAsset(one) }

        let part = ReplicationService.archivePartPrefix + "takeout-2026-001"
        try hold(catalog, inZip.id, on: driveA, path: part)
        try hold(catalog, inZip.id, on: driveB, path: part)
        // The other one is inside a zip on one drive and a real file on the
        // other, so a deletion of the zips still leaves it a copy.
        try hold(catalog, copiedOut.id, on: driveA, path: part)
        try hold(catalog, copiedOut.id, on: driveB, path: "cc/copied-out.jpg")

        let store = makeStore(in: directory)
        XCTAssertEqual(store.copyCoverage, [2: 2], "both look equally safe by copy count")
        XCTAssertEqual(store.archiveBackedOnlyCount, 1, "and only one of them really is")
    }

    /// An empty archive has no answer, and must not invent a reassuring one.
    func testAnEmptyArchiveReportsNothing() throws {
        let store = makeStore(in: try makeDirectory())
        XCTAssertTrue(store.copyCoverage.isEmpty)
        XCTAssertNil(store.leastCopiesAnywhere)
        XCTAssertEqual(store.archiveBackedOnlyCount, 0)
    }
}

/// What forgetting a download would actually cost.
extension CopyCoverageTests {

    /// "Stop tracking this download (deletes nothing)" was true about files and
    /// badly wrong about photos. The app counts photos *inside* the Takeout
    /// files rather than copying them out, so on a real archive that button
    /// would have dropped 18,136 photos to no copy at all while promising the
    /// opposite.
    func testPhotosHeldOnlyInsideADownloadAreCounted() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let stranded = asset("only-in-zip.jpg"), alsoOut = asset("also-copied.jpg")
        let driveA = UUID(), driveB = UUID()
        for one in [stranded, alsoOut] { try catalog.upsertAsset(one) }

        // The real shapes, which are two different strings: the part is
        // recorded under its file name and the set id is the token inside it.
        // The first version of this test built the path out of the set id, so
        // it agreed with a lookup that matched nothing on a real archive — and
        // the dialog it backs said 18,136 photos could be forgotten safely.
        let set = "20260710T081521Z-2"
        try catalog.upsertTakeoutArchive(archive(named: "takeout-\(set)-001.zip", set: set))
        let part = ReplicationService.archivePartPrefix + "takeout-\(set)-001.zip"
        try hold(catalog, stranded.id, on: driveA, path: part)
        try hold(catalog, stranded.id, on: driveB, path: part)
        try hold(catalog, alsoOut.id, on: driveA, path: part)
        try hold(catalog, alsoOut.id, on: driveB, path: "cc/also-copied.jpg")

        let store = makeStore(in: directory)
        XCTAssertEqual(store.photosHeldOnlyBy(exportSetID: set), 1)
        XCTAssertEqual(
            store.photosHeldOnlyBy(exportSetID: "takeout-\(set)"), 0,
            "and a set id nothing is filed under finds nothing, rather than matching by luck"
        )
    }

    /// A download every photo of which is also copied out costs nothing to
    /// forget, and must not be made to sound like it does.
    func testADownloadNothingDependsOnStrandsNobody() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let one = asset("copied.jpg")
        try catalog.upsertAsset(one)
        try catalog.upsertTakeoutArchive(archive(named: "takeout-set-001.zip", set: "set"))
        try hold(catalog, one.id, on: UUID(),
                 path: ReplicationService.archivePartPrefix + "takeout-set-001.zip")
        try hold(catalog, one.id, on: UUID(), path: "cc/copied.jpg")

        let store = makeStore(in: directory)
        XCTAssertEqual(store.photosHeldOnlyBy(exportSetID: "set"), 0)
    }

    private func archive(named name: String, set: String) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(), path: "/Volumes/Drive/\(name)", kind: .zip, sizeBytes: 1,
            targetID: nil, discoveredAt: Date(), importedAt: Date(), importBatchID: nil,
            importedAssetCount: 0, skippedDuplicateCount: 0, note: nil,
            exportSetID: set, partNumber: 1
        )
    }
}

/// How a set's photos physically exist — the fact a copy count cannot carry.
extension CopyCoverageTests {

    /// Two sets asking for the same copies on the same drives can be in very
    /// different situations, and the row said the same sentence for both.
    ///
    /// On a real archive all three read "two copies on Owner's Back and My
    /// Passport" while one was twelve real files and another had 17,964 photos
    /// living inside .zip files.
    func testStorageFormSplitsCountedInsideADownloadFromCopiedOut() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let groupID = UUID()
        try catalog.upsertStorageGroup(StorageGroup(
            id: groupID, label: "Takeout", desiredCopies: 2,
            destinationTargetIDs: [], destinationMode: .automatic, createdAt: Date()
        ))
        let part = ReplicationService.archivePartPrefix + "takeout-set-001.zip"
        let driveA = UUID(), driveB = UUID()

        // One held only by the download, one also written out, one plain file.
        let onlyZip = asset("in-zip.jpg"), both = asset("both.jpg"), plain = asset("plain.jpg")
        for one in [onlyZip, both, plain] { try catalog.upsertAsset(one) }
        try catalog.assignStorageGroup(groupID, toAssets: [onlyZip.id, both.id, plain.id])
        try hold(catalog, onlyZip.id, on: driveA, path: part)
        try hold(catalog, both.id, on: driveA, path: part)
        try hold(catalog, both.id, on: driveB, path: "bb/both.jpg")
        try hold(catalog, plain.id, on: driveA, path: "pp/plain.jpg")

        let store = makeStore(in: directory)
        let form = store.storageForm(forStorageGroup: groupID)
        XCTAssertEqual(form.insideDownload, 2)
        XCTAssertEqual(form.copiedOut, 2)
        XCTAssertEqual(
            form.onlyInsideDownload, 1,
            "and only the one with no file of its own is at the download's mercy"
        )
        // The two the screen draws are `onlyInsideDownload` and `copiedOut`,
        // and they have to be exclusive or the bar claims a set is bigger than
        // it is. `insideDownload` overlaps `copiedOut` by design — a photo can
        // be counted inside a download on one drive and written out on another
        // — which is what made the first version print 21,117 and 5,658 under
        // a total of 21,117.
        XCTAssertEqual(
            form.onlyInsideDownload + form.copiedOut, 3,
            "the split adds up to the photos it describes"
        )
        XCTAssertGreaterThan(
            form.insideDownload + form.copiedOut, 3,
            "which the other pair does not, because they overlap"
        )
    }

    /// Counted in photos, like every other number the app shows. A Live Photo
    /// is one photo though it is a still and a movie on disk, and counting
    /// files here printed "24,355 counted inside a Google download" directly
    /// under "21,117 photos" — the same screen contradicting itself.
    func testStorageFormCountsPhotosNotFiles() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let groupID = UUID()
        try catalog.upsertStorageGroup(StorageGroup(
            id: groupID, label: "Live", desiredCopies: 1,
            destinationTargetIDs: [], destinationMode: .automatic, createdAt: Date()
        ))
        let still = asset("live.heic")
        var motion = asset("live.mov")
        // What makes a row a motion part: it names the still it belongs to.
        motion.livePhotoStillID = still.id
        try catalog.upsertAsset(still)
        try catalog.upsertAsset(motion)
        try catalog.assignStorageGroup(groupID, toAssets: [still.id, motion.id])

        let drive = UUID()
        let part = ReplicationService.archivePartPrefix + "takeout-set-001.zip"
        try hold(catalog, still.id, on: drive, path: part)
        try hold(catalog, motion.id, on: drive, path: part)

        let store = makeStore(in: directory)
        XCTAssertEqual(
            store.storageForm(forStorageGroup: groupID).insideDownload, 1,
            "one photo, though two files back it"
        )
    }

    /// A set backed by a download can show that download's parts — which is the
    /// only place that grid has ever belonged. It was on the import card
    /// because nowhere else existed.
    func testASetNamesTheDownloadsBackingIt() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let groupID = UUID()
        try catalog.upsertStorageGroup(StorageGroup(
            id: groupID, label: "Photos library", desiredCopies: 2,
            destinationTargetIDs: [], destinationMode: .automatic, createdAt: Date()
        ))
        try catalog.upsertTakeoutArchive(archive(named: "takeout-abc-001.zip", set: "abc"))
        let one = asset("dedup.jpg")
        try catalog.upsertAsset(one)
        try catalog.assignStorageGroup(groupID, toAssets: [one.id])
        try hold(catalog, one.id, on: UUID(),
                 path: ReplicationService.archivePartPrefix + "takeout-abc-001.zip")

        let store = makeStore(in: directory)
        // A set named after the Photos library, held by a Google download —
        // the real case, produced by the same picture arriving twice.
        XCTAssertEqual(store.exportSetIDs(backingStorageGroup: groupID), ["abc"])
    }
}
