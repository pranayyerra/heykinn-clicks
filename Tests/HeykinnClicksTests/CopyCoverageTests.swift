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

    private func archive(
        named name: String, set: String, on targetID: UUID? = nil
    ) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(), path: "/Volumes/Drive/\(name)", kind: .zip, sizeBytes: 1,
            targetID: targetID, discoveredAt: Date(), importedAt: Date(), importBatchID: nil,
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

/// Where a group's photos are, device by device.
extension CopyCoverageTests {

    /// The archive-wide split cannot answer "where are the rest of them".
    ///
    /// It collapses across devices — a photo counts as copied-out if *any*
    /// drive has a real file — so a set whose two drives hold different mixes
    /// reads as one number. On a real archive one drive was carrying 91 more
    /// photos as their own files than the other, and nothing said so.
    func testHoldingsAreCountedPerDeviceNotAcrossThem() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let groupID = UUID(), driveA = UUID(), driveB = UUID()
        try catalog.upsertStorageGroup(StorageGroup(
            id: groupID, label: "Mixed", desiredCopies: 2,
            destinationTargetIDs: [driveA, driveB], destinationMode: .chosen, createdAt: Date()
        ))
        let one = asset("one.jpg"), two = asset("two.jpg")
        for a in [one, two] { try catalog.upsertAsset(a) }
        try catalog.assignStorageGroup(groupID, toAssets: [one.id, two.id])

        let part = ReplicationService.archivePartPrefix + "takeout-set-001.zip"
        // Drive A keeps both inside the download; drive B has written one out.
        try hold(catalog, one.id, on: driveA, path: part)
        try hold(catalog, two.id, on: driveA, path: part)
        try hold(catalog, one.id, on: driveB, path: part)
        try hold(catalog, two.id, on: driveB, path: "bb/two.jpg")

        let store = makeStore(in: directory)
        let holdings = store.holdings(forStorageGroup: groupID)
        XCTAssertEqual(holdings.map(\.targetID), [driveA, driveB], "named devices, in the named order")
        XCTAssertEqual(holdings.map(\.photos), [2, 2], "both hold everything")
        XCTAssertEqual(
            holdings.map(\.insideDownload), [2, 1],
            "and they do not hold it the same way, which is the point"
        )
    }

    /// A set with no download behind it still has to say where it is. This was
    /// the case that said nothing at all: no download section, and the copies
    /// line above is a policy, not an observation.
    func testASetOfPlainFilesStillSaysWhereItIs() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let groupID = UUID(), drive = UUID()
        try catalog.upsertStorageGroup(StorageGroup(
            id: groupID, label: "SampleBooks", desiredCopies: 1,
            destinationTargetIDs: [drive], destinationMode: .chosen, createdAt: Date()
        ))
        let book = asset("book1.png")
        try catalog.upsertAsset(book)
        try catalog.assignStorageGroup(groupID, toAssets: [book.id])
        try hold(catalog, book.id, on: drive, path: "8a/book1.png")

        let store = makeStore(in: directory)
        let holdings = store.holdings(forStorageGroup: groupID)
        XCTAssertEqual(holdings.count, 1)
        XCTAssertEqual(holdings.first?.photos, 1)
        XCTAssertEqual(holdings.first?.insideDownload, 0)
    }
}

/// Which forms count as "inside a download" — the question that had two
/// answers when there are four prefixes.
extension CopyCoverageTests {

    /// A `zipmember:` replica is a photo the app never wrote out: the bytes are
    /// inside the .zip and can only be reached by opening it. Reading it as a
    /// file of the photo's own under-reported the risk by 6,482 copies on a
    /// real archive, and told somebody 100 photos "would survive" when they
    /// were in the same .zip as the ones that would not.
    func testAFileInsideAZipIsNotAFileOfItsOwn() {
        XCTAssertTrue(ReplicationService.isInsideADownload(
            ReplicationService.zipMemberPrefix + "Takeout/part-001.zip!Google Photos/a.jpg"
        ))
        XCTAssertTrue(ReplicationService.isInsideADownload(
            ReplicationService.archivePartPrefix + "takeout-2026-001"
        ))
        // A user's own file sitting on the volume is a real file — it just is
        // not one the app put there, and a deleted .zip does not touch it.
        XCTAssertFalse(ReplicationService.isInsideADownload(
            ReplicationService.volumeBackedPrefix + "Photos/a.jpg"
        ))
        XCTAssertFalse(ReplicationService.isInsideADownload("8a/a.jpg"))
        XCTAssertFalse(ReplicationService.isInsideADownload(nil))
    }

