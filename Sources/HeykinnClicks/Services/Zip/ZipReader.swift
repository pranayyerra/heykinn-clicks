import Foundation

/// Reads entries out of a zip without running another program.
///
/// The container is parsed by `ZipContainer`, which is portable; the only
/// platform-specific part is inflating, and every target platform supplies it —
/// `Compression` on Apple, zlib on Windows, `java.util.zip.Inflater` on
/// Android. That is why this was never the large piece of work it looked like:
/// the hard algorithm is already there, and what had to be written is the
/// container parse.
///
/// **What it replaces.** `unzip -Z1` to list and `unzip -p` to read. Those
/// mangle every non-ASCII byte in a name to a literal `?`, and `?` is unzip's
/// own wildcard, so the round trip fails — measured as exit 11 with no output
/// on a real Google export. The callers read that as a missing copy, so a
/// photograph sitting on a drive was reported as not there.
struct ZipReader {

    let url: URL
    private let handle: FileHandle
    private let container: ZipContainer

    /// Every file entry, directories excluded, in the order the archive lists
    /// them.
    var entries: [ZipContainer.Entry] { container.entries.filter { !$0.isDirectory } }
    var names: [String] { entries.map(\.name) }

    init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let length = try handle.seekToEnd()
        container = try ZipContainer(readingFrom: handle, fileLength: length)
    }

    func close() { try? handle.close() }

    func entry(named name: String) -> ZipContainer.Entry? {
        entries.first { $0.name == name }
    }

    // MARK: - Reading one entry

    /// Streams an entry's decompressed bytes, a chunk at a time.
    ///
    /// Streamed rather than returned whole because a single entry can be a
    /// video of any size, and the callers here are hashing rather than holding.
    func read(_ entry: ZipContainer.Entry, into receive: (Data) throws -> Void) throws {
        let start = try ZipContainer.dataOffset(of: entry, in: handle)
        try handle.seek(toOffset: start)

        switch entry.method {
        case ZipContainer.Entry.stored:
            var remaining = entry.compressedSize
            while remaining > 0 {
                let want = Int(min(remaining, 1 << 20))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
                try receive(chunk)
                remaining -= UInt64(chunk.count)
            }

        case ZipContainer.Entry.deflated:
            try Inflate.stream(
                reading: { try handle.read(upToCount: $0) ?? Data() },
                compressedSize: entry.compressedSize,
                into: receive
            )

        default:
            throw ZipContainer.ReadError.unsupported("compression method \(entry.method)")
        }
    }

    /// The whole entry in memory. For sidecars and other small things.
    func data(for entry: ZipContainer.Entry) throws -> Data {
        var out = Data()
        out.reserveCapacity(Int(min(entry.uncompressedSize, 32 << 20)))
        try read(entry) { out.append($0) }
        return out
    }
}
