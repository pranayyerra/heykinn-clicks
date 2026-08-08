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
            kind: kind, sizeBytes: size, targetID: drive, discoveredAt: Date(),
            importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: setID, partNumber: part,
            contentHash: hash
        )
    }

    func testPartOnTwoDrivesWithMatchingSizesMeetsThePolicy() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a), archive(part: 1, drive: b)],
            managedTargetIDs: [a, b]
        )
        XCTAssertEqual(plan.parts.count, 1)
        XCTAssertEqual(plan.parts[0].redundancy(acrossTargets: [a, b]), .redundantUnverified)
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
            managedTargetIDs: [a, b]
        )
        XCTAssertEqual(plan.parts[0].redundancy(acrossTargets: [a, b]), .redundantVerified)
    }

    func testDisagreeingSizesAreNotClaimedAsRedundant() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(part: 1, drive: a, size: 10_000_000_000),
                archive(part: 1, drive: b, size: 9_000_000_000),
            ],
            managedTargetIDs: [a, b]
        )
        XCTAssertEqual(
            plan.parts[0].redundancy(acrossTargets: [a, b]), .singleCopy,
            "Same part number is not proof the bytes match"
        )
        XCTAssertFalse(plan.isSatisfied)
    }

    func testSingleCopyNeedsTransferToTheOtherDrive() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a, size: 5_000)],
            managedTargetIDs: [a, b]
        )
        let part = plan.parts[0]
        XCTAssertEqual(part.redundancy(acrossTargets: [a, b]), .singleCopy)
        XCTAssertEqual(part.targetsNeedingACopy(managedTargetIDs: [a, b]), [b])
        XCTAssertEqual(plan.bytesOutstanding, 5_000, "One part, one drive short")
    }

    func testAnExtractedFolderAlsoCountsAsACopy() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(part: 3, drive: a, kind: .folder, size: 7_000),
                archive(part: 3, drive: b, kind: .zip, size: 7_000),
            ],
            managedTargetIDs: [a, b]
        )
        XCTAssertTrue(plan.parts[0].redundancy(acrossTargets: [a, b]).meetsPolicy,
                      "The bytes are present either way")
    }

    func testZipIsPreferredOverAFolderAsThePartsCanonicalCopy() {
        let a = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(part: 2, drive: a, kind: .zip),
                archive(part: 2, drive: a, kind: .folder),
            ],
            managedTargetIDs: [a]
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
        let plan = ArchiveReplicationPlanner.plan(archives: archives, managedTargetIDs: [a, b])
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
            managedTargetIDs: [a, b]
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
    /// targets must get three-drive answers from the same model.
    func testRedundancyFollowsTheConfiguredPolicyNotTheNumberTwo() {
        let a = UUID(), b = UUID(), c = UUID()
        let archives = [
            archive(part: 1, drive: a, size: 100),
            archive(part: 1, drive: b, size: 100),
        ]
                let underDefault = ArchiveReplicationPlanner.plan(
            archives: archives, managedTargetIDs: [a, b, c]
        )
        XCTAssertTrue(underDefault.isSatisfied, "Two copies satisfies the default policy")

        let underThree = ArchiveReplicationPlanner.plan(
            archives: archives, managedTargetIDs: [a, b, c], defaultCopiesRequired: 3
        )
        XCTAssertFalse(underThree.isSatisfied, "Two copies does not satisfy a three-copy policy")
        XCTAssertEqual(underThree.partsNeedingWork.first?.targetsNeedingACopy(managedTargetIDs: [a, b, c]), [c])
        XCTAssertEqual(underThree.bytesOutstanding, 100)
    }

    /// The state of every single-target install, because the policy is clamped
    /// to the number of registered targets. One copy is exactly what the policy
    /// asks for, so it cannot be work outstanding — the card used to report a
    /// shortfall that no amount of copying could ever clear.
    func testOneCopyUnderAOneCopyPolicyIsNotAShortfall() {
        let a = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a, size: 5_000)],
            managedTargetIDs: [a], defaultCopiesRequired: 1
        )
        let redundancy = plan.parts[0].redundancy(acrossTargets: [a], copiesRequired: 1)

        XCTAssertEqual(redundancy, .singleCopyByPolicy)
        XCTAssertTrue(redundancy.meetsPolicy, "One copy is what was asked for")
        XCTAssertEqual(plan.partsNeedingWork, [], "There is no copy left to make")
        XCTAssertTrue(plan.isSatisfied)
        XCTAssertEqual(plan.bytesOutstanding, 0)
    }

    /// The other half of the same claim: the fix must not turn a genuine
    /// shortfall into a pass. The same lone copy under the default policy is
    /// still a part that needs a second home.
    func testTheSameLoneCopyIsStillAShortfallUnderATwoCopyPolicy() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a, size: 5_000)],
            managedTargetIDs: [a, b]
        )
        let redundancy = plan.parts[0].redundancy(acrossTargets: [a, b])

        XCTAssertEqual(redundancy, .singleCopy)
        XCTAssertFalse(redundancy.meetsPolicy)
        XCTAssertNotEqual(redundancy, .singleCopyByPolicy, "Two states, two different truths")
        XCTAssertEqual(plan.bytesOutstanding, 5_000)
    }

    /// Satisfying the policy is not evidence the bytes are good. A copy with a
    /// hash on it has still been compared to nothing, so it must never be
    /// reported at any of the grades that mean "the copies agree".
    func testASingleCopyIsNeverGradedAsVerifiedHoweverMuchIsKnownAboutIt() {
        let a = UUID()
        var hashed = archive(part: 1, drive: a, hash: "abc")
        hashed.quickChecksum = "abc-quick"
        let plan = ArchiveReplicationPlanner.plan(
            archives: [hashed], managedTargetIDs: [a], defaultCopiesRequired: 1
        )

        XCTAssertEqual(
            plan.parts[0].redundancy(acrossTargets: [a], copiesRequired: 1), .singleCopyByPolicy,
            "A hash agrees with nothing until there is a second copy to hold it against"
        )
        XCTAssertFalse(plan.parts[0].hashesAgree)
        XCTAssertFalse(plan.parts[0].quickChecksumsAgree)
    }

    /// Comparing takes two copies whatever the policy asks for, which is why
    /// the checks read this number rather than `desiredCopies`. Without it,
    /// a lone copy would pass a comparison against itself and be recorded as
    /// verified across targets.
    func testAComparisonNeedsTwoCopiesEvenWhenThePolicyAsksForOne() {
        XCTAssertEqual(copiesNeededToCompare(forCopies: 1), 2)
        XCTAssertEqual(copiesNeededToCompare(forCopies: 2), 2)
        XCTAssertEqual(copiesNeededToCompare(forCopies: 3), 3)
        XCTAssertEqual(
            Formatters.copies(1), "one copy",
            "A number the user can actually set has to read as English"
        )
    }

    /// Two drives registered but only one copy asked for: the part that happens
    /// to exist twice is graded on the evidence, the part that exists once is
    /// complete as it stands. Both meet the policy, by different routes.
    func testAnExtraCopyIsStillGradedWhenThePolicyOnlyAsksForOne() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                archive(part: 1, drive: a, size: 100),
                archive(part: 1, drive: b, size: 100),
                archive(part: 2, drive: a, size: 100),
            ],
            managedTargetIDs: [a, b], defaultCopiesRequired: 1
        )
        XCTAssertEqual(
            plan.parts[0].redundancy(acrossTargets: [a, b], copiesRequired: 1), .redundantUnverified
        )
        XCTAssertEqual(
            plan.parts[1].redundancy(acrossTargets: [a, b], copiesRequired: 1), .singleCopyByPolicy
        )
        XCTAssertTrue(plan.isSatisfied)
    }

    /// The consequence the user actually sees: a single-target install has no
    /// transfers to run, nothing stranded, and nothing parked on the Mac
    /// waiting for a drive that the policy never asked for.
    func testASingleTargetInstallHasNoTransfersToRun() {
        let a = UUID()
        let replication = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a, size: 5_000)],
            managedTargetIDs: [a], defaultCopiesRequired: 1
        )
        let transfers = ExportPartTransferPlanner.plan(
            replication: replication,
            connectedDriveIDs: [a],
            heldParts: [],
            availableHoldingBytes: 500 * 1024 * 1024 * 1024
        )
        XCTAssertTrue(transfers.isEmpty)
        XCTAssertEqual(transfers.stranded, [])
        XCTAssertEqual(transfers.deferredForSpace, [])
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
            TargetReplicaState(
                assetID: asset.id, targetID: UUID(), state: .present,
                relativePath: "volume:x", lastVerifiedAt: Date()
            )
        }
        XCTAssertEqual(
            ProtectionEvaluator.protectionStates(
                for: [asset], replicaStates: replicas, desiredCopies: { _ in 2 }
            )[asset.id],
            .fullyReplicated
        )
        XCTAssertEqual(
            ProtectionEvaluator.protectionStates(
                for: [asset], replicaStates: replicas, desiredCopies: { _ in 3 }
            )[asset.id],
            .replicatedToOneDrive,
            "Where a source asks for three copies, two is not full protection"
        )
    }

    /// Two drives and one cable is the ordinary case, not an exotic one.
    ///
    /// The comparison checks required every copy of a part to be readable at
    /// once, which reads as caution and is really an assumption about cabling.
    /// A part whose copies live on drives that are never plugged in together
    /// could never be compared, so an archive on that setup could never be
    /// verified at all — while the card said the files "have not been checked
    /// against the other copy yet", a state that was permanent rather than
    /// pending.
    func testAPartIsComparableFromReadingsTakenInDifferentSessions() {
        let here = UUID(), away = UUID()
        var onHere = archive(part: 1, drive: here, size: 100)
        var onAway = archive(part: 1, drive: away, size: 100)

        // Neither has been read yet: nothing to compare, and the grade says so
        // rather than claiming agreement.
        var part = ExportPart(setID: "set", partNumber: 1, copies: [here: onHere, away: onAway])
        XCTAssertFalse(part.hashesAgree)
        XCTAssertEqual(part.redundancy(acrossTargets: [here, away], copiesRequired: 2), .redundantUnverified)

        // Session one: the drive that is here gets read.
        onHere.contentHash = "abc"
        part = ExportPart(setID: "set", partNumber: 1, copies: [here: onHere, away: onAway])
        XCTAssertFalse(part.hashesAgree, "one reading is not an agreement")

        // Session two, weeks later, the other drive. The readings meet.
        onAway.contentHash = "abc"
        part = ExportPart(setID: "set", partNumber: 1, copies: [here: onHere, away: onAway])
        XCTAssertTrue(part.hashesAgree)
        XCTAssertEqual(
            part.redundancy(acrossTargets: [here, away], copiesRequired: 2), .redundantVerified
        )
    }

    /// And two readings that disagree still disagree across sessions — the
    /// point is when they are taken, not what they are allowed to say.
    func testReadingsTakenApartStillCatchADifference() {
        let here = UUID(), away = UUID()
        var onHere = archive(part: 1, drive: here, size: 100)
        var onAway = archive(part: 1, drive: away, size: 100)
        onHere.contentHash = "abc"
        onAway.contentHash = "def"

        let part = ExportPart(setID: "set", partNumber: 1, copies: [here: onHere, away: onAway])
        XCTAssertFalse(part.hashesAgree)
        XCTAssertNotEqual(
            part.redundancy(acrossTargets: [here, away], copiesRequired: 2), .redundantVerified
        )
    }

    func testMissingPartsAreTheOnlyWorkReported() {
        let a = UUID(), b = UUID()
        var archives: [TakeoutArchive] = []
        for part in 1...12 {
            archives.append(archive(part: part, drive: a, size: 1_000))
            if part <= 9 { archives.append(archive(part: part, drive: b, size: 1_000)) }
        }
        let plan = ArchiveReplicationPlanner.plan(archives: archives, managedTargetIDs: [a, b])
        XCTAssertEqual(plan.partsNeedingWork.map(\.partNumber).sorted(), [10, 11, 12])
        XCTAssertEqual(plan.bytesOutstanding, 3_000)
    }

    /// An archive the app looked for on its connected drive and did not find is
    /// not a copy. Counting the row rather than the file is how a deleted
    /// export part went on reading as redundancy.
    func testAnArchiveFoundToBeGoneStopsCountingAsACopy() {
        let a = UUID(), b = UUID()
        var deleted = archive(part: 1, drive: a)
        deleted.missingSince = Date()

        let plan = ArchiveReplicationPlanner.plan(
            archives: [deleted, archive(part: 1, drive: b)], managedTargetIDs: [a, b]
        )
        XCTAssertEqual(
            plan.parts.first?.redundancy(acrossTargets: [a, b]), .singleCopy,
            "One drive still has the part; the other's copy was deleted"
        )
        XCTAssertFalse(plan.isSatisfied)
        XCTAssertEqual(
            plan.parts.first?.targetsNeedingACopy(managedTargetIDs: [a, b]), [a],
            "The drive that lost it is the one owed a copy"
        )
    }

    /// The extracted folder is the same part. A drive that still has the folder
    /// has not lost the part just because its zip twin was deleted.
    func testAPartSurvivingAsItsExtractedTwinIsStillHeld() {
        let a = UUID(), b = UUID()
        var deletedZip = archive(part: 1, drive: a)
        deletedZip.missingSince = Date()

        let plan = ArchiveReplicationPlanner.plan(
            archives: [
                deletedZip,
                archive(part: 1, drive: a, kind: .folder),
                archive(part: 1, drive: b),
            ],
            managedTargetIDs: [a, b]
        )
        XCTAssertEqual(plan.parts.first?.redundancy(acrossTargets: [a, b]), .redundantUnverified)
        XCTAssertTrue(plan.isSatisfied)
    }
}

