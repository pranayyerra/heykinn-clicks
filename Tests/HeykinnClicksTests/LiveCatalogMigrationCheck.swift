import XCTest
@testable import HeykinnClicks

/// Opens a *copy* of a real catalog and checks the schema step does what it
/// claims on data that actually exists.
///
/// Skipped unless `HEYKINN_LIVE_CATALOG` names a copy — the suite must never
/// depend on one machine's archive, and must never touch the original.
final class LiveCatalogMigrationCheck: XCTestCase {

    func testTheSchemaStepMigratesARealCatalogWithoutLosingRows() throws {
        guard let path = ProcessInfo.processInfo.environment["HEYKINN_LIVE_CATALOG"] else {
            throw XCTSkip("Set HEYKINN_LIVE_CATALOG to a copy of a real catalog.")
        }

        func count(_ db: CatalogStore, _ table: String) throws -> Int {
            try db.database.query("SELECT count(*) FROM \(table);") { Int($0.int(0)) }.first ?? -1
        }
        func columns(_ db: CatalogStore, _ table: String) throws -> [String] {
            try db.database.query("PRAGMA table_info(\(table));") { $0.text(1) }
        }

        let catalog = try CatalogStore(databasePath: path)

        // The speculative columns are gone; the one that carries membership
        // stays, and so does everything the tables held.
        XCTAssertFalse(try columns(catalog, "import_batches").contains("source_id"))
        XCTAssertFalse(try columns(catalog, "takeout_archives").contains("source_id"))
        XCTAssertTrue(try columns(catalog, "assets").contains("source_id"))
        XCTAssertTrue(try columns(catalog, "sources").contains("export_set_id"))

        let assets = try count(catalog, "assets")
        XCTAssertGreaterThan(assets, 0)
        print("LIVE assets=\(assets) batches=\(try count(catalog, "import_batches")) archives=\(try count(catalog, "takeout_archives")) sources=\(try count(catalog, "sources"))")

        // Reading still works through the real accessors, not only by count.
        XCTAssertEqual(try catalog.fetchAssets().count, assets)
        let sources = try catalog.fetchSources()
        print("LIVE sources: \(sources.map { "\($0.kind.rawValue) set=\($0.exportSetID ?? "-")" })")
        let linked = try catalog.fetchSourceIDsByAsset()
        print("LIVE assets linked to a source: \(linked.count) of \(assets)")

        // Idempotent: launching again over the migrated catalog is a no-op.
        let reopened = try CatalogStore(databasePath: path)
        XCTAssertEqual(try count(reopened, "assets"), assets)
        XCTAssertFalse(try columns(reopened, "import_batches").contains("source_id"))
    }

