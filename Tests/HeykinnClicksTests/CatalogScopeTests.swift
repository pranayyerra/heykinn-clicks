import XCTest
@testable import HeykinnClicks

/// The boundary between what the archive knows and what this device knows.
///
/// The archive is meant to be one thing across several devices, with metadata
/// carried on the drives. That only works if the app knows which rows are safe
/// to carry — and the failure mode for getting it wrong is quiet: a
/// `/Volumes/...` path copied onto a device where no such path exists, read
/// back as though it meant something.
final class CatalogScopeTests: XCTestCase {

    private func makeCatalog() throws -> CatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func tables(in catalog: CatalogStore) throws -> Set<String> {
        Set(try catalog.database.query(
            """
            SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%';
            """
        ) { $0.text(0) })
    }

    // MARK: - Nothing unclassified

    /// The point of the whole file. A table added later fails this until
    /// somebody decides whether it describes the archive or the device — which
    /// is a question worth answering while writing the table, and nearly
    /// impossible to answer well for sixteen tables at once, later, under a
    /// deadline.
    func testEveryTableInTheSchemaIsClassified() throws {
        let catalog = try makeCatalog()
        let unclassified = try tables(in: catalog).subtracting(CatalogScope.allClassified)

        XCTAssertTrue(
            unclassified.isEmpty,
            """
            These tables are in the schema but not in CatalogScope: \
            \(unclassified.sorted().joined(separator: ", ")). \
            Decide whether each describes the archive (shared), this device \
            (deviceLocal), or is an append-only log, and add it.
            """
        )
    }

    /// The other direction: a table named in the classification that no longer
    /// exists means the list has drifted from the schema.
    func testNothingIsClassifiedThatDoesNotExist() throws {
        let catalog = try makeCatalog()
        let missing = CatalogScope.allClassified.subtracting(try tables(in: catalog))

        XCTAssertTrue(
            missing.isEmpty,
            "Classified but not in the schema: \(missing.sorted().joined(separator: ", "))"
        )
    }

    func testATableIsNeverInTwoCategories() {
        XCTAssertTrue(CatalogScope.shared.isDisjoint(with: CatalogScope.deviceLocal))
        XCTAssertTrue(CatalogScope.shared.isDisjoint(with: CatalogScope.appendOnly))
        XCTAssertTrue(CatalogScope.deviceLocal.isDisjoint(with: CatalogScope.appendOnly))
    }

    func testMachineLocalTablesDoNotTravel() {
        for table in CatalogScope.deviceLocal {
            XCTAssertFalse(CatalogScope.travels(table), "\(table) must never be carried to another device")
        }
        for table in CatalogScope.shared.union(CatalogScope.appendOnly) {
            XCTAssertTrue(CatalogScope.travels(table))
        }
    }

    /// Named individually because these are the three that were mixed into
    /// shared tables or would most plausibly be waved through.
    func testTheObviouslyLocalTablesAreClassifiedLocal() {
        for table in ["drive_local_state", "replication_tasks", "import_scan_memo"] {
            XCTAssertTrue(
                CatalogScope.deviceLocal.contains(table),
                "\(table) describes this device and must not be shared"
            )
        }
    }
}