/// An asset is only protected by the targets holding *its own* part. Treating
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

    /// The case the bug would have got wrong: targets holding different
    /// subsets. Only the part they both hold is redundant.
    func testDrivesHoldingDifferentPartsOnlyShareWhatTheyBothHave() {
        let a = UUID(), b = UUID()
        func archive(_ part: Int, _ drive: UUID) -> TakeoutArchive {
            TakeoutArchive(
                id: UUID(), path: "/V/takeout-S-\(String(format: "%03d", part)).zip",
                kind: .zip, sizeBytes: 100, targetID: drive, discoveredAt: Date(),
                importedAt: nil, importBatchID: nil, importedAssetCount: 0,
                skippedDuplicateCount: 0, note: nil, exportSetID: "S", partNumber: part
            )
        }
        // Both hold part 1; only A holds 2, only B holds 3.
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(1, a), archive(1, b), archive(2, a), archive(3, b)],
            managedTargetIDs: [a, b]
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

    private func drive(name: String, mount: String?) -> ReplicationTarget {
        ReplicationTarget(
            id: UUID(), name: name, volumeUUID: nil, markerToken: "t",
            registeredAt: Date(), lastSeenAt: nil, lastKnownPath: mount,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    /// Mirrors the store's resolution: connected mounts first, then each
    /// drive's last known mount point.
    private func resolve(
        path: String, connected: [UUID: URL], targets: [ReplicationTarget]
    ) -> UUID? {
        if let hit = connected.first(where: { path.hasPrefix($0.value.path + "/") })?.key {
            return hit
        }
        return targets.first {
            guard let mount = $0.lastKnownPath else { return false }
            return path.hasPrefix(mount + "/")
        }?.id
    }

    func testConnectedDriveIsMatchedByItsMountPoint() {
        let d = drive(name: "A", mount: nil)
        let resolved = resolve(
            path: "/Volumes/A/Backup/takeout-S-001.zip",
            connected: [d.id: URL(fileURLWithPath: "/Volumes/A")],
            targets: [d]
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
            targets: [d]
        )
        XCTAssertEqual(resolved, d.id, "An unplugged drive's archives must still count")
    }

    func testPathsOutsideAnyDriveAreNotAttributed() {
        let d = drive(name: "A", mount: "/Volumes/A")
        XCTAssertNil(resolve(path: "/Users/me/Downloads/takeout-S-001.zip", connected: [:], targets: [d]))
        XCTAssertNil(resolve(path: "/Volumes/Another/takeout-S-001.zip", connected: [:], targets: [d]))
    }

    /// An archive with no drive is invisible to planning, so a part with an
    /// unattributed copy must not be reported as redundant.
    func testUnattributedArchivesDoNotCountTowardsRedundancy() {
        let a = UUID()
        let attributed = TakeoutArchive(
            id: UUID(), path: "/V/A/takeout-S-001.zip", kind: .zip, sizeBytes: 10,
            targetID: a, discoveredAt: Date(), importedAt: nil, importBatchID: nil,
            importedAssetCount: 0, skippedDuplicateCount: 0, note: nil,
            exportSetID: "S", partNumber: 1
        )
        var orphan = attributed
        orphan.targetID = nil
        orphan.path = "/V/B/takeout-S-001.zip"

        let plan = ArchiveReplicationPlanner.plan(
            archives: [attributed, orphan], managedTargetIDs: [a, UUID()]
        )
        XCTAssertEqual(
            plan.parts.first?.redundancy(acrossTargets: plan.managedTargetIDs), .singleCopy,
            "A copy that belongs to no known drive cannot be counted as protection"
        )
    }
}

/// Comparing whole-file checksums of the export parts settles everything
/// inside them at once, instead of reading tens of thousands of assets.
final class ChecksumVerificationTests: XCTestCase {

    private func archive(part: Int, drive: UUID, hash: String?, size: Int64 = 100) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(), path: "/V/\(drive.uuidString)/takeout-S-\(String(format: "%03d", part)).zip",
            kind: .zip, sizeBytes: size, targetID: drive, discoveredAt: Date(),
            importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S", partNumber: part,
            contentHash: hash
        )
    }

    func testMatchingChecksumsProveThePartIsRedundant() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a, hash: "abc"), archive(part: 1, drive: b, hash: "abc")],
            managedTargetIDs: [a, b]
        )
        XCTAssertEqual(plan.parts[0].redundancy(acrossTargets: [a, b]), .redundantVerified)
        XCTAssertTrue(plan.parts[0].hashesAgree)
    }

    /// Same name, same size, different bytes: one copy is damaged or is not
    /// the part it claims to be. That must not pass as protection.
    func testDifferingChecksumsAreNotTreatedAsRedundancy() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a, hash: "abc"), archive(part: 1, drive: b, hash: "xyz")],
            managedTargetIDs: [a, b]
        )
        let part = plan.parts[0]
        XCTAssertFalse(part.hashesAgree)
        // Sizes still match, so it reads as present-but-unproven rather than
        // verified — the mismatch is what the check then flags.
        XCTAssertEqual(part.redundancy(acrossTargets: [a, b]), .redundantUnverified)
    }

    func testUnfingerprintedCopiesAreNotClaimedAsVerified() {
        let a = UUID(), b = UUID()
        let plan = ArchiveReplicationPlanner.plan(
            archives: [archive(part: 1, drive: a, hash: "abc"), archive(part: 1, drive: b, hash: nil)],
            managedTargetIDs: [a, b]
        )
        XCTAssertFalse(plan.parts[0].hashesAgree, "One hash is not a comparison")
        XCTAssertEqual(plan.parts[0].redundancy(acrossTargets: [a, b]), .redundantUnverified)
    }

    /// The point of the approach: one hash per part, whatever it contains.
    func testCostIsPerPartNotPerAsset() {
        let a = UUID(), b = UUID()
        var archives: [TakeoutArchive] = []
        for part in 1...12 {
            archives.append(archive(part: part, drive: a, hash: "h\(part)"))
            archives.append(archive(part: part, drive: b, hash: "h\(part)"))
        }
        let plan = ArchiveReplicationPlanner.plan(archives: archives, managedTargetIDs: [a, b])
        let comparisons = plan.parts.reduce(0) { $0 + $1.copies.count }
        XCTAssertEqual(comparisons, 24, "Two copies of twelve parts — not one read per photo")
        XCTAssertEqual(plan.partsMeetingPolicy.count, 12)
        XCTAssertTrue(plan.parts.allSatisfy { $0.hashesAgree })
    }
}

