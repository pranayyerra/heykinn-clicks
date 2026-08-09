import XCTest
@testable import HeykinnClicks

/// What the archive would be left with if something went.
///
/// Every test here runs against a deliberately awkward archive, because the
/// real one cannot prove any of this: all 21,401 of its photos are in exactly
/// two places, so every projection over it returns nothing or everything, and
/// a rule that has only ever produced those two answers has not been tested.
/// The fixture holds one photo of each shape the model has to tell apart.
final class LossProjectionTests: XCTestCase {

    private let driveA = UUID(), driveB = UUID(), mac = UUID()
    private let groupOne = UUID(), groupTwo = UUID()

    private func photo(_ name: String, staged: Bool = false) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: staged ? "staging/\(name)" : nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    private func replica(
        _ asset: Asset, on target: UUID,
        state: ReplicaFileState = .present, path: String = "Buckets/aa/file.jpg"
    ) -> TargetReplicaState {
        TargetReplicaState(
            assetID: asset.id, targetID: target, state: state,
            relativePath: path, lastVerifiedAt: state == .present ? Date() : nil
        )
    }

    private let inDownload = ReplicationService.archivePartPrefix + "takeout-20260710-001"

    /// One photo of every shape that behaves differently under a loss.
    private func awkwardArchive() -> (LossProjection.Input, [String: Asset]) {
        let safe = photo("safe.jpg")             // A and B, real files
        let onlyA = photo("only-a.jpg")          // A alone
        let onlyMac = photo("only-mac.jpg")      // this Mac alone
        let zipped = photo("zipped.jpg")         // inside the download on A and B
        let halfOut = photo("half-out.jpg")      // in the download on A, a real file on B
        let arriving = photo("arriving.jpg", staged: true)   // staging only, no drive yet
        let queued = photo("queued.jpg", staged: true)  // staging, and pending on A
        let rotten = photo("rotten.jpg")         // present on A, damaged on B
        let orphan = photo("orphan.jpg")         // nowhere at all
        var motion = photo("live.mov")           // a Live Photo's other half
        motion.livePhotoStillID = safe.id

        let assets = [safe, onlyA, onlyMac, zipped, halfOut, arriving, queued, rotten, orphan, motion]
        var replicas: [TargetReplicaState] = [
            replica(safe, on: driveA), replica(safe, on: driveB),
            replica(onlyA, on: driveA),
            replica(onlyMac, on: mac),
            replica(zipped, on: driveA, path: inDownload),
            replica(zipped, on: driveB, path: inDownload),
            replica(halfOut, on: driveA, path: inDownload),
            replica(halfOut, on: driveB),
            replica(queued, on: driveA, state: .pending),
            replica(rotten, on: driveA),
            replica(rotten, on: driveB, state: .drift),
            // The motion half is copied and verified like anything else, and
            // must not be counted as a photo by any of this.
            replica(motion, on: driveA), replica(motion, on: driveB),
        ]
        replicas.shuffle()

        let groups = [
            safe.id: groupOne, onlyA.id: groupOne, zipped.id: groupOne, halfOut.id: groupOne,
            onlyMac.id: groupTwo, arriving.id: groupTwo, queued.id: groupTwo,
            rotten.id: groupTwo, orphan.id: groupTwo,
        ]
        let input = LossProjection.Input(
            assets: assets, replicas: replicas, groupOfAsset: groups, hostTargetID: mac
        )
        let named = Dictionary(uniqueKeysWithValues: [
            ("safe", safe), ("onlyA", onlyA), ("onlyMac", onlyMac), ("zipped", zipped),
            ("halfOut", halfOut), ("arriving", arriving), ("queued", queued),
            ("rotten", rotten), ("orphan", orphan),
        ])
        return (input, named)
    }

