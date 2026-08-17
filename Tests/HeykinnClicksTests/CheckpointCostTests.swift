import XCTest
@testable import HeykinnClicks

/// What the checkpoint actually costs and saves, on an archive the size of a
/// real one.
///
/// Off by default because it builds a few thousand photographs and takes tens of
/// seconds. The numbers in `docs/ARCHITECTURE-DECISIONS.md` §D6 came from here,
/// and this is how to get them again:
///
///     HEYKINN_BENCH=1 swift test --filter CheckpointCostTests
final class CheckpointCostTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["HEYKINN_BENCH"] == nil,
            "Set HEYKINN_BENCH=1 to measure checkpoint cost"
        )
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-cost-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        let directory = try makeDirectory(label)
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func makeAsset(_ index: Int) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "IMG_\(index).jpg",
            importOrigin: .googleTakeout, captureDate: Date(), importDate: Date(),
            updatedDate: Date(), fileSize: Int64(2_400_000 + index), pixelWidth: 4032,
            pixelHeight: 3024, contentHash: UUID().uuidString, residency: .local,
            residencySource: .importDefault, presence: .localOnly, stagingRelativePath: nil,
            importBatchID: nil, exifSummary: [:]
        )
    }

    private func bytes(_ drive: DirectorySegmentStore, _ device: String) throws -> Int {
        try drive.list(DriveSync.deviceDirectory(device))
            .filter { $0.hasSuffix(".jsonl") }
            .reduce(0) { total, name in
                total + ((try? drive.size("\(DriveSync.deviceDirectory(device))/\(name)")) ?? 0 ?? 0)
            }
    }

    func testWhatALogCostsAgainstWhatStateCosts() throws {
        let photographs = 2_000
        let deviceA = try makeCatalog("a")
        let drive = try makeDrive()
        let device = try XCTUnwrap(deviceA.journal).device.id

        let importing = Date()
        for index in 0..<photographs { try deviceA.upsertAsset(makeAsset(index)) }
        let importSeconds = Date().timeIntervalSince(importing)

        let logging = Date()
        try DriveSync.publish(from: deviceA, to: drive, checkpointing: .never)
        let logSeconds = Date().timeIntervalSince(logging)
        let logBytes = try bytes(drive, device)

        let checkpointing = Date()
        let published = try DriveSync.publish(from: deviceA, to: drive, checkpointing: .always)
        let checkpointSeconds = Date().timeIntervalSince(checkpointing)
        let checkpoint = try XCTUnwrap(published.checkpoint)

        // And what a device that has never seen the archive pays, now that the
        // log it would have replayed is gone.
        let deviceB = try makeCatalog("b")
        let reading = Date()
        let report = try DriveSync.merge(into: deviceB, from: drive)
        let readSeconds = Date().timeIntervalSince(reading)

        print("""

        ── checkpoint cost, \(photographs) photographs ──────────────────────
          import                 \(String(format: "%6.2f", importSeconds))s
          log, published         \(String(format: "%6.2f", logSeconds))s   \
        \(logBytes / 1024) KB
          checkpoint, written    \(String(format: "%6.2f", checkpointSeconds))s   \
        \(checkpoint.byteCount / 1024) KB, \(checkpoint.rows) rows
          ratio                  \(String(format: "%.2f", Double(logBytes) / Double(max(checkpoint.byteCount, 1))))× \
        smaller as state
          segments pruned        \(published.segmentsPruned)
          first sync, from state \(String(format: "%6.2f", readSeconds))s   \
        \(report.outcome.applied) applied, \(report.outcome.rejected.count) rejected
        ─────────────────────────────────────────────────────────────

        """)

        XCTAssertEqual(try deviceB.fetchAssets().count, photographs)
        XCTAssertTrue(report.outcome.rejected.isEmpty, "\(report.outcome.rejected.prefix(3))")
    }

    private func makeDrive() throws -> DirectorySegmentStore {
        DirectorySegmentStore(root: try makeDirectory("drive"))
    }
}
