import XCTest
@testable import HeykinnClicks

/// Both import paths must benefit from everything learned about reading media.
/// A fix that only lands in the Takeout importer leaves anyone importing a
/// plain folder on the old behaviour.
final class ImportParityTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var url = raw
        if let resolved = realpath(raw.path, nil) {
            url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: raw) }
        return url
    }

    func testFolderImportResolvesDatesFromTheFilename() async throws {
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("IMG-20160508-WA0004.jpg")
        try Data("bytes".utf8).write(to: file)

        let result = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [],
            staging: StagingStore(rootURL: try makeTempDirectory())
        )
        let asset = try XCTUnwrap(result.importedAssets.first)
        XCTAssertEqual(asset.captureDateSource, .filename)
        XCTAssertEqual(
            Calendar(identifier: .gregorian).component(.year, from: try XCTUnwrap(asset.captureDate)),
            2016
        )
    }

    func testFolderImportFallsBackToTheFolderYear() async throws {
        let root = try makeTempDirectory().appendingPathComponent("Photos from 2013", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("6734fbf7-7aa0.jpg")
        try Data("bytes".utf8).write(to: file)

        let result = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [],
            staging: StagingStore(rootURL: try makeTempDirectory())
        )
        let asset = try XCTUnwrap(result.importedAssets.first)
        XCTAssertEqual(asset.captureDateSource, .folderYear)
        XCTAssertFalse(asset.captureDateSource.isExact)
    }

    func testFolderImportReadsASidecarWhenOneIsPresent() async throws {
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("pic2.jpg")
        try Data("bytes".utf8).write(to: file)
        try Data("""
        {"title":"pic2.jpg","photoTakenTime":{"timestamp":"1390612940"}}
        """.utf8).write(to: root.appendingPathComponent("pic2.jpg.json"))

        let result = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [],
            staging: StagingStore(rootURL: try makeTempDirectory())
        )
        let asset = try XCTUnwrap(result.importedAssets.first)
        XCTAssertEqual(asset.captureDateSource, .sidecar)
        XCTAssertEqual(asset.captureDate, Date(timeIntervalSince1970: 1_390_612_940))
    }

    func testFolderImportOnAManagedDriveDoesNotDuplicateIntoStaging() async throws {
        let mount = try makeTempDirectory()
        let file = mount.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: file)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let targetID = UUID()

        let result = await ImportService.importFiles(
            [file], sourceDescription: "drive folder", existingAssets: [], policyRules: [],
            staging: staging, placement: TargetPlacement(targetID: targetID, mountPath: mount.path)
        )
        let asset = try XCTUnwrap(result.importedAssets.first)
        XCTAssertNil(asset.stagingRelativePath, "The drive already holds the bytes")
        XCTAssertEqual(result.archiveBackedReplicas[asset.id]?.targetID, targetID)
        XCTAssertEqual(staging.totalBytes, 0)
    }

    func testFolderImportStillStagesWhenTheSourceIsNotOnADrive() async throws {
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: file)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let result = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [],
            staging: staging
        )
        XCTAssertNotNil(result.importedAssets.first?.stagingRelativePath)
        XCTAssertGreaterThan(staging.totalBytes, 0)
    }

    func testFolderImportDedupesAgainstTheExistingCatalog() async throws {
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: file)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let first = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [], staging: staging
        )
        let second = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: first.importedAssets,
            policyRules: [], staging: staging
        )
        XCTAssertEqual(second.importedAssets.count, 0)
        XCTAssertEqual(second.duplicateFilenames, ["photo.jpg"])
    }

    /// The placement decision has to survive being made in the wrong order.
    /// Importing from a drive before registering it used to settle the
    /// question forever: the second sweep saw a hash it knew and stopped
    /// there, so the drive holding the file could never be credited with it.
    func testASweepCreditsADriveWithContentTheArchiveAlreadyHad() async throws {
        let mount = try makeTempDirectory()
        let file = mount.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: file)
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let targetID = UUID()

        // Imported while the drive was just a folder: staged, nothing adopted.
        let first = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [], staging: staging
        )
        let asset = try XCTUnwrap(first.importedAssets.first)
        XCTAssertNotNil(asset.stagingRelativePath)
        XCTAssertTrue(first.adoptedReplicas.isEmpty)

        // Registered, then swept again.
        let second = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: first.importedAssets,
            policyRules: [], staging: staging,
            placement: TargetPlacement(targetID: targetID, mountPath: mount.path)
        )
        XCTAssertEqual(second.importedAssets.count, 0, "Nothing new arrives")
        let adopted = try XCTUnwrap(second.adoptedReplicas[asset.id])
        XCTAssertEqual(adopted.targetID, targetID)
        XCTAssertEqual(adopted.state, .present)
        XCTAssertEqual(adopted.relativePath, ReplicationService.volumeBackedPrefix + "photo.jpg")
        XCTAssertNotNil(adopted.lastVerifiedAt, "The sweep just read these bytes")
    }

    func testADuplicateThatIsNotOnATargetAdoptsNothing() async throws {
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: file)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let first = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [], staging: staging
        )
        let second = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: first.importedAssets,
            policyRules: [], staging: staging,
            placement: TargetPlacement(targetID: UUID(), mountPath: try makeTempDirectory().path)
        )
        XCTAssertEqual(second.duplicateFilenames, ["photo.jpg"])
        XCTAssertTrue(second.adoptedReplicas.isEmpty, "Nowhere the app manages")
    }

    /// Which root the picker happened to hand back first is not a fact about
    /// where content belongs. It used to be: the whole batch took its placement
    /// from the first file found, so selecting the same two folders in the
    /// other order produced a different archive.
    func testPlacementDoesNotDependOnWhichRootCameFirst() async throws {
        let loose = try makeTempDirectory()
        let looseFile = loose.appendingPathComponent("loose.jpg")
        try Data("loose bytes".utf8).write(to: looseFile)

        let mount = try makeTempDirectory()
        let driveFile = mount.appendingPathComponent("ondrive.jpg")
        try Data("drive bytes".utf8).write(to: driveFile)

        let targetID = UUID()
        let staging = StagingStore(rootURL: try makeTempDirectory())
        let result = await ImportService.importFiles(
            [looseFile, driveFile], sourceDescription: "two folders",
            existingAssets: [], policyRules: [], staging: staging,
            placement: TargetPlacement(targetID: targetID, mountPath: mount.path)
        )

        let onDrive = try XCTUnwrap(result.importedAssets.first { $0.originalFilename == "ondrive.jpg" })
        let staged = try XCTUnwrap(result.importedAssets.first { $0.originalFilename == "loose.jpg" })
        XCTAssertNil(onDrive.stagingRelativePath, "On the target even though it was swept second")
        XCTAssertEqual(result.archiveBackedReplicas[onDrive.id]?.targetID, targetID)
        XCTAssertNotNil(staged.stagingRelativePath, "Not on any target, so it is staged")
        XCTAssertNil(result.archiveBackedReplicas[staged.id])
    }

    /// Pointing the app at the same folder again should cost a stat per file,
    /// not a full read of every byte to arrive at hashes it already has.
    func testASecondSweepOfUnchangedFilesReadsNothing() async throws {
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: file)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let first = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [], staging: staging
        )
        let memo = Dictionary(
            first.scanMemoEntries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }
        )
        XCTAssertEqual(memo.count, 1, "The first sweep wrote down what it read")

        // Swap the contents for different bytes of the same length and put the
        // modification date back. Anything that opens this file now gets a
        // different hash and imports it as new; only an answer taken from the
        // memo still calls it the file it already has.
        let entry = try XCTUnwrap(memo[file.path])
        try Data("BYTES".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: entry.modifiedAt], ofItemAtPath: file.path
        )

        let second = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: first.importedAssets,
            policyRules: [], staging: staging, scanMemo: [entry.path: entry]
        )
        XCTAssertEqual(second.duplicateFilenames, ["photo.jpg"])
        XCTAssertEqual(second.importedAssets.count, 0, "Never opened, so never re-hashed")
        XCTAssertTrue(second.failures.isEmpty)
    }

    /// A `stat` is enough to trust a hash the app worked out itself. It is not
    /// enough to admit something new to the archive, so a remembered hash that
    /// matches nothing known still gets read in full.
    func testARememberedHashForUnknownContentIsStillRead() async throws {
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: file)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let observation = try XCTUnwrap(ReplicaStatGate.observe(file))
        let stale = ScanMemoEntry(
            path: file.path, size: observation.size, modifiedAt: observation.modifiedAt,
            contentHash: "a-hash-no-asset-has", seenAt: Date()
        )

        let result = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [],
            staging: staging, scanMemo: [stale.path: stale]
        )
        let asset = try XCTUnwrap(result.importedAssets.first)
        XCTAssertNotEqual(asset.contentHash, stale.contentHash, "Hashed for real, not taken on trust")
    }

    /// A file edited in place is a different file. Size and modification date
    /// are what say so.
    func testAChangedFileIsReadAgain() async throws {
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("photo.jpg")
        try Data("bytes".utf8).write(to: file)
        let staging = StagingStore(rootURL: try makeTempDirectory())

        let first = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: [], policyRules: [], staging: staging
        )
        let entry = try XCTUnwrap(first.scanMemoEntries.first)
        try Data("entirely different bytes".utf8).write(to: file)

        let second = await ImportService.importFiles(
            [file], sourceDescription: "folder", existingAssets: first.importedAssets,
            policyRules: [], staging: staging, scanMemo: [entry.path: entry]
        )
        XCTAssertEqual(second.importedAssets.count, 1, "Different content is new content")
        XCTAssertTrue(second.duplicateFilenames.isEmpty)
    }

    /// A target's replica root holds the app's own copies under names the app
    /// invented. Sweeping a whole drive must not read them back as though the
    /// user had put them there.
    func testASweepSkipsTheAppsOwnFolderOnATarget() throws {
        let mount = try makeTempDirectory()
        let replicaRoot = mount
            .appendingPathComponent(ReplicationTarget.appFolderName, isDirectory: true)
            .appendingPathComponent("Replicas/ab", isDirectory: true)
        try FileManager.default.createDirectory(at: replicaRoot, withIntermediateDirectories: true)
        try Data("app copy".utf8).write(to: replicaRoot.appendingPathComponent("\(UUID().uuidString).jpg"))
        let userFile = mount.appendingPathComponent("mine.jpg")
        try Data("user file".utf8).write(to: userFile)

        let found = ImportService.mediaFileURLs(under: [mount])
        XCTAssertEqual(found.map(\.lastPathComponent), ["mine.jpg"])
    }
}