/// A shortfall must name the parts and the drive that needs them. "4 of 12
/// parts need another copy" tells you nothing you can act on.
final class ShortfallReportingTests: XCTestCase {

    private func archive(part: Int, drive: UUID, size: Int64 = 1_000) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(), path: "/V/takeout-S-\(String(format: "%03d", part)).zip",
            kind: .zip, sizeBytes: size, targetID: drive, discoveredAt: Date(),
            importedAt: nil, importBatchID: nil, importedAssetCount: 0,
            skippedDuplicateCount: 0, note: nil, exportSetID: "S", partNumber: part
        )
    }

    private func summary(_ archives: [TakeoutArchive], targets: Set<UUID>) -> ExportSummary {
        ExportSummary(
            setID: "S", archives: archives,
            plan: ArchiveReplicationPlanner.plan(archives: archives, managedTargetIDs: targets)
        )
    }

    func testShortfallNamesThePartsAndTheDriveThatNeedsThem() {
        let a = UUID(), b = UUID()
        // Parts 1 and 2 on both; 3 and 4 only on A.
        var archives = [archive(part: 1, drive: a), archive(part: 1, drive: b),
                        archive(part: 2, drive: a), archive(part: 2, drive: b)]
        archives += [archive(part: 3, drive: a), archive(part: 4, drive: a)]

        let export = summary(archives, targets: [a, b])
        let text = export.protection(driveNames: [a: "Drive A", b: "Drive B"]).text

        XCTAssertTrue(text.contains("3"), text)
        XCTAssertTrue(text.contains("4"), text)
        XCTAssertTrue(text.contains("Drive B"), "It must say where the copies must go: \(text)")
        XCTAssertFalse(text.contains("Drive A"), "Drive A already has them: \(text)")
        XCTAssertEqual(export.shortfall.count, 2)
    }

    /// Outstanding bytes are this export's, not every export's added together.
    func testBytesOutstandingCountOnlyThisExport() {
        let a = UUID(), b = UUID()
        let mine = [archive(part: 1, drive: a, size: 500)]
        let other = TakeoutArchive(
            id: UUID(), path: "/V/takeout-OTHER-001.zip", kind: .zip, sizeBytes: 9_000,
            targetID: a, discoveredAt: Date(), importedAt: nil, importBatchID: nil,
            importedAssetCount: 0, skippedDuplicateCount: 0, note: nil,
            exportSetID: "OTHER", partNumber: 1
        )
        let plan = ArchiveReplicationPlanner.plan(archives: mine + [other], managedTargetIDs: [a, b])
        let export = ExportSummary(setID: "S", archives: mine, plan: plan)

        XCTAssertEqual(export.bytesOutstanding, 500, "The other export's 9,000 bytes are not this export's problem")
        XCTAssertEqual(plan.bytesOutstanding, 9_500, "…though the plan as a whole still owes both")
    }

    func testFullyPresentExportReportsNoShortfall() {
        let a = UUID(), b = UUID()
        let export = summary([archive(part: 1, drive: a), archive(part: 1, drive: b)], targets: [a, b])
        XCTAssertTrue(export.shortfall.isEmpty)
        XCTAssertEqual(export.bytesOutstanding, 0)
        XCTAssertTrue(export.protection(driveNames: [:]).text.contains("On every drive"))
    }

    func testSingularWordingForOnePart() {
        let a = UUID(), b = UUID()
        let export = summary([archive(part: 7, drive: a)], targets: [a, b])
        let text = export.protection(driveNames: [a: "A", b: "B"]).text
        XCTAssertTrue(text.hasPrefix("File 7 of this download is"), text)
        XCTAssertFalse(text.contains("Files"), text)
    }

    /// The numbers are what the reader goes looking for on the drive, so they
    /// are listed the way a person would say them.
    func testSeveralShortPartsAreListedReadably() {
        let a = UUID(), b = UUID()
        var archives = [archive(part: 1, drive: a), archive(part: 1, drive: b)]
        archives += [archive(part: 3, drive: a), archive(part: 4, drive: a), archive(part: 7, drive: a)]
        let text = summary(archives, targets: [a, b]).protection(driveNames: [a: "A", b: "B"]).text
        XCTAssertTrue(text.hasPrefix("Files 3, 4 and 7 of this download are"), text)
    }
}

