import XCTest
@testable import HeykinnClicks

/// Staging is transit, and was never emptied. `StagingStore.remove` has existed
/// since the file was written and nothing ever called it, so a photo imported
/// from anywhere unmanaged left a permanent second copy on the boot disk —
/// still there long after both drives held verified copies of it.
///
/// These are mostly the cases where a copy must *not* go. Releasing one is the
/// only irreversible thing in this area, so the bar is the same one the rest of
/// the app uses to call a photo safe: the policy is satisfied, every copy
/// counted was read back and matched, and none of those reads has gone stale.
final class StagingReclaimTests: XCTestCase {

    private func asset(
        staged: String? = "ab/one.jpg",
        size: Int64 = 100
    ) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "one.jpg", importOrigin: .localFolder,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: size,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString,
            residency: .local, residencySource: .importDefault,
            presence: DomainPresence(local: true, appleCloud: false, googleCloud: false),
            stagingRelativePath: staged, importBatchID: nil, exifSummary: [:]
        )
    }

    func testAFullyReplicatedAssetCanReleaseItsStagedCopy() {
        let one = asset()
        let plan = StagingReclaimer.plan(
            assets: [one], protectionStates: [one.id: .fullyReplicated]
        )
        XCTAssertEqual(plan.releasable[one.id], "ab/one.jpg")
        XCTAssertEqual(plan.bytes, 100)
    }

    /// Every verdict short of "safe" keeps the copy. Written out one by one
    /// rather than as "not fullyReplicated", so that a new state added later
    /// has to be considered here instead of silently becoming releasable.
    func testEveryOtherVerdictKeepsIt() {
        for state in [
            ProtectionState.stagedOnly,
            .replicatedToOneDrive,
            .awaitingFirstCheck,
            .verificationOverdue,
            .driftDetected,
            .notApplicable,
        ] {
            let one = asset()
            let plan = StagingReclaimer.plan(assets: [one], protectionStates: [one.id: state])
            XCTAssertTrue(plan.isEmpty, "\(state) is not grounds for releasing a copy")
        }
    }

    func testAnAssetWithNoVerdictAtAllKeepsIt() {
        let one = asset()
        XCTAssertTrue(StagingReclaimer.plan(assets: [one], protectionStates: [:]).isEmpty)
    }

    func testAnAssetThatWasNeverStagedIsNotInThePlan() {
        let one = asset(staged: nil)
        let plan = StagingReclaimer.plan(assets: [one], protectionStates: [one.id: .fullyReplicated])
        XCTAssertTrue(plan.isEmpty)
    }

    /// A file deletion and a database write are not one operation. Whichever
    /// order they happen in, a crash between them leaves a mismatch — and the
    /// one that leaves a file nobody names would otherwise sit there forever.
    func testStagedFilesNoAssetClaimsAreFound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let staging = StagingStore(rootURL: root)

        let bucket = root.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try Data("claimed".utf8).write(to: bucket.appendingPathComponent("one.jpg"))
        try Data("nobody names this".utf8).write(to: bucket.appendingPathComponent("stray.jpg"))

        let orphans = StagingReclaimer.orphans(in: staging, claimedBy: [asset()])
        XCTAssertEqual(orphans, ["ab/stray.jpg"])
    }

    func testNothingIsAnOrphanWhenEveryFileIsClaimed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let staging = StagingStore(rootURL: root)
        let bucket = root.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try Data("claimed".utf8).write(to: bucket.appendingPathComponent("one.jpg"))

        XCTAssertTrue(StagingReclaimer.orphans(in: staging, claimedBy: [asset()]).isEmpty)
    }
}

/// The same thing end to end, through the store that actually deletes.
@MainActor
final class StagingReclaimIntegrationTests: XCTestCase {

    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        roots = []
        suiteNames = []
        super.tearDown()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func makeStore(reclaim: Bool = true) throws -> AppStore {
        let directory = try makeDirectory("store")
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(reclaim, forKey: "reclaimStagingWhenSafe")
        defaults.set(false, forKey: "autoSyncOnConnect")
        return AppStore(environment: AppEnvironment(
            appDirectory: directory, defaults: defaults, runsBackgroundWork: false
        ))
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The whole point, end to end: content imported from somewhere unmanaged
    /// costs a copy on the Mac until a drive holds it, and then stops costing
    /// one.
    func testTheStagedCopyGoesOnceADriveHoldsItAndHasBeenChecked() async throws {
        let store = try makeStore()
        let source = try makeDirectory("source")
        try Data("a photo".utf8).write(to: source.appendingPathComponent("photo.jpg"))
        let mount = try makeDirectory("target")

        store.importFolders([source])
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        let asset = try XCTUnwrap(store.assets.first)
        XCTAssertNotNil(asset.stagingRelativePath)
        XCTAssertGreaterThan(store.staging.totalBytes, 0)

        store.registerHostDeviceTarget(at: mount, name: "Drive")
        XCTAssertNotNil(store.targets.first, store.lastError ?? "")
        store.syncDrive(try XCTUnwrap(store.targets.first?.id))
        try await waitUntil("the sync to drain") { !store.isSyncing }

        XCTAssertEqual(store.protectionStates[asset.id], .fullyReplicated)
        XCTAssertNil(
            store.assets.first?.stagingRelativePath,
            "The copy the drive now holds does not also need holding here"
        )
        XCTAssertEqual(store.staging.totalBytes, 0)
    }

    /// One drive short of the policy is not safe, whatever the disk pressure.
    func testNothingIsReleasedWhileAPhotoIsShortOfTheCopiesAskedFor() async throws {
        let store = try makeStore()
        let source = try makeDirectory("source")
        try Data("a photo".utf8).write(to: source.appendingPathComponent("photo.jpg"))

        store.importFolders([source])
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }

        let before = store.staging.totalBytes
        store.reclaimStaging(force: true)
        XCTAssertEqual(store.staging.totalBytes, before, "No target holds it at all")
        XCTAssertNotNil(store.assets.first?.stagingRelativePath)
    }

    func testTurningItOffKeepsTheStagedCopy() async throws {
        let store = try makeStore(reclaim: false)
        let source = try makeDirectory("source")
        try Data("a photo".utf8).write(to: source.appendingPathComponent("photo.jpg"))
        let mount = try makeDirectory("target")

        store.importFolders([source])
        try await waitUntil("the import") { !store.isImporting && store.assets.count == 1 }
        store.registerHostDeviceTarget(at: mount, name: "Drive")
        store.syncDrive(try XCTUnwrap(store.targets.first?.id))
        try await waitUntil("the sync to drain") { !store.isSyncing }

        XCTAssertNotNil(store.assets.first?.stagingRelativePath, "Left alone, as asked")
        XCTAssertGreaterThan(store.staging.totalBytes, 0)
        XCTAssertFalse(store.stagingReclaimPlan.isEmpty, "But the app can still say what it would free")
    }
}
