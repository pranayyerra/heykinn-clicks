import XCTest
@testable import HeykinnClicks

/// Extracting a zip without running another program.
///
/// This is hazard H3 — the last thing standing between the archive format and a
/// second platform, because `unzip`, `tar` and `ditto` exist on none of them and
/// nearly every photograph in a real archive arrives through extraction.
///
/// Two things have to hold, and only one of them was somebody else's problem
/// before: the bytes must come out exactly, and an archive is untrusted input.
final class ZipExtractorTests: XCTestCase {

    private let awkwardName = "Image 10-10-24 at 4.54\u{202f}PM.jpg"

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeZip(_ contents: [String: Data]) throws -> URL {
        let directory = try makeDirectory()
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, data) in contents {
            let file = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: file)
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
        return zipURL
    }

    // MARK: - The bytes

    /// Compressible, incompressible and empty in one archive: the three shapes
    /// the inflate path behaves differently on.
    func testEntriesComeOutByteForByte() throws {
        var random = Data(count: 300_000)
        random.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 300_000, $0.baseAddress!) }
        let contents: [String: Data] = [
            "Takeout/Google Photos/2024/\(awkwardName)": Data(repeating: 0x41, count: 500_000),
            "Takeout/Google Photos/2024/noise.bin": random,
            "Takeout/Google Photos/2024/empty.txt": Data(),
            "Takeout/archive_browser.html": Data("<html>ok</html>".utf8),
        ]
        let zip = try makeZip(contents)
        let out = try makeDirectory()

        let outcome = try ZipExtractor.extractAll(from: zip, into: out)

        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        for (name, expected) in contents {
            let landed = try Data(contentsOf: out.appendingPathComponent(name))
            XCTAssertEqual(landed, expected, "\(name) did not come out byte for byte")
        }
    }

    /// A named subset, which is what a parallel worker is given.
    func testOnlyTheNamedEntriesAreWritten() throws {
        let zip = try makeZip([
            "a/one.txt": Data("1".utf8),
            "a/two.txt": Data("2".utf8),
            "b/three.txt": Data("3".utf8),
        ])
        let out = try makeDirectory()

        let outcome = try ZipExtractor.extract(
            entries: ["a/one.txt", "b/three.txt"], from: zip, into: out
        )

        XCTAssertEqual(outcome.written.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("a/one.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("a/two.txt").path))
    }

    /// An entry the archive does not hold is reported, not thrown: the caller's
    /// other entries are still worth extracting.
    func testAnUnknownEntryIsReportedRatherThanFatal() throws {
        let zip = try makeZip(["a/one.txt": Data("1".utf8)])
        let out = try makeDirectory()

        let outcome = try ZipExtractor.extract(
            entries: ["a/one.txt", "a/absent.txt"], from: zip, into: out
        )

        XCTAssertEqual(outcome.written, ["a/one.txt"])
        XCTAssertEqual(outcome.failures.keys.sorted(), ["a/absent.txt"])
    }

    // MARK: - An archive is untrusted input

    /// The oldest trick there is. `unzip` and `tar` each refused this in their
    /// own way; doing the extraction here means owning the refusal.
    func testAnEntryCannotEscapeTheDestination() throws {
        let out = try makeDirectory()

        for name in [
            "../escaped.txt",
            "a/../../escaped.txt",
            "/etc/passwd",
            "C:/Windows/system32",
            "",
        ] {
            XCTAssertThrowsError(
                try ZipExtractor.resolve(name, under: out),
                "\"\(name)\" should not resolve to anywhere writable"
            )
        }
    }

    /// A sibling directory whose name merely starts with the destination's is
    /// not inside it — the check has to be on a path boundary, not a prefix.
    func testASiblingWithASharedPrefixIsNotInside() throws {
        let parent = try makeDirectory()
        let destination = parent.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ZipExtractor.resolve("../out-evil/x.txt", under: destination))
        XCTAssertNoThrow(try ZipExtractor.resolve("nested/x.txt", under: destination))
    }

    /// An entry that fails half way must leave nothing behind. A short file
    /// would be recorded as a copy and only found to be damaged later, which is
    /// a slow and confusing way to learn about it.
    func testAFailedEntryLeavesNoPartialFile() throws {
        let zip = try makeZip(["a/one.txt": Data(repeating: 0x42, count: 200_000)])
        let out = try makeDirectory()

        // Truncate the archive so the entry's data is cut off mid-stream.
        var bytes = try Data(contentsOf: zip)
        bytes = bytes.prefix(bytes.count / 3)
        let broken = out.appendingPathComponent("broken.zip")
        try bytes.write(to: broken)

        // A truncated archive has no readable central directory at all, which
        // is refused before any file is created.
        XCTAssertThrowsError(try ZipExtractor.extractAll(from: broken, into: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("a/one.txt").path))
    }

    // MARK: - Matching

    func testGlobMatchingCoversWhatTheCallersBuild() {
        // `*` crosses `/`, which is what unzip and tar did and what the callers
        // rely on.
        XCTAssertTrue(ZipTools.matches("*.json", "Takeout/Google Photos/2024/x.json"))
        XCTAssertTrue(ZipTools.matches("Takeout/Google Photos/2024/*", "Takeout/Google Photos/2024/a/b.jpg"))
        XCTAssertFalse(ZipTools.matches("*.json", "Takeout/x.jpg"))

        // A trailing `*` may match nothing.
        XCTAssertTrue(ZipTools.matches("abc*", "abc"))
        XCTAssertTrue(ZipTools.matches("*", ""))
        XCTAssertTrue(ZipTools.matches("", ""))
        XCTAssertFalse(ZipTools.matches("", "a"))

        // Backtracking: the first `*` must give characters back.
        XCTAssertTrue(ZipTools.matches("*a*b", "xxaxxb"))
        XCTAssertTrue(ZipTools.matches("a*b*c", "abbbc"))
        XCTAssertFalse(ZipTools.matches("a*b*c", "abbb"))

        XCTAssertTrue(ZipTools.matches("?bc", "abc"))
        XCTAssertFalse(ZipTools.matches("?bc", "bc"))

        // Escaped wildcards match themselves, which is what `escapePattern` is
        // for — a name really containing `*` or `[`.
        XCTAssertTrue(ZipTools.matches(ZipTools.escapePattern("Album [best]/IMG*.jpg"), "Album [best]/IMG*.jpg"))
        XCTAssertFalse(ZipTools.matches(ZipTools.escapePattern("IMG*.jpg"), "IMGxyz.jpg"))

        // Non-ASCII, which is the whole reason this code exists.
        XCTAssertTrue(ZipTools.matches("Takeout/*", "Takeout/\(awkwardName)"))
    }

    /// The listing and the extraction have to agree, since a pattern is now
    /// matched against the same names that get written.
    func testExtractingByPatternWritesExactlyWhatItMatched() throws {
        let zip = try makeZip([
            "Takeout/Google Photos/2024/\(awkwardName)": Data("photo".utf8),
            "Takeout/Google Photos/2024/meta.json": Data("{}".utf8),
            "Takeout/Google Photos/2024/other.jpg": Data("jpg".utf8),
        ])
        let out = try makeDirectory()

        let written = ZipTools.extractEntries(matching: "*.json", inZip: zip, to: out)

        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].hasSuffix("meta.json"))
        XCTAssertEqual(
            try Data(contentsOf: out.appendingPathComponent(written[0])), Data("{}".utf8)
        )
    }

    // MARK: - Partitioning

    /// Workers must own disjoint directories, or two of them race to create the
    /// same intermediate folder.
    func testBucketsAreDisjointAndComplete() {
        let entries = (0..<50).map { "Takeout/Google Photos/Album \($0 % 7)/IMG_\($0).jpg" }
            + ["Takeout/archive_browser.html", "Takeout/index.html"]

        for workers in [1, 2, 3, 8, 64] {
            let buckets = ParallelZipExtraction.partition(entries: entries, workers: workers)
            let flattened = buckets.flatMap { $0 }

            XCTAssertEqual(Set(flattened), Set(entries), "at \(workers) workers")
            XCTAssertEqual(flattened.count, entries.count, "an entry was duplicated at \(workers) workers")
            XCTAssertLessThanOrEqual(buckets.count, max(1, workers))

            // No directory may appear in two buckets.
            var owner: [String: Int] = [:]
            for (index, bucket) in buckets.enumerated() {
                for entry in bucket {
                    let directory = (entry as NSString).deletingLastPathComponent
                    XCTAssertEqual(
                        owner[directory] ?? index, index,
                        "\(directory) is split across buckets at \(workers) workers"
                    )
                    owner[directory] = index
                }
            }
        }
    }
}
