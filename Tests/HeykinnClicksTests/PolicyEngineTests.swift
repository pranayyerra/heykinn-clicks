import XCTest
@testable import HeykinnClicks

/// The rules decide what content *should* be — but a rule can only grant what
/// presence supports. These pin the completion of the engine: cloud targets
/// become migration intents, and the primary import path consults the rules.
final class PolicyEngineTests: XCTestCase {

    private func rule(
        priority: Int = 50,
        enabled: Bool = true,
        origin: ImportOrigin? = nil,
        kind: AssetKind? = nil,
        minSize: Int64? = nil,
        target: ResidencyDomain
    ) -> PolicyRule {
        PolicyRule(
            id: UUID(), name: "r\(priority)", priority: priority, isEnabled: enabled,
            matchOrigin: origin, matchKind: kind, minFileSize: minSize,
            targetResidency: target
        )
    }

    // MARK: - Cloud targets are intents, not labels

    /// The core completion: an import proves local presence and nothing else,
    /// so a cloud-targeting rule must never write a cloud residency the
    /// violation scanner would immediately (and correctly) reject.
    func testCloudTargetRuleAssignsLocalWithAMigrationIntent() {
        let decision = PolicyEngine.assignResidency(
            kind: .photo, origin: .googleTakeout, fileSize: 1,
            rules: [rule(target: .googleCloud)]
        )

        XCTAssertEqual(decision.residency, .local, "Residency is what presence supports")
        XCTAssertEqual(decision.source, .policy)
        XCTAssertEqual(decision.pendingCloudTarget, .googleCloud, "The rule's wish becomes a migration")
    }

    func testLocalTargetRuleCarriesNoIntent() {
        let decision = PolicyEngine.assignResidency(
            kind: .photo, origin: .whatsapp, fileSize: 1,
            rules: [rule(origin: .whatsapp, target: .local)]
        )

        XCTAssertEqual(decision.residency, .local)
        XCTAssertEqual(decision.source, .policy)
        XCTAssertNil(decision.pendingCloudTarget)
    }

    func testDisabledRulesAreSkipped() {
        let decision = PolicyEngine.assignResidency(
            kind: .photo, origin: .localFolder, fileSize: 1,
            rules: [rule(enabled: false, target: .googleCloud)]
        )

        XCTAssertEqual(decision.source, .importDefault)
        XCTAssertNil(decision.pendingCloudTarget)
    }

    func testMinimumSizeIsAnInclusiveThreshold() {
        let rules = [rule(minSize: 100, target: .local)]
        XCTAssertNil(PolicyEngine.assignResidency(kind: .video, origin: .localFolder, fileSize: 99, rules: rules).matchedRule)
        XCTAssertNotNil(PolicyEngine.assignResidency(kind: .video, origin: .localFolder, fileSize: 100, rules: rules).matchedRule)
    }

    // MARK: - The Takeout path consults the rules

    private func makeTinyTakeoutTree() throws -> (root: URL, staging: StagingStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-takeout-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Takeout/Google Photos/Photos from 2020", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Two real one-pixel PNGs with distinct bytes, one WhatsApp-named.
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for (name, tail) in [("IMG_100.PNG", UInt8(1)), ("IMG-20200101-WA0001.PNG", UInt8(2))] {
            var data = Data(pngHeader)
            data.append(tail)
            try data.write(to: photos.appendingPathComponent(name))
        }
        let staging = StagingStore(
            rootURL: root.appendingPathComponent("staging", isDirectory: true)
        )
        return (root.appendingPathComponent("Takeout"), staging)
    }

    /// The primary import path used to hardcode importDefault and ignore the
    /// rule table entirely.
    func testTakeoutImportAppliesRulesAndCollectsCloudIntents() async throws {
        let (takeout, staging) = try makeTinyTakeoutTree()

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeout, cleanupURL: nil),
            archiveName: "Takeout",
            staging: staging,
            policyRules: [rule(origin: .googleTakeout, target: .googleCloud)]
        )

        XCTAssertEqual(result.failures.count, 0)
        let takeoutOrigin = result.importedAssets.filter { $0.importOrigin == .googleTakeout }
        XCTAssertFalse(takeoutOrigin.isEmpty)
        for asset in takeoutOrigin {
            XCTAssertEqual(asset.residency, .local, "Rules never flip residency past presence")
            XCTAssertEqual(asset.residencySource, .policy)
        }
        XCTAssertEqual(
            Set(result.cloudPlacements[.googleCloud] ?? []),
            Set(takeoutOrigin.map(\.id)),
            "Every rule-matched asset is queued for migration, and only those"
        )
    }

    /// WhatsApp media that travelled through a Takeout keeps its real origin,
    /// so origin-scoped rules see it.
    func testWhatsAppMediaInsideATakeoutKeepsItsOrigin() async throws {
        let (takeout, staging) = try makeTinyTakeoutTree()

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeout, cleanupURL: nil),
            archiveName: "Takeout",
            staging: staging,
            policyRules: []
        )

        let whatsapp = result.importedAssets.filter { $0.importOrigin == .whatsapp }
        XCTAssertEqual(whatsapp.count, 1)
        XCTAssertEqual(whatsapp.first?.originalFilename, "IMG-20200101-WA0001.PNG")
        XCTAssertEqual(whatsapp.first?.residencySource, .importDefault)
    }

    /// With no rules, the Takeout path behaves exactly as before completion.
    func testNoRulesMeansImportDefaultEverywhere() async throws {
        let (takeout, staging) = try makeTinyTakeoutTree()

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeout, cleanupURL: nil),
            archiveName: "Takeout",
            staging: staging
        )

        for asset in result.importedAssets {
            XCTAssertEqual(asset.residency, .local)
            XCTAssertEqual(asset.residencySource, .importDefault)
        }
        XCTAssertTrue(result.cloudPlacements.isEmpty)
    }
}
