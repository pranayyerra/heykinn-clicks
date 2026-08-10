import XCTest
@testable import HeykinnClicks

/// Guards the figures that moved out of view bodies and into the store.
///
/// Each was a computed property read a dozen times to draw one screen, and a
/// computed property is recomputed at every mention — so a redraw walked the
/// whole archive once per mention. Moving them here is only safe while they
/// still say exactly what the per-view versions said, which is what these
/// tests hold them to.
@MainActor
final class DerivedCountsTests: XCTestCase {

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
            .appendingPathComponent("heykinn-derived-\(UUID().uuidString)", isDirectory: true)
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

    private func asset(
        _ name: String,
        kind: AssetKind = .photo,
        residency: ResidencyDomain = .local,
        captureDate: Date? = nil
    ) -> Asset {
        Asset(
            id: UUID(), kind: kind, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: captureDate, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: residency,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    // MARK: - Counted total

    /// A Live Photo is one photograph. Counting its motion half again is how
    /// "24,618 of them" ended up larger than the set it was drawn from.
    func testCountedTotalCountsALivePhotoOnce() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let still = asset("IMG_1.HEIC", kind: .livePhoto)
        var motion = asset("IMG_1.MOV", kind: .video)
        motion.livePhotoStillID = still.id
        for one in [still, motion, asset("IMG_2.jpg")] { try catalog.upsertAsset(one) }

        let store = makeStore(in: directory)
        store.loadAll()

        XCTAssertTrue(motion.isLivePhotoMotion, "Fixture must actually be a motion half")
        XCTAssertEqual(store.countedPhotoTotal, 2, "The motion half is not its own photograph")
        XCTAssertEqual(
            store.countedPhotoTotal,
            store.assets.count { !$0.isLivePhotoMotion },
            "Must match the count the views used to do for themselves"
        )
    }

    // MARK: - Protection counts

    /// The store's tally must agree with counting the verdicts by hand, which
    /// is what every view did before.
    func testProtectionCountsMatchCountingTheVerdictsByHand() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let drive = UUID()
        var held: [Asset] = []
        for index in 0..<12 {
            let one = asset("IMG_\(index).jpg")
            try catalog.upsertAsset(one)
            held.append(one)
            // Two thirds get a copy, so the tally has more than one bucket in it.
            if index % 3 != 0 {
                try catalog.upsertReplicaState(TargetReplicaState(
                    assetID: one.id, targetID: drive, state: .present,
                    relativePath: "volume:drive/\(index).jpg", lastVerifiedAt: Date()
                ))
            }
        }

        let store = makeStore(in: directory)
        store.loadAll()

        var byHand: [ProtectionState: Int] = [:]
        for one in store.assets where !one.isLivePhotoMotion {
            guard let state = store.protectionStates[one.id], state != .notApplicable else { continue }
            byHand[state, default: 0] += 1
        }
        XCTAssertFalse(byHand.isEmpty, "Fixture must produce verdicts to compare")
        XCTAssertEqual(store.protectionCountsByState, byHand)
        XCTAssertEqual(
            store.protectionCountsByState.values.reduce(0, +),
            byHand.values.reduce(0, +),
            "The totals the Overview prints must not drift from the buckets under them"
        )
    }

    // MARK: - Residency uniformity

    /// The badge is drawn per photo but decided for the archive, so this has to
    /// be the archive's answer and not the visible page's.
    func testResidencyIsUniformUntilSomethingLivesElsewhere() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        for index in 0..<4 { try catalog.upsertAsset(asset("IMG_\(index).jpg", residency: .local)) }

        let store = makeStore(in: directory)
        store.loadAll()
        XCTAssertTrue(store.residencyIsUniform, "Every photo is Local")

        try catalog.upsertAsset(asset("cloudy.jpg", residency: .appleCloud))
        store.loadAll()
        XCTAssertFalse(store.residencyIsUniform, "One photo lives somewhere else")
    }

    /// An empty archive has nothing to disagree with itself about.
    func testEmptyArchiveReadsAsUniform() throws {
        let directory = try makeDirectory()
        _ = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let store = makeStore(in: directory)
        store.loadAll()
        XCTAssertTrue(store.residencyIsUniform)
        XCTAssertEqual(store.countedPhotoTotal, 0)
    }
}

/// The fourteen newest thumbnails on the Overview used to cost a sort of the
/// whole archive, paid twice per redraw. The replacement keeps a fourteen-long
/// list instead — which is only worth having if it picks the same photographs.
final class NewestSelectionTests: XCTestCase {

