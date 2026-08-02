import XCTest
@testable import HeykinnClicks

/// Measures the import scan phase (hash + EXIF + sidecar) against a real
/// directory, comparing serial and parallel throughput. Gated because it needs
/// a path and reads a lot of data:
///
///     HEYKINN_BENCH_DIR=/Volumes/Drive/Takeout/... \
///     HEYKINN_BENCH_FILES=300 swift test --filter ScanBenchmark
final class ScanBenchmarkTests: XCTestCase {

    /// Isolates the sidecar-lookup fix: the old path listed the containing
    /// directory once per media file (quadratic inside an album folder); the
    /// new path lists each directory once and reuses it.
    func testSidecarLookupPerDirectoryListingVersusCached() throws {
        guard let path = ProcessInfo.processInfo.environment["HEYKINN_BENCH_DIR"] else {
            throw XCTSkip("Set HEYKINN_BENCH_DIR to benchmark sidecar lookup")
        }
        let limit = Int(ProcessInfo.processInfo.environment["HEYKINN_BENCH_FILES"] ?? "300") ?? 300
        let files = Array(
            ImportService.mediaFileURLs(under: [URL(fileURLWithPath: path)])
                .sorted { $0.path < $1.path }.prefix(limit)
        )
        try XCTSkipIf(files.count < 50, "Not enough files to benchmark sidecar lookup")

        // Warm the directory metadata for both runs so this measures work, not
        // first-touch I/O.
        for directory in Set(files.map { $0.deletingLastPathComponent().path }) {
            _ = try? FileManager.default.contentsOfDirectory(atPath: directory)
        }

        let uncachedStart = Date()
        var uncachedHits = 0
        for file in files where TakeoutImporter.findSidecar(for: file) != nil { uncachedHits += 1 }
        let uncached = Date().timeIntervalSince(uncachedStart)

        let cachedStart = Date()
        var listings: [String: [String]] = [:]
        for directory in Set(files.map { $0.deletingLastPathComponent().path }) {
            listings[directory] = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        }
        var cachedHits = 0
        for file in files where TakeoutImporter.findSidecar(for: file, directoryListings: listings) != nil {
            cachedHits += 1
        }
        let cached = Date().timeIntervalSince(cachedStart)

        XCTAssertEqual(uncachedHits, cachedHits, "Caching must not change which sidecars are found")
        print("""

        === sidecar lookup (\(files.count) files, \(listings.count) dirs) ===
        per-file listing: \(String(format: "%.2f", uncached))s
        cached listing:   \(String(format: "%.2f", cached))s
        speedup:          \(String(format: "%.1f", uncached / max(cached, 0.0001)))x
        sidecars found:   \(cachedHits)
        ==================================================

        """)
    }

    func testScanThroughputSerialVersusParallel() throws {
        guard let path = ProcessInfo.processInfo.environment["HEYKINN_BENCH_DIR"] else {
            throw XCTSkip("Set HEYKINN_BENCH_DIR to benchmark the scan phase")
        }
        let limit = Int(ProcessInfo.processInfo.environment["HEYKINN_BENCH_FILES"] ?? "300") ?? 300
        let widths = [1, 2, 4, 6, 8, 12]
        let root = URL(fileURLWithPath: path)
        let all = ImportService.mediaFileURLs(under: [root]).sorted { $0.path < $1.path }
        try XCTSkipIf(
            all.count < limit * widths.count,
            "Need \(limit * widths.count) media files at \(path); found \(all.count)"
        )

        // Each width gets a DISJOINT slice. Re-reading the same files would
        // measure the OS page cache (which produced impossible >1 GB/s figures
        // on a USB drive), not the drive.
        func slice(_ index: Int) -> [URL] {
            Array(all[(index * limit)..<((index + 1) * limit)])
        }
        func megabytes(_ files: [URL]) -> Double {
            let bytes = files.reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return Double(bytes) / 1_048_576
        }
        func hashes(_ scans: [TakeoutImporter.FileScan]) -> [String] {
            scans.map { if case .success(let h, _, _) = $0.outcome { return h } else { return "FAIL" } }
        }

        var report = """

        === scan benchmark (disjoint slices, cold) ===
        cores:        \(ProcessInfo.processInfo.activeProcessorCount)
        recommended:  \(TakeoutImporter.recommendedScanConcurrency(for: all[0]))
        slice size:   \(limit) files each

        """
        var baselineMBps: Double?
        for (index, width) in widths.enumerated() {
            let files = slice(index)
            let mb = megabytes(files)
            let start = Date()
            let scans = TakeoutImporter.scanFilesInParallel(files, concurrency: width)
            let seconds = Date().timeIntervalSince(start)

            // Correctness: every hash must match a direct computation.
            let produced = hashes(scans)
            for (fileIndex, url) in files.enumerated() where produced[fileIndex] != "FAIL" {
                XCTAssertEqual(produced[fileIndex], try HashingService.sha256(of: url))
            }

            let mbps = mb / seconds
            if width == 1 { baselineMBps = mbps }
            let speedup = baselineMBps.map { mbps / $0 } ?? 1
            report += String(
                format: "  width %2d: %6.2fs  %6.1f files/s  %6.1f MB/s  %.2fx\n",
                width, seconds, Double(files.count) / seconds, mbps, speedup
            )
        }
        report += "==============================================\n"
        print(report)
    }
}
