import XCTest
@testable import HeykinnClicks

/// A Takeout search and its import are separate actions. These tests prove
/// the permission created by the first one is still available to the second,
/// including in a fresh process using the same per-machine preferences.
@MainActor
final class SourceBookmarkTests: XCTestCase {

    private var suiteNames: [String] = []
    private var stores: [SourceBookmarks] = []

    override func tearDown() {
        for store in stores { store.releaseAll() }
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        stores = []
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "heykinn-source-bookmarks-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeStore(_ defaults: UserDefaults) -> SourceBookmarks {
        let store = SourceBookmarks(defaults: defaults)
        stores.append(store)
        return store
    }

    private func makeDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-source-bm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var url = raw
        if let resolved = realpath(raw.path, nil) {
            url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSelectedSourceIsHeldForDeferredWork() throws {
        let root = try makeDirectory()
        let media = root.appendingPathComponent("Takeout/Google Photos/Album/photo.jpg")
        try FileManager.default.createDirectory(
            at: media.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("sample".utf8).write(to: media)

        let store = makeStore(makeDefaults())
        XCTAssertTrue(store.record(path: root.path))
        XCTAssertTrue(store.hasBookmark(forPath: root.path))
        XCTAssertTrue(store.grantsAccess(to: media.path))
    }

    func testSelectedSourceSurvivesRelaunch() throws {
        let root = try makeDirectory()
        let defaults = makeDefaults()

        let first = makeStore(defaults)
        XCTAssertTrue(first.record(path: root.path))
        first.releaseAll()

        let second = makeStore(defaults)
        XCTAssertTrue(second.hasBookmark(forPath: root.path))
        second.resumeAccess()
        XCTAssertTrue(second.grantsAccess(to: root.path))
    }

    func testMissingSourceIsNotRemembered() {
        let path = "/nowhere/source-\(UUID().uuidString)"
        let store = makeStore(makeDefaults())
        XCTAssertFalse(store.record(path: path))
        XCTAssertFalse(store.hasBookmark(forPath: path))
    }

    func testTakeoutSearchPersistsRootBeforeDeferredImport() async throws {
        let appDirectory = try makeDirectory()
        let selectedRoot = try makeDirectory()
        try FileManager.default.createDirectory(
            at: selectedRoot.appendingPathComponent("Takeout/Google Photos/Album", isDirectory: true),
            withIntermediateDirectories: true
        )
        let defaults = makeDefaults()
        let app = AppStore(environment: AppEnvironment(
            appDirectory: appDirectory,
            defaults: defaults,
            runsBackgroundWork: false
        ))

        XCTAssertTrue(app.scanForTakeout(rootURL: selectedRoot, targetID: nil))
        XCTAssertTrue(
            app.sourceBookmarks.hasBookmark(forPath: selectedRoot.path),
            "the picker grant must be persisted synchronously, before the scan task can finish"
        )

        for _ in 0..<100 where !app.auditEvents.contains(where: {
            $0.message.contains("Takeout scan of \(selectedRoot.path)")
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(app.auditEvents.contains {
            $0.message.contains("Takeout scan of \(selectedRoot.path)")
        })
        app.sourceBookmarks.releaseAll()
    }
}