    private func asset(_ name: String, captureDate: Date?, importDate: Date) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: captureDate, importDate: importDate, updatedDate: importDate, fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    /// The sort it replaced, kept here as the thing to agree with.
    private func bySorting(_ count: Int, in assets: [Asset]) -> [Asset] {
        assets
            .filter { !$0.isLivePhotoMotion }
            .sorted { ($0.captureDate ?? $0.importDate) > ($1.captureDate ?? $1.importDate) }
            .prefix(count)
            .map { $0 }
    }

    func testPicksTheSamePhotographsAsSortingTheArchive() {
        let epoch = Date(timeIntervalSince1970: 1_600_000_000)
        var assets: [Asset] = []
        for index in 0..<500 {
            // Deliberately unordered, and a third with no capture date so the
            // import-date fallback is exercised too.
            let offset = TimeInterval((index * 7919) % 500) * 3_600
            let stamp = epoch.addingTimeInterval(offset)
            assets.append(
                index % 3 == 0
                    ? asset("IMG_\(index).jpg", captureDate: nil, importDate: stamp)
                    : asset("IMG_\(index).jpg", captureDate: stamp, importDate: epoch)
            )
        }

        let picked = OverviewView.newest(14, in: assets)
        let sorted = bySorting(14, in: assets)

        XCTAssertEqual(picked.count, 14)
        XCTAssertEqual(
            picked.map { $0.captureDate ?? $0.importDate },
            sorted.map { $0.captureDate ?? $0.importDate },
            "Must be the same fourteen dates, newest first"
        )
        XCTAssertEqual(picked.map(\.id), sorted.map(\.id))
    }

    /// Ties are the case a partial selection gets wrong: every photograph here
    /// carries the same date, so the list must still fill and stay the length
    /// it was asked for.
    func testIdenticalDatesStillFillTheList() {
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        let assets = (0..<40).map { asset("IMG_\($0).jpg", captureDate: stamp, importDate: stamp) }
        let picked = OverviewView.newest(14, in: assets)
        XCTAssertEqual(picked.count, 14)
        XCTAssertEqual(Set(picked.map(\.id)).count, 14, "No photograph may appear twice")
    }

    func testFewerPhotographsThanAskedForReturnsThemAllNewestFirst() {
        let epoch = Date(timeIntervalSince1970: 1_600_000_000)
        let assets = (0..<5).map {
            asset("IMG_\($0).jpg", captureDate: epoch.addingTimeInterval(TimeInterval($0) * 60), importDate: epoch)
        }
        let picked = OverviewView.newest(14, in: assets)
        XCTAssertEqual(picked.map(\.originalFilename), ["IMG_4.jpg", "IMG_3.jpg", "IMG_2.jpg", "IMG_1.jpg", "IMG_0.jpg"])
    }

    func testEmptyArchiveHasNothingRecent() {
        XCTAssertTrue(OverviewView.newest(14, in: []).isEmpty)
    }
}

/// Two refusals wearing one word.
///
/// A first "no" is somebody choosing, and the switch in System Settings is the
/// answer. A "no" after this archive has already read the library is macOS not
/// recognising the app any more — the permission was recorded against the code
/// identity that asked for it, and re-signing leaves a decision matching
/// nothing. Sending that person to the switch is the worst available advice:
/// the app is usually not in the list at all.
@MainActor
final class ApplePhotosPermissionAdviceTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-advice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
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

    private func asset(providerLocalID: String?) -> Asset {
        var one = Asset(
            id: UUID(), kind: .photo, originalFilename: "a.jpg", importOrigin: .appleExport,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
        one.providerLocalID = providerLocalID
        return one
    }

    func testAFirstRefusalPointsAtTheSwitch() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        try catalog.upsertAsset(asset(providerLocalID: nil))
        let store = makeStore(in: directory)
        store.loadAll()

        XCTAssertEqual(store.applePhotosIndexedCount, 0)
        let advice = store.applePhotosPermissionAdvice
        XCTAssertTrue(advice.contains("System Settings"), advice)
        XCTAssertFalse(advice.contains("tccutil"), "Nothing to reset yet: \(advice)")
    }

    /// The archive holding photographs read out of the library is proof the
    /// permission was granted once, which is what makes this the other case.
    func testARefusalAfterTheLibraryWasReadSaysWhatActuallyFixesIt() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        for index in 0..<3 { try catalog.upsertAsset(asset(providerLocalID: "local-\(index)")) }
        let store = makeStore(in: directory)
        store.loadAll()

        XCTAssertEqual(store.applePhotosIndexedCount, 3)
        let advice = store.applePhotosPermissionAdvice
        XCTAssertTrue(advice.contains("tccutil reset Photos"), advice)
        XCTAssertTrue(
            advice.contains("re-signed") || advice.contains("updated"),
            "Must say why it happened, or it reads as the app being broken: \(advice)"
        )
        XCTAssertTrue(
            advice.contains("untouched"),
            "Must say the library and the archive are unharmed: \(advice)"
        )
    }
}