/// An ImportBatch is written by every import path, not only by somebody
/// choosing a folder — and `sourcePath` holds a label rather than a path for
/// three of the four things that write it. A screen that took either at face
/// value showed a user seven Google Takeout imports as folders they had added,
/// with no paths under them, none of which they remembered doing.
final class ImportBatchOriginTests: XCTestCase {

    private func batch(_ path: String, _ origin: ImportOrigin?) -> ImportBatch {
        ImportBatch(
            id: UUID(), sourcePath: path, startedAt: Date(), completedAt: nil,
            importedCount: 1, duplicateCount: 0, failedCount: 0, origin: origin
        )
    }

    func testATakeoutImportIsNotAFolderSomebodyAdded() {
        XCTAssertFalse(batch("Takeout export 20260710T081521Z-2 (3 parts)", .googleTakeout).isFolderImport)
        XCTAssertFalse(batch("Recovered import (Google Takeout)", .googleTakeout).isFolderImport)
        XCTAssertFalse(batch("/Users/me/Photos", .appleExport).isFolderImport)
    }

    func testAFolderImportIs() {
        XCTAssertTrue(batch("/Users/me/Pictures/Camera Roll", .localFolder).isFolderImport)
        XCTAssertTrue(batch("/Users/me/WhatsApp", .whatsapp).isFolderImport)
    }

