import Foundation
import CryptoKit

/// The Mac's holding area for export parts in transit between targets.
///
/// Two managed targets are often not plugged in at the same time — one port,
/// one drive at the desk, one kept elsewhere. Without somewhere to put a part
/// in between, a part that exists only on drive A can never reach drive B, and
/// the redundancy policy stays unsatisfiable no matter how long you wait. This
/// is that somewhere: a part is copied here from the drive that has it, moved
/// onto the drive that needs it when that drive next connects, and deleted.
///
/// It is a corridor, not a home. Nothing is meant to live here, so the only
/// state is the directory listing — a file named after the part it holds.
/// A catalog restored from backup, a crash mid-copy, or someone emptying the
/// folder in Finder all leave the truth plainly on disk with nothing to
/// reconcile. Incomplete copies carry a `.partial` suffix and are never
/// mistaken for deliverable parts.
struct ExportPartRelay {
    let rootURL: URL

    static let partialSuffix = "partial"
    /// Where a delivered part lands when the receiving drive holds no other
    /// part of its export set — a waiting room, not a home. A part whose set
    /// already lives somewhere on that drive is delivered beside its siblings
    /// instead; see `AppStore.exportSetHome`.
    static let onDriveDirectoryName = ReplicationTarget.appFolderName + "/ExportParts"

    init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    static func destinationDirectory(onMount mountURL: URL) -> URL {
        mountURL.appendingPathComponent(onDriveDirectoryName, isDirectory: true)
    }

    func url(setID: String, partNumber: Int) -> URL {
        rootURL.appendingPathComponent("takeout-\(setID)-\(String(format: "%03d", partNumber)).zip")
    }

    /// Parts currently parked, newest first. Anything whose name is not a
    /// recognisable part is ignored rather than guessed at.
    func heldParts() -> [HeldExportPart] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> HeldExportPart? in
            guard url.pathExtension.lowercased() == "zip",
                  let components = TakeoutArchive.parseExportComponents(filename: url.lastPathComponent)
            else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return HeldExportPart(
                setID: components.setID,
                partNumber: components.part,
                path: url.path,
                sizeBytes: Int64(values?.fileSize ?? 0),
                stagedAt: values?.contentModificationDate ?? Date()
            )
        }
        .sorted { $0.stagedAt > $1.stagedAt }
    }

    /// Removes leftovers from an interrupted copy. Returns how many were
    /// cleared, so a restart can say what it tidied instead of silently
    /// reclaiming gigabytes.
    @discardableResult
    func discardIncompleteCopies() -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: []
        ) else { return 0 }
        var removed = 0
        for url in entries where url.pathExtension == Self.partialSuffix {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    func remove(_ part: HeldExportPart) throws {
        if FileManager.default.fileExists(atPath: part.path) {
            try FileManager.default.removeItem(at: part.url)
        }
    }

    var totalBytes: Int64 {
        heldParts().reduce(0) { $0 + $1.sizeBytes }
    }

    /// Free space on the volume the holding area sits on.
    var availableBytes: Int64 {
        TakeoutExtractor.availableCapacity(onVolumeOf: rootURL.appendingPathComponent("probe")) ?? 0
    }

    // MARK: - Copying

    enum TransferError: Error, LocalizedError {
        case sourceMissing(String)
        case notEnoughSpace(needed: Int64, available: Int64)
        case verificationFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let name):
                return "\(name) is no longer readable — the drive holding it may have been unplugged."
            case .notEnoughSpace(let needed, let available):
                let f = ByteCountFormatter.string(fromByteCount:countStyle:)
                return "Needs \(f(needed, .file)) but only \(f(available, .file)) is free."
            case .verificationFailed(let name):
                return "The copy of \(name) does not match its source and was discarded."
            case .cancelled:
                return "Transfer cancelled."
            }
        }
    }

    struct TransferOutcome {
        var destination: URL
        var sizeBytes: Int64
        /// Whole-file hash of the bytes read from the source. Free to compute
        /// while copying, and worth keeping: it is what a later byte-for-byte
        /// comparison needs, and nobody would read 10 GB twice to get it.
        var sourceHash: String
        /// Fast partial fingerprint of what actually landed, compared against
        /// the source before the copy was accepted.
        var quickChecksum: String
    }

    /// Copies one large file with progress, then checks what landed.
    ///
    /// Streams through a temporary `.partial` name and renames only on
    /// success, so an interrupted transfer never leaves a plausible-looking
    /// half a part. Verification is the quick partial checksum, not a full
    /// re-read: reading 10 GB back to prove a 10 GB write would double the
    /// cost of every transfer, and the failures that actually happen here —
    /// truncation, a disconnect mid-copy, a full disk — all change the length
    /// or the tail, which sampling sees.
    static func copyPart(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedBytes: Int64,
        isCancelled: () -> Bool = { false },
        progress: (Int64) -> Void = { _ in }
    ) throws -> TransferOutcome {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TransferError.sourceMissing(sourceURL.lastPathComponent)
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let available = TakeoutExtractor.availableCapacity(onVolumeOf: destinationURL),
           expectedBytes > 0, available < expectedBytes {
            throw TransferError.notEnoughSpace(needed: expectedBytes, available: available)
        }

        let temporary = destinationURL.appendingPathExtension(partialSuffix)
        for candidate in [temporary, destinationURL]
        where FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }

        let reader = try FileHandle(forReadingFrom: sourceURL)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let writer = try FileHandle(forWritingTo: temporary)

        var hasher = SHA256()
        var written: Int64 = 0
        do {
            while true {
                if isCancelled() { throw TransferError.cancelled }
                guard let chunk = try reader.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty else { break }
                try writer.write(contentsOf: chunk)
                hasher.update(data: chunk)
                written += Int64(chunk.count)
                progress(written)
            }
            try writer.close()
        } catch {
            try? writer.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        let landedQuick = try HashingService.quickChecksum(of: temporary)
        let sourceQuick = try HashingService.quickChecksum(of: sourceURL)
        guard landedQuick == sourceQuick else {
            try? FileManager.default.removeItem(at: temporary)
            throw TransferError.verificationFailed(destinationURL.lastPathComponent)
        }

        try FileManager.default.moveItem(at: temporary, to: destinationURL)
        return TransferOutcome(
            destination: destinationURL,
            sizeBytes: written,
            sourceHash: HashingService.hex(hasher.finalize()),
            quickChecksum: landedQuick
        )
    }
}

/// Shared control for one in-flight transfer: a cancel flag the main actor can
/// set and the copying thread can read, plus throttled progress back the other
/// way. A multi-gigabyte copy has to run off the main actor or the window
/// stops painting, so the two sides need something safe to talk through.
final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReportedBytes: Int64 = 0
    /// Bytes between progress updates. Reporting every 8 MB chunk would hop to
    /// the main actor a thousand times for one part, to move a progress bar by
    /// a pixel.
    private static let reportInterval: Int64 = 32 * 1024 * 1024

    private let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func report(_ bytes: Int64) {
        lock.lock()
        let due = bytes - lastReportedBytes >= Self.reportInterval
        if due { lastReportedBytes = bytes }
        lock.unlock()
        if due { onProgress(bytes) }
    }
}
