import XCTest
@testable import HeykinnClicks

/// Sync against a **real mounted volume**, not a directory standing in for one.
///
/// Everything else is proven against directories. This is the level that was
/// missing: a real mount, a real filesystem — exFAT by default, which is what a
/// drive shared between a Mac and a PC actually is — and the hidden files macOS
/// scatters over anything it touches.
///
/// Point it at a volume you do not mind writing to. Writes stay inside
/// `HeykinnClicks/Sync/` and touch no photographs:
///
///     HEYKINN_TEST_VOLUME="/Volumes/HK Drive" swift test --filter RealVolumeSyncTests
final class RealVolumeSyncTests: XCTestCase {

    private var volume: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["HEYKINN_TEST_VOLUME"] else {
            throw XCTSkip("Set HEYKINN_TEST_VOLUME to a mounted volume to run these. The two unplug tests need HEYKINN_TEST_VOLUME_IMAGE as well, naming the .dmg behind that volume — an ordinary USB drive runs six of the eight and says nothing about the other two.")
        }
        volume = URL(fileURLWithPath: path, isDirectory: true)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path), "\(path) is not mounted"
        )
    }

    /// A fresh sync directory per test run, so a re-run never inherits state and
    /// the volume can be left holding several runs without them interfering.
    private func makeStore() throws -> DirectorySegmentStore {
        let root = volume
            .appendingPathComponent("HeykinnClicks", isDirectory: true)
            .appendingPathComponent("SyncTest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return DirectorySegmentStore(root: root)
    }

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-real-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func makeAsset(_ name: String) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: Date(), importDate: Date(), updatedDate: Date(), fileSize: 2_400_000,
            pixelWidth: 4032, pixelHeight: 3024, contentHash: UUID().uuidString,
            residency: .local, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
        )
    }

    private func makeGroup(id: UUID = UUID(), label: String) -> StorageGroup {
        StorageGroup(id: id, label: label, desiredCopies: 2, destinationTargetIDs: [],
                     createdAt: Date(timeIntervalSince1970: 1_000_000))
    }

    // MARK: - The basic journey, on real media

    func testTwoDevicesConvergeOverARealDrive() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeStore()

        for index in 0..<200 { try deviceA.upsertAsset(makeAsset("IMG_\(index).jpg")) }
        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))

        let published = try DriveSync.publish(from: deviceA, to: drive)
        XCTAssertGreaterThan(published.recordsWritten, 0)

        let report = try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertTrue(report.outcome.rejected.isEmpty, "\(report.outcome.rejected.prefix(5))")
        XCTAssertTrue(report.truncatedPeers.isEmpty)
        XCTAssertEqual(try deviceB.fetchAssets().count, 200)
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label), ["Family"])
    }

    /// A name that is not ASCII has to survive the filesystem as well as the
    /// format. exFAT stores UTF-16 and macOS hands names back decomposed.
    func testANonAsciiNameSurvivesTheRoundTrip() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeStore()

        let awkward = "Image 10-10-24 at 4.54\u{202f}PM.jpg"
        try deviceA.upsertAsset(makeAsset(awkward))
        try DriveSync.publish(from: deviceA, to: drive)
        try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertEqual(try deviceB.fetchAssets().map(\.originalFilename), [awkward])
    }

    /// macOS writes `.DS_Store`, `._` forks and `.Spotlight-V100` onto anything
    /// it touches, and a real drive is full of them.
    func testTheReaderIgnoresWhatMacOSLeavesLyingAround() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeStore()

        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive)

        // Scatter the debris macOS actually produces, including inside the
        // device directory the reader walks.
        let device = try XCTUnwrap(deviceA.journal).device.id
        for relative in [
            ".DS_Store",
            "devices/.DS_Store",
            "\(DriveSync.deviceDirectory(device))/.DS_Store",
            "\(DriveSync.deviceDirectory(device))/._00000001.jsonl",
        ] {
            let url = relative.split(separator: "/").reduce(drive.root) {
                $0.appendingPathComponent(String($1))
            }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("junk".utf8).write(to: url)
        }

        let report = try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertTrue(report.outcome.rejected.isEmpty, "\(report.outcome.rejected)")
        XCTAssertTrue(report.truncatedPeers.isEmpty, "macOS debris was read as a damaged segment")
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label), ["Family"])
    }

    // MARK: - Checkpointing on real media

    /// Writing a full state dump and then deleting the log it replaces, on a
    /// real filesystem. Deleting is the one thing sync does that removes
    /// anything, so it is worth watching happen somewhere real.
    func testACheckpointReplacesTheLogOnARealDrive() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeStore()

        for index in 0..<300 { try deviceA.upsertAsset(makeAsset("IMG_\(index).jpg")) }

        let published = try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)
        let checkpoint = try XCTUnwrap(published.checkpoint)
        // One row per photograph, and nothing else here to add to it.
        XCTAssertEqual(checkpoint.rows, 300)
        XCTAssertGreaterThan(published.segmentsPruned, 0)

        let device = try XCTUnwrap(deviceA.journal).device.id
        let segments = try drive.list(DriveSync.deviceDirectory(device))
            .filter { $0.hasSuffix(".jsonl") }
        XCTAssertTrue(segments.isEmpty, "the log survived the checkpoint that covers it")

        // And a device that has never seen the archive gets all of it from the
        // state alone.
        let report = try DriveSync.merge(into: deviceB, from: drive)
        XCTAssertTrue(report.outcome.rejected.isEmpty, "\(report.outcome.rejected.prefix(5))")
        XCTAssertEqual(try deviceB.fetchAssets().count, 300)
    }

    // MARK: - Unmount and remount

    /// Everything written has to still be there after the volume goes away and
    /// comes back, and the next sync has to carry on rather than start again.
    ///
    /// Skipped unless the volume is a disk image this test can detach.
    func testWorkSurvivesTheDriveBeingEjectedAndPluggedBackIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HEYKINN_TEST_VOLUME_IMAGE"] != nil,
            "Set HEYKINN_TEST_VOLUME_IMAGE to the .dmg backing the volume"
        )
        let image = ProcessInfo.processInfo.environment["HEYKINN_TEST_VOLUME_IMAGE"]!

        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeStore()
        let relativeRoot = drive.root.lastPathComponent

        try deviceA.upsertStorageGroup(makeGroup(label: "Before ejecting"))
        try DriveSync.publish(from: deviceA, to: drive)

        detach(image)
        attach(image)

        // Same path, same volume, after a real unmount and remount.
        let reopened = DirectorySegmentStore(
            root: volume.appendingPathComponent("HeykinnClicks", isDirectory: true)
                .appendingPathComponent(relativeRoot, isDirectory: true)
        )
        let report = try DriveSync.merge(into: deviceB, from: reopened)

        XCTAssertTrue(report.truncatedPeers.isEmpty, "the drive came back damaged")
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label), ["Before ejecting"])

        // And the writer carries on rather than republishing everything.
        try deviceA.upsertStorageGroup(makeGroup(label: "After"))
        let again = try DriveSync.publish(from: deviceA, to: reopened)
        XCTAssertLessThan(again.recordsWritten, 20, "republished its whole history after a remount")
    }

    // MARK: - The drive pulled out mid-write

    /// **The failure removable media actually has**, and the one thing every
    /// other test can only imitate. A segment is written by appending, so a
    /// disconnect part way through leaves a half-written line at the tail of a
    /// real file on a real filesystem.
    ///
    /// Three things have to hold, and only the first is about not crashing:
    ///
    /// 1. the writer fails rather than dies;
    /// 2. a reader stops at the damage instead of treating what follows as
    ///    authoritative, and says the drive was truncated;
    /// 3. everything lost comes back on the next sync, because the writer's
    ///    record of what it published never advanced past the tear.
    func testADriveYankedMidWriteLosesNothingPermanently() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HEYKINN_TEST_VOLUME_IMAGE"] != nil,
            "Set HEYKINN_TEST_VOLUME_IMAGE to the .dmg backing the volume"
        )
        let image = ProcessInfo.processInfo.environment["HEYKINN_TEST_VOLUME_IMAGE"]!

        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeStore()
        let relativeRoot = drive.root.lastPathComponent
        func reopened() -> DirectorySegmentStore {
            DirectorySegmentStore(
                root: volume.appendingPathComponent("HeykinnClicks", isDirectory: true)
                    .appendingPathComponent(relativeRoot, isDirectory: true)
            )
        }

        // A first publish that completes, so a real segment exists on the
        // volume. Without this the yank interrupts the *creation* of the file
        // and there is no tail to tear — which is a much easier case, and not
        // the one this test is for.
        for index in 0..<1_000 { try deviceA.upsertAsset(makeAsset("IMG_\(index).jpg")) }
        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)

        let device = try XCTUnwrap(deviceA.journal).device.id
        let segmentPath = drive.root
            .appendingPathComponent(DriveSync.segmentPath(device, index: 1))
        let sizeBefore = (try? FileManager.default
            .attributesOfItem(atPath: segmentPath.path)[.size] as? Int) ?? 0

        // Now interrupt an append onto that existing file.
        for index in 1_000..<4_000 { try deviceA.upsertAsset(makeAsset("IMG_\(index).jpg")) }

        let yank = Thread { [self] in
            Thread.sleep(forTimeInterval: 0.25)
            run("/usr/bin/hdiutil", ["detach", "-force", volume.path])
        }
        yank.start()

        var writerFailed = false
        do {
            try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)
        } catch {
            writerFailed = true
        }

        attach(image)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: volume.path),
            "the volume did not come back; nothing can be concluded"
        )

        let sizeAfter = (try? FileManager.default
            .attributesOfItem(atPath: segmentPath.path)[.size] as? Int) ?? 0

        // 2. A reader either reads what survived or reports the truncation. It
        //    must never read past damage, and must never claim more than it has.
        let report = try DriveSync.merge(into: deviceB, from: reopened())
        let arrivedAfterYank = try deviceB.fetchAssets().count

        // 3. Whatever was lost comes back, because the watermark never advanced
        //    past the tear — the writer verifies its own tail before deciding
        //    what is new.
        try DriveSync.publish(from: deviceA, to: reopened(), checkpointing: .never)
        try DriveSync.merge(into: deviceB, from: reopened())

        XCTAssertEqual(
            try deviceB.fetchAssets().count, 4_000,
            "photographs lost to a disconnect did not come back on the next sync"
        )
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label), ["Family"])

        // Which case this run actually hit. A run where the write never landed
        // at all is a weaker test than one that tore a file, and saying so is
        // the difference between a green tick and evidence.
        let partial = sizeAfter > sizeBefore
        print("""

        ── drive yanked mid-write ─────────────────────────────
          segment before yank    \(sizeBefore / 1024) KB
          segment after yank     \(sizeAfter / 1024) KB
          case exercised         \(partial ? "a partly-written append" : "the append never landed")
          writer                 \(writerFailed ? "failed cleanly" : "finished before the yank")
          reader reported torn   \(report.truncatedPeers.isEmpty ? "no" : "yes")
          arrived before repair  \(arrivedAfterYank) of 4000
          arrived after repair   \(try deviceB.fetchAssets().count) of 4000
        ───────────────────────────────────────────────────────

        """)

        XCTAssertGreaterThanOrEqual(
            arrivedAfterYank, 1_000,
            "the completed first publish should have survived the yank regardless"
        )
    }

    /// The torn tail itself, on real media.
    ///
    /// **Why this is separate from the yank test.** Force-detaching a disk image
    /// discards whatever the buffer cache was still holding, so the append is
    /// all-or-nothing and no file is ever left half written — measured, both
    /// ways round, with the segment byte-identical before and after. A physical
    /// disconnect can leave a partial line; a disk image cannot. So the damage
    /// here is made deliberately, and what is being tested is everything after
    /// it.
    ///
    /// **Swept across cut depths, because the outcome depends on where the tear
    /// lands.** One photograph's records are written contiguously under a single
    /// stamp, so a tear splits at most one of them — and whether that row is
    /// still buildable from what survived depends on which columns were lost.
    /// A single cut size tests whichever case it happens to hit; only a sweep
    /// tests the one that matters.
    ///
    /// The property is the same at every depth: **whatever a reader gets while
    /// the file is torn, after the writer repairs it nothing is missing.**
    func testARepairedTornTailLosesNothingOnRealMedia() throws {
        for cut in [200, 900, 1_600, 2_400, 4_000] {
            let deviceA = try makeCatalog("a-\(cut)")
            let deviceB = try makeCatalog("b-\(cut)")
            let drive = try makeStore()

            for index in 0..<500 { try deviceA.upsertAsset(makeAsset("IMG_\(index).jpg")) }
            try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)

            let device = try XCTUnwrap(deviceA.journal).device.id
            let segment = drive.root.appendingPathComponent(DriveSync.segmentPath(device, index: 1))
            let whole = try Data(contentsOf: segment)
            try whole.prefix(whole.count - cut).write(to: segment)

            let torn = try DriveSync.merge(into: deviceB, from: drive)
            let whileTorn = try deviceB.fetchAssets().count
            XCTAssertFalse(torn.truncatedPeers.isEmpty, "read past a torn line at cut \(cut)")

            // The writer repairs its own tail and re-sends what the tear took.
            try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)
            let after = try DriveSync.merge(into: deviceB, from: drive)
            let recovered = try deviceB.fetchAssets().count

            print(">>> cut \(cut) bytes: \(whileTorn) arrived torn, \(recovered) after repair")

            XCTAssertTrue(after.truncatedPeers.isEmpty, "still damaged after repair, cut \(cut)")
            XCTAssertEqual(
                recovered, 500,
                "cut \(cut): a photograph lost to the tear never came back"
            )
        }
    }

    /// The damage a yank leaves that truncation does not: the file keeps its
    /// length and the tail never reached the disk.
    ///
    /// **Neither simulation available here can produce this, which is why it is
    /// made by hand.** Detaching a disk image discards the buffer cache, so the
    /// append is all-or-nothing — measured, byte-identical before and after.
    /// Killing the writing process does not tear one either: the app appends a
    /// whole batch in a single write, so a dying process leaves the file at a
    /// line boundary — measured too, 11,600 lines and every checksum good after
    /// a SIGKILL mid-publish.
    ///
    /// A real disconnect can still do it, because the size can be recorded
    /// while the data is still in flight. What lands then is not a short file
    /// but a full-length one ending in bytes nobody wrote.
    func testATailThatNeverReachedTheDiskIsCaught() throws {
        for rubbish in [Data(repeating: 0, count: 1_200), Data(repeating: 0xFF, count: 1_200)] {
            let deviceA = try makeCatalog("a-\(rubbish.first!)")
            let deviceB = try makeCatalog("b-\(rubbish.first!)")
            let drive = try makeStore()

            for index in 0..<400 { try deviceA.upsertAsset(makeAsset("IMG_\(index).jpg")) }
            try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)

            let device = try XCTUnwrap(deviceA.journal).device.id
            let segment = drive.root.appendingPathComponent(DriveSync.segmentPath(device, index: 1))
            var bytes = try Data(contentsOf: segment)
            let length = bytes.count
            bytes.replaceSubrange((bytes.count - rubbish.count)..<bytes.count, with: rubbish)
            try bytes.write(to: segment)
            XCTAssertEqual(
                try Data(contentsOf: segment).count, length,
                "the point of this case is that the file did not get shorter"
            )

            // Read it: the checksums have to catch bytes nobody wrote, and the
            // reader must stop rather than trust what follows.
            let torn = try DriveSync.merge(into: deviceB, from: drive)
            XCTAssertFalse(
                torn.truncatedPeers.isEmpty,
                "a tail of \(rubbish.first! == 0 ? "zeroes" : "0xFF") was read as though it were records"
            )
            let whileDamaged = try deviceB.fetchAssets().count
            XCTAssertLessThan(whileDamaged, 400)

            // And the writer repairs its own tail, so nothing is lost for good.
            try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)
            let after = try DriveSync.merge(into: deviceB, from: drive)
            XCTAssertTrue(after.truncatedPeers.isEmpty, "still damaged after a repair")
            XCTAssertEqual(
                try deviceB.fetchAssets().count, 400,
                "photographs lost to a tail that never landed did not come back"
            )
        }
    }

    private func detach(_ image: String) {
        run("/usr/bin/hdiutil", ["detach", "-force", volume.path])
    }

    private func attach(_ image: String) {
        run("/usr/bin/hdiutil", ["attach", image])
        // The mount is asynchronous; wait for the volume to come back.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: volume.path) {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
