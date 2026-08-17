import XCTest
@testable import HeykinnClicks

/// The ways a real drive differs from a temporary directory.
///
/// Every other sync test uses a folder, which is a well-behaved, writable,
/// case-sensitive, empty place. A drive somebody plugs in is none of those: it
/// is usually exFAT, macOS scatters its own hidden files over it, it can be
/// mounted read-only, and it can be full. None of that can be reproduced by
/// mounting a disk image here, so the conditions are reproduced directly.
final class RealDriveConditionsTests: XCTestCase {

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-real-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            // Restore write permission first: a case below removes it, and a
            // directory that cannot be written cannot be deleted either.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        try CatalogStore(
            databasePath: try makeDirectory(label).appendingPathComponent("catalog.sqlite").path
        )
    }

    private func makeGroup(_ label: String) -> StorageGroup {
        StorageGroup(
            id: UUID(), label: label, desiredCopies: 2,
            destinationTargetIDs: [], createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    // MARK: - What macOS leaves lying about

    /// Every removable volume macOS touches collects these, and Finder adds
    /// `.DS_Store` to any directory it opens. None of them are segments, and
    /// treating one as a device would invent a peer that does not exist.
    func testMacOSHousekeepingFilesAreIgnored() throws {
        let mount = try makeDirectory("drive")
        let root = mount.appendingPathComponent("HeykinnClicks/Sync", isDirectory: true)
        let store = DirectorySegmentStore(root: root)

        let deviceA = try makeCatalog("a")
        try deviceA.upsertStorageGroup(makeGroup("Family"))
        try DriveSync.publish(from: deviceA, to: store)

        // The debris a real volume accumulates, in the places it accumulates.
        let devices = root.appendingPathComponent("devices", isDirectory: true)
        for junk in [".DS_Store", ".Spotlight-V100", ".fseventsd", ".Trashes"] {
            try Data("junk".utf8).write(to: devices.appendingPathComponent(junk))
        }
        try Data("junk".utf8).write(
            to: devices
                .appendingPathComponent(deviceA.journal.device.id, isDirectory: true)
                .appendingPathComponent(".DS_Store")
        )

        let deviceB = try makeCatalog("b")
        let report = try DriveSync.merge(into: deviceB, from: store)

        XCTAssertEqual(report.peersRead, 1, "Housekeeping files were counted as devices")
        XCTAssertTrue(report.truncatedPeers.isEmpty, "A stray file was read as a damaged segment")
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label), ["Family"])
    }

    /// A file that is not a segment sitting beside real ones — a copy somebody
    /// made, something another program dropped in.
    func testNonSegmentFilesBesideSegmentsAreIgnored() throws {
        let mount = try makeDirectory("drive")
        let root = mount.appendingPathComponent("HeykinnClicks/Sync", isDirectory: true)
        let store = DirectorySegmentStore(root: root)

        let deviceA = try makeCatalog("a")
        try deviceA.upsertStorageGroup(makeGroup("Family"))
        try DriveSync.publish(from: deviceA, to: store)

        let deviceDir = root
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent(deviceA.journal.device.id, isDirectory: true)
        try Data("not a segment".utf8).write(to: deviceDir.appendingPathComponent("notes.txt"))
        try Data("not a segment".utf8).write(
            to: deviceDir.appendingPathComponent("00000001.jsonl.bak")
        )

        let deviceB = try makeCatalog("b")
        let report = try DriveSync.merge(into: deviceB, from: store)

        XCTAssertTrue(report.truncatedPeers.isEmpty, "A non-segment file was parsed as one")
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label), ["Family"])
    }

    // MARK: - Case

    /// Drives are usually exFAT, which is case-insensitive. Two devices whose
    /// ids differ only in case would share one directory there — and each would
    /// take the other's segments for its own and skip them. Minting lowercase
    /// is what stops that being possible.
    func testDeviceIdentitiesAreLowercase() throws {
        let directory = try makeDirectory("identity")
        let identity = DeviceIdentity.resolve(inDirectory: directory)

        XCTAssertEqual(identity.id, identity.id.lowercased())
        XCTAssertFalse(identity.id.isEmpty)
    }

    /// And a device keeps the same id across relaunches, or every launch would
    /// look like a new device and the drive would fill with abandoned
    /// directories.
    func testDeviceIdentityIsStableAcrossRelaunches() throws {
        let directory = try makeDirectory("identity")
        let first = DeviceIdentity.resolve(inDirectory: directory)
        let second = DeviceIdentity.resolve(inDirectory: directory)

        XCTAssertEqual(first, second)
    }

    /// A device must never treat its own directory as a peer's. On a
    /// case-insensitive volume this is decided by string comparison, so it is
    /// worth asserting rather than assuming.
    func testADeviceNeverReadsItsOwnDirectoryAsAPeer() throws {
        let mount = try makeDirectory("drive")
        let store = DirectorySegmentStore(
            root: mount.appendingPathComponent("HeykinnClicks/Sync", isDirectory: true)
        )
        let deviceA = try makeCatalog("a")
        try deviceA.upsertStorageGroup(makeGroup("Family"))
        try DriveSync.publish(from: deviceA, to: store)

        let report = try DriveSync.merge(into: deviceA, from: store)

        XCTAssertEqual(report.peersRead, 0)
        XCTAssertEqual(report.outcome.applied, 0)
    }

    // MARK: - A drive that cannot be written to

    /// A drive with its lock switch on, mounted read-only, or one the user has
    /// no write permission for. The photographs on it are still perfectly good,
    /// so failing to sync metadata must be reported and must not stop anything
    /// else — least of all crash.
    func testAReadOnlyDriveIsReportedRatherThanFatal() throws {
        let mount = try makeDirectory("drive")
        let root = mount.appendingPathComponent("HeykinnClicks/Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let deviceA = try makeCatalog("a")
        try deviceA.upsertStorageGroup(makeGroup("Family"))

        let store = DirectorySegmentStore(root: root)
        XCTAssertThrowsError(
            try DriveSync.publish(from: deviceA, to: store),
            "A read-only drive should surface as an error to report, not silence"
        )

        // And the archive itself is untouched by the failure.
        XCTAssertEqual(try deviceA.fetchStorageGroups().map(\.label), ["Family"])
    }

    /// Reading a drive that cannot be written to must still work. Somebody
    /// plugging in a locked drive should still learn what is on it.
    func testAReadOnlyDriveCanStillBeReadFrom() throws {
        let mount = try makeDirectory("drive")
        let root = mount.appendingPathComponent("HeykinnClicks/Sync", isDirectory: true)
        let store = DirectorySegmentStore(root: root)

        let deviceA = try makeCatalog("a")
        try deviceA.upsertStorageGroup(makeGroup("Family"))
        try DriveSync.publish(from: deviceA, to: store)

        // Locked after being written, the way a drive arrives from elsewhere.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.path
            )
        }

        let deviceB = try makeCatalog("b")
        let peers = try DriveSync.pending(from: store, for: deviceB.journal)
        for peer in peers {
            try DriveSync.applySlice(peer.records[...], from: peer.peerID, using: deviceB.journal)
        }

        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label), ["Family"])
    }

    // MARK: - Deep paths

    /// A drive's sync directory is several levels down and may not exist at
    /// all. Nothing should require the caller to have made it first.
    func testTheSyncDirectoryIsCreatedWhereItDoesNotExist() throws {
        let mount = try makeDirectory("drive")
        let store = DirectorySegmentStore(
            root: mount.appendingPathComponent("HeykinnClicks/Sync", isDirectory: true)
        )

        let deviceA = try makeCatalog("a")
        try deviceA.upsertStorageGroup(makeGroup("Family"))
        try DriveSync.publish(from: deviceA, to: store)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mount.appendingPathComponent("HeykinnClicks/Sync/manifest.json").path
        ))
    }
}
