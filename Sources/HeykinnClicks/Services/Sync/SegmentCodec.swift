import Foundation

/// The bytes a change becomes on a drive.
///
/// **JSON Lines with a checksum on every line**, chosen for removable media
/// rather than for elegance:
///
/// - **A yanked drive tears the last line, not the file.** Records are appended,
///   so an interrupted write can only damage the tail. A reader takes lines
///   until one fails, keeps everything before it, and the next write appends
///   after the good part. A torn write into a SQLite file on exFAT is a much
///   worse day.
/// - **The checksum is what makes "fails" definite.** Truncated JSON usually
///   fails to parse, but usually is not a word this app should rely on: a cut
///   at the wrong byte can leave something that parses and means something
///   else. Sixteen hex characters settle it.
/// - **Anything can read it.** A Windows or Android client needs no SQLite
///   build, no schema knowledge and no Apple frameworks to make sense of a line
///   of JSON.
///
/// Concrete on purpose. This is a format with exactly one implementation, and
/// putting it behind a protocol would suggest a choice that does not exist.
enum SegmentCodec {

    /// Characters of hex used from the digest. 64 bits is far more than enough
    /// to catch truncation and corruption, which is all this is for — it is not
    /// protecting against anybody who is trying.
    static let checksumLength = 16

    enum DecodeFailure: Equatable {
        /// The line's checksum does not match its content.
        case corrupt(line: Int)
        /// Well-formed checksum, but the JSON behind it is not a record.
        case unreadable(line: Int)
        /// A line with no separator at all — the usual shape of a torn tail.
        case truncated(line: Int)
    }

    struct DecodeResult: Equatable {
        /// Everything read before trouble started.
        var records: [ChangeRecord]
        /// Why reading stopped, or nil if the whole file was good.
        var stoppedAt: DecodeFailure?
        /// Bytes up to and including the last complete, verified line.
        ///
        /// What a device truncates its own damaged segment back to before
        /// appending again. Appending after a half-written line would splice
        /// the new record onto the broken one and leave the file corrupt from
        /// that point forever — and since a reader stops at the first bad line,
        /// that would block every record written after it, permanently.
        var goodByteCount: Int
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted so the same record encodes to the same bytes every time —
        // which is what makes the checksum reproducible and lets two
        // implementations be compared byte for byte.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: - Writing

    /// One line, with its trailing newline.
    ///
    /// Generic over what is on the line because a checkpoint uses this same
    /// framing for a different record — see `CheckpointRecord`. The framing is
    /// the format; what it carries is not. Keeping one implementation is what
    /// stops the two drifting apart in the checksum, which is where a divergence
    /// would show up as unreadable files rather than as a compile error.
    ///
    /// Named apart from `encode` deliberately: an array is itself `Encodable`,
    /// so a single generic pair would let `encode(someArray)` resolve to "one
    /// line holding the whole array" — a silent format change that would compile
    /// and produce files nothing could read back as records.
    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let json = try encoder.encode(value)
        let checksum = Digest256.hex(Digest256.hash(json)).prefix(checksumLength)
        var line = Data(checksum.utf8)
        line.append(0x20)   // space
        line.append(json)
        line.append(0x0a)   // newline
        return line
    }

    static func encode(_ record: ChangeRecord) throws -> Data {
        try encodeLine(record)
    }

    static func encode(_ records: [ChangeRecord]) throws -> Data {
        var out = Data()
        for record in records { out.append(try encodeLine(record)) }
        return out
    }

    // MARK: - Reading

    /// The same as `DecodeResult`, for whatever is on the lines.
    struct LineResult<T> {
        var values: [T]
        var stoppedAt: DecodeFailure?
        var goodByteCount: Int
    }

