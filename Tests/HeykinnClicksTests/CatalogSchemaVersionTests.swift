import XCTest
@testable import HeykinnClicks

/// The stamp that stops an old build quietly eating a newer catalog's data.
///
/// SQLite reads a newer file perfectly well, and every query in `CatalogStore`
/// names its columns, so nothing throws. The damage comes afterwards: the
/// upserts rewrite whole rows, so a build that has never heard of a column
/// writes the row back without it. These cover the refusal, and — just as
/// importantly — that a refusal changes nothing on disk.
final class CatalogSchemaVersionTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeAsset(_ name: String = "a.jpg") -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    /// Forces a catalog's stamp to `version`, the way a future build would
    /// leave it.
    private func stamp(_ path: URL, version: Int64) throws {
        let database = try SQLiteDatabase(path: path.path)
        try database.exec("PRAGMA user_version = \(version);")
        database.close()
    }

    // MARK: - Stamping

    func testANewCatalogCarriesTheCurrentVersion() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite")
        _ = try CatalogStore(databasePath: path.path)

        XCTAssertEqual(try CatalogStore.schemaVersion(ofDatabaseAt: path), CatalogStore.schemaVersion)
    }

    /// Every catalog written before the stamp existed reads as 0, which is
    /// SQLite's default. Those must open and be brought forward, not refused —
    /// this is every existing user's archive.
    func testAnUnstampedCatalogOpensAndIsBroughtForward() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite")
        let first = try CatalogStore(databasePath: path.path)
        try first.upsertAsset(makeAsset())
        try stamp(path, version: 0)

        let reopened = try CatalogStore(databasePath: path.path)

        XCTAssertEqual(try reopened.fetchAssets().count, 1)
        XCTAssertEqual(try CatalogStore.schemaVersion(ofDatabaseAt: path), CatalogStore.schemaVersion)
    }

    // MARK: - Refusing

    func testACatalogFromANewerBuildIsRefused() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite")
        _ = try CatalogStore(databasePath: path.path)
        try stamp(path, version: CatalogStore.schemaVersion + 1)

        XCTAssertThrowsError(try CatalogStore(databasePath: path.path)) { error in
            guard case CatalogStore.OpenError.builtForNewerVersion(let found, let supported) = error else {
                return XCTFail("Expected builtForNewerVersion, got \(error)")
            }
            XCTAssertEqual(found, CatalogStore.schemaVersion + 1)
            XCTAssertEqual(supported, CatalogStore.schemaVersion)
        }
    }

    /// The refusal has to leave the file exactly as it was. Somebody in this
    /// state is going to open the archive again with the right build, and a
    /// "safe" refusal that had already downgraded the stamp — or applied this
    /// build's schema on the way to deciding — would have done the damage it
    /// was there to prevent.
    func testARefusedOpenChangesNothingOnDisk() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite")
        let first = try CatalogStore(databasePath: path.path)
        try first.upsertAsset(makeAsset())
        first.database.checkpoint()
        try stamp(path, version: 99)

        let before = try Data(contentsOf: path)
        XCTAssertThrowsError(try CatalogStore(databasePath: path.path))

        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(try CatalogStore.schemaVersion(ofDatabaseAt: path), 99)
    }

    // MARK: - Restore

    /// A snapshot is written by whichever build was running when the drive was
    /// last connected, so a newer one is the ordinary case for an archive that
    /// moves between devices — not a corner.
    func testRestoringASnapshotFromANewerBuildIsRefused() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite")
        let catalog = try CatalogStore(databasePath: path.path)
        try catalog.upsertAsset(makeAsset("kept.jpg"))

        let snapshotPath = try makeTempDirectory().appendingPathComponent("snapshot.sqlite")
        let snapshot = try CatalogStore(databasePath: snapshotPath.path)
        try snapshot.upsertAsset(makeAsset("incoming.jpg"))
        snapshot.database.close()
        try stamp(snapshotPath, version: CatalogStore.schemaVersion + 1)

        XCTAssertThrowsError(try catalog.replaceContents(withDatabaseAt: snapshotPath))
    }

    // MARK: - What the app does with it

    /// The whole point of the guard is that somebody meets a sentence, not a
    /// crash. `AppStore` opened the catalog with `fatalError` on any failure,
    /// so without this the refusal would have been indistinguishable from the
    /// app being broken.
    @MainActor
    func testTheAppReportsANewerCatalogInsteadOfCrashing() throws {
        let directory = try makeTempDirectory()
        let catalogPath = directory.appendingPathComponent("catalog.sqlite")
        _ = try CatalogStore(databasePath: catalogPath.path)
        try stamp(catalogPath, version: CatalogStore.schemaVersion + 1)

        let suiteName = "heykinn-schema-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory, defaults: defaults, runsBackgroundWork: false
        ))

        let explanation = try XCTUnwrap(store.catalogRequiresNewerApp)
        XCTAssertTrue(
            explanation.contains("newer version"),
            "The explanation has to say what to do, got: \(explanation)"
        )
    }

    @MainActor
    func testTheAppOpensNormallyWhenTheCatalogIsNotNewer() throws {
        let directory = try makeTempDirectory()
        let suiteName = "heykinn-schema-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory, defaults: defaults, runsBackgroundWork: false
        ))

        XCTAssertNil(store.catalogRequiresNewerApp)
    }

    /// The check runs before the live catalog is moved aside, so a refused
    /// restore is a no-op rather than something that has to be undone.
    func testARefusedRestoreLeavesTheLiveCatalogInPlace() throws {
        let path = try makeTempDirectory().appendingPathComponent("catalog.sqlite")
        let catalog = try CatalogStore(databasePath: path.path)
        try catalog.upsertAsset(makeAsset("kept.jpg"))

        let snapshotPath = try makeTempDirectory().appendingPathComponent("snapshot.sqlite")
        let snapshot = try CatalogStore(databasePath: snapshotPath.path)
        snapshot.database.close()
        try stamp(snapshotPath, version: CatalogStore.schemaVersion + 1)

        XCTAssertThrowsError(try catalog.replaceContents(withDatabaseAt: snapshotPath))

        // Still usable, still holding its own rows, and nothing left beside it.
        XCTAssertEqual(try catalog.fetchAssets().map(\.originalFilename), ["kept.jpg"])
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: path.deletingLastPathComponent().path
        )
        XCTAssertFalse(
            siblings.contains { $0.hasPrefix("catalog-replaced-") },
            "A refused restore kept a copy aside, so it had already started replacing"
        )
    }
}
