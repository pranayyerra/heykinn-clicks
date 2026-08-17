import XCTest
@testable import HeykinnClicks

/// Capture that cannot be bypassed.
///
/// The wrapper it replaced was opt-in, and eleven write paths did not opt in.
/// These use raw SQL that goes nowhere near the journal — the shape of every one
/// of those eleven — and require it to be recorded anyway. **No test here can
/// pass under a wrapper**, which is the point of them.
final class TriggerCaptureTests: XCTestCase {

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trig-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func makeGroup(_ id: UUID = UUID(), _ label: String = "Family") -> StorageGroup {
        StorageGroup(
            id: id, label: label, desiredCopies: 2,
            destinationTargetIDs: [], createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private func stamps(_ catalog: CatalogStore, table: String) throws -> [String: String] {
        let rows = try catalog.database.query(
            "SELECT column_name, hlc FROM change_field_versions WHERE table_name = ?;",
            [.text(table)]
        ) { (column: $0.text(0), hlc: $0.text(1)) }
        return Dictionary(rows.map { ($0.column, $0.hlc) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - The thing a wrapper could not do

    func testARawUpdateNothingWrappedIsRecorded() throws {
        let catalog = try makeCatalog("a")
        let group = makeGroup()
        try catalog.upsertStorageGroup(group)
        let before = try stamps(catalog, table: "storage_groups")["label"]

        // Exactly the shape of the eleven paths that used to slip through.
        try catalog.database.run(
            "UPDATE storage_groups SET label = ? WHERE id = ?;",
            [.text("Family photos"), .text(group.id.uuidString)]
        )

        let after = try stamps(catalog, table: "storage_groups")["label"]
        XCTAssertNotNil(after)
        XCTAssertNotEqual(after, before, "A write that bypassed the journal was not recorded")
    }

    func testARawDeleteNothingWrappedLeavesATombstone() throws {
        let catalog = try makeCatalog("a")
        let group = makeGroup()
        try catalog.upsertStorageGroup(group)

        try catalog.database.run(
            "DELETE FROM storage_groups WHERE id = ?;", [.text(group.id.uuidString)]
        )

        let tombstones = try catalog.database.query(
            "SELECT row_id FROM change_row_tombstones WHERE table_name = 'storage_groups';"
        ) { $0.text(0) }
        XCTAssertEqual(tombstones, [ChangeJournal.rowID([group.id.uuidString])])
    }

    /// A bulk update touches many rows in one statement. The wrapper needed a
    /// special path for this; a trigger fires per row on its own.
    func testABulkUpdateIsRecordedPerRow() throws {
        let catalog = try makeCatalog("a")
        let ids = (0..<25).map { _ in UUID() }
        for id in ids { try catalog.upsertStorageGroup(makeGroup(id, "Before")) }

        try catalog.database.run("UPDATE storage_groups SET label = 'After';")

        let recorded = try catalog.database.query("""
        SELECT count(*) FROM change_field_versions
         WHERE table_name = 'storage_groups' AND column_name = 'label';
        """) { $0.int(0) }.first
        XCTAssertEqual(recorded, 25, "A bulk update did not record every row it changed")
    }

    /// A rewrite that changes nothing must produce nothing, or every routine
    /// rescan would look to other devices like the archive being rewritten.
    func testARewriteThatChangesNothingRecordsNothing() throws {
        let catalog = try makeCatalog("a")
        let group = makeGroup()
        try catalog.upsertStorageGroup(group)
        let before = try stamps(catalog, table: "storage_groups")

        try catalog.upsertStorageGroup(group)

        XCTAssertEqual(try stamps(catalog, table: "storage_groups"), before)
    }

    /// Every firing needs its own stamp, or two changes share one and "later
    /// wins" stops being a function.
    func testEveryRecordedChangeHasADistinctStamp() throws {
        let catalog = try makeCatalog("a")
        let ids = (0..<40).map { _ in UUID() }
        try catalog.transaction {
            for id in ids { try catalog.upsertStorageGroup(makeGroup(id)) }
        }

        let all = try catalog.database.query(
            "SELECT hlc FROM change_field_versions WHERE table_name = 'storage_groups';"
        ) { $0.text(0) }
        XCTAssertEqual(Set(all).count, all.count, "Two changes were given the same stamp")
        XCTAssertTrue(all.allSatisfy { HLCTimestamp.decode($0) != nil }, "A stamp did not parse")
    }

    // MARK: - Applying somebody else's changes must not look like making them

    /// Without suppression a merge would restamp everything it applied with this
    /// device's clock, publish it straight back, and the two devices would echo
    /// the same change at each other for ever.
    func testMergingDoesNotRecordTheChangesAsThisDevicesOwn() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        try deviceA.upsertStorageGroup(makeGroup())

        let fromA = try deviceA.journal.changes(since: nil)
        try deviceB.journal.merge(fromA)

        // What B would now publish. Nothing, because it originated none of it.
        let fromB = try deviceB.journal.changes(since: nil)
        let bStampedAnything = fromB.contains { $0.stamp.deviceID == deviceB.journal.device.id }

        XCTAssertFalse(bStampedAnything, "Merging recorded the changes as this device's own")
        XCTAssertEqual(
            Set(fromB.map(\.stamp)), Set(fromA.map(\.stamp)),
            "Merged changes carry stamps other than the ones they arrived with"
        )
    }

    /// And capture has to come back on afterwards, including when a merge fails.
    func testCaptureResumesAfterAMerge() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        try deviceA.upsertStorageGroup(makeGroup())
        try deviceB.journal.merge(try deviceA.journal.changes(since: nil))

        let ownGroup = makeGroup(UUID(), "Made on B")
        try deviceB.upsertStorageGroup(ownGroup)

        let mine = try deviceB.journal.changes(since: nil)
            .filter { $0.stamp.deviceID == deviceB.journal.device.id }
        XCTAssertFalse(mine.isEmpty, "Capture did not resume after merging")
    }

    // MARK: - Keeping the triggers in step with the schema

    /// A column added by a later migration needs a trigger of its own, so the
    /// set is rebuilt from the live schema rather than created once.
    func testEveryColumnOfEverySharedTableHasATrigger() throws {
        let catalog = try makeCatalog("a")

        let installed = Set(try catalog.database.query("""
        SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'hk_change_%';
        """) { $0.text(0) })

        for table in CatalogScope.shared.sorted() {
            let columns = try catalog.database.query("PRAGMA table_info(\"\(table)\");") { $0.text(1) }
            XCTAssertTrue(installed.contains("hk_change_\(table)_ins"), "No insert trigger for \(table)")
            XCTAssertTrue(installed.contains("hk_change_\(table)_del"), "No delete trigger for \(table)")
            for column in columns {
                XCTAssertTrue(
                    installed.contains("hk_change_\(table)_upd_\(column)"),
                    "No update trigger for \(table).\(column)"
                )
            }
        }
    }

    /// Reopening must not accumulate a second set.
    func testReopeningDoesNotDuplicateTriggers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trig-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("catalog.sqlite").path

        func triggerCount(_ catalog: CatalogStore) throws -> Int64 {
            try catalog.database.query("""
            SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'hk_change_%';
            """) { $0.int(0) }.first ?? 0
        }

        let first = try CatalogStore(databasePath: path)
        let initial = try triggerCount(first)
        first.database.close()

        let reopened = try CatalogStore(databasePath: path)
        XCTAssertEqual(try triggerCount(reopened), initial)
        XCTAssertGreaterThan(initial, 0)
    }

    /// The clock must not reissue a stamp the triggers already used, since they
    /// advance the counter without telling it.
    func testTheClockResumesPastWhatTheTriggersUsed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trig-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("catalog.sqlite").path

        let first = try CatalogStore(databasePath: path)
        try first.transaction {
            for _ in 0..<30 { try first.upsertStorageGroup(makeGroup()) }
        }
        let highest = try first.database.query(
            "SELECT max(hlc) FROM change_field_versions;"
        ) { $0.text(0) }.first
        first.database.close()

        let reopened = try CatalogStore(databasePath: path)
        let next = try reopened.journal.stamp()

        XCTAssertGreaterThan(
            next.encoded, highest ?? "",
            "The clock reissued a stamp the triggers had already used"
        )
    }
}
