import XCTest
@testable import HeykinnClicks

final class CoreEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeAsset(
        id: UUID = UUID(),
        filename: String = "test.jpg",
        residency: ResidencyDomain = .local,
        presence: DomainPresence = .localOnly,
        hash: String = "deadbeef",
        stagingPath: String? = nil
    ) -> Asset {
        Asset(
            id: id,
            kind: .photo,
            originalFilename: filename,
            importOrigin: .localFolder,
            captureDate: nil,
            importDate: Date(),
            updatedDate: Date(),
            fileSize: 100,
            pixelWidth: nil,
            pixelHeight: nil,
            contentHash: hash,
            residency: residency,
            residencySource: .importDefault,
            presence: presence,
            stagingRelativePath: stagingPath,
            importBatchID: nil,
            exifSummary: [:]
        )
    }

    private func makeDrive(id: UUID = UUID(), name: String = "Drive") -> ReplicationTarget {
        ReplicationTarget(
            id: id,
            name: name,
            volumeUUID: nil,
            markerToken: "token",
            registeredAt: Date(),
            lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    // MARK: - PolicyEngine

    func testPolicyEngineHighestPriorityMatchWins() {
        let whatsappRule = PolicyRule(
            id: UUID(), name: "WA", priority: 100, isEnabled: true,
            matchOrigin: .whatsapp, matchKind: nil, minFileSize: nil, targetResidency: .local
        )
        let catchAllRule = PolicyRule(
            id: UUID(), name: "All to Google", priority: 10, isEnabled: true,
            matchOrigin: nil, matchKind: nil, minFileSize: nil, targetResidency: .googleCloud
        )
        let decision = PolicyEngine.assignResidency(
            kind: .photo, origin: .whatsapp, fileSize: 1, rules: [catchAllRule, whatsappRule]
        )
        XCTAssertEqual(decision.residency, .local)
        XCTAssertEqual(decision.source, .policy)
        XCTAssertEqual(decision.matchedRule?.id, whatsappRule.id)
    }

    func testPolicyEngineDefaultsToLocal() {
        let decision = PolicyEngine.assignResidency(kind: .photo, origin: .localFolder, fileSize: 1, rules: [])
        XCTAssertEqual(decision.residency, .local)
        XCTAssertEqual(decision.source, .importDefault)
    }

    func testPolicyEngineDisabledRuleIgnored() {
        let disabled = PolicyRule(
            id: UUID(), name: "Off", priority: 100, isEnabled: false,
            matchOrigin: nil, matchKind: nil, minFileSize: nil, targetResidency: .appleCloud
        )
        let decision = PolicyEngine.assignResidency(kind: .photo, origin: .localFolder, fileSize: 1, rules: [disabled])
        XCTAssertEqual(decision.residency, .local)
    }

    // MARK: - DuplicateDetector

    func testDuplicateDetectorGroupsByHash() {
        let a = makeAsset(hash: "same")
        let b = makeAsset(hash: "same")
        let c = makeAsset(hash: "different")
        let groups = DuplicateDetector.groups(in: [a, b, c])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].assetIDs), Set([a.id, b.id]))
    }

    // MARK: - ProtectionEvaluator

    func testProtectionStates() {
        let asset = makeAsset()
        let driveA = UUID()
        let driveB = UUID()

        func replica(_ drive: UUID, _ state: ReplicaFileState, verified: Date? = Date()) -> TargetReplicaState {
            TargetReplicaState(assetID: asset.id, targetID: drive, state: state, relativePath: nil, lastVerifiedAt: verified)
        }

        XCTAssertEqual(
            ProtectionEvaluator.protectionState(for: asset, replicaStates: [], desiredCopies: 2),
            .stagedOnly
        )
        XCTAssertEqual(
            ProtectionEvaluator.protectionState(for: asset, replicaStates: [replica(driveA, .present)], desiredCopies: 2),
            .replicatedToOneDrive
        )
        XCTAssertEqual(
            ProtectionEvaluator.protectionState(for: asset, replicaStates: [replica(driveA, .present), replica(driveB, .present)], desiredCopies: 2),
            .fullyReplicated
        )
        XCTAssertEqual(
            ProtectionEvaluator.protectionState(for: asset, replicaStates: [replica(driveA, .drift), replica(driveB, .present)], desiredCopies: 2),
            .driftDetected
        )
        let staleDate = Date().addingTimeInterval(-ProtectionEvaluator.verificationMaxAge - 3600)
        XCTAssertEqual(
            ProtectionEvaluator.protectionState(
                for: asset,
                replicaStates: [replica(driveA, .present, verified: staleDate), replica(driveB, .present)],
            desiredCopies: 2
        ),
            .verificationOverdue
        )
    }

    func testProtectionNotApplicableForCloudResidency() {
        let asset = makeAsset(residency: .appleCloud, presence: DomainPresence(local: false, appleCloud: true, googleCloud: false))
        XCTAssertEqual(ProtectionEvaluator.protectionState(for: asset, replicaStates: [], desiredCopies: 2), .notApplicable)
    }

    // MARK: - ViolationScanner

    func testMultiDomainCoexistenceFlaggedWithoutMigration() {
        let asset = makeAsset(presence: DomainPresence(local: true, appleCloud: true, googleCloud: false))
        let violations = ViolationScanner.scan(assets: [asset], replicaStates: [], migrationJobs: [], targetsByID: [:])
        XCTAssertTrue(violations.contains { $0.kind == .multiDomainCoexistence && $0.assetID == asset.id })
    }

    func testMultiDomainOverlapAllowedDuringActiveMigration() {
        let asset = makeAsset(presence: DomainPresence(local: true, appleCloud: true, googleCloud: false))
        let job = MigrationJob(
            id: UUID(), assetIDs: [asset.id], fromDomain: .local, toDomain: .appleCloud,
            state: .verifyingTarget, createdAt: Date(), updatedAt: Date(), note: nil
        )
        let violations = ViolationScanner.scan(assets: [asset], replicaStates: [], migrationJobs: [job], targetsByID: [:])
        XCTAssertFalse(violations.contains { $0.kind == .multiDomainCoexistence })
    }

    func testResidencyPresenceMismatchFlagged() {
        let asset = makeAsset(residency: .googleCloud, presence: .localOnly)
        let violations = ViolationScanner.scan(assets: [asset], replicaStates: [], migrationJobs: [], targetsByID: [:])
        XCTAssertTrue(violations.contains { $0.kind == .residencyPresenceMismatch })
        // The Local + GoogleCloud shape is also multi-domain? No: presence is local-only,
        // residency google — only the mismatch fires.
        XCTAssertFalse(violations.contains { $0.kind == .multiDomainCoexistence })
    }

    func testOrphanReplicaFlagged() {
        let drive = makeDrive()
        let asset = makeAsset(residency: .appleCloud, presence: DomainPresence(local: false, appleCloud: true, googleCloud: false))
        let replica = TargetReplicaState(assetID: asset.id, targetID: drive.id, state: .present, relativePath: nil, lastVerifiedAt: Date())
        let violations = ViolationScanner.scan(
            assets: [asset], replicaStates: [replica], migrationJobs: [], targetsByID: [drive.id: drive]
        )
        XCTAssertTrue(violations.contains { $0.kind == .orphanReplica })
    }

    // MARK: - MigrationService

    func testMigrationLifecycleClearsSourceAndFlipsResidency() throws {
        let asset = makeAsset()
        let drive = makeDrive()
        let replica = TargetReplicaState(assetID: asset.id, targetID: drive.id, state: .present, relativePath: nil, lastVerifiedAt: Date())

        var job = try MigrationService.createJob(assetIDs: [asset.id], from: .local, to: .appleCloud, note: nil)
        XCTAssertEqual(job.state, .pending)

        job = try MigrationService.start(job)
        XCTAssertEqual(job.state, .copyingToTarget)

        let copyEffect = try MigrationService.markTargetCopyComplete(job, assets: [asset])
        job = copyEffect.job
        XCTAssertEqual(job.state, .verifyingTarget)
        let overlapping = copyEffect.updatedAssets[0]
        XCTAssertTrue(overlapping.presence.appleCloud)
        XCTAssertTrue(overlapping.presence.local, "Overlap window: both domains present during migration")

        job = try MigrationService.markTargetVerified(job)
        XCTAssertEqual(job.state, .clearingSource)

        let cleanupEffect = try MigrationService.completeCleanup(
            job, assets: [overlapping], targets: [drive], replicaStates: [replica]
        )
        XCTAssertEqual(cleanupEffect.job.state, .completed)
        let final = cleanupEffect.updatedAssets[0]
        XCTAssertFalse(final.presence.local)
        XCTAssertTrue(final.presence.appleCloud)
        XCTAssertEqual(final.residency, .appleCloud)
        XCTAssertEqual(final.residencySource, .migration)
        XCTAssertEqual(cleanupEffect.replicationTasks.count, 1)
        XCTAssertEqual(cleanupEffect.replicationTasks[0].action, .remove)
    }

    func testMigrationRejectsSameDomain() {
        XCTAssertThrowsError(try MigrationService.createJob(assetIDs: [], from: .local, to: .local, note: nil))
    }

    func testMigrationRejectsInvalidTransition() throws {
        let job = try MigrationService.createJob(assetIDs: [], from: .local, to: .appleCloud, note: nil)
        XCTAssertThrowsError(try MigrationService.markTargetVerified(job))
    }

    // MARK: - ReplicationService (real files)

    func testCopyVerifyRemoveRoundTrip() throws {
        let stagingRoot = try makeTempDirectory()
        let mountRoot = try makeTempDirectory()
        let staging = StagingStore(rootURL: stagingRoot)
        let drive = makeDrive(name: "TestDrive")

        // Stage a real file and build the matching asset record.
        let sourceFile = try makeTempDirectory().appendingPathComponent("photo.jpg")
        try Data("hello archive".utf8).write(to: sourceFile)
        let assetID = UUID()
        let stagingPath = try staging.stage(fileAt: sourceFile, assetID: assetID, fileExtension: "jpg")
        let hash = try HashingService.sha256(of: staging.url(forRelativePath: stagingPath))
        let asset = makeAsset(id: assetID, filename: "photo.jpg", hash: hash, stagingPath: stagingPath)

        func task(_ action: ReplicationAction) -> ReplicationTask {
            ReplicationTask(
                id: UUID(), assetID: assetID, targetID: drive.id, action: action,
                state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
            )
        }

        // Copy
        let copyOutcome = ReplicationService.processBacklog(
            tasks: [task(.copy)], drive: drive, mountURL: mountRoot,
            assetsByID: [assetID: asset], staging: staging
        )
        XCTAssertEqual(copyOutcome.completedTasks.count, 1)
        XCTAssertEqual(copyOutcome.updatedReplicas[0].state, .present)
        let replicaURL = ReplicationService.replicaURL(for: asset, drive: drive, mountURL: mountRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replicaURL.path))
        XCTAssertEqual(try HashingService.sha256(of: replicaURL), hash)

        // Verify clean replica
        let verifyOutcome = ReplicationService.processBacklog(
            tasks: [task(.verify)], drive: drive, mountURL: mountRoot,
            assetsByID: [assetID: asset], staging: staging
        )
        XCTAssertEqual(verifyOutcome.updatedReplicas[0].state, .present)

        // Corrupt the replica → verify detects drift
        try Data("tampered".utf8).write(to: replicaURL)
        let driftOutcome = ReplicationService.processBacklog(
            tasks: [task(.verify)], drive: drive, mountURL: mountRoot,
            assetsByID: [assetID: asset], staging: staging
        )
        XCTAssertEqual(driftOutcome.updatedReplicas[0].state, .drift)

        // Remove
        let removeOutcome = ReplicationService.processBacklog(
            tasks: [task(.remove)], drive: drive, mountURL: mountRoot,
            assetsByID: [assetID: asset], staging: staging
        )
        XCTAssertEqual(removeOutcome.updatedReplicas[0].state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replicaURL.path))
    }

    func testRetryAfterInterruptedCopyDiscardsLeftoverPartial() throws {
        let stagingRoot = try makeTempDirectory()
        let mountRoot = try makeTempDirectory()
        let staging = StagingStore(rootURL: stagingRoot)
        let drive = makeDrive()

        let sourceFile = try makeTempDirectory().appendingPathComponent("photo.jpg")
        try Data("real content".utf8).write(to: sourceFile)
        let assetID = UUID()
        let stagingPath = try staging.stage(fileAt: sourceFile, assetID: assetID, fileExtension: "jpg")
        let hash = try HashingService.sha256(of: staging.url(forRelativePath: stagingPath))
        let asset = makeAsset(id: assetID, hash: hash, stagingPath: stagingPath)

        // Simulate a previous sync that died mid-copy: a garbage .partial file
        // (and a stale destination) already sit in the replica directory.
        let destination = ReplicationService.replicaURL(for: asset, drive: drive, mountURL: mountRoot)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("truncated garbage".utf8).write(to: destination.appendingPathExtension("partial"))
        try Data("stale old copy".utf8).write(to: destination)

        let task = ReplicationTask(
            id: UUID(), assetID: assetID, targetID: drive.id, action: .copy,
            state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
        )
        let result = ReplicationService.perform(
            task, drive: drive, mountURL: mountRoot, asset: asset,
            sourceURL: staging.url(forRelativePath: stagingPath)
        )

        XCTAssertEqual(result.task.state, .completed)
        XCTAssertEqual(result.replica?.state, .present)
        XCTAssertEqual(try HashingService.sha256(of: destination), hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }

    /// A file the user kept somewhere of their own is restored to exactly that
    /// path. Answering "your file is gone" by writing a differently-named copy
    /// into the app's own folder leaves the user with a hole where their file
    /// was and a UUID they cannot recognise somewhere else.
    func testARestoredCopyGoesBackWhereTheUsersFileWas() throws {
        let root = try makeTempDirectory()
        let mountRoot = root.appendingPathComponent("mount", isDirectory: true)
        let staging = StagingStore(rootURL: root.appendingPathComponent("staging", isDirectory: true))
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)

        let sourceFile = try makeTempDirectory().appendingPathComponent("photo.jpg")
        try Data("the user's own photo".utf8).write(to: sourceFile)
        let assetID = UUID()
        let stagingPath = try staging.stage(fileAt: sourceFile, assetID: assetID, fileExtension: "jpg")
        let hash = try HashingService.sha256(of: staging.url(forRelativePath: stagingPath))
        let asset = makeAsset(id: assetID, hash: hash, stagingPath: stagingPath)
        let drive = makeDrive()

        // It used to live in a folder of the user's own, and was deleted.
        let recorded = "volume:Owner/Takeout_Archive_2026/Takeout/Google Photos/IMG_1.jpg"
        let missing = TargetReplicaState(
            assetID: asset.id, targetID: drive.id, state: .missing,
            relativePath: recorded, lastVerifiedAt: Date()
        )
        let task = ReplicationTask(
            id: UUID(), assetID: asset.id, targetID: drive.id, action: .copy,
            state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
        )

        let result = ReplicationService.perform(
            task, drive: drive, mountURL: mountRoot, asset: asset,
            sourceURL: staging.url(forRelativePath: stagingPath), existingReplica: missing
        )

        XCTAssertEqual(result.task.state, .completed)
        XCTAssertEqual(result.replica?.relativePath, recorded, "The recorded location is kept")
        let restored = mountRoot.appendingPathComponent("Owner/Takeout_Archive_2026/Takeout/Google Photos/IMG_1.jpg")
        XCTAssertEqual(try HashingService.sha256(of: restored), hash)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ReplicationService.replicaURL(for: asset, drive: drive, mountURL: mountRoot).path
            ),
            "Nothing was left in the app's replica root"
        )
    }

    /// Content that never had a place of its own on the drive still goes to the
    /// managed root — there is nowhere else it could go.
    func testContentWithNoPlaceOfItsOwnStillGoesToTheReplicaRoot() throws {
        let root = try makeTempDirectory()
        let mountRoot = root.appendingPathComponent("mount", isDirectory: true)
        let staging = StagingStore(rootURL: root.appendingPathComponent("staging", isDirectory: true))
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)

        let sourceFile = try makeTempDirectory().appendingPathComponent("photo.jpg")
        try Data("imported from the Mac".utf8).write(to: sourceFile)
        let assetID = UUID()
        let stagingPath = try staging.stage(fileAt: sourceFile, assetID: assetID, fileExtension: "jpg")
        let hash = try HashingService.sha256(of: staging.url(forRelativePath: stagingPath))
        let asset = makeAsset(id: assetID, hash: hash, stagingPath: stagingPath)
        let drive = makeDrive()
        let task = ReplicationTask(
            id: UUID(), assetID: asset.id, targetID: drive.id, action: .copy,
            state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
        )

        let result = ReplicationService.perform(
            task, drive: drive, mountURL: mountRoot, asset: asset,
            sourceURL: staging.url(forRelativePath: stagingPath), existingReplica: nil
        )

        XCTAssertEqual(result.replica?.relativePath, ReplicationService.replicaRelativePath(for: asset))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ReplicationService.replicaURL(for: asset, drive: drive, mountURL: mountRoot).path
        ))
    }

    func testCopyFailsWithoutStagedSource() {
        let staging = StagingStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let drive = makeDrive()
        let asset = makeAsset(stagingPath: nil)
        let task = ReplicationTask(
            id: UUID(), assetID: asset.id, targetID: drive.id, action: .copy,
            state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
        )
        let outcome = ReplicationService.processBacklog(
            tasks: [task], drive: drive, mountURL: FileManager.default.temporaryDirectory,
            assetsByID: [asset.id: asset], staging: staging
        )
        XCTAssertEqual(outcome.failedTasks.count, 1)
        XCTAssertEqual(outcome.completedTasks.count, 0)
    }
}

