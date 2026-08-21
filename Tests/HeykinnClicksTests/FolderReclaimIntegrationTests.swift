import XCTest
@testable import HeykinnClicks

/// The reclaim against a real folder on disk: what it reads, what it removes,
/// and what it leaves standing.
///
/// The removal is injected. Calling the real one puts files in the tester's own
/// Trash, which a test suite has no business doing.
@MainActor
final class FolderReclaimIntegrationTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "heykinn-reclaim-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
    }

    private func makeFolder(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, named name: String, into folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// What the archive holds for that file's bytes, and in what state.
    private func held(
        _ url: URL, as state: ProtectionState
    ) throws -> [String: ProtectionState] {
        [try HashingService.sha256(of: url): state]
    }

    /// Held, read back, and on enough drives: the file in the folder is spare.
    func testAFolderTheArchiveHasTakenEverythingFromCanBeCleared() async throws {
        let store = try makeStore()
        let folder = try makeFolder("done")
        let photo = try write("a photograph", named: "one.jpg", into: folder)
        let archive = try held(photo, as: .fullyReplicated)

        let plan = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        XCTAssertEqual(plan.releasable.map(\.url.lastPathComponent), ["one.jpg"])

        var removed: [String] = []
        let count = await store.reclaimFolder(at: folder.path, protectionByHash: archive) {
            removed.append($0.lastPathComponent)
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(removed, ["one.jpg"])
    }

    /// **The refusal that matters, against a real folder.** A file the app never
    /// imported is untouched, and the reclaim still runs for the rest.
    func testAFileTheAppNeverImportedIsLeftWhereItIs() async throws {
        let store = try makeStore()
        let folder = try makeFolder("mixed")
        let photo = try write("a photograph", named: "one.jpg", into: folder)
        try write("my notes", named: "notes.txt", into: folder)
        let archive = try held(photo, as: .fullyReplicated)

        var removed: [String] = []
        let count = await store.reclaimFolder(at: folder.path, protectionByHash: archive) {
            removed.append($0.lastPathComponent)
        }

        XCTAssertEqual(count, 1)
        XCTAssertEqual(removed, ["one.jpg"], "something the app never read was going to be deleted")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path),
            "the file is still on disk"
        )
    }

    /// Copies that exist but have never been read back are the app believing
    /// itself. Nothing goes.
    func testNothingGoesWhileTheCopiesAreUnread() async throws {
        let store = try makeStore()
        let folder = try makeFolder("unread")
        let photo = try write("a photograph", named: "one.jpg", into: folder)
        let archive = try held(photo, as: .awaitingFirstCheck)

        var removed: [String] = []
        let count = await store.reclaimFolder(at: folder.path, protectionByHash: archive) {
            removed.append($0.lastPathComponent)
        }
        XCTAssertEqual(count, 0)
        XCTAssertTrue(removed.isEmpty)
    }

    /// **Edited after it was imported.** The archive holds the old bytes; the
    /// file on disk is now something else, and something else is not spare.
    func testAFileEditedSinceImportIsNoLongerRecognised() async throws {
        let store = try makeStore()
        let folder = try makeFolder("edited")
        let photo = try write("a photograph", named: "one.jpg", into: folder)
        let archive = try held(photo, as: .fullyReplicated)

        try Data("a photograph, cropped".utf8).write(to: photo)

        let plan = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        XCTAssertTrue(plan.releasable.isEmpty, "the edited file was treated as the one imported")
        XCTAssertEqual(plan.notImported.map(\.url.lastPathComponent), ["one.jpg"])
    }

    /// Reads what is in subfolders too — a folder somebody imported is a tree,
    /// not a flat list.
    func testItReadsBelowTheTopLevel() async throws {
        let store = try makeStore()
        let folder = try makeFolder("nested")
        let inner = folder.appendingPathComponent("2019", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let photo = try write("a photograph", named: "deep.jpg", into: inner)
        let archive = try held(photo, as: .fullyReplicated)

        let plan = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        XCTAssertEqual(plan.releasable.map(\.url.lastPathComponent), ["deep.jpg"])
    }
}
