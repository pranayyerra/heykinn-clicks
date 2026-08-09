import XCTest
@testable import HeykinnClicks

/// Which reader has been over which part of an export.
///
/// The exports are kept permanently so a reader that learns something new can
/// be run over them again. That decision is only actionable if the app records
/// what read what — otherwise "re-run in case we missed something" means
/// re-reading 127 GB on the chance it matters.
final class CaptureVersionTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeCatalog() throws -> CatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        roots.append(directory)
        return try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
    }

    func testAPartRemembersWhichReaderReadIt() throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(try catalog.fetchCaptureVersions().isEmpty)

        try catalog.recordCapture(setID: "20260710T081521Z-2", partNumber: 3, version: 1)
        XCTAssertEqual(try catalog.fetchCaptureVersions()["20260710T081521Z-2"]?[3], 1)

        // Reading it again with a newer reader replaces the record rather than
        // piling a second one beside it — a part has one answer, not a history
        // of everything that has ever been over it.
        try catalog.recordCapture(setID: "20260710T081521Z-2", partNumber: 3, version: 2)
        let versions = try catalog.fetchCaptureVersions()
        XCTAssertEqual(versions["20260710T081521Z-2"]?[3], 2)
        XCTAssertEqual(versions["20260710T081521Z-2"]?.count, 1)
    }

    /// Parts are keyed by content, not by the drive whose copy was read: one
    /// part exists as a zip on one drive and an unzipped folder on another, and
    /// reading either reads the same sidecars. Keying by the archive row would
    /// leave the other copy looking unread and invite a 10 GB re-read to prove
    /// something already known.
    func testTwoExportsDoNotShareOneAnswer() throws {
        let catalog = try makeCatalog()
        try catalog.recordCapture(setID: "setA", partNumber: 1, version: 1)
        try catalog.recordCapture(setID: "setB", partNumber: 1, version: 1)
        let versions = try catalog.fetchCaptureVersions()
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions["setA"]?[1], 1)
        XCTAssertEqual(versions["setB"]?[1], 1)
    }

    /// Everything imported before the reader was versioned was, by definition,
    /// read by something older than version 1. Treating "no record" as current
    /// would quietly exempt every existing archive from the one check this
    /// exists to make.
    @MainActor
    func testAPartNobodyHasRecordedCountsAsBehind() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-capture-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        roots.append(directory)
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        for part in 1...3 {
            try catalog.upsertTakeoutArchive(TakeoutArchive(
                id: UUID(),
                path: "/Volumes/Drive/takeout-set-00\(part).zip",
                kind: .zip, sizeBytes: 1, targetID: nil, discoveredAt: Date(),
                importedAt: Date(), importBatchID: nil, importedAssetCount: 1,
                skippedDuplicateCount: 0, note: nil, exportSetID: "set", partNumber: part
            ))
        }
        try catalog.recordCapture(setID: "set", partNumber: 2)

        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: "heykinn-capture-\(UUID().uuidString)")!,
            runsBackgroundWork: false
        ))
        XCTAssertEqual(store.exportPartsBehindReader(inSet: "set"), [1, 3], "part 2 has been read by this reader; the others have not")
    }
}
