import XCTest
@testable import HeykinnClicks

/// The one derivation, tested against an archive built to be awkward.
///
/// The real archive proves none of this: every photograph on it is in two
/// places on the drives its group names, so the projection over it returns the
/// same healthy answer for every row, and a rule that has only ever produced
/// one answer has not been tested. The fixture below holds one photograph of
/// each shape the model has to tell apart — including the three that shipped as
/// bugs this week: a copy on a drive nobody asked for, a movie half kept worse
/// than its still, and a row holding no bytes at all.
final class ArchiveProjectionTests: XCTestCase {

    private let named = UUID(), alsoNamed = UUID(), stranger = UUID()
    private let group = UUID(), weakGroup = UUID()

    private func photo(
        _ name: String, kind: AssetKind = .photo,
        residency: ResidencyDomain = .local, indexed: Bool = false
    ) -> Asset {
        Asset(
            id: UUID(), kind: kind, originalFilename: name, importOrigin: .appleExport,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil,
            contentHash: indexed ? Asset.providerIndexHashPrefix + name : UUID().uuidString,
            residency: residency, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
        )
    }

    private func replica(
        _ asset: Asset, on target: UUID,
        state: ReplicaFileState = .present, verified: Date? = Date()
    ) -> TargetReplicaState {
        TargetReplicaState(
            assetID: asset.id, targetID: target, state: state,
            relativePath: "Buckets/aa/\(asset.originalFilename)",
            lastVerifiedAt: state == .present ? verified : nil
        )
    }

    private func policy(_ wants: Int, _ targets: Set<UUID>) -> ArchiveProjection.Input.Policy {
        ArchiveProjection.Input.Policy(wants: wants, named: targets)
    }

    /// One photograph of every shape that behaves differently.
    private func awkwardArchive() -> (ArchiveProjection.Input, [String: Asset]) {
        let safe = photo("safe.heic")
        let onlyOne = photo("only-one.heic")
        let unverified = photo("unverified.heic")
        let misplaced = photo("misplaced.heic")      // two copies, neither asked for
        let leaving = photo("leaving.heic")
        let drifted = photo("drifted.heic")
        let staged = photo("staged.heic")
        let indexedOnly = photo("indexed.heic", indexed: true)
        let cloud = photo("cloud.heic", residency: .appleCloud)
        // A Live Photo whose still is kept twice and whose movie is kept once.
        let liveStill = photo("live.heic", kind: .livePhoto)
        var liveMotion = photo("live.mov", kind: .video)
        liveMotion.livePhotoStillID = liveStill.id

        let assets = [
            safe, onlyOne, unverified, misplaced, leaving, drifted,
            staged, indexedOnly, cloud, liveStill, liveMotion,
        ]
        var replicas: [TargetReplicaState] = [
            replica(safe, on: named), replica(safe, on: alsoNamed),
            replica(onlyOne, on: named),
            replica(unverified, on: named), replica(unverified, on: alsoNamed, verified: nil),
            replica(misplaced, on: stranger), replica(misplaced, on: UUID()),
            replica(leaving, on: named), replica(leaving, on: alsoNamed),
            replica(leaving, on: stranger),
            replica(drifted, on: named), replica(drifted, on: alsoNamed, state: .drift),
            replica(indexedOnly, on: named),
            replica(liveStill, on: named), replica(liveStill, on: alsoNamed),
            replica(liveMotion, on: named),
        ]
        // Nothing may depend on the order rows arrive in.
        replicas.shuffle()

        let tasks = [
            ReplicationTask(
                id: UUID(), assetID: leaving.id, targetID: stranger, action: .remove,
                state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
            )
        ]
        var groupOf: [UUID: UUID] = [:]
        for asset in assets { groupOf[asset.id] = group }
        // The movie half left on the weaker policy, as the backfill used to.
        groupOf[liveMotion.id] = weakGroup

        let input = ArchiveProjection.Input(
            assets: assets,
            replicaStates: replicas,
            replicationTasks: tasks,
            groupOfAsset: groupOf,
            policyOfGroup: [
                group: policy(2, [named, alsoNamed]),
                weakGroup: policy(2, [named, alsoNamed]),
            ],
            fallbackPolicy: policy(2, [])
        )
        let byName = Dictionary(uniqueKeysWithValues: assets.map { ($0.originalFilename, $0) })
        return (input, byName)
    }

    private func photograph(
        _ name: String, in result: ArchiveProjection.Result, _ byName: [String: Asset]
    ) throws -> ArchiveProjection.Photograph {
        try XCTUnwrap(result.photograph(try XCTUnwrap(byName[name]).id), "no photograph for \(name)")
    }

    // MARK: - The unit is a photograph

    /// The movie half of a Live Photo is not a photograph. Counting it as one is
    /// how a numerator of 25 ended up quoted against a total of 23,121 that
    /// excluded every one of them.
    func testAMovieHalfIsPartOfAPhotographAndNeverOneItself() throws {
        let (input, byName) = awkwardArchive()
        let result = ArchiveProjection.project(input)

        XCTAssertEqual(result.counted, 10, "eleven rows, ten photographs")
        XCTAssertNil(
            result.photograph(try XCTUnwrap(byName["live.mov"]).id),
            "the movie is reached through its still, never on its own"
        )
        let live = try photograph("live.heic", in: result, byName)
        XCTAssertEqual(live.motion, try XCTUnwrap(byName["live.mov"]).id)
        XCTAssertLessThanOrEqual(
            result.short, result.counted,
            "a numerator can never exceed the total it is quoted against"
        )
    }

