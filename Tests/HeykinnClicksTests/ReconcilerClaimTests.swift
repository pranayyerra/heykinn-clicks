import XCTest
@testable import HeykinnClicks

/// A drive that already holds the archive is the case reconciliation exists
/// for, and it is also the case that used to cost the most: every file on it
/// was checked against a list of claims that grew with every claim made.
final class ReconcilerClaimTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // realpath /var → /private/var, so the mount prefix compares equal with
        // what the directory enumerator reports. Same reason as TakeoutTests.
        var url = raw
        if let resolved = realpath(raw.path, nil) {
            url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        roots.append(url)
        return url
    }

    /// One claim per photograph, however many files on the drive turn out to
    /// hold it. This is the guarantee the growing-array scan provided and the
    /// set has to keep.
    func testTheSamePhotographTwiceOnADriveIsClaimedOnce() throws {
        let mount = try makeDirectory()
        let folder = mount.appendingPathComponent("Takeout", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Same bytes under two names — a duplicate on the drive itself.
        let bytes = Data("the same photograph".utf8)
        try bytes.write(to: folder.appendingPathComponent("IMG_1.jpg"))
        try bytes.write(to: folder.appendingPathComponent("IMG_1 copy.jpg"))
        let hash = try HashingService.sha256(of: folder.appendingPathComponent("IMG_1.jpg"))

        let assetID = UUID()
        let result = TakeoutReconciler.reconcileFolder(
            folderURL: folder,
            mountURL: mount,
            targetID: UUID(),
            assetIDsByHash: [hash: assetID],
            assetsNeedingReplica: [assetID]
        )

        XCTAssertEqual(result.scannedFileCount, 2, "Both files are read")
        XCTAssertEqual(result.claimedReplicas.count, 1, "One photograph, one claim")
        XCTAssertEqual(result.claimedReplicas.first?.assetID, assetID)
    }

    /// A photograph the catalog does not want a copy of on this drive is not
    /// claimed, and does not consume the one claim its hash was entitled to.
    func testOnlyPhotographsThisDriveIsShortOfAreClaimed() throws {
        let mount = try makeDirectory()
        let folder = mount.appendingPathComponent("Takeout", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let wanted = folder.appendingPathComponent("wanted.jpg")
        let ignored = folder.appendingPathComponent("ignored.jpg")
        try Data("wanted".utf8).write(to: wanted)
        try Data("ignored".utf8).write(to: ignored)

        let wantedID = UUID()
        let ignoredID = UUID()
        let result = TakeoutReconciler.reconcileFolder(
            folderURL: folder,
            mountURL: mount,
            targetID: UUID(),
            assetIDsByHash: [
                try HashingService.sha256(of: wanted): wantedID,
                try HashingService.sha256(of: ignored): ignoredID,
            ],
            assetsNeedingReplica: [wantedID]
        )

        XCTAssertEqual(result.claimedReplicas.map(\.assetID), [wantedID])
    }

    /// Every file on a drive holding the whole archive is claimed, and each is
    /// claimed exactly once.
    ///
    /// Deliberately not a timing test. The obvious one — reconcile 400 files,
    /// then 3,200, and assert the time did not grow eightfold — passes with the
    /// old quadratic scan restored, because reading and hashing each file costs
    /// far more than walking the claims. A test that cannot fail for the reason
    /// it names is worse than no test, so this holds the behaviour the scan
    /// provided and leaves the cost to the shape of the code.
    func testEveryPhotographOnTheDriveIsClaimedExactlyOnce() throws {
        let mount = try makeDirectory()
        let folder = mount.appendingPathComponent("Takeout", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var hashes: [String: UUID] = [:]
        var needed: Set<UUID> = []
        for index in 0..<400 {
            let url = folder.appendingPathComponent("IMG_\(index).jpg")
            try Data("photograph number \(index)".utf8).write(to: url)
            let id = UUID()
            hashes[try HashingService.sha256(of: url)] = id
            needed.insert(id)
        }

        let result = TakeoutReconciler.reconcileFolder(
            folderURL: folder, mountURL: mount, targetID: UUID(),
            assetIDsByHash: hashes, assetsNeedingReplica: needed
        )

        XCTAssertEqual(result.scannedFileCount, 400)
        XCTAssertEqual(result.claimedReplicas.count, 400)
        XCTAssertEqual(Set(result.claimedReplicas.map(\.assetID)), needed)
    }
}

/// The largest table in the catalog is keyed by photograph, and every
/// per-drive question asks it by drive.
final class ReplicaStateIndexTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeCatalog() throws -> CatalogStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return try CatalogStore(databasePath: url.appendingPathComponent("catalog.sqlite").path)
    }

    /// Asked of the query planner rather than of the schema: an index that
    /// exists and is not used costs writes and buys nothing.
    func testDriveScopedQueriesUseTheIndexRatherThanScanning() throws {
        let catalog = try makeCatalog()
        let plan = try catalog.database.query("""
        EXPLAIN QUERY PLAN
        SELECT relative_path FROM replica_states WHERE drive_id = ?;
        """, [.text(UUID().uuidString)]) { $0.text(3) }.joined(separator: " | ")

        XCTAssertTrue(
            plan.contains("idx_replica_states_drive"),
            "Per-drive reads must use the index; the planner said: \(plan)"
        )
        XCTAssertFalse(
            plan.contains("SCAN replica_states"),
            "Per-drive reads must not walk the whole table; the planner said: \(plan)"
        )
    }

    /// Opening an existing catalog again adds the index rather than failing,
    /// which is how a catalog written before it gains it.
    func testAnExistingCatalogGainsTheIndexOnNextOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let path = url.appendingPathComponent("catalog.sqlite").path

        let first = try CatalogStore(databasePath: path)
        try first.database.exec("DROP INDEX IF EXISTS idx_replica_states_drive;")

        let reopened = try CatalogStore(databasePath: path)
        let names = try reopened.database.query("""
        SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'replica_states';
        """) { $0.text(0) }
        XCTAssertTrue(names.contains("idx_replica_states_drive"))
    }
}
