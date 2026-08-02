import XCTest
@testable import HeykinnClicks

/// Guards against the O(assets × replicas) regression that pinned the main
/// thread at 100% CPU on a real 24k-asset catalog.
final class ScalePerformanceTests: XCTestCase {

    private func makeCatalogFixture(assetCount: Int) -> ([Asset], [DriveReplicaState]) {
        let driveA = UUID()
        let driveB = UUID()
        var assets: [Asset] = []
        var replicas: [DriveReplicaState] = []
        assets.reserveCapacity(assetCount)
        for index in 0..<assetCount {
            let asset = Asset(
                id: UUID(), kind: .photo, originalFilename: "IMG_\(index).jpg",
                importOrigin: .googleTakeout, captureDate: nil, importDate: Date(),
                updatedDate: Date(), fileSize: 1_000, pixelWidth: nil, pixelHeight: nil,
                contentHash: "hash-\(index)", residency: .local, residencySource: .importDefault,
                presence: .localOnly, stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
            )
            assets.append(asset)
            replicas.append(DriveReplicaState(
                assetID: asset.id, driveID: driveA, state: .present,
                relativePath: "volume:a/\(index).jpg", lastVerifiedAt: Date()
            ))
            if index.isMultiple(of: 2) {
                replicas.append(DriveReplicaState(
                    assetID: asset.id, driveID: driveB, state: .present,
                    relativePath: "volume:b/\(index).jpg", lastVerifiedAt: Date()
                ))
            }
        }
        return (assets, replicas)
    }

    func testBatchProtectionMatchesPerAssetResults() {
        let (assets, replicas) = makeCatalogFixture(assetCount: 300)
        let batch = ProtectionEvaluator.protectionStates(for: assets, replicaStates: replicas)
        XCTAssertEqual(batch.count, assets.count)
        for asset in assets {
            let individual = ProtectionEvaluator.protectionState(for: asset, replicaStates: replicas)
            XCTAssertEqual(batch[asset.id], individual, "Batch result must match the per-asset computation")
        }
        // Alternating fixture: half on both drives, half on one.
        XCTAssertEqual(batch.values.filter { $0 == .fullyReplicated }.count, 150)
        XCTAssertEqual(batch.values.filter { $0 == .replicatedToOneDrive }.count, 150)
    }

    func testProtectionScalesLinearlyNotQuadratically() {
        func measure(_ count: Int) -> TimeInterval {
            let (assets, replicas) = makeCatalogFixture(assetCount: count)
            let start = Date()
            _ = ProtectionEvaluator.protectionStates(for: assets, replicaStates: replicas)
            return Date().timeIntervalSince(start)
        }
        // Warm up so first-call overhead does not dominate the small case.
        _ = measure(500)

        let small = max(measure(2_000), 0.0005)
        let large = measure(16_000)
        let growth = large / small

        // 8x the data must not cost anything like 64x the time. Generous
        // bound so the test is not flaky on a busy machine, but a return of
        // the quadratic scan would blow straight past it.
        XCTAssertLessThan(
            growth, 24,
            "Protection computation grew \(String(format: "%.1f", growth))x for 8x data — quadratic scaling has regressed"
        )
    }
}