    /// A photograph is only as safe as its worse-off half.
    func testAPhotographTakesTheVerdictOfItsWorseHalf() throws {
        let (input, byName) = awkwardArchive()
        let result = ArchiveProjection.project(input)
        let live = try photograph("live.heic", in: result, byName)

        XCTAssertEqual(live.placement.presentOnNamed.count, 2, "the still itself is kept twice")
        XCTAssertEqual(try XCTUnwrap(live.motionPlacement).presentOnNamed.count, 1)
        XCTAssertTrue(live.isShort, "so the photograph is short, because half of it is")
    }

    // MARK: - Where the copies are

    /// A copy on a drive the group does not name is a real file and not a copy
    /// where it was asked for. Counting it as protection is what had the archive
    /// calling photographs safe on the strength of copies it was about to delete.
    func testACopyOnAnUnnamedDriveIsHeldButNotWhereItWasAskedFor() throws {
        let (input, byName) = awkwardArchive()
        let result = ArchiveProjection.project(input)
        let misplaced = try photograph("misplaced.heic", in: result, byName)

        XCTAssertEqual(misplaced.placement.presentOnNamed.count, 0)
        XCTAssertEqual(misplaced.placement.presentElsewhere.count, 2)
        XCTAssertEqual(misplaced.placement.presentAnywhere.count, 2, "two real files, both counted")
        XCTAssertTrue(misplaced.placement.isShortOfWanted)
        XCTAssertTrue(misplaced.isShort, "and the photograph is short, with two copies")
    }

    /// Queued deletions are counted as leaving, never folded into what is
    /// arriving — the grid drew them as work in progress on a drive it was
    /// about to erase files from.
    func testAQueuedRemovalIsCountedAsLeavingAndNotAsArriving() throws {
        let (input, byName) = awkwardArchive()
        let result = ArchiveProjection.project(input)
        let leaving = try photograph("leaving.heic", in: result, byName)

        XCTAssertEqual(leaving.placement.leaving, [stranger])
        XCTAssertTrue(leaving.placement.pending.isEmpty, "nothing is on its way here")
        XCTAssertEqual(leaving.placement.presentOnNamed.count, 2, "and it is kept as asked")
        XCTAssertFalse(leaving.isShort)
    }

    /// The four senses of "held" are different questions and must stay apart.
    func testTheSensesOfHeldAreDistinct() throws {
        let (input, byName) = awkwardArchive()
        let result = ArchiveProjection.project(input)

        let unverified = try photograph("unverified.heic", in: result, byName)
        XCTAssertEqual(unverified.placement.presentOnNamed.count, 2, "two files are there")
        XCTAssertEqual(
            unverified.placement.verifiedOnNamed.count, 1,
            "only one has been read back, which is what a removal may be proven against"
        )

        let drifted = try photograph("drifted.heic", in: result, byName)
        XCTAssertEqual(drifted.placement.damaged.count, 1)
        XCTAssertEqual(
            drifted.placement.readable.count, 2,
            "a drifted copy still has bytes to read, so the patrol has something to check"
        )
        XCTAssertEqual(drifted.verdict, .driftDetected)
    }

    // MARK: - Aggregates

    func testCoverageCountsPlacesHoldingAPhotographAndSkipsThoseHeldNowhere() throws {
        let (input, byName) = awkwardArchive()
        let result = ArchiveProjection.project(input)

        let staged = try photograph("staged.heic", in: result, byName)
        XCTAssertTrue(staged.placement.presentAnywhere.isEmpty)
        XCTAssertNil(result.copyCoverage[0], "held nowhere is absent, not counted as zero places")
        XCTAssertEqual(result.copyCoverage.values.reduce(0, +), 8, "the eight held somewhere")
    }

    /// A photograph that is not local is not judged at all — it is somewhere
    /// else by design, not short.
    func testACloudPhotographIsNotJudgedAgainstLocalCopies() throws {
        let (input, byName) = awkwardArchive()
        let result = ArchiveProjection.project(input)
        let cloud = try photograph("cloud.heic", in: result, byName)

        XCTAssertEqual(cloud.verdict, .notApplicable)
        XCTAssertFalse(cloud.isShort)
        XCTAssertNil(result.verdictCounts[.notApplicable], "and it is left out of the histogram")
    }

    /// Per group, the shortfall can never exceed the group's own total. The
    /// store's `photosShortByGroup` counts per row and so can.
    func testAGroupsShortfallNeverExceedsItsOwnTotal() {
        let (input, _) = awkwardArchive()
        let result = ArchiveProjection.project(input)

        for (groupID, short) in result.shortByGroup {
            XCTAssertLessThanOrEqual(
                short, result.countByGroup[groupID] ?? 0,
                "group \(groupID) reports more short than it holds"
            )
        }
        XCTAssertEqual(
            result.countByGroup.values.reduce(0, +), result.counted,
            "every photograph belongs to exactly one group's count"
        )
    }

    /// A group naming nowhere judges a photograph on the copies it has, rather
    /// than reporting every one of them short against a list nobody filled in.
    func testAPhotographWhoseGroupNamesNowhereIsJudgedOnTheCopiesItHas() {
        let asset = photo("loose.heic")
        let input = ArchiveProjection.Input(
            assets: [asset],
            replicaStates: [replica(asset, on: stranger), replica(asset, on: named)],
            groupOfAsset: [:],
            policyOfGroup: [:],
            fallbackPolicy: policy(2, [])
        )

        let result = ArchiveProjection.project(input)

        XCTAssertEqual(result.short, 0)
        XCTAssertEqual(result.photographs.first?.verdict, .fullyReplicated)
    }
}
