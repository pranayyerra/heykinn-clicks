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
