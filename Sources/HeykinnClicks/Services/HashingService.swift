import Foundation

/// The recorded fingerprints of files on disk.
///
/// Both values here are **specified**, not merely implemented — see
/// `docs/SPEC-hashing.md`. They are written into the catalog and compared
/// later, including against values a different platform may one day compute, so
/// the constants and the window layout below are the format rather than tuning.
///
/// Hashing goes through `Digest256`, which picks the fastest SHA-256 the
/// platform offers. Nothing in this file is Apple-specific any more: the last
/// piece that was, `sha256OfZipEntry`, reads through `ZipReader` rather than
/// piping `unzip -p`.
enum HashingService {
    /// Hex encoding for a finished digest, so callers that hash a stream
    /// themselves format the result the same way the catalog stores it.
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        Digest256.hex(digest)
    }

    /// Streaming SHA-256 of a file's contents, hex-encoded.
    ///
    /// Contents only — never the name, size, or any filesystem metadata. See
    /// SPEC-hashing §2 for why.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Digest256.Streaming()
        while true {
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }

    /// Bytes sampled from the head and tail of a file.
    static let quickChecksumEdgeWindow = 2 * 1024 * 1024
    /// Bytes sampled at each interior probe point.
    static let quickChecksumInteriorWindow = 512 * 1024
    /// How many interior points are sampled between head and tail.
    static let quickChecksumInteriorProbes = 6

    /// A fast, deliberately partial fingerprint: the file's length plus a few
    /// fixed windows read from it.
    ///
    /// Reads a handful of megabytes instead of the whole file, so comparing
    /// two 10 GB archives takes seconds rather than minutes. It catches the
    /// failures that actually happen to archive copies — truncation, a partial
    /// transfer, the wrong file under the right name, corruption at the start
    /// or end — but it cannot see a flipped bit between the sampled windows.
    /// Matching quick checksums mean "almost certainly the same file", never
    /// "proven identical"; only a full hash can say that.
    static func quickChecksum(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var hasher = Digest256.Streaming()
        // Length first: a truncated copy differs even if every sampled window
        // happens to match.
        hasher.update(Data(String(size).utf8))

        func absorb(offset: Int64, length: Int) throws {
            guard offset >= 0, offset < size else { return }
            try handle.seek(toOffset: UInt64(offset))
            if let chunk = try handle.read(upToCount: length), !chunk.isEmpty {
                hasher.update(chunk)
            }
        }

        // Small files are read whole — sampling would cost more than it saves.
        let edge = Int64(quickChecksumEdgeWindow)
        guard size > edge * 2 else {
            try absorb(offset: 0, length: Int(max(size, 0)))
            return hasher.finalizeHex()
        }

        try absorb(offset: 0, length: quickChecksumEdgeWindow)
        for probe in 1...quickChecksumInteriorProbes {
            let offset = size * Int64(probe) / Int64(quickChecksumInteriorProbes + 1)
            try absorb(offset: offset, length: quickChecksumInteriorWindow)
        }
        try absorb(offset: size - edge, length: quickChecksumEdgeWindow)

        return hasher.finalizeHex()
    }

    enum ZipEntryError: Error, LocalizedError {
        case unreadableEntry(String)

        var errorDescription: String? {
            switch self {
            case .unreadableEntry(let entry): return "Could not read zip entry \(entry)"
            }
        }
    }

    /// Streaming SHA-256 of one entry inside a zip, without extracting it to
    /// disk. Lets a zip that already sits on a drive serve as verified replica
    /// storage.
    ///
    /// **This used to be the one thing in this file that did not port**, piping
    /// `unzip -p` into the hasher — a program absent from Windows and Android,
    /// and a subprocess per entry besides. It reads through `ZipReader` now, so
    /// the only platform-specific part left is inflate, which every target
    /// supplies. See H3 in `docs/MULTI_DEVICE_STATE.md`.
    ///
    /// The value produced was always ordinary — the content hash of §2, of bytes
    /// that happen to live inside an archive — so nothing about the *format*
    /// changed when the reader did.
    static func sha256OfZipEntry(zipURL: URL, entry: String) throws -> String {
        let reader = try ZipReader(url: zipURL)
        defer { reader.close() }
        guard let member = reader.entry(named: entry) else {
            throw ZipEntryError.unreadableEntry(entry)
        }

        var hasher = Digest256.Streaming()
        var totalBytes = 0
        try reader.read(member) { chunk in
            totalBytes += chunk.count
            hasher.update(chunk)
        }
        // An entry that is genuinely empty is legal; one that produced nothing
        // when the directory said it holds bytes is not, and must not be
        // recorded as a verified copy of nothing.
        guard totalBytes > 0 || member.uncompressedSize == 0 else {
            throw ZipEntryError.unreadableEntry(entry)
        }
        return hasher.finalizeHex()
    }
}
