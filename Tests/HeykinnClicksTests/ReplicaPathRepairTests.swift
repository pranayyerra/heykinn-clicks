import XCTest
@testable import HeykinnClicks

/// Renaming a folder on a target invalidates every path recorded beneath it.
/// The content is still there, so the answer is to find it — not to copy it
/// again.
final class ReplicaPathRepairTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeMount() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func makeTree(_ mount: URL, _ relative: String) throws {
        try FileManager.default.createDirectory(
            at: mount.appendingPathComponent(relative),
            withIntermediateDirectories: true
        )
    }

    /// The case that happened: an ancestor folder renamed, everything beneath
    /// it intact under the new name.
    func testARenamedAncestorIsFoundAndRewritten() throws {
        let mount = try makeMount()
        try makeTree(mount, "Owner/Backup_Google_Takeout/takeout-001/Google Photos")

        let recorded = [
            "volume:Owner/Backup_Google/takeout-001/Google Photos/a.jpg",
            "volume:Owner/Backup_Google/takeout-001/Google Photos/b.jpg",
        ]
        let plan = ReplicaPathRepair.plan(recordedPaths: recorded, mountURL: mount)

        XCTAssertEqual(plan.unplaceable, [])
        XCTAssertEqual(
            ReplicaPathRepair.apply(plan, to: recorded[0]),
            "volume:Owner/Backup_Google_Takeout/takeout-001/Google Photos/a.jpg"
        )
    }

    /// Thousands of replicas under one renamed folder must cost one check, not
    /// thousands: the whole point of the gate is that it is cheap enough to run
    /// whenever a target is looked at.
    func testManyReplicasUnderOneRenameProduceASingleRewrite() throws {
        let mount = try makeMount()
        try makeTree(mount, "Owner/Renamed/takeout-001/Google Photos")

        let recorded = (1...5_000).map { "volume:Owner/Original/takeout-001/Google Photos/\($0).jpg" }
        let plan = ReplicaPathRepair.plan(recordedPaths: recorded, mountURL: mount)

        XCTAssertEqual(plan.rewrites.count, 1)
        XCTAssertEqual(
            ReplicaPathRepair.apply(plan, to: recorded[4_999]),
            "volume:Owner/Renamed/takeout-001/Google Photos/5000.jpg"
        )
    }

    func testPathsThatStillResolveAreLeftAlone() throws {
        let mount = try makeMount()
        try makeTree(mount, "Owner/Backup_Google/takeout-001/Google Photos")

        let plan = ReplicaPathRepair.plan(
            recordedPaths: ["volume:Owner/Backup_Google/takeout-001/Google Photos/a.jpg"],
            mountURL: mount
        )

        XCTAssertTrue(plan.isEmpty, "Nothing moved, so there is nothing to repair")
    }

    /// Guessing between two candidates would point the archive at the wrong
    /// content, which is worse than admitting the content cannot be found.
    func testAnAmbiguousMatchIsRefusedRatherThanGuessed() throws {
        let mount = try makeMount()
        try makeTree(mount, "A/Backup/takeout-001")
        try makeTree(mount, "B/Backup/takeout-001")

        let plan = ReplicaPathRepair.plan(
            recordedPaths: ["volume:Owner/Gone/takeout-001/x.jpg"],
            mountURL: mount
        )

        XCTAssertEqual(plan.rewrites, [])
        XCTAssertEqual(plan.unplaceable, ["Owner/Gone/takeout-001"])
    }

    func testContentThatIsSimplyGoneIsReportedNotInvented() throws {
        let mount = try makeMount()
        try makeTree(mount, "Something/Else")

        let plan = ReplicaPathRepair.plan(
            recordedPaths: ["volume:Owner/Gone/takeout-001/x.jpg"],
            mountURL: mount
        )

        XCTAssertEqual(plan.rewrites, [])
        XCTAssertEqual(plan.unplaceable, ["Owner/Gone/takeout-001"])
        XCTAssertNil(ReplicaPathRepair.apply(plan, to: "volume:Owner/Gone/takeout-001/x.jpg"))
    }

    /// Replicas the app laid down itself live under its own replica root and
    /// are not user-managed paths; they are not this mechanism's business.
    func testAppManagedReplicaPathsAreIgnored() throws {
        let mount = try makeMount()
        let plan = ReplicaPathRepair.plan(
            recordedPaths: ["d6/D6DA3AC1-30DA-4349-8595-CFFF8E79B892.png"],
            mountURL: mount
        )

        XCTAssertTrue(plan.isEmpty)
    }
}
