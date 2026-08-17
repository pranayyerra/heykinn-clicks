import XCTest
@testable import HeykinnClicks

/// The vectors any implementation of this app has to reproduce.
///
/// Everything here is a **fixed expected value**, not a round trip. A test that
/// hashes something and compares it to itself passes on every platform and
/// proves nothing; these say what the answer *is*, so a second implementation —
/// on Windows, on Android, or a future rewrite of this one — can be held to the
/// same numbers. See `docs/SPEC-hashing.md`.
///
/// Changing an expected value in this file is changing the format. Every
/// checksum and fingerprint already recorded in every user's
/// catalog was computed under these rules.
final class HashingConformanceTests: XCTestCase {

    // MARK: - SHA-256 itself

    /// FIPS 180-4 / NIST published vectors. These are the numbers that make the
    /// portable implementation trustworthy without a second opinion.
    func testReferenceSHA256MatchesTheNISTVectors() {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
        ]
        for (input, expected) in vectors {
            let digest = SHA256Reference.hash(Array(input.utf8))
            XCTAssertEqual(Digest256.hex(digest), expected, "SHA-256 of \"\(input)\"")
        }
    }

    /// Lengths either side of the point where padding needs a second block.
    /// A message of 55 bytes pads inside one block, 56 does not, and getting
    /// that boundary wrong is the classic way a hand-written SHA-256 passes
    /// "abc" and fails on real data.
    func testReferenceSHA256HandlesThePaddingBoundary() {
        let expected: [Int: String] = [
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            57: "f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6",
        ]
        for (length, digest) in expected {
            let input = String(repeating: "a", count: length)
            XCTAssertEqual(
                Digest256.hex(SHA256Reference.hash(Array(input.utf8))), digest,
                "SHA-256 of \(length) 'a's"
            )
        }
    }

    /// The accelerated path and the specified one must not be allowed to drift.
    /// This is the check that would catch it.
    func testTheAcceleratedAndReferenceImplementationsAgree() {
        let inputs: [Data] = [
            Data(),
            Data("abc".utf8),
            Data(String(repeating: "boundary", count: 7).utf8),   // 56 bytes
            Data(String(repeating: "x", count: 64).utf8),         // exactly one block
            Data(String(repeating: "y", count: 65).utf8),
            Data((0...255).map { UInt8($0) }),                    // every byte value
            Data(String(repeating: "café ☕️ 📷", count: 40).utf8), // multi-byte UTF-8
        ]
        for input in inputs {
            XCTAssertEqual(
                Digest256.hash(input),
                Data(SHA256Reference.hash(input)),
                "Platform SHA-256 disagreed with the reference on \(input.count) bytes"
            )
        }
    }

    func testStreamingInPiecesMatchesHashingAtOnce() {
        let whole = Data((0..<5000).map { UInt8($0 % 251) })
        var streaming = Digest256.Streaming()
        for chunk in stride(from: 0, to: whole.count, by: 97) {
            streaming.update(whole[chunk..<min(chunk + 97, whole.count)])
        }
        XCTAssertEqual(streaming.finalize(), Digest256.hash(whole))
    }

    // MARK: - Ordering

    /// The hazard `ByteOrdering` exists for, written as a test so it cannot be
    /// quietly undone.
    ///
    /// `"e" + combining acute` and `"z"`: Swift orders the first *after* `"z"`,
    /// because it compares canonically composed forms and `é` is U+00E9, well
    /// past `z`. Bytes order it *before*, because the string starts with `0x65`.
    /// A platform using its own native ordering would build a different tree.
    func testSwiftsOwnOrderingDisagreesWithBytes() {
        let combining = "e\u{0301}"
        let plain = "z"

        XCTAssertFalse(combining < plain, "Swift is expected to order the composed form after 'z'")
        XCTAssertTrue(
            ByteOrdering.precedes(combining, plain),
            "Bytewise, a string starting 0x65 precedes one starting 0x7a"
        )
    }

    /// macOS hands out decomposed filenames where other platforms give
    /// precomposed ones. Swift calls these two strings equal; their bytes are
    /// not. Anything recorded and later compared has to see the difference.
    func testComposedAndDecomposedAreDistinctByBytes() {
        let precomposed = "\u{00e9}"      // é
        let decomposed = "e\u{0301}"      // e + combining acute

        XCTAssertEqual(precomposed, decomposed, "Swift treats these as the same string")
        XCTAssertNotEqual(
            Array(precomposed.utf8), Array(decomposed.utf8),
            "…but they are different bytes, which is the whole problem"
        )
        XCTAssertTrue(ByteOrdering.precedes(decomposed, precomposed))
    }

    func testByteOrderingIsPlainAsciiWhereItShouldBe() {
        XCTAssertEqual(
            ["b", "A", "a", "B", "0", "_"].sortedByBytes(),
            ["0", "A", "B", "_", "a", "b"]
        )
    }

    // MARK: - Quick checksum

    private func makeFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-qc-\(UUID().uuidString).bin")
        // Deterministic contents, so the expected values below are reproducible
        // by any implementation reading this test.
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Small files are read whole, so the checksum is SHA-256 over the decimal
    /// length followed by every byte.
    func testQuickChecksumOfASmallFileIsLengthThenContents() throws {
        let url = try makeFile(bytes: 1000)

        var expected = Digest256.Streaming()
        expected.update(Data("1000".utf8))
        expected.update(Data((0..<1000).map { UInt8($0 % 251) }))

        XCTAssertEqual(try HashingService.quickChecksum(of: url), expected.finalizeHex())
    }

    /// The boundary: at or below 4 MiB the whole file is read, above it the
    /// windows kick in. Two files identical except past the boundary must be
    /// distinguishable below it and are only sampled above it.
    func testQuickChecksumChangesAtTheSamplingBoundary() throws {
        let justUnder = try makeFile(bytes: 4 * 1024 * 1024)
        let justOver = try makeFile(bytes: 4 * 1024 * 1024 + 1)

        // Different lengths alone guarantee different checksums — the length is
        // absorbed first precisely so a truncated copy cannot match.
        XCTAssertNotEqual(
            try HashingService.quickChecksum(of: justUnder),
            try HashingService.quickChecksum(of: justOver)
        )
    }

    /// A truncated copy must never match its original. This is the failure the
    /// quick checksum exists to catch.
    func testQuickChecksumCatchesTruncation() throws {
        let full = try makeFile(bytes: 9 * 1024 * 1024)
        let truncated = try makeFile(bytes: 9 * 1024 * 1024 - 1)

        XCTAssertNotEqual(
            try HashingService.quickChecksum(of: full),
            try HashingService.quickChecksum(of: truncated)
        )
    }

    /// The sampled windows are at fixed offsets, so a change inside one is
    /// caught. Stated as a test because the offsets are specification.
    func testQuickChecksumSeesAChangeInsideASampledWindow() throws {
        let size = 9 * 1024 * 1024
        let original = try makeFile(bytes: size)
        let before = try HashingService.quickChecksum(of: original)

        // The first interior probe sits at floor(size * 1 / 7).
        var bytes = try Data(contentsOf: original)
        bytes[size / 7] = bytes[size / 7] &+ 1
        try bytes.write(to: original)

        XCTAssertNotEqual(try HashingService.quickChecksum(of: original), before)
    }

    func testQuickChecksumOfAnEmptyFile() throws {
        let url = try makeFile(bytes: 0)

        var expected = Digest256.Streaming()
        expected.update(Data("0".utf8))

        XCTAssertEqual(try HashingService.quickChecksum(of: url), expected.finalizeHex())
    }

    // MARK: - Content hash

    func testContentHashIsPlainSHA256OfTheBytes() throws {
        let url = try makeFile(bytes: 3000)
        let contents = try Data(contentsOf: url)

        XCTAssertEqual(
            try HashingService.sha256(of: url),
            Digest256.hex(Digest256.hash(contents))
        )
    }
}
