import XCTest
@testable import HeykinnClicks

/// The first-run screen's first step, which could never be done.
///
/// Found on a clean account: Photos was connected, granted, and working — and
/// the Overview still said to go and point the app at some photos. The step's
/// `isDone` was hardcoded `false`, so it was an instruction that stayed an
/// instruction however thoroughly it had been followed.
///
/// The two facts it conflated are genuinely different. "Something has been
/// pointed at this archive" and "this archive holds photographs" come apart
/// exactly when a connected library is empty — which is every first run of the
/// app on a new device, and was the case being tested.
@MainActor
final class FirstRunStateTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-firstrun-\(UUID().uuidString)", isDirectory: true)
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

    private func asset(_ name: String, origin: ImportOrigin, providerLocalID: String? = nil) -> Asset {
        var one = Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: origin,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
        one.providerLocalID = providerLocalID
        return one
    }

    /// A genuinely untouched archive. The step is an instruction, and should be.
    func testAnUntouchedArchiveHasNotBeenPointedAtAnything() throws {
        let directory = try makeDirectory()
        _ = try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
        let store = makeStore(in: directory)
        store.loadAll()

        XCTAssertFalse(store.hasPointedAtPhotos)
        XCTAssertEqual(store.countedPhotoTotal, 0)
    }

    /// The case that was wrong on screen: a library has been read, it held
    /// nothing the archive does not already have, and the archive is still
    /// empty. Pointed at something; holding nothing.
    func testALibraryThatWasReadCountsAsPointedAtEvenWithNothingInIt() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        // Indexed from a provider: known about, no bytes held here.
        try catalog.upsertAsset(asset("IMG_1.HEIC", origin: .appleExport, providerLocalID: "abc123"))
        let store = makeStore(in: directory)
        store.loadAll()

        XCTAssertTrue(
            store.hasPointedAtPhotos,
            "Reading a library is pointing the app at photos, whatever came of it"
        )
    }

    /// A folder import counts too — the step names three ways in and must not
    /// only notice one of them.
    func testAFolderImportCountsAsPointedAt() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        try catalog.upsertAsset(asset("scan.jpg", origin: .localFolder))
        let store = makeStore(in: directory)
        store.loadAll()

        XCTAssertTrue(store.hasPointedAtPhotos)
    }

    /// A Google download found on a drive is the third way in.
    func testAFoundTakeoutExportCountsAsPointedAt() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        try catalog.upsertTakeoutArchive(TakeoutArchive(
            id: UUID(), path: "/Volumes/Field Drive/takeout-001.zip", kind: .zip,
            sizeBytes: 1, targetID: nil, discoveredAt: Date(),
            importedAssetCount: 0, skippedDuplicateCount: 0,
            exportSetID: "set", partNumber: 1
        ))
        let store = makeStore(in: directory)
        store.loadAll()

        XCTAssertTrue(store.hasPointedAtPhotos)
    }

    /// The two facts stay distinct. Something being connected must never be
    /// read as the archive holding anything — every count on every screen is
    /// built on that difference.
    func testBeingPointedAtSomethingIsNotHoldingPhotographs() throws {
        let directory = try makeDirectory()
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        try catalog.upsertAsset(asset("IMG_1.HEIC", origin: .appleExport, providerLocalID: "abc123"))
        let store = makeStore(in: directory)
        store.loadAll()

        XCTAssertTrue(store.hasPointedAtPhotos)
        XCTAssertEqual(
            store.applePhotosIndexedCount, 1,
            "Known about from the library"
        )
    }
}