    func testLosingADriveCostsOnlyThePhotosItAloneHeld() {
        let (input, _) = awkwardArchive()
        let projection = LossProjection.project(.device(driveA), in: input)
        XCTAssertEqual(projection.lost, 2, "only-a.jpg, and rotten.jpg whose other copy is damaged")
        XCTAssertEqual(
            projection.alreadyUnprotected, 1,
            "orphan.jpg was already in no place — losing a drive did not cost that"
        )
        XCTAssertEqual(projection.lostByGroup[groupOne], 1)
        XCTAssertEqual(projection.lostByGroup[groupTwo], 1)
    }

    /// The one a replica-shaped model gets wrong. A photo waiting in staging has
    /// no replica row at all, so the naive answer to "what does losing this Mac
    /// cost" is zero — wrong by exactly the photos with the least protection.
    func testLosingThisMacTakesTheStagingAreaWithIt() {
        let (input, _) = awkwardArchive()
        let projection = LossProjection.project(.device(mac), in: input)
        XCTAssertEqual(
            projection.lost, 3,
            """
            only-mac.jpg; arriving.jpg, which exists nowhere but staging; and \
            queued.jpg, whose one replica on driveA is still pending — a promise, \
            not a copy. All three are invisible to a model built from replicas alone.
            """
        )
        XCTAssertEqual(
            LossProjection.project(.device(driveA), in: input).lost, 2,
            "and staging keeps queued.jpg alive when a drive is what fails"
        )
    }

    func testLosingADriveDoesNotTouchStaging() {
        let (input, names) = awkwardArchive()
        var input2 = input
        // Strip every replica of the staged-and-pending photo so staging is
        // genuinely its only home.
        input2.replicas.removeAll { $0.assetID == names["queued"]!.id }
        XCTAssertEqual(
            LossProjection.project(.device(driveA), in: input2).lost, 2,
            "queued.jpg survives on this Mac when a drive dies"
        )
        XCTAssertEqual(
            LossProjection.project(.device(mac), in: input2).lost, 3,
            "and goes when this Mac does"
        )
    }

    /// The archive's real weak point, and the distinction the wording has to
    /// carry: deleting the downloads everywhere is a catastrophe, deleting them
    /// from one drive is housekeeping.
    func testDeletingDownloadsEverywhereIsNotTheSameAsDeletingThemHere() {
        let (input, _) = awkwardArchive()

        let everywhere = LossProjection.project(.downloadsEverywhere, in: input)
        XCTAssertEqual(
            everywhere.lost, 1,
            "zipped.jpg is inside the download on both drives, so one decision takes both copies"
        )
        XCTAssertEqual(
            everywhere.reducedToOneCopy, 1,
            "half-out.jpg keeps the real file it was copied out to on driveB"
        )

        let onA = LossProjection.project(.downloadsOn(driveA), in: input)
        XCTAssertEqual(onA.lost, 0, "the other drive's copy of the download is still there")
        XCTAssertGreaterThan(
            onA.reducedToOneCopy, 0,
            "but the photos inside it are down to a single copy, which is the point of saying so"
        )
    }

    /// A Live Photo is one photo though it is two files. Every sentence built
    /// from a projection says "photo", so the motion half must not be one.
    func testAMotionHalfIsNotAPhotoThatCanBeLost() {
        let (input, _) = awkwardArchive()
        XCTAssertEqual(input.photos.count, 9, "ten assets, nine photos")
        let everything = LossProjection.project(.device(driveA), in: input)
        let alsoEverything = LossProjection.project(.device(driveB), in: input)
        XCTAssertEqual(everything.lost + everything.alreadyUnprotected, 3)
        XCTAssertEqual(alsoEverything.lost, 0, "driveB is the sole holder of nothing")
    }

    func testAnUntouchedArchiveProjectsNoLossAtAll() {
        let only = photo("a.jpg")
        let input = LossProjection.Input(
            assets: [only],
            replicas: [replica(only, on: driveA), replica(only, on: driveB)]
        )
        let projection = LossProjection.project(.device(driveA), in: input)
        XCTAssertTrue(projection.isHarmless)
        XCTAssertEqual(projection.reducedToOneCopy, 1, "it survives, on one drive")
        XCTAssertEqual(projection.alreadyUnprotected, 0)
    }
}
