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

    /// A merge has to accept a child before its parent — records arrive in
    /// whatever order a drive is read, so a device routinely learns about a copy
    /// before the photograph it belongs to. A foreign key would reject that
    /// record and the reader has no way to ask for the missing parent, so
    /// order-independence and referential integrity cannot both hold on a table
    /// that travels.
    ///
    /// The database enforces nothing either way — `PRAGMA foreign_keys` is
    /// deliberately not switched on — so a constraint added here would be inert
    /// today and start dropping merged rows the moment somebody turned it on
    /// while tidying up. This is the check that makes that unlikely to survive
    /// review. See `ARCHITECTURE-DECISIONS.md` D14.
    func testNoSharedTableDeclaresAForeignKey() throws {
        let catalog = try makeCatalog()
        for table in CatalogScope.shared.union(CatalogScope.appendOnly).sorted() {
            let keys = try catalog.database.query("PRAGMA foreign_key_list(\"\(table)\");") {
                $0.text(2)
            }
            XCTAssertTrue(
                keys.isEmpty,
                "\(table) travels between devices and declares a foreign key to \(keys.joined(separator: ", ")) "
                + "— a merge that receives the child first could never apply it"
            )
        }
    }
}
