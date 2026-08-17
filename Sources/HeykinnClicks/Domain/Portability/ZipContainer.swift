import Foundation

/// The structure of a zip file: what is inside it and where each piece begins.
///
/// **Parsing only — nothing here decompresses.** That split is the point. The
/// container format is a handful of little-endian records that any language can
/// read, and it is the part that has to be identical everywhere; inflating the
/// bytes is supplied by the platform (`Inflate`). Keeping them apart is what
/// makes this file portable and the other one small.
///
/// **Why this exists at all.** Entries were listed by running `unzip -Z1` and
/// read by running `unzip -p`. `unzip` replaces every byte of a non-ASCII name
/// with a literal `?` in its listing — and `?` is its own single-character
/// wildcard, so feeding that name back finds nothing. On a real Google export
/// that is not exotic: a Mac screenshot carries a narrow no-break space, and the
/// round trip exits 11 with no output. The caller reads that as "this copy is
/// missing" for a photograph sitting on the drive.
///
/// Names here come from the file's own bytes and are decoded exactly once, so
/// there is no round trip to lose them in.
struct ZipContainer {

    struct Entry: Equatable {
        /// The name as recorded, decoded per the flag the archive set.
        var name: String
        /// 0 = stored, 8 = deflate. Others are refused rather than guessed at.
        var method: UInt16
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        /// Where this entry's *local* header starts. The data does not begin
        /// here — the local header's own name and extra lengths must be read,
        /// because they are allowed to differ from the central directory's.
        var localHeaderOffset: UInt64

        var isDirectory: Bool { name.hasSuffix("/") }

        static let stored: UInt16 = 0
        static let deflated: UInt16 = 8
    }

