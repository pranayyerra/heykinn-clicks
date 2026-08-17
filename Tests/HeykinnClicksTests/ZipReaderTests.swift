import XCTest
@testable import HeykinnClicks

/// Reading a zip without running another program.
///
/// The case that forced this is the first one: an entry whose name contains a
/// narrow no-break space, which a Mac screenshot exported by Google carries.
/// `unzip` replaces every non-ASCII byte in its listing with a literal `?`, and
/// `?` is its own single-character wildcard — so asking for the entry back finds
/// nothing, and the caller records a photograph sitting on the drive as a
/// missing copy.
final class ZipReaderTests: XCTestCase {

    /// A Mac screenshot's name as Google exports it. U+202F, narrow no-break
    /// space, between the time and the meridiem.
    private let awkwardName = "Image 10-10-24 at 4.54\u{202f}PM.jpg"

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Builds a zip with the system archiver, so the fixtures are real archives
    /// rather than something shaped to suit the parser.
    private func makeZip(_ contents: [String: Data], compressed: Bool = true) throws -> URL {
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

        let zipURL = directory.appendingPathComponent("archive.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", compressed ? "-r" : "-r0", zipURL.path, "."]
        process.currentDirectoryURL = staging
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try XCTSkipIf(process.terminationStatus != 0, "Could not build a zip fixture")
        return zipURL
    }

    // MARK: - The bug

    /// The name has to survive being read. Everything else depends on it.
    func testANonAsciiEntryNameIsReadExactly() throws {
        let payload = Data(repeating: 0x41, count: 5_000)
        let zip = try makeZip(["./\(awkwardName)": payload, "./plain.jpg": Data("ascii".utf8)])

        let reader = try ZipReader(url: zip)
        defer { reader.close() }

        XCTAssertTrue(
            reader.names.contains { $0.hasSuffix(awkwardName) },
            "The name came back mangled: \(reader.names)"
        )
    }

    /// And the bytes have to come back, which is where `unzip -p` returned
    /// nothing at all.
    func testANonAsciiEntryCanBeHashed() throws {
        let payload = Data((0..<20_000).map { UInt8($0 % 251) })
        let zip = try makeZip(["./\(awkwardName)": payload])

        let reader = try ZipReader(url: zip)
        defer { reader.close() }
        let entry = try XCTUnwrap(reader.entries.first { $0.name.hasSuffix(awkwardName) })

        XCTAssertEqual(try reader.data(for: entry), payload)
    }

    /// **The production path, and the one that was broken.**
    ///
    /// The reconciler lists a zip's entries and hashes each listed name to
    /// claim it as a copy. Both halves have to agree about what the name is —
    /// and they did not, because listing went through `unzip -Z1`. Handing the
    /// reader a name it produced itself would prove nothing; this goes through
    /// `ZipTools.listEntries`, exactly as the app does.
    func testListingThenHashingWorksForANonAsciiName() throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 253) })
        let zip = try makeZip(["./\(awkwardName)": payload, "./other.jpg": Data("x".utf8)])

        let listed = try XCTUnwrap(
            ZipTools.listEntries(inZip: zip).first { $0.hasSuffix(awkwardName) },
            "The listing did not contain the entry at all"
        )

        XCTAssertEqual(
            try HashingService.sha256OfZipEntry(zipURL: zip, entry: listed),
            Digest256.hex(Digest256.hash(payload)),
            "A name from the listing could not be read back — the copy would be recorded as missing"
        )
    }

    /// Every listed name must be readable, since the reconciler hashes all of
    /// them and silently skips any that fail.
    func testEveryListedNameCanBeRead() throws {
        let zip = try makeZip([
            "./\(awkwardName)": Data("one".utf8),
            "./café/naïve.jpg": Data("two".utf8),
            "./emoji 📷 shot.jpg": Data("three".utf8),
            "./plain.jpg": Data("four".utf8),
        ])

        let listed = ZipTools.listEntries(inZip: zip)
        XCTAssertEqual(listed.count, 4, "Some entries were dropped from the listing")

        for name in listed {
            XCTAssertNoThrow(
                try HashingService.sha256OfZipEntry(zipURL: zip, entry: name),
                "Listed but unreadable: \(name)"
            )
        }
    }

    // MARK: - Ordinary archives

    func testListsEveryFileAndNoDirectories() throws {
        let zip = try makeZip([
            "./a.jpg": Data("a".utf8),
            "./nested/b.jpg": Data("b".utf8),
            "./nested/deeper/c.jpg": Data("c".utf8),
        ])
        let reader = try ZipReader(url: zip)
        defer { reader.close() }

        let names = reader.names.map { $0.replacingOccurrences(of: "./", with: "") }.sorted()
        XCTAssertEqual(names, ["a.jpg", "nested/b.jpg", "nested/deeper/c.jpg"])
        XCTAssertFalse(reader.names.contains { $0.hasSuffix("/") }, "Directories were listed")
    }

    /// Stored entries carry no compression at all, and an archive of already
    /// compressed photographs is full of them.
    func testStoredEntriesReadBack() throws {
        let payload = Data((0..<9_000).map { UInt8($0 % 199) })
        let zip = try makeZip(["./stored.jpg": payload], compressed: false)

        let reader = try ZipReader(url: zip)
        defer { reader.close() }
        let entry = try XCTUnwrap(reader.entries.first)

        XCTAssertEqual(entry.method, ZipContainer.Entry.stored)
        XCTAssertEqual(try reader.data(for: entry), payload)
    }

    /// Large enough to cross the streaming buffer several times, so a chunking
    /// mistake shows up as wrong bytes rather than passing on a small fixture.
    func testAnEntryLargerThanTheStreamingBufferReadsBackWhole() throws {
        let payload = Data((0..<600_000).map { UInt8($0 &* 37 % 251) })
        let zip = try makeZip(["./big.bin": payload])

        let reader = try ZipReader(url: zip)
        defer { reader.close() }
        let entry = try XCTUnwrap(reader.entries.first)

        let read = try reader.data(for: entry)
        XCTAssertEqual(read.count, payload.count)
        XCTAssertEqual(Digest256.hash(read), Digest256.hash(payload))
    }

    func testEmptyEntriesAreHandled() throws {
        let zip = try makeZip(["./empty.txt": Data(), "./real.txt": Data("x".utf8)])
        let reader = try ZipReader(url: zip)
        defer { reader.close() }

        let empty = try XCTUnwrap(reader.entries.first { $0.name.hasSuffix("empty.txt") })
        XCTAssertEqual(try reader.data(for: empty), Data())
    }

    // MARK: - Refusing rather than guessing

    func testSomethingThatIsNotAZipIsRefused() throws {
        let file = try makeDirectory().appendingPathComponent("not.zip")
        try Data(repeating: 0x00, count: 4_000).write(to: file)

        XCTAssertThrowsError(try ZipReader(url: file))
    }

    /// A zip cut short — the shape a half-copied archive on a drive has.
    func testATruncatedArchiveIsRefused() throws {
        let zip = try makeZip(["./a.jpg": Data(repeating: 0x42, count: 30_000)])
        let whole = try Data(contentsOf: zip)
        let cut = try makeDirectory().appendingPathComponent("cut.zip")
        try whole.prefix(whole.count / 2).write(to: cut)

        XCTAssertThrowsError(
            try ZipReader(url: cut),
            "A truncated archive must be refused, not read as empty"
        )
    }
}
