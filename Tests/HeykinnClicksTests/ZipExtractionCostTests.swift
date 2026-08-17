import XCTest
@testable import HeykinnClicks

/// What extracting in process costs against the subprocesses it replaces.
///
/// The correctness case for removing `unzip`, `tar` and `ditto` is settled — they
/// do not exist on Windows or Android, and 21,380 of 21,401 photographs arrive
/// through extraction. The open question was speed: `unzip` is decades of
/// tuning, and a rewrite that is three times slower on a 10 GB Takeout part is
/// not obviously a good trade. This answers it with numbers rather than hope.
///
///     HEYKINN_BENCH=1 swift test --filter ZipExtractionCostTests
final class ZipExtractionCostTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["HEYKINN_BENCH"] == nil,
            "Set HEYKINN_BENCH=1 to measure extraction cost"
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipcost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Shaped like a Takeout part: photographs of a few hundred KB each, spread
    /// across album directories, each with a small JSON sidecar.
    private func makeTakeoutLikeZip(photographs: Int) throws -> URL {
        let directory = try makeDirectory()
        let staging = directory.appendingPathComponent("staging", isDirectory: true)

        for index in 0..<photographs {
            let album = "Takeout/Google Photos/Album \(index % 24)"
            let folder = staging.appendingPathComponent(album, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            // JPEG bytes barely compress; a run of zeroes compresses to nothing.
            // Neither alone is honest, so this is mostly incompressible with a
            // compressible header, which is roughly what a real photo does.
            var bytes = Data(count: 220_000)
            bytes.withUnsafeMutableBytes {
                _ = SecRandomCopyBytes(kSecRandomDefault, 200_000, $0.baseAddress!)
            }
            try bytes.write(to: folder.appendingPathComponent("IMG_\(index).jpg"))
            try Data(#"{"title":"IMG_\#(index).jpg","photoTakenTime":{"timestamp":"1700000000"}}"#.utf8)
                .write(to: folder.appendingPathComponent("IMG_\(index).jpg.json"))
        }

        let zipURL = directory.appendingPathComponent("part.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zipURL.path, "."]
        process.currentDirectoryURL = staging
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try XCTSkipIf(process.terminationStatus != 0, "Could not build a zip fixture")
        try FileManager.default.removeItem(at: staging)
        return zipURL
    }

    /// The bucketing `ParallelZipExtraction` used before extraction moved in
    /// process: entries grouped by their first three path components into
    /// disjoint `<prefix>/*` patterns, shallow entries passed by escaped name,
    /// balanced across buckets largest-first.
    ///
    /// Kept here rather than in the source, because its only remaining job is to
    /// be the thing the current implementation is measured against.
    private func priorArtPatternBuckets(entries: [String], workers: Int) -> [[String]] {
        var groupCounts: [String: Int] = [:]
        var exactNames: [String] = []
        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            if components.count > 3 {
                groupCounts[components[0...2].joined(separator: "/"), default: 0] += 1
            } else {
                exactNames.append(entry)
            }
        }

        var groups = groupCounts.map { (pattern: ZipTools.escapePattern($0.key) + "/*", count: $0.value) }
        if !exactNames.isEmpty { groups.append((pattern: "", count: exactNames.count)) }

        let bucketCount = min(max(1, workers), max(1, groups.count))
        var buckets: [[String]] = Array(repeating: [], count: bucketCount)
        var loads = Array(repeating: 0, count: bucketCount)
        for group in groups.sorted(by: { $0.count > $1.count }) {
            let lightest = loads.enumerated().min(by: { $0.element < $1.element })!.offset
            if group.pattern.isEmpty {
                buckets[lightest].append(contentsOf: exactNames.map(ZipTools.escapePattern))
            } else {
                buckets[lightest].append(group.pattern)
            }
            loads[lightest] += group.count
        }
        return buckets.filter { !$0.isEmpty }
    }

    private func time(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    private func fileCount(under root: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return 0 }
        var count = 0
        for case let url as URL in walker where
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            _ = url
            count += 1
        }
        return count
    }

    func testInProcessExtractionAgainstTheSubprocesses() throws {
        let photographs = 1_200
        let zip = try makeTakeoutLikeZip(photographs: photographs)
        let zipBytes = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0

        let workers = ParallelZipExtraction.recommendedWorkerCount(destination: try makeDirectory())

        let inProcessOut = try makeDirectory()
        let inProcess = try time {
            try ParallelZipExtraction.extract(zipURL: zip, into: inProcessOut, workers: workers)
        }
        let inProcessFiles = fileCount(under: inProcessOut)

        let dittoOut = try makeDirectory()
        let ditto = try time { try TakeoutExtractor.dittoExtract(zipURL: zip, into: dittoOut) }
        let dittoFiles = fileCount(under: dittoOut)

        let unzipOut = try makeDirectory()
        let unzip = time {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-qq", "-o", zip.path, "-d", unzipOut.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        let unzipFiles = fileCount(under: unzipOut)

        // The comparison that actually decides whether this change made the app
        // slower: what it did *before*, which was N concurrent `unzip` processes
        // over disjoint `<prefix>/*` patterns. Measuring against a single-process
        // `unzip` would flatter the rewrite by crediting it with parallelism the
        // old code already had.
        let priorOut = try makeDirectory()
        let patterns = priorArtPatternBuckets(
            entries: ZipTools.listEntries(inZip: zip), workers: workers
        )
        let prior = time {
            var running: [Process] = []
            for bucket in patterns {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-qq", "-o", zip.path] + bucket + ["-d", priorOut.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                running.append(process)
            }
            for process in running { process.waitUntilExit() }
        }
        let priorFiles = fileCount(under: priorOut)

        print("""

        ── extraction cost, \(photographs) photographs + sidecars ─────────────
          archive                \(zipBytes / 1_048_576) MB, \(photographs * 2) entries
          workers                \(workers)
          in process             \(String(format: "%6.2f", inProcess))s   \(inProcessFiles) files
          unzip ×\(patterns.count) (as before)    \(String(format: "%6.2f", prior))s   \(priorFiles) files
          ditto (one process)    \(String(format: "%6.2f", ditto))s   \(dittoFiles) files
          unzip (one process)    \(String(format: "%6.2f", unzip))s   \(unzipFiles) files

          vs what it replaced    \(String(format: "%.2f", prior / max(inProcess, 0.001)))× \
        \(inProcess <= prior ? "faster" : "SLOWER")
          vs ditto               \(String(format: "%.2f", ditto / max(inProcess, 0.001)))× \
        \(inProcess <= ditto ? "faster" : "slower")
        ──────────────────────────────────────────────────────────────

        """)

        XCTAssertEqual(inProcessFiles, photographs * 2, "in-process extraction lost files")
        XCTAssertEqual(inProcessFiles, dittoFiles, "in process and ditto disagree about how many files there are")
        XCTAssertEqual(inProcessFiles, priorFiles, "in process and the old parallel unzip disagree")
    }
}
