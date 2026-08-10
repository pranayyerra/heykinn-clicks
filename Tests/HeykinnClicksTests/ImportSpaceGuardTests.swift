import XCTest
@testable import HeykinnClicks

/// Importing had no free-space check at all. Registering a device refuses when
/// the archive will not fit; pointing an import at a borrowed 400 GB drive
/// filled the boot disk and stopped only when writes began failing — part-way
/// through, with staging full and no room left to tidy up in.
final class StagingBytesNeededTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-space-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ bytes: Int, to url: URL) throws -> URL {
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func memoEntry(for url: URL, hash: String) -> ScanMemoEntry {
        let observation = ReplicaStatGate.observe(url)!
        return ScanMemoEntry(
            path: url.path,
            size: observation.size,
            modifiedAt: observation.modifiedAt,
            contentHash: hash,
            seenAt: Date()
        )
    }

    func testNewFilesAreCountedInFull() throws {
        let dir = try makeTempDirectory()
        let a = try write(1_000, to: dir.appendingPathComponent("a.jpg"))
        let b = try write(2_500, to: dir.appendingPathComponent("b.jpg"))

        let needed = ImportService.stagingBytesNeeded(for: [a, b], scanMemo: [:], knownHashes: [])
        XCTAssertEqual(needed, 3_500)
    }

    /// Re-sweeping a folder the archive already holds is an ordinary thing to
    /// do, and the memo exists to make it cheap. Counting those bytes would
    /// refuse the one import guaranteed to need no room at all.
    func testAFileTheArchiveAlreadyHoldsCostsNothing() throws {
        let dir = try makeTempDirectory()
        let a = try write(4_000, to: dir.appendingPathComponent("a.jpg"))

        let needed = ImportService.stagingBytesNeeded(
            for: [a],
            scanMemo: [a.path: memoEntry(for: a, hash: "known-hash")],
            knownHashes: ["known-hash"]
        )
        XCTAssertEqual(needed, 0)
    }

    /// Remembered, but the catalog no longer holds those bytes — so this file
    /// is going to be copied, and its size counts.
    func testARememberedFileTheCatalogLostIsCounted() throws {
        let dir = try makeTempDirectory()
        let a = try write(4_000, to: dir.appendingPathComponent("a.jpg"))

        let needed = ImportService.stagingBytesNeeded(
            for: [a],
            scanMemo: [a.path: memoEntry(for: a, hash: "forgotten-hash")],
            knownHashes: ["some-other-hash"]
        )
        XCTAssertEqual(needed, 4_000)
    }

    /// The memo is only ever allowed to skip work when the stat still matches.
    /// A file rewritten since is new content and is counted in full.
    func testAFileChangedSinceItWasRememberedIsCounted() throws {
        let dir = try makeTempDirectory()
        let a = try write(1_000, to: dir.appendingPathComponent("a.jpg"))
        let stale = memoEntry(for: a, hash: "known-hash")
        // Same path, different bytes — the size no longer agrees.
        try write(9_000, to: a)

        let needed = ImportService.stagingBytesNeeded(
            for: [a],
            scanMemo: [a.path: stale],
            knownHashes: ["known-hash"]
        )
        XCTAssertEqual(needed, 9_000)
    }

    func testFilesThatCannotBeStattedAreSkippedRatherThanGuessedAt() throws {
        let dir = try makeTempDirectory()
        let absent = dir.appendingPathComponent("gone.jpg")
        XCTAssertEqual(ImportService.stagingBytesNeeded(for: [absent], scanMemo: [:], knownHashes: []), 0)
    }
}

/// The refusal itself: when it fires, and whether it says anything a person
/// can act on.
@MainActor
final class ImportSpaceRefusalTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-refusal-\(UUID().uuidString)", isDirectory: true)
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

    private func makeFile(_ bytes: Int, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private var reserve: Int64 { ExportPartTransferPlanner.holdingAreaReserveBytes }

    func testRefusesWhenTheImportWouldEatIntoTheMacsReserve() throws {
        let store = makeStore(in: try makeTempDirectory())
        let source = try makeTempDirectory()
        let file = try makeFile(10_000, in: source)

        // Ten thousand bytes wanted; a thousand spare above the reserve.
        let refusal = store.stagingSpaceRefusal(
            for: [file], existing: [], memo: [:], availableBytes: reserve + 1_000
        )

        let message = try XCTUnwrap(refusal)
        XCTAssertTrue(message.contains("Not importing"), message)
        XCTAssertTrue(message.contains("Nothing was copied"), "Must say the archive is untouched")
        XCTAssertTrue(
            message.lowercased().contains("free up space") || message.contains("in parts"),
            "Must say what to do about it: \(message)"
        )
    }

    func testAllowsWhenThereIsRoomAboveTheReserve() throws {
        let store = makeStore(in: try makeTempDirectory())
        let source = try makeTempDirectory()
        let file = try makeFile(10_000, in: source)

        XCTAssertNil(store.stagingSpaceRefusal(
            for: [file], existing: [], memo: [:], availableBytes: reserve + 1_000_000
        ))
    }

    /// A re-sweep of content the archive already holds needs no room, so it is
    /// allowed however little is free — refusing it would block the cheapest
    /// import there is.
    func testAReSweepOfKnownContentIsAllowedOnAFullDisk() throws {
        let store = makeStore(in: try makeTempDirectory())
        let source = try makeTempDirectory()
        let file = try makeFile(10_000, in: source)
        let observation = try XCTUnwrap(ReplicaStatGate.observe(file))
        let memo = [file.path: ScanMemoEntry(
            path: file.path, size: observation.size, modifiedAt: observation.modifiedAt,
            contentHash: "already-here", seenAt: Date()
        )]
        let existing = [Asset(
            id: UUID(), kind: .photo, originalFilename: "a.jpg", importOrigin: .localFolder,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 10_000,
            pixelWidth: nil, pixelHeight: nil, contentHash: "already-here", residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )]

        XCTAssertNil(store.stagingSpaceRefusal(
            for: [file], existing: existing, memo: memo, availableBytes: 0
        ))
    }

    /// A guard rail, not an accounting system: if the volume will not answer,
    /// the import goes ahead rather than every import being refused because a
    /// capacity query failed.
    func testAnUnanswerableVolumeDoesNotBlockTheImport() throws {
        let store = makeStore(in: try makeTempDirectory())
        let source = try makeTempDirectory()
        let file = try makeFile(10_000, in: source)

        // Real query against a real temp volume, which has room.
        XCTAssertNil(store.stagingSpaceRefusal(for: [file], existing: [], memo: [:]))
    }
}
