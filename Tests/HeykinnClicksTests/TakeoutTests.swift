import XCTest
@testable import HeykinnClicks

final class TakeoutTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-takeout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // realpath /var → /private/var so paths compare equal with what the
        // scanner's directory enumerator reports (URL.resolvingSymlinksInPath
        // deliberately leaves /var alone).
        var url = raw
        if let resolved = realpath(raw.path, nil) {
            url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Builds `root/Takeout/Google Photos/Photos from 2021/` with one media
    /// file + sidecar pair and one sidecar-less media file.
    private func makeFakeTakeoutTree(in root: URL) throws -> URL {
        let photosDir = root
            .appendingPathComponent("Takeout/Google Photos/Photos from 2021", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)

        try Data("fake image bytes one".utf8).write(to: photosDir.appendingPathComponent("IMG_100.jpg"))
        let sidecar = """
        {
          "title": "IMG_100.jpg",
          "description": "Trip to the lake",
          "photoTakenTime": { "timestamp": "1600000000", "formatted": "Sep 13, 2020" },
          "geoData": { "latitude": 12.34567, "longitude": 76.54321, "altitude": 0.0 }
        }
        """
        try Data(sidecar.utf8).write(to: photosDir.appendingPathComponent("IMG_100.jpg.json"))
        try Data("fake image bytes two".utf8).write(to: photosDir.appendingPathComponent("IMG_101.jpg"))
        return root.appendingPathComponent("Takeout", isDirectory: true)
    }

    private func zipDirectory(_ directory: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", directory.path, zipURL.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ditto zip creation failed")
    }

    // MARK: - Scanner

    func testScannerDetectsExtractedFolderAndStandardZip() throws {
        let root = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: root)
        let zipURL = root.appendingPathComponent("takeout-20260101T000000Z-001.zip")
        try zipDirectory(takeoutFolder, to: zipURL)

        let discovered = TakeoutScanner.scan(rootURL: root)
        XCTAssertTrue(discovered.contains { $0.path == takeoutFolder.path && $0.kind == .folder })
        XCTAssertTrue(discovered.contains { $0.path == zipURL.path && $0.kind == .zip })
    }

    func testScannerDetectsRenamedTakeoutZipByListing() throws {
        let root = try makeTempDirectory()
        let treeRoot = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: treeRoot)
        let renamedZip = root.appendingPathComponent("my-google-backup.zip")
        try zipDirectory(takeoutFolder, to: renamedZip)

        let discovered = TakeoutScanner.scan(rootURL: root)
        XCTAssertTrue(
            discovered.contains { $0.path == renamedZip.path && $0.kind == .zip },
            "A zip rooted at Takeout/ should be detected regardless of filename"
        )
    }

    func testScannerIgnoresUnrelatedZip() throws {
        let root = try makeTempDirectory()
        let unrelated = try makeTempDirectory()
        let somethingElse = unrelated.appendingPathComponent("NotTakeout", isDirectory: true)
        try FileManager.default.createDirectory(at: somethingElse, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: somethingElse.appendingPathComponent("file.txt"))
        let zipURL = root.appendingPathComponent("documents.zip")
        try zipDirectory(somethingElse, to: zipURL)

        let discovered = TakeoutScanner.scan(rootURL: root)
        XCTAssertTrue(discovered.isEmpty)
    }

    // MARK: - Split-download export sets

    func testParseExportComponentsFromSplitZipNames() {
        let parsed = TakeoutArchive.parseExportComponents(filename: "takeout-20260101T000000Z-002.zip")
        XCTAssertEqual(parsed?.setID, "20260101T000000Z")
        XCTAssertEqual(parsed?.part, 2)
        XCTAssertNil(TakeoutArchive.parseExportComponents(filename: "my-google-backup.zip"))
        XCTAssertNil(TakeoutArchive.parseExportComponents(filename: "takeout-notaset.zip"))

        // Re-run sessions carry a dash suffix; the part is after the LAST dash.
        let rerun = TakeoutArchive.parseExportComponents(filename: "takeout-20260710T081521Z-2-011.zip")
        XCTAssertEqual(rerun?.setID, "20260710T081521Z-2")
        XCTAssertEqual(rerun?.part, 11)

        // A folder named zip-name-minus-.zip belongs to the same set.
        let folder = TakeoutArchive.parseExportComponents(filename: "takeout-20260710T081521Z-2-011")
        XCTAssertEqual(folder?.setID, "20260710T081521Z-2")
        XCTAssertEqual(folder?.part, 11)
    }

    func testExportSetPrefersExtractedFolderOverZipTwin() {
        func archive(_ part: Int, _ kind: TakeoutArchiveKind, imported: Bool = false) -> TakeoutArchive {
            TakeoutArchive(
                id: UUID(),
                path: "/x/takeout-S-\(String(format: "%03d", part))\(kind == .zip ? ".zip" : "")",
                kind: kind, sizeBytes: 0, targetID: nil, discoveredAt: Date(),
                importedAt: imported ? Date() : nil, importBatchID: nil,
                importedAssetCount: 0, skippedDuplicateCount: 0, note: nil,
                exportSetID: "S", partNumber: part
            )
        }
        // Part 1: zip + folder twins; part 2: zip only; part 3: folder already imported, zip twin present.
        let set = TakeoutExportSet(setID: "S", parts: [
            archive(1, .zip), archive(1, .folder),
            archive(2, .zip),
            archive(3, .folder, imported: true), archive(3, .zip),
        ])
        XCTAssertEqual(set.uniquePartCount, 3)
        XCTAssertEqual(set.importedPartCount, 1, "An imported representative marks the whole part imported")

        let toImport = set.unimportedPreferredParts
        XCTAssertEqual(toImport.count, 2)
        XCTAssertEqual(toImport[0].partNumber, 1)
        XCTAssertEqual(toImport[0].kind, .folder, "Extracted folder must be preferred over its zip twin")
        XCTAssertEqual(toImport[1].partNumber, 2)
        XCTAssertEqual(toImport[1].kind, .zip)
    }

    func testScanMatchesMixedZipAndExtractedFolderLayout() throws {
        // Mirror of a real drive layout: every part as a zip, some parts also
        // extracted to folders named zip-name-minus-.zip.
        let root = try makeTempDirectory()
        let treeRoot = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: treeRoot)
        for part in 1...3 {
            try zipDirectory(takeoutFolder, to: root.appendingPathComponent("takeout-20260710T081521Z-2-00\(part).zip"))
        }
        for part in 1...2 {
            let extracted = root.appendingPathComponent("takeout-20260710T081521Z-2-00\(part)", isDirectory: true)
                .appendingPathComponent("Takeout/Google Photos/Photos from 2021", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try Data("img \(part)".utf8).write(to: extracted.appendingPathComponent("IMG.jpg"))
        }

        let discovered = TakeoutScanner.scan(rootURL: root)
        let inSet = discovered.filter { $0.exportSetID == "20260710T081521Z-2" }
        XCTAssertEqual(inSet.filter { $0.kind == .zip }.count, 3)
        XCTAssertEqual(inSet.filter { $0.kind == .folder }.count, 2, "Extracted part folders must join the set")
        XCTAssertEqual(Set(inSet.filter { $0.kind == .folder }.compactMap(\.partNumber)), Set([1, 2]))
    }

    func testScannerAssignsSetAndPartToSplitZips() throws {
        let root = try makeTempDirectory()
        let treeRoot = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: treeRoot)
        try zipDirectory(takeoutFolder, to: root.appendingPathComponent("takeout-20260101T000000Z-001.zip"))
        try zipDirectory(takeoutFolder, to: root.appendingPathComponent("takeout-20260101T000000Z-002.zip"))

        let discovered = TakeoutScanner.scan(rootURL: root)
        let parts = discovered.filter { $0.exportSetID == "20260101T000000Z" }
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(Set(parts.compactMap(\.partNumber)), Set([1, 2]))
    }

    func testScannerDetectsCollisionNamedExtractedFolders() throws {
        let root = try makeTempDirectory()
        // Extracting multiple parts one by one produces "Takeout", "Takeout 2", …
        for name in ["Takeout", "Takeout 2", "Takeout (1)"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("Google Photos/Photos from 2021", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("img \(name)".utf8).write(to: dir.appendingPathComponent("IMG.jpg"))
        }
        let discovered = TakeoutScanner.scan(rootURL: root)
        XCTAssertEqual(discovered.filter { $0.kind == .folder }.count, 3)
        XCTAssertFalse(TakeoutScanner.nameLooksLikeTakeout("takeouts"))
    }

    /// A folder somebody made to keep their exports *in* is not an export. It
    /// used to be treated as one because its name began with "takeout" — which
    /// registered the container of a whole 254 GB archive as a single archive
    /// of its own, double-counting everything inside it.
    func testAFolderNamedAfterTakeoutIsNotItselfATakeout() {
        for collisionName in ["Takeout", "Takeout 2", "Takeout (1)", "takeout-3", "Takeout2", "TAKEOUT_4"] {
            XCTAssertTrue(
                TakeoutScanner.nameLooksLikeTakeout(collisionName),
                "\(collisionName) is what macOS names an unpacked export"
            )
        }
        // A folder named after the zip it came out of is the other legitimate
        // shape, and must keep being recognised.
        XCTAssertTrue(
            TakeoutScanner.isUnpackedTakeoutFolderName("takeout-20260710T081521Z-2-001")
        )
        for userName in [
            "Takeout_Archive_2026", "Takeout backups", "takeouts",
            "TakeoutBackups", "Takeout old stuff", "Takeout-2026-originals",
        ] {
            XCTAssertFalse(
                TakeoutScanner.isUnpackedTakeoutFolderName(userName),
                "\(userName) is a name a person chose, not one macOS or a zip produced"
            )
        }
    }

    /// The whole shape of the bug: an export unpacked inside a folder the user
    /// named. The parts are found; the folder holding them is not an export.
    func testAContainerFolderIsNotScannedAsAnExport() throws {
        let root = try makeTempDirectory()
        let container = root.appendingPathComponent("Takeout_Archive_2026", isDirectory: true)
        for part in 1...2 {
            let dir = container
                .appendingPathComponent("takeout-S1-\(String(format: "%03d", part))", isDirectory: true)
                .appendingPathComponent("Takeout/Google Photos", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("img".utf8).write(to: dir.appendingPathComponent("IMG.jpg"))
        }

        let discovered = TakeoutScanner.scan(rootURL: root)

        XCTAssertFalse(
            discovered.contains { ($0.path as NSString).lastPathComponent == "Takeout_Archive_2026" },
            "The folder holding the export is not the export"
        )
        XCTAssertEqual(discovered.count, 2, "Both parts inside it are still found")
    }

    func testScannerDetectsRenamedRootByGooglePhotosChild() throws {
        let root = try makeTempDirectory()
        let renamed = root.appendingPathComponent("MyGoogleBackup", isDirectory: true)
        let photos = renamed.appendingPathComponent("Google Photos/Photos from 2020", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("img".utf8).write(to: photos.appendingPathComponent("IMG.jpg"))

        let discovered = TakeoutScanner.scan(rootURL: root)
        XCTAssertTrue(
            discovered.contains { $0.path == renamed.path && $0.kind == .folder },
            "A renamed folder holding a Google Photos tree should be detected as a Takeout root"
        )
    }

    func testExportSetGapDetection() async {
        func part(_ number: Int) -> TakeoutArchive {
            TakeoutArchive(
                id: UUID(), path: "/x/takeout-\(number).zip", kind: .zip, sizeBytes: 0,
                targetID: nil, discoveredAt: Date(), importedAt: nil, importBatchID: nil,
                importedAssetCount: 0, skippedDuplicateCount: 0, note: nil,
                exportSetID: "S", partNumber: number
            )
        }
        XCTAssertEqual(TakeoutExportSet(setID: "S", parts: [part(1), part(3), part(4)]).missingPartNumbers, [2])
        XCTAssertEqual(TakeoutExportSet(setID: "S", parts: [part(1), part(2)]).missingPartNumbers, [])
    }

    func testCrossPartDeduplicationWithSharedBatch() async throws {
        // Two parts share one file (Google can duplicate media across parts).
        let partA = try makeTempDirectory()
        let dirA = partA.appendingPathComponent("Takeout/Google Photos/Photos from 2021", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try Data("unique to part one".utf8).write(to: dirA.appendingPathComponent("IMG_1.jpg"))
        try Data("shared across parts".utf8).write(to: dirA.appendingPathComponent("IMG_2.jpg"))

        let partB = try makeTempDirectory()
        let dirB = partB.appendingPathComponent("Takeout/Google Photos/Photos from 2021", isDirectory: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data("shared across parts".utf8).write(to: dirB.appendingPathComponent("IMG_2.jpg"))
        try Data("unique to part two".utf8).write(to: dirB.appendingPathComponent("IMG_3.jpg"))

        let staging = StagingStore(rootURL: try makeTempDirectory())
        let batchID = UUID()

        let first = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: partA, cleanupURL: nil),
            archiveName: "part 1", existingAssets: [], staging: staging, batchID: batchID
        )
        let second = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: partB, cleanupURL: nil),
            archiveName: "part 2", existingAssets: first.importedAssets, staging: staging, batchID: batchID
        )

        XCTAssertEqual(first.importedAssets.count, 2)
        XCTAssertEqual(second.importedAssets.count, 1, "The shared file must dedupe across parts")
        XCTAssertEqual(second.duplicateFilenames, ["IMG_2.jpg"])
        for asset in first.importedAssets + second.importedAssets {
            XCTAssertEqual(asset.importBatchID, batchID, "All parts must share one import batch")
        }
    }

    // MARK: - Archive-backed replicas

    func testImportRecordsTakeoutFilesAsDriveReplica() async throws {
        let mount = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: mount)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let targetID = UUID()

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging,
            placement: TargetPlacement(targetID: targetID, mountPath: mount.path)
        )

        XCTAssertEqual(result.importedAssets.count, 2)
        XCTAssertEqual(result.archiveBackedReplicas.count, 2, "Every imported file on the drive backs a replica")
        for asset in result.importedAssets {
            let replica = try XCTUnwrap(result.archiveBackedReplicas[asset.id])
            XCTAssertEqual(replica.targetID, targetID)
            XCTAssertEqual(replica.state, .present)
            XCTAssertNotNil(replica.lastVerifiedAt, "Import hashed the file, so it is verified")
            let relative = try XCTUnwrap(replica.relativePath)
            XCTAssertTrue(relative.hasPrefix(ReplicationService.volumeBackedPrefix))
            // The recorded path must resolve back to the actual Takeout file.
            let resolved = mount.appendingPathComponent(String(relative.dropFirst(ReplicationService.volumeBackedPrefix.count)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
            XCTAssertEqual(try HashingService.sha256(of: resolved), asset.contentHash)
        }
    }

    func testVerifyResolvesVolumeBackedReplicaAndDetectsDrift() async throws {
        let mount = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: mount)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let targetID = UUID()
        let drive = ReplicationTarget(
            id: targetID, name: "A", volumeUUID: nil, markerToken: "t",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging,
            placement: TargetPlacement(targetID: targetID, mountPath: mount.path)
        )
        let asset = result.importedAssets[0]
        let replica = try XCTUnwrap(result.archiveBackedReplicas[asset.id])

        func verifyTask() -> ReplicationTask {
            ReplicationTask(
                id: UUID(), assetID: asset.id, targetID: targetID, action: .verify,
                state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
            )
        }

        // Clean verify: resolves the Takeout file, not the managed replica root.
        let clean = ReplicationService.perform(
            verifyTask(), drive: drive, mountURL: mount, asset: asset,
            sourceURL: nil, existingReplica: replica
        )
        XCTAssertEqual(clean.replica?.state, .present)
        XCTAssertEqual(clean.replica?.relativePath, replica.relativePath, "Volume-backed path must survive verification")

        // Corrupt the Takeout file → drift.
        let file = ReplicationService.resolveReplicaURL(asset: asset, drive: drive, mountURL: mount, existingReplica: replica)
        try Data("tampered".utf8).write(to: file)
        let drifted = ReplicationService.perform(
            verifyTask(), drive: drive, mountURL: mount, asset: asset,
            sourceURL: nil, existingReplica: replica
        )
        XCTAssertEqual(drifted.replica?.state, .drift)
    }

    func testRemoveNeverDeletesVolumeBackedTakeoutFile() async throws {
        let mount = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: mount)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let targetID = UUID()
        let drive = ReplicationTarget(
            id: targetID, name: "A", volumeUUID: nil, markerToken: "t",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging,
            placement: TargetPlacement(targetID: targetID, mountPath: mount.path)
        )
        let asset = result.importedAssets[0]
        let replica = try XCTUnwrap(result.archiveBackedReplicas[asset.id])
        let file = ReplicationService.resolveReplicaURL(asset: asset, drive: drive, mountURL: mount, existingReplica: replica)

        let task = ReplicationTask(
            id: UUID(), assetID: asset.id, targetID: targetID, action: .remove,
            state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
        )
        let outcome = ReplicationService.perform(
            task, drive: drive, mountURL: mount, asset: asset,
            sourceURL: nil, existingReplica: replica
        )
        XCTAssertEqual(outcome.task.state, .completed)
        XCTAssertEqual(outcome.replica?.state, .missing, "Catalog claim released")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "The user's Takeout file must never be deleted by a remove task"
        )
    }

    // MARK: - Second-drive reconciliation (same zips, no extra copy)

    func testZipEntryHashMatchesDirectFileHash() throws {
        let root = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: root)
        let zipURL = root.appendingPathComponent("takeout-x.zip")
        try zipDirectory(takeoutFolder, to: zipURL)

        let directHash = try HashingService.sha256(
            of: takeoutFolder.appendingPathComponent("Google Photos/Photos from 2021/IMG_100.jpg")
        )
        let entryHash = try HashingService.sha256OfZipEntry(
            zipURL: zipURL,
            entry: "Takeout/Google Photos/Photos from 2021/IMG_100.jpg"
        )
        XCTAssertEqual(entryHash, directHash)
    }

    func testSecondDriveZipsBecomeReplicasWithoutCopying() async throws {
        // Drive A: extracted folder, imported normally (assets exist).
        let driveAMount = try makeTempDirectory()
        let folderA = try makeFakeTakeoutTree(in: driveAMount)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let importResult = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: folderA, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging
        )
        XCTAssertEqual(importResult.importedAssets.count, 2)

        // Drive B: the SAME content, but as an unextracted zip.
        let driveBMount = try makeTempDirectory()
        let zipURL = driveBMount.appendingPathComponent("takeout-20260101T000000Z-001.zip")
        try zipDirectory(folderA, to: zipURL)
        let driveBID = UUID()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: driveBMount.path)

        let assetIDsByHash = Dictionary(uniqueKeysWithValues: importResult.importedAssets.map { ($0.contentHash, $0.id) })
        let result = TakeoutReconciler.reconcileZip(
            zipURL: zipURL,
            mountURL: driveBMount,
            targetID: driveBID,
            assetIDsByHash: assetIDsByHash,
            assetsNeedingReplica: Set(importResult.importedAssets.map(\.id))
        )

        XCTAssertEqual(result.claimedReplicas.count, 2, "Both assets claim the zip as their drive-B replica")
        for replica in result.claimedReplicas {
            XCTAssertEqual(replica.state, .present)
            XCTAssertTrue(replica.relativePath?.hasPrefix(ReplicationService.zipMemberPrefix) ?? false)
        }
        // Zero additional bytes on drive B: nothing was written.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: driveBMount.path), filesBefore,
            "Reconciliation must be read-only on the drive"
        )

        // The claimed replica must pass a real verification round-trip.
        let driveB = ReplicationTarget(
            id: driveBID, name: "B", volumeUUID: nil, markerToken: "t",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
        let asset = importResult.importedAssets[0]
        let replica = try XCTUnwrap(result.claimedReplicas.first { $0.assetID == asset.id })
        let verify = ReplicationService.perform(
            ReplicationTask(
                id: UUID(), assetID: asset.id, targetID: driveBID, action: .verify,
                state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
            ),
            drive: driveB, mountURL: driveBMount, asset: asset,
            sourceURL: nil, existingReplica: replica
        )
        XCTAssertEqual(verify.replica?.state, .present)
    }

    func testReconcileFolderClaimsOnlyMatchingAssets() async throws {
        let mount = try makeTempDirectory()
        let folder = try makeFakeTakeoutTree(in: mount)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let imported = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: folder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging
        ).importedAssets

        let targetID = UUID()
        let assetIDsByHash = Dictionary(uniqueKeysWithValues: imported.map { ($0.contentHash, $0.id) })
        // Only one of the two assets still needs a replica on this drive.
        let needing: Set<UUID> = [imported[0].id]
        let result = TakeoutReconciler.reconcileFolder(
            folderURL: folder, mountURL: mount, targetID: targetID,
            assetIDsByHash: assetIDsByHash, assetsNeedingReplica: needing
        )
        XCTAssertEqual(result.claimedReplicas.count, 1)
        XCTAssertEqual(result.claimedReplicas[0].assetID, imported[0].id)
        XCTAssertEqual(result.scannedFileCount, 2)
    }

    // MARK: - Regression fixes (no duplicate staging, cheap re-scan)

    func testDriveResidentImportDoesNotDuplicateIntoMacStaging() async throws {
        let mount = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: mount)
        let stagingRoot = try makeTempDirectory()
        let staging = StagingStore(rootURL: stagingRoot)
        let targetID = UUID()

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging,
            placement: TargetPlacement(targetID: targetID, mountPath: mount.path)
        )

        XCTAssertEqual(result.importedAssets.count, 2)
        XCTAssertEqual(result.archiveBackedReplicas.count, 2)
        for asset in result.importedAssets {
            XCTAssertNil(asset.stagingRelativePath, "Drive-resident media must not be copied to Mac staging")
        }
        XCTAssertEqual(staging.totalBytes, 0, "Staging must stay empty when the drive already holds the bytes")
    }

    func testImportWithoutDriveContextStillStages() async throws {
        // Content with no drive-resident copy (e.g. a zip extracted to a Mac
        // workspace) must still be staged — it is the only local copy.
        let workspaceRoot = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: workspaceRoot)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: workspaceRoot),
            archiveName: "Takeout", existingAssets: [], staging: staging,
            placement: TargetPlacement()
        )
        for asset in result.importedAssets {
            XCTAssertNotNil(asset.stagingRelativePath)
        }
        XCTAssertGreaterThan(staging.totalBytes, 0)
    }

    func testCopyUsesAnyReachableSourceNotOnlyStaging() async throws {
        // An asset that exists only on drive A (archive-backed, never staged)
        // must still be copyable to drive B.
        let driveAMount = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: driveAMount)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let driveAID = UUID()
        let imported = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging,
            placement: TargetPlacement(targetID: driveAID, mountPath: driveAMount.path)
        )
        let asset = imported.importedAssets[0]
        XCTAssertNil(asset.stagingRelativePath)

        let replicaOnA = try XCTUnwrap(imported.archiveBackedReplicas[asset.id])
        let sourceOnA = driveAMount.appendingPathComponent(
            String(try XCTUnwrap(replicaOnA.relativePath).dropFirst(ReplicationService.volumeBackedPrefix.count))
        )

        let driveBMount = try makeTempDirectory()
        let driveB = ReplicationTarget(
            id: UUID(), name: "B", volumeUUID: nil, markerToken: "t",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
        let result = ReplicationService.perform(
            ReplicationTask(
                id: UUID(), assetID: asset.id, targetID: driveB.id, action: .copy,
                state: .queued, queuedAt: Date(), completedAt: nil, errorMessage: nil
            ),
            drive: driveB, mountURL: driveBMount, asset: asset, sourceURL: sourceOnA
        )

        XCTAssertEqual(result.task.state, .completed)
        XCTAssertEqual(result.replica?.state, .present)
        let copied = ReplicationService.replicaURL(for: asset, drive: driveB, mountURL: driveBMount)
        XCTAssertEqual(try HashingService.sha256(of: copied), asset.contentHash)
    }

    func testRescanReusesKnownFolderSizesInsteadOfRewalking() throws {
        let root = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: root)

        let first = TakeoutScanner.scan(rootURL: root)
        let folder = try XCTUnwrap(first.first { $0.kind == .folder })
        XCTAssertGreaterThan(folder.sizeBytes, 0)

        // A cached size is used verbatim, proving the tree is not re-walked.
        let sentinel: Int64 = 999_999
        let second = TakeoutScanner.scan(rootURL: root, knownFolderSizes: [takeoutFolder.path: sentinel])
        XCTAssertEqual(second.first { $0.kind == .folder }?.sizeBytes, sentinel)
    }

    func testChunkedImportMatchesWholePartImportAndDedupesAcrossChunks() async throws {
        let root = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: root)
        let workspace = TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil)

        let files = TakeoutImporter.mediaFileURLs(in: workspace)
        XCTAssertEqual(files.count, 2, "Both media files are visible before importing")

        // Import one file per chunk, feeding results forward as the app does.
        let chunkedStaging = StagingStore(rootURL: try makeTempDirectory())
        var accumulated: [Asset] = []
        for file in files {
            let result = await TakeoutImporter.importMedia(
                from: workspace, archiveName: "Takeout", existingAssets: accumulated,
                staging: chunkedStaging, fileURLs: [file]
            )
            accumulated.append(contentsOf: result.importedAssets)
        }

        let wholeStaging = StagingStore(rootURL: try makeTempDirectory())
        let whole = await TakeoutImporter.importMedia(
            from: workspace, archiveName: "Takeout", existingAssets: [],
            staging: wholeStaging
        )

        XCTAssertEqual(accumulated.count, whole.importedAssets.count)
        XCTAssertEqual(
            Set(accumulated.map(\.contentHash)),
            Set(whole.importedAssets.map(\.contentHash)),
            "Chunked import must produce the same assets as a single-shot import"
        )

        // A repeated chunk must dedupe against what earlier chunks imported.
        let repeated = await TakeoutImporter.importMedia(
            from: workspace, archiveName: "Takeout", existingAssets: accumulated,
            staging: chunkedStaging, fileURLs: [files[0]]
        )
        XCTAssertEqual(repeated.importedAssets.count, 0)
        XCTAssertEqual(repeated.duplicateFilenames.count, 1)
    }

    func testReconcileClaimsNothingWhenDriveAlreadyHasReplicas() async throws {
        // The drive the content was imported from already backs its replicas;
        // reconciling its zip twin must be recognised as pointless (no assets
        // need a replica), which is what lets the pipeline skip the read.
        let mount = try makeTempDirectory()
        let folder = try makeFakeTakeoutTree(in: mount)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let targetID = UUID()

        let imported = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: folder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging,
            placement: TargetPlacement(targetID: targetID, mountPath: mount.path)
        )
        let assetIDsByHash = Dictionary(uniqueKeysWithValues: imported.importedAssets.map { ($0.contentHash, $0.id) })

        // Every asset already has a present replica here, so nothing "needs" one.
        let result = TakeoutReconciler.reconcileFolder(
            folderURL: folder, mountURL: mount, targetID: targetID,
            assetIDsByHash: assetIDsByHash, assetsNeedingReplica: []
        )
        XCTAssertTrue(result.claimedReplicas.isEmpty)
    }

    // MARK: - Progress reporting and parallel scanning

    func testProgressBlendsStepAndWithinStepProgress() {
        // Part 3 of 12, halfway through its files: the bar must sit between
        // the 2/12 and 3/12 marks rather than freezing at 2/12.
        var activity = TakeoutActivity(
            phase: .importing, detail: "part", stepIndex: 3, stepCount: 12,
            itemIndex: 50, itemCount: 100
        )
        XCTAssertEqual(activity.stepFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(activity.fractionComplete ?? 0, (2.0 + 0.5) / 12.0, accuracy: 0.0001)

        // Start of a step: exactly the completed-steps fraction.
        activity.itemIndex = 0
        XCTAssertEqual(activity.fractionComplete ?? 0, 2.0 / 12.0, accuracy: 0.0001)

        // End of the final step: complete, never above 1.
        activity.stepIndex = 12
        activity.itemIndex = 100
        XCTAssertEqual(activity.fractionComplete ?? 0, 1.0, accuracy: 0.0001)

        // Overshooting item counts must still clamp.
        activity.itemIndex = 500
        XCTAssertLessThanOrEqual(activity.fractionComplete ?? 0, 1.0)

        // Without item counts it degrades to step-level progress.
        let coarse = TakeoutActivity(phase: .extracting, detail: "x", stepIndex: 2, stepCount: 4)
        XCTAssertEqual(coarse.fractionComplete ?? 0, 0.25, accuracy: 0.0001)
    }

    func testParallelScanPreservesOrderAndMatchesSerialResults() throws {
        let root = try makeTempDirectory()
        let dir = root.appendingPathComponent("Takeout/Google Photos/Photos from 2021", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for index in 0..<40 {
            let file = dir.appendingPathComponent(String(format: "IMG_%03d.jpg", index))
            try Data("content number \(index)".utf8).write(to: file)
            urls.append(file)
        }

        let parallel = TakeoutImporter.scanFilesInParallel(urls, concurrency: 8)
        let serial = TakeoutImporter.scanFilesInParallel(urls, concurrency: 1)

        XCTAssertEqual(parallel.count, urls.count)
        XCTAssertEqual(parallel.map(\.fileURL), urls, "Input order must be preserved")

        func hashes(_ scans: [TakeoutImporter.FileScan]) -> [String] {
            scans.map { scan in
                if case .success(let hash, _, _, _, _) = scan.outcome { return hash }
                return "FAILED"
            }
        }
        XCTAssertEqual(hashes(parallel), hashes(serial), "Parallel scan must match serial results")
        XCTAssertFalse(hashes(parallel).contains("FAILED"))
        // Hashes must match direct computation.
        for (index, url) in urls.enumerated() {
            XCTAssertEqual(hashes(parallel)[index], try HashingService.sha256(of: url))
        }
    }

    func testParallelScanReportsPerFileFailuresWithoutLosingOthers() throws {
        let root = try makeTempDirectory()
        let good = root.appendingPathComponent("good.jpg")
        try Data("fine".utf8).write(to: good)
        let missing = root.appendingPathComponent("gone.jpg")

        let scans = TakeoutImporter.scanFilesInParallel([good, missing, good], concurrency: 4)
        XCTAssertEqual(scans.count, 3)
        if case .failure = scans[1].outcome {} else {
            XCTFail("A missing file must surface as a per-file failure")
        }
        if case .success = scans[0].outcome {} else {
            XCTFail("A readable file must still succeed alongside a failure")
        }
    }

    func testParallelImportProducesSameAssetsAsSerial() async throws {
        let root = try makeTempDirectory()
        let folder = try makeFakeTakeoutTree(in: root)
        let workspace = TakeoutImporter.Workspace(mediaRoot: folder, cleanupURL: nil)

        let a = await TakeoutImporter.importMedia(
            from: workspace, archiveName: "T", existingAssets: [],
            staging: StagingStore(rootURL: try makeTempDirectory())
        )
        let b = await TakeoutImporter.importMedia(
            from: workspace, archiveName: "T", existingAssets: [],
            staging: StagingStore(rootURL: try makeTempDirectory())
        )
        XCTAssertEqual(
            a.importedAssets.map(\.originalFilename), b.importedAssets.map(\.originalFilename),
            "Parallel scanning must not make import order nondeterministic"
        )
        XCTAssertEqual(a.importedAssets.count, 2)
        // Sidecar metadata must survive the parallel path.
        let withSidecar = try XCTUnwrap(a.importedAssets.first { $0.originalFilename == "IMG_100.jpg" })
        XCTAssertEqual(withSidecar.captureDate, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(withSidecar.exifSummary["GPS"], "12.34567, 76.54321")
    }

    // MARK: - Cloud presence is never assumed

    func testImportRecordsNoCloudPresenceOrEvidenceByDefault() async throws {
        let root = try makeTempDirectory()
        let folder = try makeFakeTakeoutTree(in: root)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: folder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging
        )
        for asset in result.importedAssets {
            XCTAssertFalse(asset.presence.googleCloud)
            XCTAssertEqual(asset.presence.domains, [.local])
            XCTAssertEqual(asset.cloudPresenceEvidence, .none)
            XCTAssertNil(asset.cloudPresenceCheckedAt)
        }
    }

    /// Importing a Google export is the one moment it is most tempting to
    /// record Google presence, and the one moment there is least evidence for
    /// it: the export says where the content was when it was made.
    func testImportingAGoogleExportNeverClaimsGooglePresence() async throws {
        let root = try makeTempDirectory()
        let folder = try makeFakeTakeoutTree(in: root)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: folder, cleanupURL: nil),
            archiveName: "Takeout", existingAssets: [], staging: staging
        )
        XCTAssertFalse(result.importedAssets.isEmpty)
        for asset in result.importedAssets {
            XCTAssertFalse(
                asset.presence.googleCloud,
                "An export proves the content was in Google at export time, never that it is there now"
            )
            XCTAssertTrue(asset.presence.local, "Local presence is what hashing actually proves")
            XCTAssertEqual(asset.cloudPresenceEvidence, .none)
            XCTAssertFalse(asset.cloudPresenceEvidence.isTrustworthy)
        }
    }

    func testNoCloudVerifierIsConnectedSoNothingCanBeMarkedVerified() async {
        let registry = CloudVerifierRegistry.unconnected
        XCTAssertFalse(registry.isConnected(.googleCloud))
        XCTAssertFalse(registry.isConnected(.appleCloud))
        for domain in [ResidencyDomain.googleCloud, .appleCloud] {
            let verifier = registry.verifier(for: domain)
            XCTAssertNotNil(verifier)
            do {
                _ = try await verifier!.verifyPresence(of: [])
                XCTFail("An unconnected verifier must refuse rather than answer")
            } catch {
                XCTAssertTrue(error is CloudVerificationError)
            }
        }
    }

    // MARK: - Checksum fast-path reconciliation

    func testFastReconcileTransfersMappingFromIdenticalZip() throws {
        let setID = "20260710T081521Z-2"
        let zipHash = "abc123"
        let assetOne = UUID()
        let assetTwo = UUID()

        // Drive A processed earlier: its zip is fingerprinted, and the part's
        // extracted folder backs volume: replicas for two assets.
        let donorZip = TakeoutArchive(
            id: UUID(), path: "/Volumes/A/takeout-\(setID)-001.zip", kind: .zip, sizeBytes: 0,
            targetID: UUID(), discoveredAt: Date(), importedAt: Date(), importBatchID: nil,
            importedAssetCount: 2, skippedDuplicateCount: 0, note: nil,
            exportSetID: setID, partNumber: 1, contentHash: zipHash
        )
        let folderTwin = TakeoutArchive(
            id: UUID(), path: "/Volumes/A/takeout-\(setID)-001", kind: .folder, sizeBytes: 0,
            targetID: donorZip.targetID, discoveredAt: Date(), importedAt: Date(), importBatchID: nil,
            importedAssetCount: 2, skippedDuplicateCount: 0, note: nil,
            exportSetID: setID, partNumber: 1
        )
        let replicas = [
            TargetReplicaState(
                assetID: assetOne, targetID: donorZip.targetID!, state: .present,
                relativePath: "volume:takeout-\(setID)-001/Takeout/Google Photos/Photos from 2021/IMG_1.jpg",
                lastVerifiedAt: Date()
            ),
            TargetReplicaState(
                assetID: assetTwo, targetID: donorZip.targetID!, state: .present,
                relativePath: "volume:takeout-\(setID)-001/Takeout/Google Photos/Photos from 2021/IMG_2.jpg",
                lastVerifiedAt: Date()
            ),
        ]

        // Drive B carries a byte-identical zip; only assetOne still needs a replica.
        let driveBID = UUID()
        let result = try XCTUnwrap(TakeoutReconciler.fastReconcileZip(
            zipHash: zipHash,
            zipRelativePath: "Owner/Backup_Google/takeout-\(setID)-001.zip",
            targetID: driveBID,
            candidateDonors: [donorZip, folderTwin],
            folderTwins: [folderTwin],
            replicaStates: replicas,
            assetsNeedingReplica: [assetOne]
        ))

        XCTAssertEqual(result.claimedReplicas.count, 1)
        let claimed = result.claimedReplicas[0]
        XCTAssertEqual(claimed.assetID, assetOne)
        XCTAssertEqual(claimed.targetID, driveBID)
        XCTAssertEqual(
            claimed.relativePath,
            "zipmember:Owner/Backup_Google/takeout-\(setID)-001.zip!Takeout/Google Photos/Photos from 2021/IMG_1.jpg",
            "The donor's entry path transfers onto drive B's zip"
        )
        XCTAssertEqual(result.scannedFileCount, 2, "Mapping covered both known entries")
    }

    func testFastReconcileRefusesMismatchedHash() async {
        let donor = TakeoutArchive(
            id: UUID(), path: "/Volumes/A/takeout-S-001.zip", kind: .zip, sizeBytes: 0,
            targetID: nil, discoveredAt: Date(), importedAt: Date(), importBatchID: nil,
            importedAssetCount: 1, skippedDuplicateCount: 0, note: nil,
            exportSetID: "S", partNumber: 1, contentHash: "hash-of-A"
        )
        let result = TakeoutReconciler.fastReconcileZip(
            zipHash: "different-hash",
            zipRelativePath: "takeout-S-001.zip",
            targetID: UUID(),
            candidateDonors: [donor],
            folderTwins: [],
            replicaStates: [],
            assetsNeedingReplica: []
        )
        XCTAssertNil(result, "A zip that is not byte-identical must fall back to per-entry hashing")
    }

    // MARK: - In-place extraction

    func testExtractInPlaceCreatesConventionNamedFolder() async throws {
        let root = try makeTempDirectory()
        let treeRoot = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: treeRoot)
        let zipURL = root.appendingPathComponent("takeout-20260710T081521Z-2-007.zip")
        try zipDirectory(takeoutFolder, to: zipURL)

        let folderURL = try TakeoutExtractor.extractInPlace(zipURL: zipURL)

        XCTAssertEqual(folderURL.lastPathComponent, "takeout-20260710T081521Z-2-007")
        XCTAssertEqual(folderURL.deletingLastPathComponent().path, root.path, "Folder must sit next to the zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path), "The zip original must be kept")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folderURL.appendingPathExtension("extracting").path),
            "No temp extraction directory may remain"
        )
        // The extracted folder must parse into the same export set as its zip...
        let components = TakeoutArchive.parseExportComponents(filename: folderURL.lastPathComponent)
        XCTAssertEqual(components?.setID, "20260710T081521Z-2")
        XCTAssertEqual(components?.part, 7)
        // ...and be importable with full sidecar pairing.
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: folderURL, cleanupURL: nil),
            archiveName: folderURL.lastPathComponent, existingAssets: [],
            staging: staging
        )
        XCTAssertEqual(result.importedAssets.count, 2)
    }

    func testAvailableCapacityReportsNonZeroOrUnknown() throws {
        let dir = try makeTempDirectory()
        let capacity = TakeoutExtractor.availableCapacity(onVolumeOf: dir.appendingPathComponent("x.zip"))
        // Never a trusted zero: either a real positive reading or nil (unknown).
        if let capacity {
            XCTAssertGreaterThan(capacity, 0)
        }
    }

    func testExtractInPlaceRefusesExistingDestination() throws {
        let root = try makeTempDirectory()
        let treeRoot = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: treeRoot)
        let zipURL = root.appendingPathComponent("takeout-20260101T000000Z-001.zip")
        try zipDirectory(takeoutFolder, to: zipURL)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("takeout-20260101T000000Z-001"),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try TakeoutExtractor.extractInPlace(zipURL: zipURL))
    }

    // MARK: - Importer

    func testImportFromFolderPairsSidecarAndMarksPresence() async throws {
        let root = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: root)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let workspace = TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil)
        let result = await TakeoutImporter.importMedia(
            from: workspace,
            archiveName: "Takeout",
            existingAssets: [],
            staging: staging
        )

        XCTAssertEqual(result.importedAssets.count, 2)
        XCTAssertEqual(result.failures.count, 0)

        let withSidecar = try XCTUnwrap(result.importedAssets.first { $0.originalFilename == "IMG_100.jpg" })
        XCTAssertEqual(withSidecar.captureDate, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(withSidecar.exifSummary["GoogleDescription"], "Trip to the lake")
        XCTAssertEqual(withSidecar.exifSummary["GPS"], "12.34567, 76.54321")
        XCTAssertEqual(withSidecar.importOrigin, .googleTakeout)
        XCTAssertEqual(withSidecar.residency, .local)
        XCTAssertTrue(withSidecar.presence.local)
        XCTAssertFalse(
            withSidecar.presence.googleCloud,
            "Sidecar metadata says what Google knew about this file, not that Google still holds it"
        )

        XCTAssertEqual(withSidecar.captureDateSource, .sidecar)

        // No sidecar: the folder still names the year, which beats having no
        // date at all — but it is recorded as the weaker claim it is.
        let withoutSidecar = try XCTUnwrap(result.importedAssets.first { $0.originalFilename == "IMG_101.jpg" })
        XCTAssertEqual(withoutSidecar.captureDateSource, .folderYear)
        XCTAssertFalse(withoutSidecar.captureDateSource.isExact)
        let year = Calendar(identifier: .gregorian)
            .component(.year, from: try XCTUnwrap(withoutSidecar.captureDate))
        XCTAssertEqual(year, 2021, "Taken from the 'Photos from 2021' folder")

        // Staged copies must be real files with matching hashes.
        for asset in result.importedAssets {
            let path = try XCTUnwrap(asset.stagingRelativePath)
            XCTAssertEqual(try HashingService.sha256(of: staging.url(forRelativePath: path)), asset.contentHash)
        }
    }

    func testImportWithoutGooglePresenceWhenAlreadyDeleted() async throws {
        let root = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: root)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let result = await TakeoutImporter.importMedia(
            from: TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil),
            archiveName: "Takeout",
            existingAssets: [],
            staging: staging
        )
        for asset in result.importedAssets {
            XCTAssertFalse(asset.presence.googleCloud)
            XCTAssertEqual(asset.presence.domains, [.local])
        }
    }

    func testReimportSkipsExactDuplicates() async throws {
        let root = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: root)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let workspace = TakeoutImporter.Workspace(mediaRoot: takeoutFolder, cleanupURL: nil)

        let first = await TakeoutImporter.importMedia(
            from: workspace, archiveName: "Takeout", existingAssets: [],
            staging: staging
        )
        let second = await TakeoutImporter.importMedia(
            from: workspace, archiveName: "Takeout", existingAssets: first.importedAssets,
            staging: staging
        )
        XCTAssertEqual(second.importedAssets.count, 0)
        XCTAssertEqual(second.duplicateFilenames.count, 2)
    }

    func testImportFromZipViaWorkspaceExtraction() async throws {
        let treeRoot = try makeTempDirectory()
        let takeoutFolder = try makeFakeTakeoutTree(in: treeRoot)
        let zipURL = try makeTempDirectory().appendingPathComponent("takeout-20260101T000000Z-001.zip")
        try zipDirectory(takeoutFolder, to: zipURL)

        let archive = TakeoutArchive(
            id: UUID(),
            path: zipURL.path,
            kind: .zip,
            sizeBytes: 0,
            targetID: nil,
            discoveredAt: Date(),
            importedAt: nil,
            importBatchID: nil,
            importedAssetCount: 0,
            skippedDuplicateCount: 0,
            note: nil
        )
        let workArea = try makeTempDirectory()
        let workspace = try TakeoutImporter.prepareWorkspace(for: archive, workArea: workArea)
        defer { TakeoutImporter.cleanup(workspace) }
        XCTAssertNotNil(workspace.cleanupURL, "Zip extraction must use a disposable workspace")

        let staging = StagingStore(rootURL: try makeTempDirectory())
        let result = await TakeoutImporter.importMedia(
            from: workspace, archiveName: archive.displayName, existingAssets: [],
            staging: staging
        )
        XCTAssertEqual(result.importedAssets.count, 2)
        let withSidecar = try XCTUnwrap(result.importedAssets.first { $0.originalFilename == "IMG_100.jpg" })
        XCTAssertEqual(withSidecar.captureDate, Date(timeIntervalSince1970: 1_600_000_000))
    }
}

