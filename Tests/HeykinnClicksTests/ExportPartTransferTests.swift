import XCTest
@testable import HeykinnClicks

/// Getting a part from the drive that has it onto the drive that needs it,
/// including the case the whole holding area exists for: the two targets are
/// never plugged in at the same time.
final class ExportPartTransferTests: XCTestCase {

    private let driveA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let driveB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let tenGB: Int64 = 10_000_000_000

    private func archive(
        part: Int, drive: UUID, kind: TakeoutArchiveKind = .zip, setID: String = "S1"
    ) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(),
            path: "/Volumes/D/takeout-\(setID)-\(String(format: "%03d", part))\(kind == .zip ? ".zip" : "")",
            kind: kind, sizeBytes: tenGB, targetID: drive, discoveredAt: Date(),
            importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: setID, partNumber: part
        )
    }

    private func replicationPlan(_ archives: [TakeoutArchive]) -> ArchiveReplicationPlan {
        ArchiveReplicationPlanner.plan(archives: archives, managedTargetIDs: [driveA, driveB])
    }

    private func held(part: Int, setID: String = "S1", size: Int64? = nil) -> HeldExportPart {
        HeldExportPart(
            setID: setID, partNumber: part,
            path: "/tmp/relay/takeout-\(setID)-\(String(format: "%03d", part)).zip",
            sizeBytes: size ?? tenGB, stagedAt: Date()
        )
    }

    private let plentyOfRoom: Int64 = 500_000_000_000

    // MARK: - Routing

    func testBothDrivesConnectedCopiesStraightAcross() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA)]),
            connectedDriveIDs: [driveA, driveB],
            heldParts: [],
            availableHoldingBytes: plentyOfRoom
        )
        XCTAssertEqual(plan.transfers.count, 1)
        XCTAssertEqual(plan.transfers[0].route, .driveToDrive(from: driveA, to: driveB))
        XCTAssertTrue(plan.deferredForSpace.isEmpty)
    }

    /// The case the holding area exists for. Without it, a part on drive A can
    /// never reach drive B when the two are never connected together, and the
    /// policy stays permanently unsatisfiable.
    func testOnlyTheDonorConnectedParksThePartOnTheMac() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA)]),
            connectedDriveIDs: [driveA],
            heldParts: [],
            availableHoldingBytes: plentyOfRoom
        )
        XCTAssertEqual(plan.transfers.count, 1)
        XCTAssertEqual(plan.transfers[0].route, .driveToHoldingArea(from: driveA, intendedFor: driveB))
    }

    func testAParkedPartIsDeliveredWhenItsDriveAppears() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA)]),
            connectedDriveIDs: [driveB],
            heldParts: [held(part: 1)],
            availableHoldingBytes: plentyOfRoom
        )
        XCTAssertEqual(plan.transfers.count, 1)
        XCTAssertEqual(plan.transfers[0].route, .holdingAreaToDrive(to: driveB))
    }

    /// A part already parked must not also be copied from the donor again —
    /// that would be a second 10 GB read for bytes already on the Mac.
    func testAParkedPartIsNotCopiedFromTheDonorAgain() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA)]),
            connectedDriveIDs: [driveA],
            heldParts: [held(part: 1)],
            availableHoldingBytes: plentyOfRoom
        )
        XCTAssertTrue(plan.transfers.isEmpty, "Nothing to do: the part is on the Mac waiting for drive B")
    }

    func testNothingToDoWhenBothDrivesAlreadyHoldThePart() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA), archive(part: 1, drive: driveB)]),
            connectedDriveIDs: [driveA, driveB],
            heldParts: [],
            availableHoldingBytes: plentyOfRoom
        )
        XCTAssertTrue(plan.transfers.isEmpty)
        XCTAssertEqual(plan.bytesToMove, 0)
    }

    /// The corridor drains itself: once a part is on every drive, the copy on
    /// the Mac is dead weight on the boot disk.
    func testAParkedPartIsDiscardedOnceEveryDriveHasIt() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA), archive(part: 1, drive: driveB)]),
            connectedDriveIDs: [driveA, driveB],
            heldParts: [held(part: 1)],
            availableHoldingBytes: plentyOfRoom
        )
        XCTAssertTrue(plan.transfers.isEmpty)
        XCTAssertEqual(plan.discardable.map(\.id), ["S1-1"])
    }

    func testNoConnectedDonorLeavesThePartStrandedRatherThanFailing() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA)]),
            connectedDriveIDs: [],
            heldParts: [],
            availableHoldingBytes: plentyOfRoom
        )
        XCTAssertTrue(plan.transfers.isEmpty)
        XCTAssertEqual(plan.stranded.map(\.partNumber), [1])
    }

    /// An extracted folder holds the same photos, but handing a directory of
    /// tens of thousands of files to another drive is a different operation
    /// with none of the same guarantees.
    func testAPartThatSurvivesOnlyAsAnExtractedFolderIsNotTransferred() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA, kind: .folder)]),
            connectedDriveIDs: [driveA],
            heldParts: [],
            availableHoldingBytes: plentyOfRoom
        )
        XCTAssertTrue(plan.transfers.isEmpty)
        XCTAssertEqual(plan.stranded.map(\.partNumber), [1])
    }

    // MARK: - Space

    /// "As many as fit": filling the boot disk is a worse outcome than a
    /// transfer taking two sessions.
    func testOnlyAsManyPartsAsFitAreParked() {
        let archives = (1...5).map { archive(part: $0, drive: driveA) }
        let room = ExportPartTransferPlanner.holdingAreaReserveBytes + tenGB * 2 + 1
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan(archives),
            connectedDriveIDs: [driveA],
            heldParts: [],
            availableHoldingBytes: room
        )
        XCTAssertEqual(plan.transfers.count, 2)
        XCTAssertEqual(plan.deferredForSpace.map(\.partNumber).sorted(), [3, 4, 5])
    }

    func testTheReserveIsLeftFreeOnTheMac() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA)]),
            connectedDriveIDs: [driveA],
            heldParts: [],
            // Room for the part, but only by eating into the reserve.
            availableHoldingBytes: ExportPartTransferPlanner.holdingAreaReserveBytes + tenGB / 2
        )
        XCTAssertTrue(plan.transfers.isEmpty)
        XCTAssertEqual(plan.deferredForSpace.map(\.partNumber), [1])
    }

    /// Space pressure must never block a delivery: delivering is what frees
    /// the space up.
    func testDeliveryIsPlannedEvenWithNoRoomLeft() {
        let plan = ExportPartTransferPlanner.plan(
            replication: replicationPlan([archive(part: 1, drive: driveA)]),
            connectedDriveIDs: [driveB],
            heldParts: [held(part: 1)],
            availableHoldingBytes: 0
        )
        XCTAssertEqual(plan.transfers.map(\.route), [.holdingAreaToDrive(to: driveB)])
    }

    // MARK: - Copying

    private func makeTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testCopyLandsTheBytesAndReportsBothFingerprints() throws {
        let dir = try makeTree()
        let source = dir.appendingPathComponent("takeout-S1-001.zip")
        let payload = Data((0..<(6 * 1024 * 1024)).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let destination = dir.appendingPathComponent("out/takeout-S1-001.zip")

        var seen: [Int64] = []
        let outcome = try ExportPartRelay.copyPart(
            from: source, to: destination, expectedBytes: Int64(payload.count),
            progress: { seen.append($0) }
        )

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(outcome.sizeBytes, Int64(payload.count))
        XCTAssertEqual(outcome.sourceHash, try HashingService.sha256(of: source))
        XCTAssertEqual(outcome.quickChecksum, try HashingService.quickChecksum(of: source))
        XCTAssertFalse(seen.isEmpty, "progress should be reported during the copy")
    }

    /// An interrupted transfer must never leave something that looks like a
    /// complete part — that is exactly the file a later run would trust.
    func testACancelledCopyLeavesNothingBehind() throws {
        let dir = try makeTree()
        let source = dir.appendingPathComponent("takeout-S1-002.zip")
        try Data(repeating: 7, count: 40 * 1024 * 1024).write(to: source)
        let destination = dir.appendingPathComponent("out/takeout-S1-002.zip")

        var chunks = 0
        XCTAssertThrowsError(try ExportPartRelay.copyPart(
            from: source, to: destination, expectedBytes: 40 * 1024 * 1024,
            isCancelled: { chunks += 1; return chunks > 2 }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathExtension(ExportPartRelay.partialSuffix).path
        ))
    }

    func testCopyRefusesWhenTheDestinationCannotHoldIt() throws {
        let dir = try makeTree()
        let source = dir.appendingPathComponent("takeout-S1-003.zip")
        try Data(repeating: 1, count: 1024).write(to: source)
        XCTAssertThrowsError(try ExportPartRelay.copyPart(
            from: source,
            to: dir.appendingPathComponent("out/takeout-S1-003.zip"),
            expectedBytes: Int64.max / 2
        )) { error in
            guard case ExportPartRelay.TransferError.notEnoughSpace = error else {
                return XCTFail("expected a space error, got \(error)")
            }
        }
    }

    // MARK: - The holding area

    func testTheDirectoryListingIsTheState() throws {
        let dir = try makeTree()
        let relay = ExportPartRelay(rootURL: dir)
        try Data(repeating: 3, count: 2048).write(to: relay.url(setID: "S1", partNumber: 7))
        // Things that are not parts are left alone rather than guessed at.
        try Data(repeating: 4, count: 16).write(to: dir.appendingPathComponent("notes.txt"))

        let parts = relay.heldParts()
        XCTAssertEqual(parts.map(\.id), ["S1-7"])
        XCTAssertEqual(parts[0].displayName, "takeout-S1-007")
        XCTAssertEqual(parts[0].sizeBytes, 2048)

        try relay.remove(parts[0])
        XCTAssertTrue(relay.heldParts().isEmpty)
    }

    func testHalfWrittenCopiesAreNeverOfferedAsHeldParts() throws {
        let dir = try makeTree()
        let relay = ExportPartRelay(rootURL: dir)
        let partial = relay.url(setID: "S1", partNumber: 4)
            .appendingPathExtension(ExportPartRelay.partialSuffix)
        try Data(repeating: 9, count: 4096).write(to: partial)

        XCTAssertTrue(relay.heldParts().isEmpty)
        XCTAssertEqual(relay.discardIncompleteCopies(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }
}