/// The fast comparison: a few megabytes sampled instead of every byte.
final class QuickChecksumTests: XCTestCase {

    private func makeFile(_ bytes: Int, fill: UInt8 = 0xAB, tweakAt: Int? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var data = Data(repeating: fill, count: bytes)
        if let tweakAt, tweakAt < bytes { data[tweakAt] = fill &+ 1 }
        let url = dir.appendingPathComponent("part.zip")
        try data.write(to: url)
        return url
    }

    func testIdenticalFilesProduceTheSameQuickChecksum() throws {
        let size = 12 * 1024 * 1024
        let a = try makeFile(size)
        let b = try makeFile(size)
        XCTAssertEqual(
            try HashingService.quickChecksum(of: a),
            try HashingService.quickChecksum(of: b)
        )
    }

    /// Truncation is the classic half-finished-copy failure, and length is
    /// folded into the checksum precisely so it cannot slip through.
    func testTruncatedCopyIsDetected() throws {
        let full = try makeFile(12 * 1024 * 1024)
        let short = try makeFile(11 * 1024 * 1024)
        XCTAssertNotEqual(
            try HashingService.quickChecksum(of: full),
            try HashingService.quickChecksum(of: short)
        )
    }

    func testCorruptionAtTheStartIsDetected() throws {
        let size = 12 * 1024 * 1024
        let good = try makeFile(size)
        let bad = try makeFile(size, tweakAt: 1_000)
        XCTAssertNotEqual(
            try HashingService.quickChecksum(of: good),
            try HashingService.quickChecksum(of: bad)
        )
    }