    /// The export sources on a real catalog find their set ids, so the card
    /// for a download the user already has can offer its settings.
    @MainActor
    func testExportSourcesOnARealCatalogLinkToTheirSets() throws {
        guard let path = ProcessInfo.processInfo.environment["HEYKINN_LIVE_CATALOG"] else {
            throw XCTSkip("Set HEYKINN_LIVE_CATALOG to a copy of a real catalog.")
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let suiteName = "heykinn-live-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))

        let exportsBefore = store.sources.filter { $0.kind == .takeoutExport }
        let assetsBefore = store.assets.count
        let linkedBefore = store.sourceIDByAsset.count
        print("LIVE export sources before: \(exportsBefore.map { $0.exportSetID ?? "-" })")

        store.linkExportSourcesToTheirSets()

        let exportsAfter = store.sources.filter { $0.kind == .takeoutExport }
        print("LIVE export sources after: \(exportsAfter.map { $0.exportSetID ?? "-" })")
        print("LIVE copiesRequiredByExportSet: \(store.copiesRequiredByExportSet)")

        XCTAssertEqual(store.assets.count, assetsBefore, "nothing was lost linking them")
        XCTAssertEqual(
            store.sourceIDByAsset.count, linkedBefore,
            "every photo that answered to a source still does"
        )
        for source in exportsAfter {
            XCTAssertNotNil(
                source.exportSetID,
                "every export source on this catalog is derivable from its batches"
            )
        }
        // One export, one source.
        let setIDs = exportsAfter.compactMap(\.exportSetID)
        XCTAssertEqual(Set(setIDs).count, setIDs.count, "no two sources claim one export")

        // And running it again changes nothing.
        let snapshot = exportsAfter.map { "\($0.id)|\($0.exportSetID ?? "-")" }.sorted()
        store.linkExportSourcesToTheirSets()
        let again = store.sources
            .filter { $0.kind == .takeoutExport }
            .map { "\($0.id)|\($0.exportSetID ?? "-")" }
            .sorted()
        XCTAssertEqual(again, snapshot)
    }
    /// The two things the user actually saw: a device reporting thousands of
    /// photos "waiting", and an export reporting itself "not yet on" a device
    /// that was never asked to hold it.
    @MainActor
    func testARealCatalogClearsStalePendingAndUnnamedExportDevices() throws {
        guard let path = ProcessInfo.processInfo.environment["HEYKINN_LIVE_CATALOG"] else {
            throw XCTSkip("Set HEYKINN_LIVE_CATALOG to a copy of a real catalog.")
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let suiteName = "heykinn-live-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
        store.linkExportSourcesToTheirSets()

        func pending() -> [String: Int] {
            var counts: [String: Int] = [:]
            for replica in store.replicaStates where replica.state == .pending {
                let name = store.targetsByID[replica.targetID]?.name ?? "unknown"
                counts[name, default: 0] += 1
            }
            return counts
        }
        let presentBefore = store.replicaStates.filter { $0.state == .present }.count
        print("LIVE pending before: \(pending())")

        let withdrawn = store.withdrawUnnamedPlacements()
        print("LIVE withdrew: \(withdrawn)")
        print("LIVE pending after: \(pending())")

        // Every pending row that survives is on a device its source names.
        for replica in store.replicaStates where replica.state == .pending {
            let named = Set(store.placementPolicy(forAsset: replica.assetID).destinations)
            XCTAssertTrue(named.contains(replica.targetID))
        }
        XCTAssertEqual(
            store.replicaStates.filter { $0.state == .present }.count, presentBefore,
            "no copy that exists was forgotten"
        )

        // And no export part reports owing a copy to a device it does not name.
        let plan = store.makeArchivePlan()
        for part in plan.parts {
            let named = plan.destinations(forSet: part.setID)
            for owed in plan.targetsNeedingACopy(of: part) {
                XCTAssertTrue(
                    named.contains(owed),
                    "\(part.displayName) owes a copy to a device its export does not name"
                )
            }
        }
        print("LIVE parts still owing a copy: \(plan.partsNeedingWork.count) of \(plan.parts.count)")
    }

    /// The policy split, on a catalog that actually has settings in it.
    @MainActor
    func testARealCatalogsPoliciesSurviveTheStorageGroupSplit() throws {
        guard let path = ProcessInfo.processInfo.environment["HEYKINN_LIVE_CATALOG"] else {
            throw XCTSkip("Set HEYKINN_LIVE_CATALOG to a copy of a real catalog.")
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let suiteName = "heykinn-live-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))

        print("LIVE groups: \(store.storageGroups.map { "\($0.label) copies=\($0.desiredCopies) dests=\($0.destinationTargetIDs.count)" })")
        print("LIVE assets in a group: \(store.storageGroupIDByAsset.count) of \(store.assets.count)")

        XCTAssertFalse(store.storageGroups.isEmpty, "the pre-split settings came across")
        XCTAssertEqual(
            store.storageGroupIDByAsset.count, store.assets.count,
            "every photo is in a group, so none falls back to the defaults"
        )
        // Every photo is judged against a real number, not a fallback.
        for asset in store.assets.prefix(500) {
            let group = try XCTUnwrap(store.storageGroup(forAsset: asset.id))
            XCTAssertGreaterThan(group.desiredCopies, 0)
        }
        // And the export still resolves to exactly one group.
        for source in store.sources where source.exportSetID != nil {
            let setID = try XCTUnwrap(source.exportSetID)
            XCTAssertNotNil(
                store.storageGroup(forExportSet: setID),
                "the export's photos are all in one group"
            )
        }
    }
}