    /// The count that decides whether the warning appears must use the same
    /// rule, or the screen and the sentence disagree.
    func testStorageFormCountsZipMembersAsInsideTheDownload() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let groupID = UUID(), drive = UUID()
        try catalog.upsertStorageGroup(StorageGroup(
            id: groupID, label: "Zips", desiredCopies: 1,
            destinationTargetIDs: [drive], destinationMode: .chosen, createdAt: Date()
        ))
        let member = asset("in-member.jpg")
        try catalog.upsertAsset(member)
        try catalog.assignStorageGroup(groupID, toAssets: [member.id])
        try hold(catalog, member.id, on: drive,
                 path: ReplicationService.zipMemberPrefix + "T/part-001.zip!a.jpg")

        let store = makeStore(in: directory)
        let form = store.storageForm(forStorageGroup: groupID)
        XCTAssertEqual(form.onlyInsideDownload, 1)
        XCTAssertEqual(form.copiedOut, 0, "it has no file of its own to survive on")
    }
}

/// This Mac is a place like any other, and the count says so.
extension CopyCoverageTests {

    /// Briefly it did not. Coverage was split — drives counted, the host
    /// discounted — on the reasoning that the host is "the machine the drives
    /// exist to survive". That did not survive checking: a copy on a
    /// registered host target is written to the same replica root, verified
    /// the same way, and removed only when a group stops naming it.
    /// `reclaimStaging` frees the staging area, never a target's replicas. If
    /// this Mac dies, a photo on it and on a drive still has the drive.
    func testTheHostCountsAsAPlace() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let drive = UUID(), mac = UUID()
        try catalog.upsertTarget(ReplicationTarget(
            id: drive, name: "Drive", kind: .externalVolume, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: "/Volumes/Drive", configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        try catalog.upsertTarget(ReplicationTarget(
            id: mac, name: "This Mac", kind: .hostDevice, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: directory.path, configuredPath: directory.path,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        let leaning = asset("on-a-drive-and-the-mac.jpg")
        try catalog.upsertAsset(leaning)
        try hold(catalog, leaning.id, on: drive, path: "aa/x.jpg")
        try hold(catalog, leaning.id, on: mac, path: "aa/x.jpg")

        let store = makeStore(in: directory)
        XCTAssertEqual(
            store.copyCoverage, [2: 1],
            "a drive and this Mac are two places, because they are two machines"
        )
    }

    /// A photo the host alone holds is in exactly one place — which is a real
    /// place, and also the thing the app should be uneasy about, since one
    /// place is one place whichever machine it is.
    func testAPhotoOnlyOnThisMacIsInOnePlace() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let mac = UUID()
        try catalog.upsertTarget(ReplicationTarget(
            id: mac, name: "This Mac", kind: .hostDevice, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: directory.path, configuredPath: directory.path,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        let stranded = asset("only-on-the-mac.jpg")
        try catalog.upsertAsset(stranded)
        try hold(catalog, stranded.id, on: mac, path: "aa/x.jpg")

        let store = makeStore(in: directory)
        XCTAssertEqual(store.copyCoverage, [1: 1])
        XCTAssertEqual(store.leastCopiesAnywhere, 1)
    }
}

/// The folder counts, which a rewrite silently zeroed.
extension CopyCoverageTests {

    /// Each folder says how many of the group's photos are in it. Precomputing
    /// the holdings dropped the line that set this, and every download folder
    /// read "0" beside a device reporting 21,117 photos — a number wrong in a
    /// way that looks like a real answer.
    func testEachFolderCarriesItsOwnCount() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let groupID = UUID(), drive = UUID()
        try catalog.upsertTarget(ReplicationTarget(
            id: drive, name: "Drive", kind: .externalVolume, volumeUUID: nil,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
            lastKnownPath: "/Volumes/Drive", configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        ))
        try catalog.upsertStorageGroup(StorageGroup(
            id: groupID, label: "Mixed", desiredCopies: 1,
            destinationTargetIDs: [drive], destinationMode: .chosen, createdAt: Date()
        ))
        try catalog.upsertTakeoutArchive(
            archive(named: "takeout-set-001.zip", set: "set", on: drive)
        )

        let inZip = asset("a.jpg"), ownFile = asset("b.jpg")
        for one in [inZip, ownFile] { try catalog.upsertAsset(one) }
        try catalog.assignStorageGroup(groupID, toAssets: [inZip.id, ownFile.id])
        try hold(catalog, inZip.id, on: drive,
                 path: ReplicationService.archivePartPrefix + "takeout-set-001.zip")
        try hold(catalog, ownFile.id, on: drive, path: "bb/b.jpg")

        let store = makeStore(in: directory)
        let holding = try XCTUnwrap(store.holdings(forStorageGroup: groupID).first)
        XCTAssertEqual(holding.photos, 2)
        XCTAssertEqual(
            holding.locations.map(\.photos).sorted(), [1, 1],
            "one in the download's folder, one in the replica root — neither zero"
        )
    }
}
