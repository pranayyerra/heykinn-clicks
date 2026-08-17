import XCTest
@testable import HeykinnClicks

/// A merge is applied in batches so the window stays responsive. These cover the
/// thing that makes batching dangerous rather than merely fiddly: a row the
/// receiver has never seen can only be created from **all** of its columns, so a
/// batch boundary falling inside one row is a row that never arrives.
final class MergeBatchTests: XCTestCase {

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-batch-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        let directory = try makeDirectory(label)
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func makeDrive() throws -> DirectorySegmentStore {
        DirectorySegmentStore(root: try makeDirectory("drive"))
    }

    private func makeAsset() -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "a.jpg", importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    /// A batch size that does not divide a row's column count, which is the
    /// ordinary case: the real app uses 2,000 and a photograph is 29 fields.
    func testEveryPhotographArrivesWhenTheBatchCutsAcrossRows() async throws {
        let deviceA = try makeCatalog("a")
        let deviceB = try makeCatalog("b")
        let drive = try makeDrive()

        for _ in 0..<40 { try deviceA.upsertAsset(makeAsset()) }
        try DriveSync.publish(from: deviceA, to: drive)

        let report = try await DriveSync.merge(
            into: deviceB, from: drive, sliceSize: 7, betweenSlices: {}
        )

        XCTAssertTrue(
            report.outcome.rejected.isEmpty,
            "Nothing should be rejected: \(report.outcome.rejected.prefix(5))"
        )
        XCTAssertEqual(try deviceB.fetchAssets().count, 40)
    }
}
