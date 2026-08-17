import XCTest
@testable import HeykinnClicks

/// What reclamation would release. The preconditions are the safety mechanism,
/// so each of them is a test: an archive that has not met one must not appear
/// ready to give up a cloud original.
final class ReclamationPlannerTests: XCTestCase {

    /// What every source in these fixtures asks for.
    private let copies = 2
    private let first = UUID()
    private let second = UUID()

    private func makeAsset(
        residency: ResidencyDomain = .local,
        appleCloud: Bool = true,
        evidence: CloudPresenceEvidence = .verified
    ) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "photo.jpg",
            importOrigin: .googleTakeout, captureDate: Date(), importDate: Date(),
            updatedDate: Date(), fileSize: 1_000, pixelWidth: 1, pixelHeight: 1,
            contentHash: "hash", residency: residency, residencySource: .importDefault,
            presence: DomainPresence(local: true, appleCloud: appleCloud, googleCloud: false),
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:],
            cloudPresenceEvidence: evidence
        )
    }

    private func replicas(
        _ asset: Asset, on targets: [UUID], verified: Bool = true,
        state: ReplicaFileState = .present
    ) -> [TargetReplicaState] {
        targets.map {
            TargetReplicaState(
                assetID: asset.id, targetID: $0, state: state,
                relativePath: "volume:a.jpg",
                lastVerifiedAt: verified ? Date() : nil
            )
        }
    }

    private func plan(
        _ asset: Asset,
        replicas: [TargetReplicaState]
    ) -> ReclamationPlanner.Plan {
        ReclamationPlanner.plan(
            assets: [asset],
            replicasByAssetID: [asset.id: replicas],
            registeredTargetIDs: [first, second],
            desiredCopies: { _ in copies }
        )
    }

    /// Everything proven: enough copies, each read back and matched, on targets
    /// that agree with each other.
    func testAFullyProvenAssetIsReleasable() {
        let asset = makeAsset()
        let result = plan(asset, replicas: replicas(asset, on: [first, second]))

        XCTAssertEqual(result.releasableAssetIDs, [asset.id])
        XCTAssertEqual(result.releasableBytes, 1_000)
        XCTAssertTrue(result.blocked.isEmpty)
    }

    /// One copy is not redundancy. Releasing the cloud original here would
    /// leave the archive one drive failure from losing the photograph.
    func testOneCopyIsNotEnough() {
        let asset = makeAsset()
        let result = plan(asset, replicas: replicas(asset, on: [first]))

        XCTAssertTrue(result.releasableAssetIDs.isEmpty)
        XCTAssertEqual(result.blocked[.notEnoughCopies], 1)
    }

    /// A copy nobody read back is not verified — the invariant the whole app
    /// is built on, applied where it matters most.
    func testACopyNeverReadBackBlocksRelease() {
        let asset = makeAsset()
        let result = plan(asset, replicas: replicas(asset, on: [first, second], verified: false))

        XCTAssertTrue(result.releasableAssetIDs.isEmpty)
        XCTAssertEqual(result.blocked[.notReadBack], 1)
    }

    /// Devices holding different content is the normal state under k-of-n, so
    /// it must not block release on its own.
    ///
    /// This replaces `testDisagreeingTargetsBlockRelease`, which asserted the
    /// opposite. That test passed and encoded a rule that would have frozen
    /// reclamation permanently the moment devices stopped mirroring each other
    /// — the preconditions belong to the asset, not to how two disks compare.
    func testDevicesHoldingDifferentContentDoesNotBlockRelease() {
        let asset = makeAsset()
        // Proven on both devices; whatever else those devices hold is
        // irrelevant to this asset's release.
        let result = plan(asset, replicas: replicas(asset, on: [first, second]))

        XCTAssertEqual(result.releasableAssetIDs, [asset.id])
        XCTAssertTrue(result.blocked.isEmpty)
    }

    /// A copy that is only pending is not a copy.
    func testPendingCopiesDoNotCount() {
        let asset = makeAsset()
        let result = plan(asset, replicas: replicas(asset, on: [first, second], state: .pending))

        XCTAssertEqual(result.blocked[.notEnoughCopies], 1)
    }

    /// Nothing to reclaim is a different statement from nothing qualifying.
    /// With iCloud Photos off there is no cloud copy at all, and the screen
    /// must not imply the archive is failing a test it was never sitting.
    func testNoVerifiedCloudCopyMeansThereIsNothingToReclaim() {
        let asset = makeAsset(appleCloud: false, evidence: .none)
        let result = plan(asset, replicas: replicas(asset, on: [first, second]))

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.withVerifiedCloudCopy, 0)
        XCTAssertTrue(result.blocked.isEmpty)
    }

    /// Apple presence asserted without a connected account confirming it is
    /// exactly what invariant 3 forbids, and it must never reach this list.
    func testUnverifiedCloudPresenceIsNotGroundsForRelease() {
        let asset = makeAsset(evidence: .none)
        let result = plan(asset, replicas: replicas(asset, on: [first, second]))

        XCTAssertTrue(result.isEmpty)
    }

    /// An asset whose home is the cloud is a migration, not a reclamation.
    func testCloudResidentAssetsAreNotReclamationCandidates() {
        let asset = makeAsset(residency: .appleCloud)
        let result = plan(asset, replicas: replicas(asset, on: [first, second]))

        XCTAssertTrue(result.isEmpty)
    }

    /// A copy on a target that has since been forgotten is not a copy the
    /// policy counts.
    func testCopiesOnUnregisteredTargetsDoNotCount() {
        let asset = makeAsset()
        let forgotten = UUID()
        let result = ReclamationPlanner.plan(
            assets: [asset],
            replicasByAssetID: [asset.id: replicas(asset, on: [first, forgotten])],
            registeredTargetIDs: [first, second],
            desiredCopies: { _ in copies }
        )

        XCTAssertEqual(result.blocked[.notEnoughCopies], 1)
    }

    // MARK: - Saying it in a sentence

    /// The line is shown to somebody who is not technical, so it may not use a
    /// word the app invented, and it may not promise an action the app cannot
    /// take. See invariant 15 and R8.
    func testTheSummaryReadsAsEvidenceRatherThanAdvice() {
        var plan = ReclamationPlanner.Plan()
        plan.withVerifiedCloudCopy = 5_040
        plan.releasableAssetIDs = Set((0..<1_240).map { _ in UUID() })
        plan.releasableBytes = 14_000_000_000
        plan.blocked = [.notEnoughCopies: 3_000, .notReadBack: 800]

        let summary = plan.plainSummary ?? ""

        XCTAssertTrue(summary.contains("1,240 photos"), summary)
        XCTAssertTrue(summary.contains("iCloud"), "must name what was actually checked: \(summary)")
        XCTAssertTrue(summary.contains("3,000"), summary)
        XCTAssertTrue(summary.contains("800"), summary)

        for invented in ["reclamation", "releasable", "blocked", "asset", "replica", "precondition"] {
            XCTAssertFalse(
                summary.lowercased().contains(invented),
                "\"\(invented)\" is our word, not the reader's: \(summary)"
            )
        }
        // Evidence, not instruction.
        for promise in ["delete", "will be removed", "free up", "you should"] {
            XCTAssertFalse(summary.lowercased().contains(promise), "reads as advice: \(summary)")
        }
    }

    /// Nothing in the cloud is a different statement from nothing qualifying,
    /// and neither is worth a line on the screen.
    func testThereIsNothingToSayWhenNothingIsInICloud() {
        XCTAssertNil(ReclamationPlanner.Plan().plainSummary)
    }

    /// Some verified in iCloud, none of them clear yet — worth saying, because
    /// it tells somebody what is holding it up.
    func testItSaysWhatIsHoldingThingsUpWhenNothingQualifies() throws {
        var plan = ReclamationPlanner.Plan()
        plan.withVerifiedCloudCopy = 200
        plan.blocked = [.notEnoughCopies: 200]

        let summary = try XCTUnwrap(plan.plainSummary)
        XCTAssertTrue(summary.contains("200"), summary)
        XCTAssertTrue(summary.contains("waiting for another copy"), summary)
    }
}