/// "12 file(s)" was in twenty-odd strings and the audit log. It reads as a
/// template somebody forgot to finish, and it is wrong in the only case a
/// person notices.
final class PluralisationTests: XCTestCase {

    func testSingularAndPluralAreBothRight() {
        XCTAssertEqual(Formatters.count(1, "file"), "1 file")
        XCTAssertEqual(Formatters.count(2, "file"), "2 files")
        XCTAssertEqual(Formatters.count(0, "file"), "0 files")
    }

    func testAnIrregularPluralCanBeGiven() {
        XCTAssertEqual(Formatters.count(1, "copy", "copies"), "1 copy")
        XCTAssertEqual(Formatters.count(3, "copy", "copies"), "3 copies")
    }

    func testLargeNumbersAreGrouped() {
        XCTAssertEqual(Formatters.count(21397, "photo"), "21,397 photos")
    }
}

/// Worst first. A damaged copy is a photo at risk; a drive holding something
/// it need not is housekeeping, and catalog order made those read as equally
/// urgent.
final class ViolationOrderingTests: XCTestCase {

    func testDamageOutranksHousekeeping() {
        XCTAssertGreaterThan(ViolationKind.replicaDrift.severity, ViolationKind.orphanReplica.severity)
        XCTAssertGreaterThan(
            ViolationKind.multiDomainCoexistence.severity,
            ViolationKind.migrationCleanupPending.severity
        )
    }

    /// Every kind says what happened rather than which invariant caught it,
    /// and carries an explanation the reader meets once per group instead of
    /// inferring from twenty-five near-identical rows.
    func testEveryKindReadsAsSomethingThatHappened() {
        for kind in ViolationKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertFalse(
                kind.displayName.contains("coexistence") || kind.displayName.contains("mismatch"),
                "\(kind) still names the invariant: \(kind.displayName)"
            )
            XCTAssertGreaterThan(kind.explanation.count, 40, "\(kind) needs an explanation worth reading")
        }
    }
}
