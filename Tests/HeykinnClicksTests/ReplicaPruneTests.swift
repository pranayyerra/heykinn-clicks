import XCTest
@testable import HeykinnClicks

/// Draining a device should not leave a tree of empty folders behind.
@MainActor
final class ReplicaPruneTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeMount() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func makeDrive() -> ReplicationTarget {
        ReplicationTarget(
            id: UUID(), name: "Drive", volumeUUID: "VOL", markerToken: "tok",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    private func bucket(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAnEmptyBucketIsRemoved() throws {
        let mount = try makeMount()
        let drive = makeDrive()
        let root = ReplicationService.replicaRoot(drive: drive, mountURL: mount)
        let empty = try bucket(root, "ab")

        ReplicationService.pruneEmptyBucket(empty, replicaRoot: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testABucketWithFilesIsKept() throws {
        let mount = try makeMount()
        let drive = makeDrive()
        let root = ReplicationService.replicaRoot(drive: drive, mountURL: mount)
        let occupied = try bucket(root, "cd")
        try Data("photo".utf8).write(to: occupied.appendingPathComponent("keep.jpg"))

        ReplicationService.pruneEmptyBucket(occupied, replicaRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.path))
    }

    /// The replica root itself stays. It existing is how the drive reads as one
    /// the app manages, and the copy path would recreate it anyway.
    func testTheReplicaRootIsNeverRemoved() throws {
        let mount = try makeMount()
        let drive = makeDrive()
        let root = ReplicationService.replicaRoot(drive: drive, mountURL: mount)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        ReplicationService.pruneEmptyBucket(root, replicaRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    /// The guard that matters. A directory outside the managed replica root is
    /// the user's, and no argument the caller passes may reach it.
    func testNothingOutsideTheReplicaRootIsTouched() throws {
        let mount = try makeMount()
        let drive = makeDrive()
        let root = ReplicationService.replicaRoot(drive: drive, mountURL: mount)
        // An empty folder of the user's, sitting beside the app's own.
        let theirs = mount.appendingPathComponent("My Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)

        ReplicationService.pruneEmptyBucket(theirs, replicaRoot: root)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: theirs.path),
            "an empty directory outside the replica root is still the user's"
        )
    }

    /// A sibling directory whose name merely starts with the root's path must
    /// not be mistaken for a child of it.
    func testAPrefixMatchIsNotTreatedAsInside() throws {
        let mount = try makeMount()
        let drive = makeDrive()
        let root = ReplicationService.replicaRoot(drive: drive, mountURL: mount)
        let lookalike = URL(fileURLWithPath: root.path + "Extra", isDirectory: true)
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)

        ReplicationService.pruneEmptyBucket(lookalike, replicaRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path))
    }

    func testTheSweepClearsEmptyBucketsAndKeepsOccupiedOnes() throws {
        let mount = try makeMount()
        let drive = makeDrive()
        let root = ReplicationService.replicaRoot(drive: drive, mountURL: mount)
        for name in ["00", "1a", "ff"] { _ = try bucket(root, name) }
        let occupied = try bucket(root, "7c")
        try Data("photo".utf8).write(to: occupied.appendingPathComponent("keep.jpg"))

        let removed = ReplicationService.pruneEmptyBuckets(drive: drive, mountURL: mount)

        XCTAssertEqual(removed, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
}