    func testCorruptionAtTheEndIsDetected() throws {
        let size = 12 * 1024 * 1024
        let good = try makeFile(size)
        let bad = try makeFile(size, tweakAt: size - 1_000)
        XCTAssertNotEqual(
            try HashingService.quickChecksum(of: good),
            try HashingService.quickChecksum(of: bad)
        )
    }

    /// Stated honestly rather than discovered later: a change between the
    /// sampled windows is invisible. That is the trade being made, and why
    /// the result is recorded as a spot check and not as proof.
    func testAChangeBetweenSampledWindowsIsNotSeen() throws {
        let size = 64 * 1024 * 1024
        let good = try makeFile(size)
        // Just past the head window, far from any interior probe.
        let bad = try makeFile(size, tweakAt: HashingService.quickChecksumEdgeWindow + 4_000_000)
        XCTAssertEqual(
            try HashingService.quickChecksum(of: good),
            try HashingService.quickChecksum(of: bad),
            "A spot check samples; only a full hash can prove equality"
        )
        XCTAssertNotEqual(
            try HashingService.sha256(of: good),
            try HashingService.sha256(of: bad),
            "…which the full hash does catch"
        )
    }

    func testSmallFilesAreReadWholeSoSamplingNeverWeakensThem() throws {
        let a = try makeFile(64 * 1024)
        let b = try makeFile(64 * 1024, tweakAt: 30_000)
        XCTAssertNotEqual(
            try HashingService.quickChecksum(of: a),
            try HashingService.quickChecksum(of: b)
        )
    }