    /// A batch from before the app recorded this says nothing rather than
    /// guessing, so it cannot be filed under a source it did not come from.
    func testAnUnrecordedOriginClaimsNothing() {
        XCTAssertFalse(batch("/Users/me/Pictures", nil).isFolderImport)
    }

    /// Only a real path is shown as one, or offered to Finder.
    func testALabelIsNotTreatedAsAPath() {
        XCTAssertFalse(batch("Takeout: Takeout_Archive_2026", .googleTakeout).isFilesystemPath)
        XCTAssertFalse(batch("Recovered import (Google Takeout)", .googleTakeout).isFilesystemPath)
        XCTAssertTrue(batch("/Volumes/Field Drive/Exports", .localFolder).isFilesystemPath)
    }
}

/// The count above a list and the list itself have to be answering the same
/// question. On a real archive they were not: the header counted photos by
/// where they came from and the list counted recorded folders, and eight
/// photos imported before the app wrote batch rows fell between them — "All 8
/// in the archive" over an empty list, which reads as the app having lost them.
final class FolderSourceAccountingTests: XCTestCase {

    private func asset(_ origin: ImportOrigin, batch: UUID? = nil) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "IMG.jpg", importOrigin: origin,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString,
            residency: .local, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: batch, exifSummary: [:]
        )
    }

    /// One definition of "came from a folder", shared by the photo and the
    /// batch, so the two counts cannot drift apart again.
    func testTheOriginDefinitionIsShared() {
        XCTAssertTrue(ImportOrigin.localFolder.isFolderLike)
        XCTAssertTrue(ImportOrigin.whatsapp.isFolderLike)
        XCTAssertTrue(ImportOrigin.messagingApp.isFolderLike)
        XCTAssertFalse(ImportOrigin.googleTakeout.isFolderLike)
        XCTAssertFalse(ImportOrigin.appleExport.isFolderLike)

        for origin in ImportOrigin.allCases {
            let batch = ImportBatch(
                id: UUID(), sourcePath: "x", startedAt: Date(), completedAt: nil,
                importedCount: 0, duplicateCount: 0, failedCount: 0, origin: origin
            )
            XCTAssertEqual(
                batch.isFolderImport, origin.isFolderLike,
                "\(origin) must mean the same thing to a batch and to a photo"
            )
        }
    }

    /// A photo with no batch at all is the shape that was falling through.
    func testAPhotoWithNoBatchStillCountsAsComingFromAFolder() {
        let orphan = asset(.localFolder, batch: nil)
        XCTAssertNil(orphan.importBatchID)
        XCTAssertTrue(orphan.importOrigin.isFolderLike)
    }

    func testATakeoutPhotoIsNotCreditedToFolders() {
        XCTAssertFalse(asset(.googleTakeout).importOrigin.isFolderLike)
    }
}
