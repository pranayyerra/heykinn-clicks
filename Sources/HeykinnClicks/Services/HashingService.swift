import Foundation
import CryptoKit

enum HashingService {
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