/// "13 Google exports not imported yet" for one twelve-part export whose every
/// part was imported. The unit was rows, and one part is three or four rows.
final class PartsAwaitingImportTests: XCTestCase {

    private func archive(
        part: Int?, kind: TakeoutArchiveKind = .zip, drive: String = "A",
        imported: Bool = false, missing: Bool = false, setID: String? = "S1"
    ) -> TakeoutArchive {
        var archive = TakeoutArchive(
            id: UUID(),
            path: "/Volumes/\(drive)/takeout-\(part.map(String.init) ?? "loose")\(kind == .zip ? ".zip" : "")",
            kind: kind, sizeBytes: 10, targetID: UUID(), discoveredAt: Date(),
            importedAt: imported ? Date() : nil, importBatchID: nil,
            importedAssetCount: imported ? 2_432 : 0, skippedDuplicateCount: 0,
            note: nil, exportSetID: setID, partNumber: part
        )
        if missing { archive.missingSince = Date() }
        return archive
    }

    /// The reported number, reproduced: twelve parts, each held as a zip on one
    /// drive and a zip plus an extracted folder on another, all imported. The
    /// import stamp lands on whichever representation was actually read.
    func testEveryPartImportedFromSomeCopyLeavesNothingPending() {
        var archives: [TakeoutArchive] = []
        for part in 1...12 {
            archives.append(archive(part: part, drive: "My Passport", imported: true))
            archives.append(archive(part: part, kind: .folder, drive: "Owner's Back", imported: true))
            archives.append(archive(part: part, drive: "Owner's Back"))
        }
        XCTAssertEqual(archives.filter { !$0.isImported }.count, 12, "Twelve rows carry no import date")
        XCTAssertEqual(
            TakeoutExportSet.partsAwaitingImport(in: archives), 0,
            "…and every one of them is a second copy of a part already imported"
        )
    }

