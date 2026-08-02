import Foundation
import CryptoKit

enum HashingService {
    /// Hex encoding for a finished digest, so callers that hash a stream
    /// themselves format the result the same way the catalog stores it.
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA-256 of a file's contents, hex-encoded.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
        var hasher = SHA256()
        // Length first: a truncated copy differs even if every sampled window
        // happens to match.
        hasher.update(data: Data(String(size).utf8))

        func absorb(offset: Int64, length: Int) throws {
            guard offset >= 0, offset < size else { return }
            try handle.seek(toOffset: UInt64(offset))
            if let chunk = try handle.read(upToCount: length), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }

        // Small files are read whole — sampling would cost more than it saves.
        let edge = Int64(quickChecksumEdgeWindow)
        guard size > edge * 2 else {
            try absorb(offset: 0, length: Int(max(size, 0)))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        try absorb(offset: 0, length: quickChecksumEdgeWindow)
        for probe in 1...quickChecksumInteriorProbes {
            let offset = size * Int64(probe) / Int64(quickChecksumInteriorProbes + 1)
            try absorb(offset: offset, length: quickChecksumInteriorWindow)
        }
        try absorb(offset: size - edge, length: quickChecksumEdgeWindow)

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum ZipEntryError: Error, LocalizedError {
        case unzipFailed(String)

        var errorDescription: String? {
            switch self {
            case .unzipFailed(let entry): return "Could not read zip entry \(entry)"
            }
        }
    }

    /// Streaming SHA-256 of one entry inside a zip, without extracting it to
    /// disk (`unzip -p` piped straight into the hasher). Lets a zip that
    /// already sits on a drive serve as verified replica storage.
    static func sha256OfZipEntry(zipURL: URL, entry: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipURL.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()

        var hasher = SHA256()
        var totalBytes = 0
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            totalBytes += chunk.count
            hasher.update(data: chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, totalBytes > 0 else {
            throw ZipEntryError.unzipFailed(entry)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
