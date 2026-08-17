import XCTest
@testable import HeykinnClicks

/// Restoring a snapshot must not leave capture broken.
///
/// Triggers and `change_pending_stamp` both live *inside* the catalog file, so a
/// restored snapshot arrives carrying whatever the device that wrote it had —
/// possibly no triggers at all, and certainly that device's identity.
final class RestoreTriggerTests: XCTestCase {

    private func makeDirectory(_ l: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(l)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeGroup(_ label: String) -> StorageGroup {
        StorageGroup(
            id: UUID(), label: label, desiredCopies: 2,
            destinationTargetIDs: [], createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    func testARestoredCatalogStampsWithThisDeviceNotTheSnapshotsDevice() throws {
        // A snapshot written by another device, carrying its identity.
        let otherDir = try makeDirectory("other")
        let other = try CatalogStore(
            databasePath: otherDir.appendingPathComponent("catalog.sqlite").path
        )
        try other.upsertStorageGroup(makeGroup("From the other device"))
        let otherDeviceID = other.journal.device.id
        other.database.checkpoint()
        let snapshot = try makeDirectory("snap").appendingPathComponent("snapshot.sqlite")
        try other.vacuumInto(path: snapshot.path)

        // This device restores it.
        let mineDir = try makeDirectory("mine")
        let mine = try CatalogStore(
            databasePath: mineDir.appendingPathComponent("catalog.sqlite").path
        )
        let myDeviceID = mine.journal.device.id
        XCTAssertNotEqual(myDeviceID, otherDeviceID)

        try mine.replaceContents(withDatabaseAt: snapshot)

        // A change made here must be recorded, and recorded as this device's.
        try mine.upsertStorageGroup(makeGroup("Made after restoring"))

        let stamps = try mine.database.query(
            "SELECT hlc FROM change_field_versions WHERE table_name = 'storage_groups';"
        ) { $0.text(0) }.compactMap(HLCTimestamp.decode)

        XCTAssertFalse(stamps.isEmpty, "Capture was off after restoring — no triggers")
        XCTAssertTrue(
            stamps.contains { $0.deviceID == myDeviceID },
            "Nothing was recorded under this device's identity after a restore"
        )
    }

    /// A snapshot from before triggers existed has none in it.
    func testRestoringASnapshotWithNoTriggersReinstallsThem() throws {
        let sourceDir = try makeDirectory("src")
        let source = try CatalogStore(
            databasePath: sourceDir.appendingPathComponent("catalog.sqlite").path
        )
        // Strip them, the way an older build's snapshot would arrive.
        for name in try source.database.query("""
        SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'hk_change_%';
        """) { $0.text(0) } {
            try source.database.exec("DROP TRIGGER \"\(name)\";")
        }
        source.database.checkpoint()
        let snapshot = try makeDirectory("snap2").appendingPathComponent("snapshot.sqlite")
        try source.vacuumInto(path: snapshot.path)

        let mineDir = try makeDirectory("mine2")
        let mine = try CatalogStore(
            databasePath: mineDir.appendingPathComponent("catalog.sqlite").path
        )
        try mine.replaceContents(withDatabaseAt: snapshot)

        let count = try mine.database.query("""
        SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'hk_change_%';
        """) { $0.int(0) }.first ?? 0
        XCTAssertGreaterThan(count, 0, "A snapshot with no triggers left capture off")
    }
}