    func testAPartNoCopyOfWhichWasImportedIsCounted() {
        let archives = [
            archive(part: 1, imported: true),
            archive(part: 2),
            archive(part: 2, kind: .folder, drive: "B"),
        ]
        XCTAssertEqual(TakeoutExportSet.partsAwaitingImport(in: archives), 1)
    }

    func testPartsOfDifferentExportsAreCountedSeparately() {
        let archives = [
            archive(part: 1, setID: "S1"),
            archive(part: 1, setID: "S2"),
        ]
        XCTAssertEqual(
            TakeoutExportSet.partsAwaitingImport(in: archives), 2,
            "Part 1 of two different exports is two parts, not one"
        )
    }

    /// Work the user cannot do is not work to offer. A part with no copy left
    /// on any drive cannot be imported; its absence is the archive checks'
    /// business, not this number's.
    func testAPartWithNoCopyLeftIsNotOfferedAsWork() {
        XCTAssertEqual(
            TakeoutExportSet.partsAwaitingImport(in: [archive(part: 1, missing: true)]), 0
        )
        XCTAssertEqual(
            TakeoutExportSet.partsAwaitingImport(in: [
                archive(part: 1, missing: true),
                archive(part: 1, drive: "B"),
            ]),
            1,
            "One copy gone and another still here is still a part to import"
        )
    }

    func testADiscoveryOutsideAnyNumberedExportCountsAsOne() {
        let archives = [
            archive(part: nil, kind: .folder, setID: nil),
            archive(part: nil, kind: .folder, drive: "B", setID: nil),
        ]
        XCTAssertEqual(
            TakeoutExportSet.partsAwaitingImport(in: archives), 2,
            "Two bare Takeout folders are two things to import, not one"
        )
    }
}