    func testSpotCheckedRedundancyRanksBelowFullVerification() {
        XCTAssertTrue(PartRedundancy.redundantSpotChecked.meetsPolicy)
        XCTAssertTrue(PartRedundancy.redundantVerified.meetsPolicy)
        XCTAssertNotEqual(PartRedundancy.redundantSpotChecked, .redundantVerified)
    }
}

/// Where an export set lives on a drive is the user's decision, already made
/// and recorded in the paths of the parts they placed. A part arriving later
/// reads that decision rather than starting a second pile at the volume root.
final class ExportSetLayoutTests: XCTestCase {

    private let mount = URL(fileURLWithPath: "/Volumes/My Passport", isDirectory: true)

    private func archive(
        _ path: String, part: Int, setID: String = "S1", missing: Bool = false,
        kind: TakeoutArchiveKind = .zip
    ) -> TakeoutArchive {
        var archive = TakeoutArchive(
            id: UUID(), path: path, kind: kind, sizeBytes: 10, targetID: UUID(),
            discoveredAt: Date(), importedAt: nil, importBatchID: nil,
            importedAssetCount: 0, skippedDuplicateCount: 0, note: nil,
            exportSetID: setID, partNumber: part
        )
        if missing { archive.missingSince = Date() }
        return archive
    }

