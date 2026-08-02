import XCTest
@testable import HeykinnClicks

final class ParallelExtractionTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-parallel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: raw)
        }
        return raw
    }

    func testPartitionBucketsAreDisjointAndCoverEverything() {
        let entries = [
            "Takeout/Google Photos/Photos from 2020/IMG_1.jpg",
            "Takeout/Google Photos/Photos from 2020/IMG_1.jpg.json",
            "Takeout/Google Photos/Photos from 2021/IMG_2.jpg",
            "Takeout/Google Photos/Photos from 2021/nested/IMG_3.jpg",
            "Takeout/Google Photos/Album [best]/IMG_4.jpg",
            "Takeout/YouTube/videos/clip.mp4",
            "Takeout/archive_browser.html",
        ]
        let buckets = ParallelZipExtraction.partition(entries: entries, workers: 3)

        XCTAssertLessThanOrEqual(buckets.count, 3)
        // Every entry must be matched by exactly one bucket.
        for entry in entries {
            let matchingBuckets = buckets.filter { bucket in
                bucket.contains { pattern in
                    if pattern.hasSuffix("/*") {
                        let prefix = String(pattern.dropLast(2)).replacingOccurrences(of: "\\", with: "")
                        return entry.hasPrefix(prefix + "/")
                    }
                    return pattern.replacingOccurrences(of: "\\", with: "") == entry
                }
            }
            XCTAssertEqual(matchingBuckets.count, 1, "\(entry) must belong to exactly one worker")
        }
    }

    func testEscapePatternNeutralizesWildcards() {
        XCTAssertEqual(ZipTools.escapePattern("Album [best]/IMG*.jpg"), "Album \\[best\\]/IMG\\*.jpg")
        XCTAssertEqual(ZipTools.escapePattern("plain/path.jpg"), "plain/path.jpg")
    }

    func testRecommendedWorkerCountIsAtLeastOne() throws {
        let dir = try makeTempDirectory()
        XCTAssertGreaterThanOrEqual(ParallelZipExtraction.recommendedWorkerCount(destination: dir), 1)
    }

    func testParallelExtractionMatchesZipContentExactly() throws {
        // A tree with multiple sibling album dirs (so several workers engage),
        // nested subdirectories, bracketed names, and shallow files.
        let sourceRoot = try makeTempDirectory()
        let takeout = sourceRoot.appendingPathComponent("Takeout", isDirectory: true)
        var expected: [String: String] = [:]
        let layout = [
            "Google Photos/Photos from 2020/IMG_1.jpg",
            "Google Photos/Photos from 2020/IMG_1.jpg.json",
            "Google Photos/Photos from 2021/IMG_2.jpg",
            "Google Photos/Photos from 2021/nested deep/IMG_3.jpg",
            "Google Photos/Album [best of *]/IMG_4.jpg",
            "YouTube/videos/clip.mp4",
            "archive_browser.html",
        ]
        for relative in layout {
            let file = takeout.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = Data("content of \(relative)".utf8)
            try contents.write(to: file)
            expected["Takeout/\(relative)"] = try HashingService.sha256(of: file)
        }

        let zipURL = try makeTempDirectory().appendingPathComponent("takeout-parallel-test.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipProcess.arguments = ["-c", "-k", "--keepParent", takeout.path, zipURL.path]
        try zipProcess.run()
        zipProcess.waitUntilExit()
        XCTAssertEqual(zipProcess.terminationStatus, 0)

        let destination = try makeTempDirectory().appendingPathComponent("out", isDirectory: true)
        try ParallelZipExtraction.extract(zipURL: zipURL, into: destination, workers: 4)

        for (entry, expectedHash) in expected {
            let extracted = destination.appendingPathComponent(entry)
            XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path), "\(entry) missing after parallel extraction")
            XCTAssertEqual(try HashingService.sha256(of: extracted), expectedHash, "\(entry) content mismatch")
        }
    }
}
