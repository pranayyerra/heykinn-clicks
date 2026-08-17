import XCTest
@testable import HeykinnClicks

/// Whether bulk extraction — the path every Takeout import runs through —
/// preserves the names inside the archive.
///
/// Written while `ParallelZipExtraction` still ran `unzip`, to settle whether it
/// suffered the name mangling that had forced `ZipTools.extractEntries` off
/// `unzip` — a real Google part there lost 4,673 of 6,660 sidecars with an exit
/// status that looked like success. **It did not**: with a fixture in Google's
/// exact shape (UTF-8 names, the UTF-8 flag *unset*), covering both the
/// ASCII-wildcard and the literal-escaped-name paths, every entry round-tripped.
///
/// Kept now that extraction happens in process, because the property it checks
/// is the one that matters and is easy to lose quietly: 21,380 of the 21,401
/// photographs in this archive arrive this way, and a name that does not survive
/// is a photograph the app reports as absent from the drive holding it.
final class BulkExtractionNameTests: XCTestCase {

    /// A screenshot's name as Google exports it. U+202F, narrow no-break space,
    /// between the time and the meridiem.
    private let awkwardName = "Image 10-10-24 at 4.54\u{202f}PM.jpg"
    /// A decomposed é, which is a different byte sequence from the composed one
    /// and the form macOS hands back from the filesystem.
    private let decomposedName = "Cafe\u{0301} trip.jpg"
    private let emojiName = "Party 🎉.jpg"

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A zip built by the system archiver, so the fixture is a real archive
    /// rather than something shaped to suit the reader.
    private func makeZip(_ names: [String]) throws -> URL {
        let directory = try makeDirectory()
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in names {
            let file = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("payload of \(name)".utf8).write(to: file)
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

    /// Names on disk, relative to `root`, in the same normalisation the archive
    /// used — the filesystem may hand back a different one.
    private func filesOnDisk(under root: URL) -> Set<String> {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var found: Set<String> = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            found.insert(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
        }
        return found
    }

    /// The whole question, in one test: does every entry the archive holds come
    /// out under the name the archive gave it?
    func testEveryEntryLandsUnderTheNameTheArchiveHolds() throws {
        // Deep enough to exercise the prefix grouping the partitioner does.
        let names = [
            "Takeout/Google Photos/Photos from 2024/\(awkwardName)",
            "Takeout/Google Photos/Photos from 2024/\(decomposedName)",
            "Takeout/Google Photos/Photos from 2024/\(emojiName)",
            "Takeout/Google Photos/Photos from 2024/ordinary.jpg",
            "Takeout/Google Photos/Album one/\(awkwardName)",
            "Takeout/Google Photos/Album one/plain.jpg",
            "Takeout/archive_browser.html",
            // Shallow, so the partitioner passes it to the worker as a literal
            // escaped name rather than under an ASCII `<prefix>/*` wildcard.
            // That is the only place a non-ASCII name reaches the worker's
            // argument list, and so the only place a mangled round trip could
            // lose one.
            "Takeout/\(awkwardName)",
            "Takeout/\(emojiName)",
        ]
        let zip = try makeZip(names)
        let destination = try makeDirectory().appendingPathComponent("out", isDirectory: true)

        try ParallelZipExtraction.extract(zipURL: zip, into: destination, workers: 4)

        let expected = Set(ZipTools.listEntries(inZip: zip))
        let actual = filesOnDisk(under: destination)

        // Compared in a single normalisation: macOS hands decomposed names back
        // from the filesystem whatever went in, and that difference is not the
        // one under test here.
        let normalise = { (names: Set<String>) in Set(names.map { $0.decomposedStringWithCanonicalMapping }) }
        let missing = normalise(expected).subtracting(normalise(actual))

        XCTAssertTrue(
            missing.isEmpty,
            "\(missing.count) of \(expected.count) entries did not land under their own name: \(missing.sorted())"
        )
        XCTAssertEqual(normalise(actual), normalise(expected))
    }
}
