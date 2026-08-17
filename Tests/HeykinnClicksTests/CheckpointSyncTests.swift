import XCTest
@testable import HeykinnClicks

/// The checkpoint: a periodic dump of the whole archive's state, beside the log
/// of changes since it.
///
/// The log alone is four orders of magnitude smaller than the archive for a
/// day's work and five times *larger* for a first sync, because a per-field
/// record spends more on its stamp than on the value it delivers. These cover
/// the consequences of making state the base and the log the delta: a new device
/// reads one dump, an old drive stops growing, and neither of those may cost a
/// single row.
final class CheckpointSyncTests: XCTestCase {

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-cp-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        let directory = try makeDirectory(label)
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func makeDrive() throws -> DirectorySegmentStore {
        DirectorySegmentStore(root: try makeDirectory("drive"))
    }

    private func makeAsset(_ name: String = "a.jpg") -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    private func makeGroup(id: UUID = UUID(), label: String) -> StorageGroup {
        StorageGroup(
            id: id, label: label, desiredCopies: 2,
            destinationTargetIDs: [], createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private func deviceID(_ catalog: CatalogStore) throws -> String {
        try XCTUnwrap(catalog.journal).device.id
    }

    private func segmentNames(_ drive: DirectorySegmentStore, _ device: String) throws -> [String] {
        try drive.list(DriveSync.deviceDirectory(device)).filter { $0.hasSuffix(".jsonl") }.sorted()
    }

    // MARK: - A new device reads state, not history

    func testANewDeviceGetsTheWholeArchiveFromACheckpoint() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        for index in 0..<25 { try deviceA.upsertAsset(makeAsset("photo-\(index).jpg")) }
        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))

