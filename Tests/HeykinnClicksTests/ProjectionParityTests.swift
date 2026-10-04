import XCTest
@testable import HeykinnClicks

/// The projection and the properties it will replace must say the same thing.
///
/// This is the acceptance test for D17 stage one, and the reason the stage is
/// additive. `ArchiveProjection` is built and published but read by nothing, so
/// the archive currently answers every derived question twice. While that is
/// true it is cheap to prove the two answers agree — and once the screens move
/// over, "no number may change" stops being an aspiration and becomes a thing
/// that already passed.
///
/// Where they *disagree* the divergence is pinned here deliberately rather than
/// smoothed over, because each one is a fault in the old number that stage two
/// inherits the job of fixing.
@MainActor
final class ProjectionParityTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []; suiteNames = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func makeStore(in directory: URL) -> AppStore {
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
    }

    private func asset(_ name: String, kind: AssetKind = .photo) -> Asset {
        Asset(
            id: UUID(), kind: kind, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    /// An archive with every shape that makes the two derivations diverge:
    /// a Live Photo whose movie is a copy short, a photograph held only on a
    /// drive its group does not name, a drifted copy, and one held nowhere.
    private func awkwardStore() throws -> AppStore {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let named = UUID(), alsoNamed = UUID(), stranger = UUID()
        for (id, name) in [(named, "Named"), (alsoNamed, "Also"), (stranger, "Stranger")] {
            try catalog.upsertTarget(ReplicationTarget(
                id: id, name: name, kind: .externalVolume, volumeUUID: nil,
                markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: nil,
                lastKnownPath: "/Volumes/\(name)", configuredPath: nil,
                replicaRootComponent: ReplicationTarget.defaultReplicaRoot
            ))
        }
        let group = StorageGroup(
            id: UUID(), label: "Everything", desiredCopies: 2,
            destinationTargetIDs: [named, alsoNamed], createdAt: Date()
        )
        try catalog.upsertStorageGroup(group)

        let safe = asset("safe.jpg")
        let misplaced = asset("misplaced.jpg")
        let drifted = asset("drifted.jpg")
        let nowhere = asset("nowhere.jpg")
        let still = asset("live.heic", kind: .livePhoto)
        var motion = asset("live.mov", kind: .video)
        motion.livePhotoStillID = still.id

        let all = [safe, misplaced, drifted, nowhere, still, motion]
        for one in all { try catalog.upsertAsset(one) }
        try catalog.assignStorageGroup(group.id, toAssets: all.map(\.id))

        func present(_ a: Asset, _ t: UUID, _ state: ReplicaFileState = .present) throws {
            try catalog.upsertReplicaState(TargetReplicaState(
                assetID: a.id, targetID: t, state: state,
                relativePath: "Buckets/aa/\(a.originalFilename)",
                lastVerifiedAt: state == .present ? Date() : nil
            ))
        }
        try present(safe, named); try present(safe, alsoNamed)
        try present(misplaced, stranger)
        try present(drifted, named); try present(drifted, alsoNamed, .drift)
        // Both halves a copy short. One photograph, but two rows — which is
        // exactly where the row-counted shortfall and the photograph-counted
        // one part company.
        try present(still, named)
        try present(motion, named)

        let store = makeStore(in: directory)
        store.loadAll()
        return store
    }

    // MARK: - Where they must agree

    func testTheTotalAgrees() throws {
        let store = try awkwardStore()
        XCTAssertEqual(store.projection.counted, store.countedPhotoTotal)
        XCTAssertEqual(store.projection.counted, 5, "six rows, five photographs")
    }

    func testTheVerdictHistogramAgrees() throws {
        let store = try awkwardStore()
        XCTAssertEqual(store.projection.verdictCounts, store.protectionCountsByState)
    }

    func testTheHeadlineShortfallAgrees() throws {
        let store = try awkwardStore()
        XCTAssertEqual(store.projection.short, store.safetyFacts.short)
        XCTAssertLessThanOrEqual(
            store.projection.short, store.projection.counted,
            "and can never exceed the total it is quoted against"
        )
    }

    func testTheDamagedCountAgrees() throws {
        let store = try awkwardStore()
        XCTAssertEqual(store.projection.damaged, store.safetyFacts.damaged)
    }

    func testCopyCoverageAgrees() throws {
        let store = try awkwardStore()
        XCTAssertEqual(store.projection.copyCoverage, store.copyCoverage)
    }

    func testPerGroupTotalsAgree() throws {
        let store = try awkwardStore()
        XCTAssertEqual(store.projection.countByGroup, store.photoCountByStorageGroup)
    }

    /// Every target the grid draws a cell for must agree on what is present,
    /// arriving, leaving and damaged. `GroupPlaceCell` counts photographs, so
    /// the projection's still-level placement is the like-for-like comparison.
    func testTheGridCellsAgree() throws {
        let store = try awkwardStore()
        let group = try XCTUnwrap(store.storageGroups.first)

        for target in store.targets {
            let cell = store.cell(group: group.id, place: target.id)
            let photographs = store.projection.photographs.filter { $0.group == group.id }
            let present = photographs.filter { $0.placement.presentAnywhere.contains(target.id) }.count
            let waiting = photographs.filter { $0.placement.pending.contains(target.id) }.count
            let damaged = photographs.filter { $0.placement.damaged.contains(target.id) }.count
            let leaving = photographs.filter { $0.placement.leaving.contains(target.id) }.count

            XCTAssertEqual(cell?.photos ?? 0, present, "photos on \(target.name)")
            XCTAssertEqual(cell?.waiting ?? 0, waiting, "waiting on \(target.name)")
            XCTAssertEqual(cell?.damaged ?? 0, damaged, "damaged on \(target.name)")
            XCTAssertEqual(cell?.leaving ?? 0, leaving, "leaving on \(target.name)")
        }
    }

    // MARK: - The divergence that stage two closed

    /// `photosShortByGroup` used to count rows, so a Live Photo short in both
    /// halves was counted twice and a group could report more short than it
    /// held — which is what put "25 short of two copies" beside a total of
    /// 21,117 when not one photograph in that group was short. It counts
    /// photographs now, so the row's two numbers are drawn from one population.
    func testAGroupsShortfallCountsPhotographsAndNeverExceedsItsOwnTotal() throws {
        let store = try awkwardStore()
        let group = try XCTUnwrap(store.storageGroups.first)

        let short = store.photosShortByGroup[group.id] ?? 0
        let total = store.photoCountByStorageGroup[group.id] ?? 0

        XCTAssertEqual(short, store.projection.shortByGroup[group.id] ?? 0)
        XCTAssertLessThanOrEqual(short, total, "a group cannot be short more than it holds")
        XCTAssertEqual(
            short, 3,
            "the misplaced one, the one held nowhere, and the Live Photo — counted once"
        )
    }

    // MARK: - Invariants

    func testTheInvariantsHold() throws {
        let store = try awkwardStore()
        let projection = store.projection

        XCTAssertLessThanOrEqual(projection.short, projection.counted)
        XCTAssertLessThanOrEqual(projection.damaged, projection.counted)
        XCTAssertEqual(
            projection.countByGroup.values.reduce(0, +), projection.counted,
            "every photograph is in exactly one group's count"
        )
        XCTAssertEqual(
            projection.photographs.count, Set(projection.photographs.map(\.id)).count,
            "one row per photograph"
        )
        for photograph in projection.photographs {
            XCTAssertFalse(
                store.assetsByID[photograph.id]?.isLivePhotoMotion ?? false,
                "a movie half is never a photograph"
            )
            XCTAssertTrue(
                photograph.placement.presentOnNamed
                    .isDisjoint(with: photograph.placement.presentElsewhere),
                "a copy is either where it was asked for or not, never both"
            )
        }
    }
}
