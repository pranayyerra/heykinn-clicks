import XCTest
@testable import HeykinnClicks

/// The schema the sources model needs, and the two columns it turned out not
/// to.
final class SourceSchemaTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeCatalogPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        roots.append(directory)
        return directory.appendingPathComponent("catalog.sqlite").path
    }

    private func columns(_ catalog: CatalogStore, of table: String) throws -> [String] {
        try catalog.database.query("PRAGMA table_info(\(table));") { $0.text(1) }
    }

    /// Membership lives on the asset and nowhere else. That is what makes one
    /// source per asset a strict partition rather than three places to
    /// disagree.
    func testOnlyAssetsCarriesASourceColumn() throws {
        let catalog = try CatalogStore(databasePath: try makeCatalogPath())

        XCTAssertTrue(try columns(catalog, of: "assets").contains("source_id"))
        XCTAssertFalse(try columns(catalog, of: "import_batches").contains("source_id"))
        XCTAssertFalse(try columns(catalog, of: "takeout_archives").contains("source_id"))
    }

    /// A catalog that already has the speculative columns loses them, because
    /// the schema step runs on every launch and installed catalogs have them.
    func testAnInstalledCatalogLosesTheColumnsItAlreadyHas() throws {
        let path = try makeCatalogPath()
        do {
            let catalog = try CatalogStore(databasePath: path)
            // Put them back, as a catalog written by the version that added
            // them would have them.
            try catalog.database.exec("ALTER TABLE import_batches ADD COLUMN source_id TEXT;")
            try catalog.database.exec("ALTER TABLE takeout_archives ADD COLUMN source_id TEXT;")
            XCTAssertTrue(try columns(catalog, of: "import_batches").contains("source_id"))
        }

        let reopened = try CatalogStore(databasePath: path)

        XCTAssertFalse(try columns(reopened, of: "import_batches").contains("source_id"))
        XCTAssertFalse(try columns(reopened, of: "takeout_archives").contains("source_id"))
    }

    /// The schema step runs on every launch, so it has to survive being run
    /// again over a catalog it has already migrated.
    func testTheSchemaStepIsSafeToRunRepeatedly() throws {
        let path = try makeCatalogPath()
        let catalog = try CatalogStore(databasePath: path)

        XCTAssertNoThrow(try catalog.createSourceSchema())
        XCTAssertNoThrow(try catalog.createSourceSchema())

        XCTAssertTrue(try columns(catalog, of: "assets").contains("source_id"))
        XCTAssertFalse(try columns(catalog, of: "import_batches").contains("source_id"))
    }

    /// Dropping a column must not disturb the rows around it.
    func testTheRowsInThoseTablesSurviveTheDrop() throws {
        let path = try makeCatalogPath()
        let batchID = UUID()
        do {
            let catalog = try CatalogStore(databasePath: path)
            try catalog.database.exec("ALTER TABLE import_batches ADD COLUMN source_id TEXT;")
            try catalog.upsertImportBatch(ImportBatch(
                id: batchID,
                sourcePath: "/Users/someone/Pictures/2019",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                completedAt: nil,
                importedCount: 12,
                duplicateCount: 3,
                failedCount: 0,
                origin: .localFolder
            ))
        }

        let reopened = try CatalogStore(databasePath: path)
        let batches = try reopened.fetchImportBatches()

        XCTAssertFalse(try columns(reopened, of: "import_batches").contains("source_id"))
        let batch = try XCTUnwrap(batches.first { $0.id == batchID })
        XCTAssertEqual(batch.sourcePath, "/Users/someone/Pictures/2019")
        XCTAssertEqual(batch.importedCount, 12)
        XCTAssertEqual(batch.duplicateCount, 3)
    }
}
