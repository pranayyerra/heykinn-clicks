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

    // MARK: - Asking a second time

    /// Deletes for real rather than recording the call: what the *next* plan
    /// says is the thing under test, and that depends on the folder actually
    /// having changed. These are fixtures in a temp directory, not the tester's
    /// own files, so nothing goes near a real Trash.
    private func reclaimForReal(
        _ store: AppStore, _ folder: URL, _ archive: [String: ProtectionState]
    ) async -> Int {
        await store.reclaimFolder(at: folder.path, protectionByHash: archive) {
            try FileManager.default.removeItem(at: $0)
        }
    }

    /// **The folder this sheet has just emptied.** Every one of these states
    /// answers "nothing can go", and they used to be told apart by nothing —
    /// so a folder with no files left in it was described as one of the places
    /// your photographs are kept.
    func testAnEmptiedFolderIsNotDescribedAsStillHoldingPhotographs() async throws {
        let store = try makeStore()
        let folder = try makeFolder("emptied")
        let photo = try write("a photograph", named: "one.jpg", into: folder)
        let archive = try held(photo, as: .fullyReplicated)

        let count = await reclaimForReal(store, folder, archive)
        XCTAssertEqual(count, 1)

        let after = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        XCTAssertTrue(after.isEmpty, "there is nothing left to release")
        XCTAssertTrue(
            after.isFolderEmpty,
            "the folder is empty, and the sheet has to be able to say so rather than claiming copies are still being made"
        )
        XCTAssertFalse(after.holdsOnlyFilesTheAppNeverTookIn)
        XCTAssertFalse(after.leavesFilesBehind)
    }

    /// What is left is only ever somebody's own files, so there is nothing
    /// pending — "still needs its copies made" would be inventing a wait.
    func testAFolderLeftHoldingOnlyItsOwnFilesIsNotDescribedAsWaiting() async throws {
        let store = try makeStore()
        let folder = try makeFolder("leftovers")
        let photo = try write("a photograph", named: "one.jpg", into: folder)
        try write("my notes", named: "notes.txt", into: folder)
        let archive = try held(photo, as: .fullyReplicated)

        let removed = await reclaimForReal(store, folder, archive)
        XCTAssertEqual(removed, 1)

        let after = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(after.isFolderEmpty, "notes.txt is still there")
        XCTAssertTrue(
            after.holdsOnlyFilesTheAppNeverTookIn,
            "nothing here is blocked, so nothing is being waited on"
        )
        XCTAssertEqual(after.notImported.map(\.url.lastPathComponent), ["notes.txt"])
    }

    /// The one case the old wording was written for, and the one it must keep:
    /// files that really are waiting on their copies.
    func testAFolderStillWaitingOnCopiesKeepsSayingSo() async throws {
        let store = try makeStore()
        let folder = try makeFolder("waiting")
        let safe = try write("a photograph", named: "safe.jpg", into: folder)
        let unread = try write("another photograph", named: "unread.jpg", into: folder)
        let archive = [
            try HashingService.sha256(of: safe): ProtectionState.fullyReplicated,
            try HashingService.sha256(of: unread): ProtectionState.awaitingFirstCheck,
        ]

        let removed = await reclaimForReal(store, folder, archive)
        XCTAssertEqual(removed, 1)

        let after = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(after.isFolderEmpty)
        XCTAssertFalse(
            after.holdsOnlyFilesTheAppNeverTookIn,
            "unread.jpg is blocked, so this folder genuinely is waiting"
        )
        XCTAssertEqual(after.blocked.values.map(\.self), [.neverReadBack])
    }

    // MARK: - What the folder looks like afterwards

    /// The husk problem: a reclaim that empties `logo-jpg/` used to leave the
    /// empty directory sitting there for somebody to clear up by hand.
    func testTheDirectoriesAReclaimEmptiesAreTidiedUp() async throws {
        let store = try makeStore()
        let folder = try makeFolder("husks")
        let jpg = folder.appendingPathComponent("logo-jpg", isDirectory: true)
        let png = folder.appendingPathComponent("logo-png", isDirectory: true)
        for directory in [jpg, png] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let one = try write("a photograph", named: "one.jpg", into: jpg)
        let two = try write("another photograph", named: "two.png", into: png)
        let archive = [
            try HashingService.sha256(of: one): ProtectionState.fullyReplicated,
            try HashingService.sha256(of: two): ProtectionState.fullyReplicated,
        ]

        let removed = await reclaimForReal(store, folder, archive)
        XCTAssertEqual(removed, 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.path), "logo-jpg was left behind empty")
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path), "logo-png was left behind empty")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path),
            "the folder somebody chose must survive — that is what the sheet promises"
        )
    }

    /// A directory that still holds something of the user's is not empty, and
    /// is not the app's to remove.
    func testADirectoryStillHoldingSomethingIsLeftAlone() async throws {
        let store = try makeStore()
        let folder = try makeFolder("kept")
        let inner = folder.appendingPathComponent("mixed", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let photo = try write("a photograph", named: "one.jpg", into: inner)
        try write("my notes", named: "notes.txt", into: inner)
        let archive = try held(photo, as: .fullyReplicated)

        let removed = await reclaimForReal(store, folder, archive)
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inner.path),
            "notes.txt is still in there, so the directory is not the app's to remove"
        )
    }

    /// The prune must never reach the folder somebody pointed the app at, even
    /// when the reclaim empties it completely.
    func testTheChosenFolderItselfIsNeverRemoved() async throws {
        let folder = try makeFolder("survivor")
        try write("a photograph", named: "one.jpg", into: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("one.jpg"))

        let pruned = SourceFolderReclaim.pruneEmptyDirectories(under: folder)
        XCTAssertEqual(pruned, 0, "there were no subdirectories to take")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    /// What the row asks before it offers the question at all.
    func testPresenceTellsAnEmptiedFolderFromOneStillHoldingThings() throws {
        let folder = try makeFolder("presence")
        XCTAssertEqual(SourceFolderReclaim.presence(of: folder), .empty)

        try write("a photograph", named: "one.jpg", into: folder)
        XCTAssertEqual(SourceFolderReclaim.presence(of: folder), .holdsFiles)

        let gone = folder.appendingPathComponent("not-there", isDirectory: true)
        XCTAssertEqual(SourceFolderReclaim.presence(of: gone), .unreachable)
    }

    /// Files below the top level still count as the folder holding something.
    func testPresenceLooksBelowTheTopLevel() throws {
        let folder = try makeFolder("deep-presence")
        let inner = folder.appendingPathComponent("2019", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertEqual(SourceFolderReclaim.presence(of: folder), .empty, "an empty tree is empty")

        try write("a photograph", named: "deep.jpg", into: inner)
        XCTAssertEqual(SourceFolderReclaim.presence(of: folder), .holdsFiles)
    }

    /// Asking again after everything went must not offer to do it again.
    func testAskingAgainAfterEverythingWentFindsNothingToOffer() async throws {
        let store = try makeStore()
        let folder = try makeFolder("twice")
        let photo = try write("a photograph", named: "one.jpg", into: folder)
        let archive = try held(photo, as: .fullyReplicated)

        let first = await reclaimForReal(store, folder, archive)
        XCTAssertEqual(first, 1)
        let second = await reclaimForReal(store, folder, archive)
        XCTAssertEqual(
            second, 0,
            "a second run had nothing to take and must not claim otherwise"
        )
    }
}
