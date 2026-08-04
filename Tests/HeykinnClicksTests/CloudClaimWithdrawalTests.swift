import XCTest
@testable import HeykinnClicks

/// Withdrawing cloud claims rewrites assets in a catalog that is somebody's
/// only record of where their photos are, so the rule is pinned here.
final class CloudClaimWithdrawalTests: XCTestCase {

    private func makeAsset(
        residency: ResidencyDomain,
        presence: DomainPresence,
        evidence: CloudPresenceEvidence
    ) -> Asset {
        Asset(
            id: UUID(),
            kind: .photo,
            originalFilename: "photo.jpg",
            importOrigin: .googleTakeout,
            captureDate: nil,
            importDate: Date(),
            updatedDate: Date(),
            fileSize: 1024,
            pixelWidth: nil,
            pixelHeight: nil,
            contentHash: "hash",
            residency: residency,
            residencySource: .importDefault,
            presence: presence,
            stagingRelativePath: nil,
            importBatchID: nil,
            exifSummary: [:],
            cloudPresenceEvidence: evidence,
            cloudPresenceCheckedAt: nil
        )
    }

    func testAnUnverifiedClaimIsWithdrawn() throws {
        let asset = makeAsset(
            residency: .local,
            presence: DomainPresence(local: true, appleCloud: false, googleCloud: true),
            evidence: .none
        )

        let updated = try XCTUnwrap(CloudClaimWithdrawal.withdraw(.googleCloud, from: asset))

        XCTAssertFalse(updated.presence.googleCloud)
        XCTAssertTrue(updated.presence.local, "Local presence is untouched — hashing proved it")
        XCTAssertEqual(updated.cloudPresenceEvidence, .none)
        XCTAssertNil(updated.cloudPresenceCheckedAt)
    }

    /// The app holds the bytes, so Local is a claim it can actually stand behind.
    func testResidencyFallsBackToLocalWhenTheBytesAreHere() throws {
        let asset = makeAsset(
            residency: .googleCloud,
            presence: DomainPresence(local: true, appleCloud: false, googleCloud: true),
            evidence: .none
        )

        let updated = try XCTUnwrap(CloudClaimWithdrawal.withdraw(.googleCloud, from: asset))

        XCTAssertEqual(updated.residency, .local)
        XCTAssertEqual(updated.residencySource, .manual)
    }

    /// The case that matters: a cloud-resident asset the app has never held.
    /// With no local copy the claim is the only record that this content exists
    /// anywhere, so withdrawing it would assert the asset is nowhere at all —
    /// a stronger falsehood than the unverified claim it replaces.
    func testNothingIsWithdrawnWhenThereAreNoLocalBytes() {
        let asset = makeAsset(
            residency: .appleCloud,
            presence: DomainPresence(local: false, appleCloud: true, googleCloud: false),
            evidence: .none
        )

        XCTAssertNil(
            CloudClaimWithdrawal.withdraw(.appleCloud, from: asset),
            "Withdrawal needs a local copy to stand on; without one the claim stays"
        )
        XCTAssertTrue(
            CloudClaimWithdrawal.isUnverifiedClaim(asset, domain: .appleCloud),
            "It is still an unfounded claim…"
        )
        XCTAssertFalse(
            CloudClaimWithdrawal.isWithdrawable(asset, domain: .appleCloud),
            "…but not one the app can safely drop"
        )
    }

    func testVerifiedPresenceIsNeverWithdrawn() {
        let asset = makeAsset(
            residency: .googleCloud,
            presence: DomainPresence(local: false, appleCloud: false, googleCloud: true),
            evidence: .verified
        )

        XCTAssertNil(
            CloudClaimWithdrawal.withdraw(.googleCloud, from: asset),
            "A claim the app checked against a connected account is evidence, not a guess"
        )
    }

    func testAssetsWithoutAClaimAreUntouched() {
        let asset = makeAsset(
            residency: .local,
            presence: .localOnly,
            evidence: .none
        )

        XCTAssertNil(CloudClaimWithdrawal.withdraw(.googleCloud, from: asset))
        XCTAssertFalse(CloudClaimWithdrawal.isUnverifiedClaim(asset, domain: .googleCloud))
    }

    func testLocalIsNotACloudClaim() {
        let asset = makeAsset(residency: .local, presence: .localOnly, evidence: .none)

        XCTAssertNil(CloudClaimWithdrawal.withdraw(.local, from: asset))
        XCTAssertFalse(CloudClaimWithdrawal.isUnverifiedClaim(asset, domain: .local))
    }
}
