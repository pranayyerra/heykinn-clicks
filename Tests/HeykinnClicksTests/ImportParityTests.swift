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
            staging: staging, replicaContext: (targetID: targetID, mountPath: mount.path)
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
}
