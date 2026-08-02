import Foundation

/// Extracts a Takeout zip in place on its drive, next to the zip, into a
/// folder named zip-name-minus-.zip (`takeout-<session>-<part>`) — the
/// convention the scanner groups into export sets. The zip is never modified:
/// it remains the pristine original; the folder exists to make imports fast
/// (no per-import extraction to Mac scratch space) and is safe to delete
/// after replication.
enum TakeoutExtractor {

    enum ExtractionError: Error, LocalizedError {
        case destinationExists(String)
        case insufficientFreeSpace(needed: Int64, available: Int64)
        case dittoFailed(String)

        var errorDescription: String? {
            switch self {
            case .destinationExists(let path):
                return "Extraction target already exists: \(path)"
            case .insufficientFreeSpace(let needed, let available):
                return "Not enough free space on the drive: need about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available."
            case .dittoFailed(let message):
                return "Extraction failed: \(message)"
            }
        }
    }

    static func destinationURL(forZip zipURL: URL) -> URL {
        zipURL.deletingPathExtension()
    }

    /// Best available free-space reading, or nil when the volume can't say.
    /// `volumeAvailableCapacityForImportantUsage` is APFS-oriented and reports
    /// 0 on ExFAT/NTFS externals, so a zero there falls through to the plain
    /// capacity key rather than being trusted.
    static func availableCapacity(onVolumeOf url: URL) -> Int64? {
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let plain = values?.volumeAvailableCapacity, plain > 0 {
            return Int64(plain)
        }
        return nil
    }

    /// Interruption-safe: extracts into a `.extracting` temp directory beside
    /// the target, then renames into place, so a crash mid-extract leaves an
    /// obviously-partial directory (cleaned up on retry), never a
    /// plausible-looking incomplete folder.
    static func extractInPlace(zipURL: URL) throws -> URL {
        let destination = destinationURL(forZip: zipURL)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExtractionError.destinationExists(destination.path)
        }

        let zipSize = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int64) ?? 0
        // Takeout zips hold already-compressed media, so the extracted size is
        // roughly the zip size; require a small margin on top. An unknown
        // reading never blocks extraction — the temp-dir + rename flow is
        // interruption-safe and ditto fails cleanly if the disk truly fills.
        let needed = zipSize + zipSize / 20 + 100_000_000
        if let available = availableCapacity(onVolumeOf: zipURL), available < needed {
            throw ExtractionError.insufficientFreeSpace(needed: needed, available: available)
        }

        let temporary = destination.appendingPathExtension("extracting")
        if FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        do {
            let workers = ParallelZipExtraction.recommendedWorkerCount(destination: temporary)
            try ParallelZipExtraction.extract(zipURL: zipURL, into: temporary, workers: workers)
        } catch {
            // Parallel path failed (unreadable listing, worker error): fall
            // back to single-process ditto before giving up.
            try? FileManager.default.removeItem(at: temporary)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try dittoExtract(zipURL: zipURL, into: temporary)
        }

        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    static func dittoExtract(zipURL: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            try? FileManager.default.removeItem(at: destination)
            throw ExtractionError.dittoFailed(message)
        }
    }
}