    func testAPartJoinsTheFolderWhereTheSetAlreadyLives() {
        let archives = (1...11).map {
            archive("/Volumes/My Passport/Google_Photos_Backup_July2026/takeout-S1-\($0).zip", part: $0)
        }
        XCTAssertEqual(
            ExportSetLayout.home(forSet: "S1", onMount: mount, archives: archives)?.path,
            "/Volumes/My Passport/Google_Photos_Backup_July2026"
        )
    }

    /// The reported bug in one assertion: eleven parts in the user's folder and
    /// one the app dropped at the root must not make the root look like home.
    func testTheAppsOwnFolderIsNeverTheHome() {
        var archives = (1...11).map {
            archive("/Volumes/My Passport/Google_Photos_Backup_July2026/takeout-S1-\($0).zip", part: $0)
        }
        archives.append(archive("/Volumes/My Passport/HeykinnClicks/ExportParts/takeout-S1-012.zip", part: 12))

        XCTAssertEqual(
            ExportSetLayout.home(forSet: "S1", onMount: mount, archives: archives)?.path,
            "/Volumes/My Passport/Google_Photos_Backup_July2026"
        )
    }

    /// Even when the app's folder holds more of the set than anywhere else: it
    /// is a waiting room, and a waiting room that filled up is still not a home.
    func testTheAppsFolderLosesEvenWithMoreParts() {
        var archives = [archive("/Volumes/My Passport/Mine/takeout-S1-001.zip", part: 1)]
        archives += (2...9).map {
            archive("/Volumes/My Passport/HeykinnClicks/ExportParts/takeout-S1-\($0).zip", part: $0)
        }
        XCTAssertEqual(
            ExportSetLayout.home(forSet: "S1", onMount: mount, archives: archives)?.path,
            "/Volumes/My Passport/Mine"
        )
    }