        let published = try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)
        let checkpoint = try XCTUnwrap(published.checkpoint)
        XCTAssertGreaterThan(checkpoint.rows, 25)

        // Every segment is now redundant, so the drive holds state and nothing
        // else. This is the case a new device meets.
        XCTAssertEqual(try segmentNames(drive, try deviceID(deviceA)), [])
        XCTAssertGreaterThan(published.segmentsPruned, 0)

        let report = try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertTrue(report.outcome.rejected.isEmpty, "\(report.outcome.rejected.prefix(5))")
        XCTAssertEqual(try deviceB.fetchAssets().count, 25)
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label), ["Family"])
    }

    /// The measurement D6 rests on, pinned so it cannot quietly reverse: state
    /// is smaller than the history that produced it.
    func testACheckpointIsSmallerThanTheLogItReplaces() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()
        for index in 0..<50 { try deviceA.upsertAsset(makeAsset("photo-\(index).jpg")) }

        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)
        let device = try deviceID(deviceA)
        let logBytes = try segmentNames(drive, device).reduce(0) {
            $0 + ((try? drive.size("\(DriveSync.deviceDirectory(device))/\($1)")) ?? 0 ?? 0)
        }

        let published = try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)
        let checkpoint = try XCTUnwrap(published.checkpoint)

        XCTAssertGreaterThan(logBytes, 0)
        XCTAssertLessThan(
            checkpoint.byteCount, logBytes,
            "A whole-archive checkpoint (\(checkpoint.byteCount) bytes) should undercut the log "
            + "that built it (\(logBytes) bytes) — the log pays a 60-character stamp per field."
        )
    }

    // MARK: - Nothing is lost to pruning

    /// The failure this would have if `readableWatermark` ignored the
    /// checkpoint: the device finds its own log gone, decides the drive has lost
    /// its work, and writes the whole archive out again on every sync for ever.
    func testPruningDoesNotMakeADeviceRepublishEverything() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()
        for index in 0..<10 { try deviceA.upsertAsset(makeAsset("photo-\(index).jpg")) }

        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)
        let after = try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)

        XCTAssertTrue(after.upToDate, "Republished \(after.recordsWritten) records it had checkpointed")
        XCTAssertEqual(try segmentNames(drive, try deviceID(deviceA)), [])
    }

    /// New work after a checkpoint goes into the log, and a device that already
    /// read the checkpoint picks it up from there without reading state again.
    func testWorkAfterACheckpointTravelsAsOrdinaryLog() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)
        try DriveSync.merge(into: deviceB, from: drive)

        try deviceA.upsertStorageGroup(makeGroup(label: "Work"))
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)

        // The new segment must not reuse an index the checkpoint has declared
        // covered, or every reader would skip straight past it.
        let names = try segmentNames(drive, try deviceID(deviceA))
        XCTAssertEqual(names.count, 1)
        let checkpoint = try XCTUnwrap(DriveSync.newestCheckpoint(drive, try deviceID(deviceA)))
        XCTAssertEqual(names.first, String(format: "%08d.jsonl", checkpoint.firstSegmentIndexAfter))

        try DriveSync.merge(into: deviceB, from: drive)
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label).sorted(), ["Family", "Work"])
    }

    /// A deletion has to survive the checkpoint too. A row that is merely absent
    /// from a state dump is indistinguishable, on the other device, from one it
    /// has never been told about — and the merge would hand it straight back.
    func testACheckpointCarriesDeletionsRatherThanResurrectingThem() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        let doomed = UUID()
        try deviceA.upsertStorageGroup(makeGroup(id: doomed, label: "Temporary"))
        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.synchronise(deviceA, with: drive)
        try DriveSync.merge(into: deviceB, from: drive)
        XCTAssertEqual(try deviceB.fetchStorageGroups().count, 2)

        try deviceA.deleteStorageGroup(id: doomed)
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)

        // A third device, arriving only after the deletion, reads state alone.
        let deviceC = try makeCatalog("c")
        try DriveSync.merge(into: deviceC, from: drive)

        XCTAssertEqual(try deviceC.fetchStorageGroups().map(\.label), ["Family"])
    }

    /// Three devices, and the last one arrives after the drive has been pruned
    /// twice. It has only ever seen state, never history.
    func testADeviceArrivingAfterSeveralCheckpointsIsStillComplete() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)
        try deviceA.upsertStorageGroup(makeGroup(label: "Work"))
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)
        try deviceA.upsertStorageGroup(makeGroup(label: "Scans"))
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)

        // Only the newest generation survives; the older two were replaced.
        let generations = try drive.list(
            "\(DriveSync.deviceDirectory(try deviceID(deviceA)))/\(DriveSync.checkpointsDirectory)"
        )
        XCTAssertEqual(generations, ["00000003"])

        let deviceB = try makeCatalog("b")
        let report = try DriveSync.merge(into: deviceB, from: drive)

        XCTAssertTrue(report.outcome.rejected.isEmpty, "\(report.outcome.rejected.prefix(5))")
        XCTAssertEqual(try deviceB.fetchStorageGroups().map(\.label).sorted(), ["Family", "Scans", "Work"])
    }

    // MARK: - A checkpoint that was interrupted

    /// The marker is written last, so a checkpoint the drive interrupted is not
    /// a short checkpoint — it is no checkpoint at all.
    func testAMarkerlessCheckpointIsIgnoredEntirely() throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)

        let device = try deviceID(deviceA)
        try drive.remove(DriveSync.checkpointInfoPath(device, generation: 1))

        XCTAssertNil(try DriveSync.newestCheckpoint(drive, device))
        // And with the log pruned there is nothing left to read, which is the
        // honest answer rather than a partial archive.
        let report = try DriveSync.merge(into: deviceB, from: drive)
        XCTAssertEqual(report.outcome.applied, 0)
        XCTAssertEqual(try deviceB.fetchStorageGroups().count, 0)
    }

    /// A part damaged after the marker was written is caught by the line
    /// checksums, and the whole checkpoint is refused rather than half applied.
    func testADamagedPartRefusesTheWholeCheckpoint() throws {
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()
        try deviceA.upsertStorageGroup(makeGroup(label: "Family"))
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)

        let device = try deviceID(deviceA)
        let info = try XCTUnwrap(DriveSync.newestCheckpoint(drive, device))
        let path = DriveSync.checkpointPartPath(device, generation: info.generation, part: 1)
        var bytes = try XCTUnwrap(drive.read(path))
        bytes[bytes.startIndex] = bytes[bytes.startIndex] == 0x61 ? 0x62 : 0x61
        try drive.writeAtomically(bytes, to: path)

        XCTAssertNil(try DriveSync.readCheckpoint(drive, device, info))
    }

    // MARK: - More than one part

    /// A checkpoint too big for one file rolls into parts, and the marker has to
    /// count the parts that were *written* rather than the rolls that happened.
    /// A roll landing on the last record leaves those two disagreeing, and a
    /// marker claiming a part that is not there refuses the whole checkpoint —
    /// after the log it replaced has already been deleted.
    ///
    /// Swept across sizes so the boundary case is hit rather than hoped for.
    func testACheckpointSpreadOverSeveralPartsIsReadBackWhole() throws {
        for limit in 1...12 {
            let deviceA = try makeCatalog("a-\(limit)")
            let deviceB = try makeCatalog("b-\(limit)")
            let drive = try makeDrive()

            for index in 0..<6 { try deviceA.upsertStorageGroup(makeGroup(label: "Group \(index)")) }
            try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)

            let journal = try XCTUnwrap(deviceA.journal)
            // A line is a few hundred bytes, so these limits roll on almost
            // every record and land on the last one somewhere in the sweep.
            let info = try DriveSync.writeCheckpoint(
                from: journal, to: drive, partSizeLimit: limit * 64
            )

            let device = journal.device.id
            let onDisk = try drive.list(
                DriveSync.checkpointDirectory(device, generation: info.generation)
            ).filter { $0.hasSuffix(".jsonl") }
            XCTAssertEqual(
                onDisk.count, info.parts,
                "The marker claims \(info.parts) parts at limit \(limit * 64); \(onDisk.count) exist"
            )

            let read = try DriveSync.readCheckpoint(drive, device, info)
            XCTAssertEqual(try XCTUnwrap(read).count, info.rows, "at limit \(limit * 64)")

            try DriveSync.merge(into: deviceB, from: drive)
            XCTAssertEqual(try deviceB.fetchStorageGroups().count, 6, "at limit \(limit * 64)")
        }
    }

    // MARK: - Batching

    func testABatchNeverCutsARowInHalf() {
        let rows = (0..<10).map { row in
            (0..<7).map { column in
                ChangeRecord.set(
                    table: "t", rowID: "\(row)", column: "c\(column)",
                    value: .integer(1),
                    stamp: HLCTimestamp(wallMillis: 1, counter: UInt32(row), deviceID: "d")
                )
            }
        }

        for size in [1, 3, 7, 8, 20, 1_000] {
            let batches = DriveSync.checkpointBatches(rows, size: size)
            XCTAssertEqual(
                batches.reduce(0) { $0 + $1.count }, rows.count,
                "Every row must land in exactly one batch at size \(size)"
            )
            XCTAssertEqual(batches.first?.lowerBound, 0)
            XCTAssertEqual(batches.last?.upperBound, rows.count)
        }
    }

    // MARK: - The record shape

    func testARowExpandsBackIntoTheRecordsTheMergeAlreadyUnderstands() throws {
        let base = try XCTUnwrap(HLCTimestamp.decode("000000000001000-000001-alpha"))
        let later = try XCTUnwrap(HLCTimestamp.decode("000000000002000-000001-beta"))

        let record = CheckpointRecord.row(
            table: "storage_groups", rowID: "1:x", stamp: base,
            values: ["label": .text("Family"), "desired_copies": .integer(2)],
            stamps: ["label": later]
        )

        let expanded = record.expanded()
        XCTAssertEqual(expanded.count, 2)
        XCTAssertEqual(expanded.first { $0.column == "label" }?.stamp, later)
        XCTAssertEqual(expanded.first { $0.column == "desired_copies" }?.stamp, base)
        XCTAssertEqual(record.newestStamp, later)

        let tombstone = CheckpointRecord.deleted(table: "storage_groups", rowID: "1:x", stamp: base)
        XCTAssertEqual(tombstone.expanded(), [.delete(table: "storage_groups", rowID: "1:x", stamp: base)])
    }

    /// The line format is the one segments already use, so a reader that can
    /// read one file on the drive can read them all.
    func testACheckpointRecordSurvivesTheLineFormat() throws {
        let stamp = try XCTUnwrap(HLCTimestamp.decode("000000000001000-000001-alpha"))
        let record = CheckpointRecord.row(
            table: "assets", rowID: "3:abc", stamp: stamp,
            values: ["name": .text("π.jpg"), "size": .integer(9), "ratio": .real(1.5), "gone": .null]
        )

        let line = try SegmentCodec.encodeLine(record)
        let result = SegmentCodec.decode(line, as: CheckpointRecord.self)

        XCTAssertNil(result.stoppedAt)
        XCTAssertEqual(result.values, [record])
        XCTAssertEqual(result.goodByteCount, line.count)
    }
}
