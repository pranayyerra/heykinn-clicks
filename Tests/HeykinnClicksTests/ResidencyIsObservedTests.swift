import XCTest
@testable import HeykinnClicks

/// Where a photograph is kept is something the app **reports**, never something
/// set by hand.
///
/// There was a control that flipped the recorded domain and moved nothing, after
/// which the app reported the photograph as being in the wrong place until a
/// migration caught up. It was also a way to assert what this app refuses to
/// take on assertion: earlier versions let somebody state that content was in a
/// cloud domain and recorded the answer as presence, and that was withdrawn
/// because a claim with no evidence under it is not data worth keeping.
///
/// These cover what has to remain true now that it is gone — chiefly that the
/// paths which change residency *because something actually happened* all still
/// work. See `docs/PRODUCT-DECISIONS.md` P3.
final class ResidencyIsObservedTests: XCTestCase {

    private func makeAsset(
        residency: ResidencyDomain = .local,
        source: ResidencyAssignmentSource = .importDefault,
        presence: DomainPresence = .localOnly,
        evidence: CloudPresenceEvidence = .none
    ) -> Asset {
        var asset = Asset(
            id: UUID(), kind: .photo, originalFilename: "a.jpg", importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString,
            residency: residency, residencySource: source, presence: presence,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
        )
        asset.cloudPresenceEvidence = evidence
        return asset
    }

    /// The path that runs on its own and legitimately rewrites residency: an
    /// unverified cloud claim being withdrawn once the content is held locally.
    /// Removing the control must not have touched it.
    func testWithdrawingAnUnverifiedCloudClaimStillRewritesResidency() throws {
        var presence = DomainPresence.localOnly
        presence.set(.appleCloud, true)
        let claimed = makeAsset(
            residency: .appleCloud, source: .importDefault, presence: presence, evidence: .none
        )

        let withdrawn = try XCTUnwrap(CloudClaimWithdrawal.withdraw(.appleCloud, from: claimed))

        XCTAssertEqual(withdrawn.residency, .local, "residency must follow the content that exists")
        XCTAssertEqual(withdrawn.residencySource, .manual)
        XCTAssertFalse(withdrawn.presence.contains(.appleCloud))
        XCTAssertEqual(withdrawn.cloudPresenceEvidence, .none)
    }

    /// And the rule that keeps that honest: a claim is only withdrawn when the
    /// app holds the bytes locally. Without a local copy the cloud claim is the
    /// only record the content exists at all, and dropping it would assert the
    /// photograph is nowhere — worse than the unchecked claim it replaces.
    func testAClaimIsNotWithdrawnWhenNothingIsHeldLocally() {
        var presence = DomainPresence.none
        presence.set(.appleCloud, true)
        let onlyInCloud = makeAsset(
            residency: .appleCloud, source: .importDefault, presence: presence, evidence: .none
        )

        XCTAssertNil(CloudClaimWithdrawal.withdraw(.appleCloud, from: onlyInCloud))
    }

    /// A claim the app actually checked is evidence, and is never withdrawn.
    func testAVerifiedClaimIsLeftAlone() {
        var presence = DomainPresence.localOnly
        presence.set(.appleCloud, true)
        let verified = makeAsset(
            residency: .appleCloud, source: .importDefault, presence: presence, evidence: .verified
        )

        XCTAssertNil(CloudClaimWithdrawal.withdraw(.appleCloud, from: verified))
    }

    /// The guard against the control coming back. `setManualResidency` had one
    /// caller — a picker in the photo detail pane — and reintroducing either
    /// means reintroducing a way to record a place the app has not checked.
    ///
    /// Written against the source because there is no API left to call: that is
    /// the point of the change, and a test that compiles is a test that the
    /// thing still exists.
    func testNothingSetsResidencyByHandAnyMore() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HeykinnClicksTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/HeykinnClicks", isDirectory: true)

        let walker = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        ))
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            // In a comment it is history; in code it is the control returning.
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = line.split(separator: "/").first.map(String.init) ?? String(line)
                if code.contains("setManualResidency") {
                    offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "residency is set by hand again: \(offenders)"
        )
    }
}