    func testTheFolderHoldingMostOfTheSetWins() {
        let archives = [
            archive("/Volumes/My Passport/Scattered/takeout-S1-001.zip", part: 1),
            archive("/Volumes/My Passport/Main/takeout-S1-002.zip", part: 2),
            archive("/Volumes/My Passport/Main/takeout-S1-003.zip", part: 3),
        ]
        XCTAssertEqual(
            ExportSetLayout.home(forSet: "S1", onMount: mount, archives: archives)?.path,
            "/Volumes/My Passport/Main"
        )
    }

    /// A zip and the folder extracted beside it are one part between them, or a
    /// directory holding both twins of one part would outvote a directory
    /// holding two real parts.
    func testAZipAndItsExtractedTwinCountAsOnePart() {
        let archives = [
            archive("/Volumes/My Passport/Twins/takeout-S1-001.zip", part: 1),
            archive("/Volumes/My Passport/Twins/takeout-S1-001", part: 1, kind: .folder),
            archive("/Volumes/My Passport/Real/takeout-S1-002.zip", part: 2),
            archive("/Volumes/My Passport/Real/takeout-S1-003.zip", part: 3),
        ]
        XCTAssertEqual(
            ExportSetLayout.home(forSet: "S1", onMount: mount, archives: archives)?.path,
            "/Volumes/My Passport/Real"
        )
    }

    func testADeletedPartDoesNotVoteForWhereTheSetLives() {
        let archives = [
            archive("/Volumes/My Passport/Gone/takeout-S1-001.zip", part: 1, missing: true),
            archive("/Volumes/My Passport/Gone/takeout-S1-002.zip", part: 2, missing: true),
            archive("/Volumes/My Passport/Here/takeout-S1-003.zip", part: 3),
        ]
        XCTAssertEqual(
            ExportSetLayout.home(forSet: "S1", onMount: mount, archives: archives)?.path,
            "/Volumes/My Passport/Here"
        )
    }

    func testAnotherExportsFolderIsNotThisExportsHome() {
        let archives = [
            archive("/Volumes/My Passport/Export2025/takeout-S2-001.zip", part: 1, setID: "S2"),
        ]
        XCTAssertNil(ExportSetLayout.home(forSet: "S1", onMount: mount, archives: archives))
    }

    func testAnotherDrivesFolderIsNotThisDrivesHome() {
        let archives = [
            archive("/Volumes/Owner's Back/Owner/takeout-S1-001.zip", part: 1),
        ]
        XCTAssertNil(
            ExportSetLayout.home(forSet: "S1", onMount: mount, archives: archives),
            "A path on another volume says nothing about where this drive keeps the set"
        )
    }

    func testNoPartsMeansNoHome() {
        XCTAssertNil(ExportSetLayout.home(forSet: "S1", onMount: mount, archives: []))
    }
}
