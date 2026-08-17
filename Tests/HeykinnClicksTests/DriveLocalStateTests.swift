import XCTest
@testable import HeykinnClicks

/// Where each target was last seen, kept apart from what the target *is*.
///
/// `drives` used to hold both. A mount path is `/Volumes/My Passport` on this
/// device and names nothing on another one, so a table mixing the two kinds is a
/// table that cannot be carried between devices at all — which is what the
/// whole multi-device design turns on.
final class DriveLocalStateTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeTarget(name: String = "My Passport", path: String? = "/Volumes/My Passport") -> ReplicationTarget {
        ReplicationTarget(
            id: UUID(),
            name: name,
            kind: .externalVolume,
            volumeUUID: "VOL-1",
            markerToken: "token-1",
            registeredAt: Date(timeIntervalSince1970: 1_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastKnownPath: path,
            configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    // MARK: - Round trip

    func testATargetSurvivesTheSplitIntact() throws {
        let catalog = try CatalogStore(
            databasePath: try makeDirectory().appendingPathComponent("catalog.sqlite").path
        )
        let target = makeTarget()
        try catalog.upsertTarget(target)

        let read = try XCTUnwrap(catalog.fetchTargets().first)
        XCTAssertEqual(read.id, target.id)
        XCTAssertEqual(read.name, target.name)
        XCTAssertEqual(read.markerToken, target.markerToken)
        XCTAssertEqual(read.replicaRootComponent, target.replicaRootComponent)
        XCTAssertEqual(read.lastKnownPath, "/Volumes/My Passport")
        XCTAssertEqual(read.lastSeenAt, target.lastSeenAt)
    }

    /// The device-local values must come from the local table, not from the
    /// columns still being written into `drives` for the older build. If this
    /// ever reverses, the split is decorative.
    func testTheLocalTableIsWhatIsRead() throws {
        let catalog = try CatalogStore(
            databasePath: try makeDirectory().appendingPathComponent("catalog.sqlite").path
        )
        let target = makeTarget()
        try catalog.upsertTarget(target)

        // Diverge the two deliberately, the way an older build writing only to
        // `drives` would.
        try catalog.database.run(
            "UPDATE drives SET last_mount_path = ? WHERE id = ?;",
            [.text("/Volumes/Stale"), .text(target.id.uuidString)]
        )
        try catalog.database.run(
            "UPDATE drive_local_state SET last_mount_path = ? WHERE drive_id = ?;",
            [.text("/Volumes/Current"), .text(target.id.uuidString)]
        )

        XCTAssertEqual(try catalog.fetchTargets().first?.lastKnownPath, "/Volumes/Current")
    }

    /// A device registered on another device arrives with no local row at all.
    /// It must still be listed — as a target this device has never seen, which
    /// is the truth — rather than vanishing from a JOIN.
    func testATargetWithNoLocalRowIsStillListed() throws {
        let catalog = try CatalogStore(
            databasePath: try makeDirectory().appendingPathComponent("catalog.sqlite").path
        )
        let target = makeTarget()
        try catalog.upsertTarget(target)
        try catalog.database.run(
            "DELETE FROM drive_local_state WHERE drive_id = ?;", [.text(target.id.uuidString)]
        )

        let read = try XCTUnwrap(catalog.fetchTargets().first)
        XCTAssertEqual(read.id, target.id)
        XCTAssertEqual(read.name, "My Passport", "Identity is shared and must survive")
        XCTAssertNil(read.lastKnownPath, "This device has never seen it, and should say so")
        XCTAssertNil(read.lastSeenAt)
    }

    func testForgettingATargetRemovesItsLocalRow() throws {
        let catalog = try CatalogStore(
            databasePath: try makeDirectory().appendingPathComponent("catalog.sqlite").path
        )
        let target = makeTarget()
        try catalog.upsertTarget(target)
        try catalog.deleteTarget(id: target.id)

        let remaining = try catalog.database.query(
            "SELECT count(*) FROM drive_local_state;"
        ) { $0.int(0) }
        XCTAssertEqual(remaining.first, 0)
    }

    // MARK: - Migration from before the split

    /// Every existing archive has its mount paths in `drives` and no local
    /// table at all. Opening must carry them across, or every registered drive
    /// reads as never-seen on the first launch after updating.
    func testValuesInTheOldColumnsAreCarriedAcross() throws {
        let path = try makeDirectory().appendingPathComponent("catalog.sqlite")
        let target = makeTarget(path: "/Volumes/Original")
        let first = try CatalogStore(databasePath: path.path)
        try first.upsertTarget(target)
        // Put the catalog back into its pre-split shape: values in `drives`,
        // nothing in the local table.
        try first.database.run("DELETE FROM drive_local_state;")
        first.database.close()

        let reopened = try CatalogStore(databasePath: path.path)

        let read = try XCTUnwrap(reopened.fetchTargets().first)
        XCTAssertEqual(read.lastKnownPath, "/Volumes/Original")
        XCTAssertEqual(read.lastSeenAt, target.lastSeenAt)
    }

    /// The migration must not run twice over a row it has already moved.
    /// Otherwise an older build writing to `drives` between two launches would
    /// silently overwrite this device's own state on the next open.
    func testMigrationDoesNotOverwriteStateItAlreadyMoved() throws {
        let path = try makeDirectory().appendingPathComponent("catalog.sqlite")
        let target = makeTarget(path: "/Volumes/Original")
        let first = try CatalogStore(databasePath: path.path)
        try first.upsertTarget(target)
        try first.database.run(
            "UPDATE drive_local_state SET last_mount_path = ? WHERE drive_id = ?;",
            [.text("/Volumes/Current"), .text(target.id.uuidString)]
        )
        // What an older build, which knows only `drives`, would have left.
        try first.database.run(
            "UPDATE drives SET last_mount_path = ? WHERE id = ?;",
            [.text("/Volumes/WrittenByAnOlderBuild"), .text(target.id.uuidString)]
        )
        first.database.close()

        let reopened = try CatalogStore(databasePath: path.path)

        XCTAssertEqual(try reopened.fetchTargets().first?.lastKnownPath, "/Volumes/Current")
    }
}