    enum ReadError: Error, LocalizedError {
        case notAZipFile
        case truncated(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notAZipFile:
                return "This file does not look like a zip archive."
            case .truncated(let what):
                return "The zip archive ends part way through its \(what)."
            case .unsupported(let what):
                return "This zip archive uses \(what), which this app cannot read."
            }
        }
    }

    // Signatures, little-endian on disk.
    private static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    private static let zip64Locator: UInt32 = 0x0706_4b50
    private static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4b50
    private static let centralFileHeader: UInt32 = 0x0201_4b50
    private static let localFileHeader: UInt32 = 0x0403_4b50

    /// Bit 11 of the general purpose flags: the name is UTF-8.
    private static let utf8NameFlag: UInt16 = 0x0800

    let entries: [Entry]

    // MARK: - Reading the directory

    /// Reads the central directory. Seeks rather than loading the archive —
    /// these are routinely tens of gigabytes.
    init(readingFrom handle: FileHandle, fileLength: UInt64) throws {
        let eocd = try Self.findEndOfCentralDirectory(handle, fileLength: fileLength)

        var directoryOffset = UInt64(eocd.record.u32(at: 16))
        var entryCount = UInt64(eocd.record.u16(at: 10))

        // 0xFFFF / 0xFFFFFFFF mean "look in the zip64 record". A Takeout part
        // can exceed both limits, so this is the ordinary path, not a corner.
        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
            let zip64 = try Self.readZip64Directory(handle, eocdOffset: eocd.offset)
            entryCount = zip64.entryCount
            directoryOffset = zip64.directoryOffset
        }

        try handle.seek(toOffset: directoryOffset)
        guard let directory = try handle.readToEnd() else {
            throw ReadError.truncated("central directory")
        }

        var found: [Entry] = []
        found.reserveCapacity(Int(min(entryCount, 100_000)))
        var cursor = 0

        while cursor + 46 <= directory.count, directory.u32(at: cursor) == Self.centralFileHeader {
            let flags = directory.u16(at: cursor + 8)
            let nameLength = Int(directory.u16(at: cursor + 28))
            let extraLength = Int(directory.u16(at: cursor + 30))
            let commentLength = Int(directory.u16(at: cursor + 32))
            let headerEnd = cursor + 46 + nameLength + extraLength + commentLength
            guard headerEnd <= directory.count else {
                throw ReadError.truncated("central directory")
            }

            let nameBytes = directory.slice(at: cursor + 46, count: nameLength)
            let extra = directory.slice(at: cursor + 46 + nameLength, count: extraLength)

            var entry = Entry(
                name: Self.decodeName(nameBytes, flags: flags),
                method: directory.u16(at: cursor + 10),
                crc32: directory.u32(at: cursor + 16),
                compressedSize: UInt64(directory.u32(at: cursor + 20)),
                uncompressedSize: UInt64(directory.u32(at: cursor + 24)),
                localHeaderOffset: UInt64(directory.u32(at: cursor + 42))
            )
            Self.applyZip64Extra(extra, to: &entry)
            found.append(entry)

            cursor = headerEnd
        }

        entries = found
    }

    /// Where an entry's bytes actually start, which needs the local header —
    /// its name and extra lengths may differ from the central directory's, and
    /// trusting the directory's is a classic way to read one entry's data as
    /// another's.
    static func dataOffset(of entry: Entry, in handle: FileHandle) throws -> UInt64 {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30 else {
            throw ReadError.truncated("local header")
        }
        guard header.u32(at: 0) == localFileHeader else { throw ReadError.notAZipFile }
        let nameLength = UInt64(header.u16(at: 26))
        let extraLength = UInt64(header.u16(at: 28))
        return entry.localHeaderOffset + 30 + nameLength + extraLength
    }

    // MARK: - Locating the records

    private static func findEndOfCentralDirectory(
        _ handle: FileHandle, fileLength: UInt64
    ) throws -> (record: Data, offset: UInt64) {
        // The record is last, but a trailing comment of up to 65,535 bytes may
        // follow it, so the tail has to be scanned backwards.
        let window = UInt64(min(fileLength, 22 + 65_535))
        guard window >= 22 else { throw ReadError.notAZipFile }
        let start = fileLength - window
        try handle.seek(toOffset: start)
        guard let tail = try handle.read(upToCount: Int(window)), tail.count >= 22 else {
            throw ReadError.notAZipFile
        }

        var index = tail.count - 22
        while index >= 0 {
            if tail.u32(at: index) == endOfCentralDirectory {
                return (tail.slice(at: index, count: tail.count - index), start + UInt64(index))
            }
            index -= 1
        }
        throw ReadError.notAZipFile
    }

    private static func readZip64Directory(
        _ handle: FileHandle, eocdOffset: UInt64
    ) throws -> (entryCount: UInt64, directoryOffset: UInt64) {
        guard eocdOffset >= 20 else { throw ReadError.truncated("zip64 locator") }
        try handle.seek(toOffset: eocdOffset - 20)
        guard let locator = try handle.read(upToCount: 20), locator.count == 20,
              locator.u32(at: 0) == zip64Locator
        else { throw ReadError.truncated("zip64 locator") }

        let recordOffset = locator.u64(at: 8)
        try handle.seek(toOffset: recordOffset)
        guard let record = try handle.read(upToCount: 56), record.count == 56,
              record.u32(at: 0) == zip64EndOfCentralDirectory
        else { throw ReadError.truncated("zip64 end of central directory") }

        return (entryCount: record.u64(at: 32), directoryOffset: record.u64(at: 48))
    }

    /// Fills in the real sizes and offset when the 32-bit fields said
    /// "see the zip64 extra field". Order is fixed and only the overflowed
    /// fields are present, so this has to track which ones it is expecting.
    private static func applyZip64Extra(_ extra: Data, to entry: inout Entry) {
        var cursor = 0
        while cursor + 4 <= extra.count {
            let headerID = extra.u16(at: cursor)
            let size = Int(extra.u16(at: cursor + 2))
            let body = cursor + 4
            guard body + size <= extra.count else { return }

            if headerID == 0x0001 {
                var field = body
                if entry.uncompressedSize == 0xFFFF_FFFF, field + 8 <= body + size {
                    entry.uncompressedSize = extra.u64(at: field); field += 8
                }
                if entry.compressedSize == 0xFFFF_FFFF, field + 8 <= body + size {
                    entry.compressedSize = extra.u64(at: field); field += 8
                }
                if entry.localHeaderOffset == 0xFFFF_FFFF, field + 8 <= body + size {
                    entry.localHeaderOffset = extra.u64(at: field)
                }
                return
            }
            cursor = body + size
        }
    }

    /// Bit 11 says the name is UTF-8. Without it the format says CP437, but
    /// every archiver worth reading writes UTF-8 anyway, so UTF-8 is tried
    /// first and the legacy interpretation is the fallback rather than the
    /// other way round.
    private static func decodeName(_ bytes: Data, flags: UInt16) -> String {
        if flags & utf8NameFlag != 0, let name = String(data: bytes, encoding: .utf8) {
            return name
        }
        if let name = String(data: bytes, encoding: .utf8) { return name }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Little-endian reads

private extension Data {
    /// `Data` slices keep their parent's indices, so every read here is
    /// relative to the slice's own start. Getting that wrong reads the right
    /// bytes from the wrong place, which a zip parser does silently.
    func byte(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func u16(at offset: Int) -> UInt16 {
        guard startIndex + offset + 2 <= endIndex else { return 0 }
        return UInt16(byte(at: offset)) | (UInt16(byte(at: offset + 1)) << 8)
    }

    func u32(at offset: Int) -> UInt32 {
        guard startIndex + offset + 4 <= endIndex else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(byte(at: offset + $1)) << (8 * UInt32($1))) }
    }

    func u64(at offset: Int) -> UInt64 {
        guard startIndex + offset + 8 <= endIndex else { return 0 }
        return (0..<8).reduce(UInt64(0)) { $0 | (UInt64(byte(at: offset + $1)) << (8 * UInt64($1))) }
    }

    func slice(at offset: Int, count: Int) -> Data {
        let lower = startIndex + offset
        let upper = Swift.min(lower + count, endIndex)
        guard lower <= upper else { return Data() }
        return self[lower..<upper]
    }
}
