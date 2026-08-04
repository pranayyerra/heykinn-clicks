import XCTest
@testable import HeykinnClicks

/// The size/mtime gate: the only thing in the system that notices a file edited
/// in place under a path that still resolves.
@MainActor
final class ReplicaStatGateTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeMount() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func makeTarget() -> ReplicationTarget {
        ReplicationTarget(
            id: UUID(), name: "Target", volumeUUID: "VOL", markerToken: "tok",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    private func makeAsset(size: Int64 = 5, hash: String = "hash") -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "photo.jpg",
            importOrigin: .googleTakeout, captureDate: Date(), importDate: Date(),
            updatedDate: Date(), fileSize: size, pixelWidth: 1, pixelHeight: 1,
            contentHash: hash, residency: .local, residencySource: .importDefault,
            presence: DomainPresence(local: true, appleCloud: false, googleCloud: false),
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
        )
    }

    private func replica(
        _ asset: Asset, _ target: ReplicationTarget, path: String,
        size: Int64? = nil, modified: Date? = nil
    ) -> TargetReplicaState {
        TargetReplicaState(
            assetID: asset.id, targetID: target.id, state: .present,
            relativePath: path, lastVerifiedAt: Date(),
            observedSize: size, observedModifiedAt: modified
        )
    }

    // MARK: - Grouping

    /// The reason this is affordable at all. A Takeout export is a handful of
    /// large files, and the replicas inside them must not each cost a stat.
    func testThousandsOfArchiveBackedReplicasResolveToAHandfulOfFiles() throws {
        let mount = try makeMount()
        let target = makeTarget()
        var assetsByID: [UUID: Asset] = [:]
        var replicas: [TargetReplicaState] = []

        // Two zips holding 5,000 entries between them, plus one whole export
        // part backing another 5,000.
        for index in 0..<10_000 {
            let asset = makeAsset()
            assetsByID[asset.id] = asset
            let path: String
            switch index % 3 {
            case 0: path = "zipmember:exports/part-1.zip!Google Photos/\(index).jpg"
            case 1: path = "zipmember:exports/part-2.zip!Google Photos/\(index).jpg"
            default: path = "archivepart:takeout-S-001"
            }
            replicas.append(replica(asset, target, path: path))
        }

        let subjects = ReplicaStatGate.subjects(
            replicas: replicas,
            assetsByID: assetsByID,
            target: target,
            mountURL: mount,
            archivePartPaths: ["takeout-S-001": mount.appendingPathComponent("takeout-S-001.zip").path]
        )

        XCTAssertEqual(subjects.count, 3, "Ten thousand replicas, three files to stat")
        XCTAssertEqual(subjects.reduce(0) { $0 + $1.replicas.count }, 10_000)
        XCTAssertTrue(
            subjects.allSatisfy { !$0.isOwnFile },
            "A zip is not the photograph, so its length says nothing about the asset's"
        )
    }

    /// A part whose location on this target is unknown is skipped, not guessed
    /// at: stat-ing a path the app invented would report every replica behind
    /// it as absent.
    func testAnExportPartWithNoKnownLocationIsSkipped() throws {
        let mount = try makeMount()
        let target = makeTarget()
        let asset = makeAsset()

        let subjects = ReplicaStatGate.subjects(
            replicas: [replica(asset, target, path: "archivepart:takeout-S-009")],
            assetsByID: [asset.id: asset],
            target: target,
            mountURL: mount,
            archivePartPaths: [:]
        )

        XCTAssertTrue(subjects.isEmpty)
    }

    /// Loose files each stand for themselves, and their length is the asset's.
    func testLooseFilesAreTheirOwnSubjects() throws {
        let mount = try makeMount()
        let target = makeTarget()
        let first = makeAsset()
        let second = makeAsset()

        let subjects = ReplicaStatGate.subjects(
            replicas: [
                replica(first, target, path: "volume:Takeout/Google Photos/a.jpg"),
                replica(second, target, path: "volume:Takeout/Google Photos/b.jpg"),
            ],
            assetsByID: [first.id: first, second.id: second],
            target: target,
            mountURL: mount,
            archivePartPaths: [:]
        )

        XCTAssertEqual(subjects.count, 2)
        XCTAssertTrue(subjects.allSatisfy(\.isOwnFile))
        XCTAssertEqual(
            subjects.first?.url.path,
            mount.appendingPathComponent("Takeout/Google Photos/a.jpg").path
        )
    }

    // MARK: - Findings

    func testAFileMatchingItsRecordedShapeIsNotRead() throws {
        let mount = try makeMount()
        let file = mount.appendingPathComponent("a.jpg")
        try Data("bytes".utf8).write(to: file)
        let observed = try XCTUnwrap(ReplicaStatGate.observe(file))
        let asset = makeAsset(size: 5)
        let existing = replica(
            asset, makeTarget(), path: "volume:a.jpg",
            size: observed.size, modified: observed.modifiedAt
        )

        XCTAssertEqual(
            ReplicaStatGate.finding(for: existing, expectedSize: 5, observed: observed),
            .unchanged
        )
    }

    /// The case the gate exists for: bytes rewritten under an intact path. No
    /// hash the catalog holds changed, so nothing else in the system notices.
    func testAFileEditedInPlaceIsFlaggedForReading() throws {
        let mount = try makeMount()
        let file = mount.appendingPathComponent("a.jpg")
        try Data("bytes".utf8).write(to: file)
        let before = try XCTUnwrap(ReplicaStatGate.observe(file))
        let asset = makeAsset(size: 5)
        let existing = replica(
            asset, makeTarget(), path: "volume:a.jpg",
            size: before.size, modified: before.modifiedAt
        )

        try Data("different bytes".utf8).write(to: file)
        let after = try XCTUnwrap(ReplicaStatGate.observe(file))

        guard case .changed = ReplicaStatGate.finding(
            for: existing, expectedSize: 5, observed: after
        ) else {
            return XCTFail("An in-place edit must be caught")
        }
    }

    /// A same-length edit still moves the clock, which is the whole reason the
    /// gate watches two things rather than one.
    func testASameLengthEditIsCaughtByItsModificationDate() throws {
        let mount = try makeMount()
        let file = mount.appendingPathComponent("a.jpg")
        try Data("bytes".utf8).write(to: file)
        let asset = makeAsset(size: 5)
        let existing = replica(
            asset, makeTarget(), path: "volume:a.jpg",
            size: 5, modified: Date(timeIntervalSince1970: 1_000_000)
        )
        let now = try XCTUnwrap(ReplicaStatGate.observe(file))
        XCTAssertEqual(now.size, 5, "Same length, different content")

        guard case .changed = ReplicaStatGate.finding(
            for: existing, expectedSize: 5, observed: now
        ) else {
            return XCTFail("A same-length edit must be caught by its date")
        }
    }

    /// A timestamp that shifted by a filesystem's rounding is not an edit.
    /// Re-reading a whole target because exFAT rounded is the overhead this
    /// design exists to avoid.
    func testATimestampWithinTheFilesystemsGranularityIsNotAnEdit() {
        let recorded = Date(timeIntervalSince1970: 1_000_000)
        let existing = replica(
            makeAsset(), makeTarget(), path: "volume:a.jpg", size: 5, modified: recorded
        )

        XCTAssertEqual(
            ReplicaStatGate.finding(
                for: existing, expectedSize: 5,
                observed: ReplicaStatGate.Observation(
                    size: 5, modifiedAt: recorded.addingTimeInterval(1)
                )
            ),
            .unchanged
        )
    }

    /// With no baseline the gate says so rather than inventing a verdict — but
    /// a file that is the wrong length is wrong whether or not anyone wrote
    /// down what it used to be. This is what makes the first run useful.
    func testWithNoBaselineTheCatalogsOwnSizeStillCatchesAWrongFile() {
        let existing = replica(makeAsset(size: 5), makeTarget(), path: "volume:a.jpg")

        XCTAssertEqual(
            ReplicaStatGate.finding(
                for: existing, expectedSize: 5,
                observed: ReplicaStatGate.Observation(size: 5, modifiedAt: Date())
            ),
            .baselineRecorded,
            "Right length, nothing recorded: a baseline, not a check"
        )
        guard case .changed = ReplicaStatGate.finding(
            for: existing, expectedSize: 5,
            observed: ReplicaStatGate.Observation(size: 9, modifiedAt: Date())
        ) else {
            return XCTFail("The wrong length is wrong on the first look too")
        }
    }

    /// A zip's length is not the length of any photo inside it, so there is
    /// nothing to compare on a first look — and the gate must not invent one.
    func testAnArchiveBackedReplicaHasNoSizeToCompareOnItsFirstLook() {
        let existing = replica(makeAsset(size: 5), makeTarget(), path: "archivepart:takeout-S-001")

        XCTAssertEqual(
            ReplicaStatGate.finding(
                for: existing, expectedSize: nil,
                observed: ReplicaStatGate.Observation(size: 4_000_000_000, modifiedAt: Date())
            ),
            .baselineRecorded
        )
    }

    /// A missing file is path repair's business. Reporting it here as well
    /// would double-count one fault as two.
    func testAMissingFileIsReportedAbsentRatherThanChanged() {
        let existing = replica(
            makeAsset(), makeTarget(), path: "volume:a.jpg", size: 5, modified: Date()
        )

        XCTAssertEqual(
            ReplicaStatGate.finding(for: existing, expectedSize: 5, observed: nil),
            .absent
        )
    }
}
