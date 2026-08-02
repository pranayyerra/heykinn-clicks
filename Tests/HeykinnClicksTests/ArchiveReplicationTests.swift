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
        XCTAssertTrue(plan.parts[0].redundancy(acrossManagedDrives: [a, b]).meetsPolicy,
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

    /// The number of copies is policy, not a constant. Someone wanting three
    /// drives must get three-drive answers from the same model.
    func testRedundancyFollowsTheConfiguredPolicyNotTheNumberTwo() {
        let a = UUID(), b = UUID(), c = UUID()
        let archives = [
            archive(part: 1, drive: a, size: 100),
            archive(part: 1, drive: b, size: 100),
        ]
        let threeCopies = LocalRedundancyPolicy(desiredCopies: 3)

        let underDefault = ArchiveReplicationPlanner.plan(
            archives: archives, managedDriveIDs: [a, b, c]
        )
        XCTAssertTrue(underDefault.isSatisfied, "Two copies satisfies the default policy")

        let underThree = ArchiveReplicationPlanner.plan(
            archives: archives, managedDriveIDs: [a, b, c], policy: threeCopies
        )
        XCTAssertFalse(underThree.isSatisfied, "Two copies does not satisfy a three-copy policy")
        XCTAssertEqual(underThree.partsNeedingWork.first?.drivesNeedingACopy(managedDriveIDs: [a, b, c]), [c])
        XCTAssertEqual(underThree.bytesOutstanding, 100)
    }

    func testProtectionAlsoFollowsThePolicy() {
        let asset = Asset(
            id: UUID(), kind: .photo, originalFilename: "p.jpg", importOrigin: .localFolder,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: "h", residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
        let replicas = (0..<2).map { _ in
            DriveReplicaState(
                assetID: asset.id, driveID: UUID(), state: .present,
                relativePath: "volume:x", lastVerifiedAt: Date()
            )
        }
        XCTAssertEqual(
            ProtectionEvaluator.protectionStates(for: [asset], replicaStates: replicas)[asset.id],
            .fullyReplicated
        )
        XCTAssertEqual(
            ProtectionEvaluator.protectionStates(
                for: [asset], replicaStates: replicas,
                policy: LocalRedundancyPolicy(desiredCopies: 3)
            )[asset.id],
            .replicatedToOneDrive,
            "Under a three-copy policy, two copies is not full protection"
        )
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

/// An asset is only protected by the drives holding *its own* part. Treating
/// every covered asset as present wherever any satisfied part lives would
/// claim redundancy that does not exist.
final class PerPartCoverageTests: XCTestCase {

    /// Mirrors the mapping the store builds from replica paths.
    private func assetsByPart(
        replicas: [(assetID: UUID, path: String)],
        stems: [String]
    ) -> [String: Set<UUID>] {
        var byPart: [String: Set<UUID>] = [:]
        for replica in replicas {
            guard let stem = stems.first(where: { replica.path.contains($0) }) else { continue }
            byPart[stem, default: []].insert(replica.assetID)
        }
        return byPart
    }

    func testAssetsAreAttributedToTheirOwnPartOnly() {
        let fromPart1 = UUID(), fromPart7 = UUID()
        let stems = ["takeout-S-001", "takeout-S-007"]
        let mapping = assetsByPart(
            replicas: [
                (fromPart1, "volume:Backup/takeout-S-001/Google Photos/a.jpg"),
                (fromPart7, "volume:Backup/takeout-S-007/Google Photos/b.jpg"),
            ],
            stems: stems
        )
        XCTAssertEqual(mapping["takeout-S-001"], [fromPart1])
        XCTAssertEqual(mapping["takeout-S-007"], [fromPart7])
        XCTAssertFalse(
            mapping["takeout-S-001"]?.contains(fromPart7) ?? false,
            "A drive holding part 1 says nothing about part 7's contents"
        )
    }

    /// The case the bug would have got wrong: drives holding different
    /// subsets. Only the part they both hold is redundant.
    func testDrivesHoldingDifferentPartsOnlyShareWhatTheyBothHave() {
        let a = UUID(), b = UUID()
        func archive(_ part: Int, _ drive: UUID) -> TakeoutArchive {
            TakeoutArchive(
                id: UUID(), path: "/V/takeout-S-\(String(format: "%03d", part)).zip",
                kind: .zip, sizeBytes: 100, driveID: drive, discoveredAt: Date(),
                importedAt: nil, importBatchID: nil, importedAssetCount: 0,
                skippedDuplicateCount: 0, note: nil, exportSetID: "S", partNumber: part
            )
        }
        // Both hold part 1; only A holds 2, only B holds 3.
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(1, a), archive(1, b), archive(2, a), archive(3, b)],
            managedDriveIDs: [a, b]
        )
        XCTAssertEqual(plan.partsMeetingPolicy.map(\.partNumber), [1])
        XCTAssertEqual(plan.partsNeedingWork.map(\.partNumber).sorted(), [2, 3])
        XCTAssertFalse(plan.isSatisfied)
    }
}

/// Content is attributed to a drive by path. Getting that wrong makes a copy
/// invisible to the redundancy policy, which then reports work that is already
/// done — or worse, reports protection that is missing.
final class DriveAttributionTests: XCTestCase {

    private func drive(name: String, mount: String?) -> ManagedDrive {
        ManagedDrive(
            id: UUID(), name: name, volumeUUID: nil, markerToken: "t",
            registeredAt: Date(), lastSeenAt: nil, lastMountPath: mount,
            replicaRootComponent: ManagedDrive.defaultReplicaRoot
        )
    }

    /// Mirrors the store's resolution: connected mounts first, then each
    /// drive's last known mount point.
    private func resolve(
        path: String, connected: [UUID: URL], drives: [ManagedDrive]
    ) -> UUID? {
        if let hit = connected.first(where: { path.hasPrefix($0.value.path + "/") })?.key {
            return hit
        }
        return drives.first {
            guard let mount = $0.lastMountPath else { return false }
            return path.hasPrefix(mount + "/")
        }?.id
    }

    func testConnectedDriveIsMatchedByItsMountPoint() {
        let d = drive(name: "A", mount: nil)
        let resolved = resolve(
            path: "/Volumes/A/Backup/takeout-S-001.zip",
            connected: [d.id: URL(fileURLWithPath: "/Volumes/A")],
            drives: [d]
        )
        XCTAssertEqual(resolved, d.id)
    }

    /// The case that made copies vanish from the plan: the drive is unplugged,
    /// so there is no mount to match, but its content is still its content.
    func testDisconnectedDriveIsStillMatchedByItsLastMountPoint() {
        let d = drive(name: "A", mount: "/Volumes/A")
        let resolved = resolve(
            path: "/Volumes/A/Backup/takeout-S-001.zip",
            connected: [:],
            drives: [d]
        )
        XCTAssertEqual(resolved, d.id, "An unplugged drive's archives must still count")
    }

    func testPathsOutsideAnyDriveAreNotAttributed() {
        let d = drive(name: "A", mount: "/Volumes/A")
        XCTAssertNil(resolve(path: "/Users/me/Downloads/takeout-S-001.zip", connected: [:], drives: [d]))
        XCTAssertNil(resolve(path: "/Volumes/Another/takeout-S-001.zip", connected: [:], drives: [d]))
    }

    /// An archive with no drive is invisible to planning, so a part with an
    /// unattributed copy must not be reported as redundant.
    func testUnattributedArchivesDoNotCountTowardsRedundancy() {
        let a = UUID()
        let attributed = TakeoutArchive(
            id: UUID(), path: "/V/A/takeout-S-001.zip", kind: .zip, sizeBytes: 10,
            driveID: a, discoveredAt: Date(), importedAt: nil, importBatchID: nil,
            importedAssetCount: 0, skippedDuplicateCount: 0, note: nil,
            exportSetID: "S", partNumber: 1
        )
        var orphan = attributed
        orphan.driveID = nil
        orphan.path = "/V/B/takeout-S-001.zip"

        let plan = ArchiveReplicationPlanner.plan(
            archives: [attributed, orphan], managedDriveIDs: [a, UUID()]
        )
        XCTAssertEqual(
            plan.parts.first?.redundancy(acrossManagedDrives: plan.managedDriveIDs), .singleCopy,
            "A copy that belongs to no known drive cannot be counted as protection"
        )
    }
}