    /// Reads until something is wrong, then stops and says why.
    ///
    /// Stops rather than skips. A bad line in the middle of a segment means the
    /// file is not what it claims to be, and reading past it would be treating
    /// damaged bytes as authoritative. The tail is exactly where damage is
    /// expected, so stopping there costs the records that were being written
    /// when the drive went away — and those are re-sent on the next sync,
    /// because the sender's watermark never advanced past them.
    static func decode<T: Decodable>(_ data: Data, as type: T.Type) -> LineResult<T> {
        var values: [T] = []
        var lineNumber = 0
        var good = 0

        for line in data.split(separator: 0x0a, omittingEmptySubsequences: false) {
            // A trailing newline leaves one empty piece; that is a complete
            // file, not a damaged one.
            if line.isEmpty { continue }
            lineNumber += 1

            func stop(_ failure: DecodeFailure) -> LineResult<T> {
                LineResult(values: values, stoppedAt: failure, goodByteCount: good)
            }

            guard let separator = line.firstIndex(of: 0x20) else {
                return stop(.truncated(line: lineNumber))
            }
            let claimed = String(decoding: line[line.startIndex..<separator], as: UTF8.self)
            let json = Data(line[line.index(after: separator)...])

            let actual = Digest256.hex(Digest256.hash(json)).prefix(checksumLength)
            guard claimed == actual else { return stop(.corrupt(line: lineNumber)) }
            guard let value = try? JSONDecoder().decode(T.self, from: json) else {
                return stop(.unreadable(line: lineNumber))
            }
            values.append(value)
            // The line plus its newline, so the count always lands on a
            // boundary an append can safely continue from.
            good += line.count + 1
        }

        return LineResult(values: values, stoppedAt: nil, goodByteCount: good)
    }

    static func decode(_ data: Data) -> DecodeResult {
        let result = decode(data, as: ChangeRecord.self)
        return DecodeResult(
            records: result.values,
            stoppedAt: result.stoppedAt,
            goodByteCount: result.goodByteCount
        )
    }
}

/// What a `Sync` directory says about itself.
///
/// Read before anything else on a drive. Both versions are here because they
/// move independently: the file format can change without the catalog schema
/// changing, and once several platforms ship on their own release cycles they
/// will not stay in step.
struct SyncManifest: Codable, Equatable {
    /// The layout and line format described in `docs/SPEC-format.md` §3.
    var formatVersion: Int
    /// The catalog schema the writing device was using.
    var catalogSchemaVersion: Int64

    static let currentFormatVersion = 1

    static func current(catalogSchemaVersion: Int64) -> SyncManifest {
        SyncManifest(
            formatVersion: currentFormatVersion,
            catalogSchemaVersion: catalogSchemaVersion
        )
    }
}

/// One device's corner of a drive.
///
/// A device writes only its own file here, which is what removes the need for
/// any locking on the drive at all.
struct SyncDeviceInfo: Codable, Equatable {
    var id: String
    var name: String
    /// Not identity, and not load-bearing. It is here so a person can be told
    /// *which* device, and so a future reader knows what wrote a segment.
    var platform: String
    /// The highest stamp this device has published, so it knows where to carry
    /// on from rather than rewriting its whole history each time.
    var published: String?
    /// Peer device id → the highest stamp this device has merged from them.
    ///
    /// Published so a person, or a future tool, can see what each device has
    /// caught up on. Pruning does **not** need it: a checkpoint stands in for
    /// every segment it covers, so a device behind the checkpoint reads that
    /// instead and no reader has to be consulted before deleting.
    var seen: [String: String]

    /// The stamp below which this device's own segments no longer exist,
    /// because a checkpoint covers them.
    ///
    /// A reader whose watermark for this device is older than the floor cannot
    /// be served by the log at all and must read the checkpoint. Written
    /// **before** anything is deleted, so the claim is never behind the truth.
    var logFloor: String?

    static let platformName: String = {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(Windows)
        return "Windows"
        #elseif os(Android)
        return "Android"
        #else
        return "unknown"
        #endif
    }()
}
