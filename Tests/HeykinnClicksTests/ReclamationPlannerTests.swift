import XCTest
@testable import HeykinnClicks

/// What reclamation would release. The preconditions are the safety mechanism,
/// so each of them is a test: an archive that has not met one must not appear
/// ready to give up a cloud original.
final class ReclamationPlannerTests: XCTestCase {

    private let policy = LocalRedundancyPolicy(desiredCopies: 2)
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
        replicas: [TargetReplicaState],
        agreeing: Set<UUID>? = nil
    ) -> ReclamationPlanner.Plan {
        ReclamationPlanner.plan(
            assets: [asset],
            replicasByAssetID: [asset.id: replicas],
            registeredTargetIDs: [first, second],
            agreeingTargetIDs: agreeing ?? [first, second],
            policy: policy
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

    /// Targets that disagree are an open question about the content, and an
    /// open question is not the ground to delete an original from.
    func testDisagreeingTargetsBlockRelease() {
        let asset = makeAsset()
        let result = plan(asset, replicas: replicas(asset, on: [first, second]), agreeing: [first])

        XCTAssertTrue(result.releasableAssetIDs.isEmpty)
        XCTAssertEqual(result.blocked[.targetsDisagree], 1)
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
            agreeingTargetIDs: [first, second, forgotten],
            policy: policy
        )

        XCTAssertEqual(result.blocked[.notEnoughCopies], 1)
    }
}
