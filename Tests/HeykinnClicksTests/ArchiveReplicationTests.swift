import XCTest
@testable import HeykinnClicks

/// The archive is twelve zips, not 24,000 photos. Replication is satisfied
/// when those zips exist twice — not by copying every file inside them.
final class ArchiveReplicationTests: XCTestCase {

    private func archive(
        part: Int, drive: UUID, kind: TakeoutArchiveKind = .zip,
        size: Int64 = 10_000_000_000, hash: String? = nil, setID: String = "S1"
    ) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(),
            path: "/Volumes/D/takeout-\(setID)-\(String(format: "%03d", part))\(kind == .zip ? ".zip" : "")",
            kind: kind, sizeBytes: size, driveID: drive, discoveredAt: Date(),
            importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: setID, partNumber: part,
            contentHash: hash
        )
    }

    func testPartOnTwoDrivesWithMatchingSizesMeetsThePolicy() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a), archive(part: 1, drive: b)],
            managedDriveIDs: [a, b]
        )
        XCTAssertEqual(plan.parts.count, 1)
        XCTAssertEqual(plan.parts[0].redundancy(acrossManagedDrives: [a, b]), .redundantUnverified)
        XCTAssertTrue(plan.isSatisfied)
        XCTAssertEqual(plan.bytesOutstanding, 0, "Nothing to transfer — both copies exist")
    }

    func testMatchingHashesUpgradeToVerified() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(part: 1, drive: a, hash: "same"),
                archive(part: 1, drive: b, hash: "same"),
            ],
            managedDriveIDs: [a, b]
        )
        XCTAssertEqual(plan.parts[0].redundancy(acrossManagedDrives: [a, b]), .redundantVerified)
    }

    func testDisagreeingSizesAreNotClaimedAsRedundant() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(part: 1, drive: a, size: 10_000_000_000),
                archive(part: 1, drive: b, size: 9_000_000_000),
            ],
            managedDriveIDs: [a, b]
        )
        XCTAssertEqual(
            plan.parts[0].redundancy(acrossManagedDrives: [a, b]), .singleCopy,
            "Same part number is not proof the bytes match"
        )
        XCTAssertFalse(plan.isSatisfied)
    }

    func testSingleCopyNeedsTransferToTheOtherDrive() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a, size: 5_000)],
            managedDriveIDs: [a, b]
        )
        let part = plan.parts[0]
        XCTAssertEqual(part.redundancy(acrossManagedDrives: [a, b]), .singleCopy)
        XCTAssertEqual(part.drivesNeedingACopy(managedDriveIDs: [a, b]), [b])
        XCTAssertEqual(plan.bytesOutstanding, 5_000, "One part, one drive short")
    }

    func testAnExtractedFolderAlsoCountsAsACopy() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(part: 3, drive: a, kind: .folder, size: 7_000),
                archive(part: 3, drive: b, kind: .zip, size: 7_000),
            ],
            managedDriveIDs: [a, b]
        )
        XCTAssertTrue(plan.parts[0].redundancy(acrossManagedDrives: [a, b]).meetsTwoCopyPolicy,
                      "The bytes are present either way")
    }

    func testZipIsPreferredOverAFolderAsThePartsCanonicalCopy() {
        let a = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(part: 2, drive: a, kind: .zip),
                archive(part: 2, drive: a, kind: .folder),
            ],
            managedDriveIDs: [a]
        )
        XCTAssertEqual(plan.parts[0].copies[a]?.kind, .zip, "The zip is what gets transferred")
    }

    func testWholeExportOfTwelvePartsOnBothDrivesIsSatisfied() {
        let a = UUID(), b = UUID()
        var archives: [TakeoutArchive] = []
        for part in 1...12 {
            archives.append(archive(part: part, drive: a))
            archives.append(archive(part: part, drive: b))
        }
        let plan = ArchiveReplicationPlanner.plan(archives: archives, managedDriveIDs: [a, b])
        XCTAssertEqual(plan.parts.count, 12)
        XCTAssertEqual(plan.partsMeetingPolicy.count, 12)
        XCTAssertTrue(plan.partsNeedingWork.isEmpty)
        XCTAssertEqual(plan.bytesOutstanding, 0)
    }

    /// A part is identified by its stem, because the same part is stored as a
    /// `.zip` on one drive and as an extracted folder on another. Matching on
    /// full filenames misses every extracted replica.
    func testPartStemMatchesBothZipAndExtractedReplicaPaths() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a), archive(part: 1, drive: b)],
            managedDriveIDs: [a, b]
        )
        let stem = plan.parts[0].displayName
        XCTAssertEqual(stem, "takeout-S1-001")

        let extractedReplica = "volume:Backup/takeout-S1-001/Google Photos/Photos from 2016/IMG.jpg"
        let zipReplica = "zipmember:Backup/takeout-S1-001.zip!Takeout/Google Photos/IMG.jpg"
        XCTAssertTrue(extractedReplica.contains(stem), "Extracted folders record no .zip")
        XCTAssertTrue(zipReplica.contains(stem))

        // And it must not match a different part.
        XCTAssertFalse("volume:Backup/takeout-S1-010/Google Photos/IMG.jpg".contains(stem))
    }

    func testMissingPartsAreTheOnlyWorkReported() {
        let a = UUID(), b = UUID()
        var archives: [TakeoutArchive] = []
        for part in 1...12 {
            archives.append(archive(part: part, drive: a, size: 1_000))
            if part <= 9 { archives.append(archive(part: part, drive: b, size: 1_000)) }
        }
        let plan = ArchiveReplicationPlanner.plan(archives: archives, managedDriveIDs: [a, b])
        XCTAssertEqual(plan.partsNeedingWork.map(\.partNumber).sorted(), [10, 11, 12])
        XCTAssertEqual(plan.bytesOutstanding, 3_000)
    }
}
