import XCTest
@testable import HeykinnClicks

/// Holding the same export twice, and choosing which copy to keep.
///
/// The only operation in the app that deletes anything the user gave it, so
/// most of these are about the answers that must be no.
final class ExportFormTests: XCTestCase {

    private let driveID = UUID()

    private var drive: ReplicationTarget {
        ReplicationTarget(
            id: driveID, name: "Owner's Back", volumeUUID: nil, markerToken: "token",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    private func archive(
        _ part: Int, _ kind: TakeoutArchiveKind, on target: UUID? = nil, bytes: Int64 = 10_000_000_000
    ) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(),
            path: "/Volumes/Owner's Back/HeykinnClicks/Exports/set/takeout-set-00\(part)"
                + (kind == .zip ? ".zip" : ""),
            kind: kind, sizeBytes: bytes, targetID: target ?? driveID,
            discoveredAt: Date(), importedAt: Date(), importBatchID: nil,
            importedAssetCount: 1, skippedDuplicateCount: 0, note: nil,
            exportSetID: "set", partNumber: part
        )
    }

    /// The state a real archive was in, unremarked, for 254 GB.
    func testHoldingBothFormsIsNoticed() {
        let archives = (1...12).flatMap { [archive($0, .zip), archive($0, .folder)] }
        let audit = ExportFormRemoval.audit(forSet: "set", target: drive, archives: archives)
        XCTAssertTrue(audit.holdsBothForms)
        XCTAssertEqual(audit.partsInBothForms.count, 12)
        XCTAssertEqual(audit.duplicatedBytes, 120_000_000_000, "one of the two is the recoverable half")
    }

    func testHoldingOneFormIsNotDuplication() {
        let archives = (1...12).map { archive($0, .zip) }
        let audit = ExportFormRemoval.audit(forSet: "set", target: drive, archives: archives)
        XCTAssertFalse(audit.holdsBothForms)
        XCTAssertEqual(audit.duplicatedBytes, 0)
    }

    func testEitherFormCanGoWhenTheOtherIsHereForEveryPart() {
        let archives = (1...12).flatMap { [archive($0, .zip), archive($0, .folder)] }
        for form in ExportForm.allCases {
            let plan = ExportFormRemoval.plan(
                removing: form, setID: "set", target: drive,
                archives: archives, replicasPointingIntoZips: 0
            )
            XCTAssertTrue(plan.isAllowed, "\(form)")
            XCTAssertEqual(plan.files.count, 12)
            XCTAssertEqual(plan.bytes, 120_000_000_000)
        }
    }

    /// A part held on this drive in one form only is this drive's whole copy of
    /// it, whatever the other drives have.
    func testAPartHeldOnlyOneWayIsNeverRemoved() {
        var archives = (1...12).flatMap { [archive($0, .zip), archive($0, .folder)] }
        archives.removeAll { $0.partNumber == 7 && $0.kind == .folder }

        let plan = ExportFormRemoval.plan(
            removing: .zip, setID: "set", target: drive,
            archives: archives, replicasPointingIntoZips: 0
        )
        XCTAssertFalse(plan.isAllowed)
        XCTAssertEqual(plan.refusals.count, 1)
        XCTAssertTrue(plan.refusals[0].contains("1 part"), plan.refusals[0])
        XCTAssertTrue(plan.refusals[0].contains("off this drive entirely"))

        // The other direction is still fine: every part has a zip.
        XCTAssertTrue(
            ExportFormRemoval.plan(
                removing: .unpacked, setID: "set", target: drive,
                archives: archives, replicasPointingIntoZips: 0
            ).isAllowed
        )
    }

    /// The refusal that matters most, and the one no catalog-only check could
    /// ever raise afterwards: photos recorded as living *inside* a zip have no
    /// file of their own on that drive, so deleting the zip deletes them while
    /// every record goes on saying they are present.
    func testZipsAPhotoIsCountedInsideAreNeverRemoved() {
        let archives = (1...12).flatMap { [archive($0, .zip), archive($0, .folder)] }
        let plan = ExportFormRemoval.plan(
            removing: .zip, setID: "set", target: drive,
            archives: archives, replicasPointingIntoZips: 6482
        )
        XCTAssertFalse(plan.isAllowed)
        XCTAssertTrue(plan.refusals[0].contains("6,482 photos"), plan.refusals[0])
        XCTAssertTrue(
            plan.refusals[0].contains("Unpack them first"),
            "and it says the way out, because there is one"
        )
        // Removing the unpacked copies is unaffected — nothing is recorded as
        // living inside a folder.
        XCTAssertTrue(
            ExportFormRemoval.plan(
                removing: .unpacked, setID: "set", target: drive,
                archives: archives, replicasPointingIntoZips: 6482
            ).isAllowed
        )
    }

    func testAnotherDrivesCopyIsNotThisPlansBusiness() {
        let other = UUID()
        let archives = [
            archive(1, .zip), archive(1, .folder),
            archive(2, .zip, on: other), archive(2, .folder, on: other),
        ]
        let plan = ExportFormRemoval.plan(
            removing: .zip, setID: "set", target: drive,
            archives: archives, replicasPointingIntoZips: 0
        )
        XCTAssertEqual(plan.files.count, 1)
        XCTAssertTrue(plan.isAllowed)
    }

    /// A part whose bytes have already gone is not a file to delete, and must
    /// not count as the surviving form either.
    func testAPartAlreadyMissingIsNeitherRemovedNorReliedOn() {
        var archives = [archive(1, .zip), archive(1, .folder)]
        archives[1].missingSince = Date()

        let plan = ExportFormRemoval.plan(
            removing: .zip, setID: "set", target: drive,
            archives: archives, replicasPointingIntoZips: 0
        )
        XCTAssertFalse(
            plan.isAllowed,
            "the unpacked copy is gone, so the zip is all this drive has"
        )
    }
}
