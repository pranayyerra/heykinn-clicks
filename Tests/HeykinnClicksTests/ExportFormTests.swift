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

    /// The state a real archive was in, unremarked, across a whole export.
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
            archives: archives, replicasPointingIntoZips: 2500
        )
        XCTAssertFalse(plan.isAllowed)
        XCTAssertTrue(plan.refusals[0].contains("2,500 photos"), plan.refusals[0])
        XCTAssertTrue(
            plan.refusals[0].contains("Unpack them first"),
            "and it says the way out, because there is one"
        )
        // Removing the unpacked copies is unaffected — nothing is recorded as
        // living inside a folder.
        XCTAssertTrue(
            ExportFormRemoval.plan(
                removing: .unpacked, setID: "set", target: drive,
                archives: archives, replicasPointingIntoZips: 2500
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

/// Grading a part whose copies are in different shapes.
final class ExportPartFormGradeTests: XCTestCase {

    private let driveA = UUID(), driveB = UUID()

    private func archive(_ kind: TakeoutArchiveKind, bytes: Int64, quick: String? = nil) -> TakeoutArchive {
        var one = TakeoutArchive(
            id: UUID(), path: "/x/takeout-set-001" + (kind == .zip ? ".zip" : ""),
            kind: kind, sizeBytes: bytes, targetID: nil, discoveredAt: Date(),
            importedAt: Date(), importBatchID: nil, importedAssetCount: 1,
            skippedDuplicateCount: 0, note: nil, exportSetID: "set", partNumber: 1
        )
        one.quickChecksum = quick
        return one
    }

    /// The state a real archive reached by keeping the zips on one drive and
    /// the unpacked copies on the other: every part on every drive, and every
    /// part reported as "one copy only".
    func testAZipAndAnUnpackedCopyAreEnoughCopies() {
        let part = ExportPart(
            setID: "set", partNumber: 1,
            copies: [
                driveA: archive(.zip, bytes: 10_652_397_244, quick: "abc"),
                driveB: archive(.folder, bytes: 10_649_826_020),
            ]
        )
        let grade = part.redundancy(acrossTargets: [driveA, driveB], copiesRequired: 2)
        XCTAssertEqual(grade, .redundantIncomparable)
        XCTAssertTrue(grade.meetsPolicy, "both drives hold it; nothing is missing")
        XCTAssertNotEqual(grade, .singleCopy, "which is what it said, in orange, under a line saying it was on every drive")
    }

    /// The warning that must survive: same form, different bytes.
    func testTwoZipsThatDisagreeAreStillReportedAsNotTheSameBytes() {
        let part = ExportPart(
            setID: "set", partNumber: 1,
            copies: [
                driveA: archive(.zip, bytes: 10_652_397_244),
                driveB: archive(.zip, bytes: 9_000_000_000),
            ]
        )
        XCTAssertEqual(
            part.redundancy(acrossTargets: [driveA, driveB], copiesRequired: 2), .singleCopy,
            "two zips of different sizes are not two copies of one thing"
        )
    }

    func testMatchingZipsAreStillGradedOnTheirEvidence() {
        let part = ExportPart(
            setID: "set", partNumber: 1,
            copies: [
                driveA: archive(.zip, bytes: 10, quick: "same"),
                driveB: archive(.zip, bytes: 10, quick: "same"),
            ]
        )
        XCTAssertEqual(
            part.redundancy(acrossTargets: [driveA, driveB], copiesRequired: 2),
            .redundantSpotChecked
        )
    }

    /// One drive, one copy, and no second form to be incomparable with.
    func testOneDriveIsUnaffected() {
        let part = ExportPart(
            setID: "set", partNumber: 1, copies: [driveA: archive(.folder, bytes: 10)]
        )
        XCTAssertEqual(
            part.redundancy(acrossTargets: [driveA, driveB], copiesRequired: 2), .singleCopy
        )
    }
}
