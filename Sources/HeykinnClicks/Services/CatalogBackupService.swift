import Foundation

/// A catalog snapshot found on a drive.
struct CatalogSnapshot: Identifiable, Hashable {
    var url: URL
    var createdAt: Date
    var sizeBytes: Int64
    var driveID: UUID?

    var id: String { url.path }
    var displayName: String { url.lastPathComponent }
}

/// Writes verified point-in-time copies of the catalog onto the managed
/// drives.
///
/// The catalog is the one thing in the system that cannot be re-derived
/// cheaply: the media survives on the drives, but residency, replica state,
/// duplicate grouping, and import history exist only in SQLite. Snapshots ride
/// along with the archive they describe, so losing the Mac does not lose the
/// metadata.
enum CatalogBackupService {

    /// Directory at a drive's root holding snapshots. Deliberately outside the
    /// replica root so replica cleanup can never remove the backups.
    static let directoryName = "HeykinnClicksCatalogBackups"
    /// Snapshots retained per drive; older ones are pruned oldest-first.
    static let retainCount = 5

    enum BackupError: Error, LocalizedError {
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .verificationFailed(let detail):
                return "Catalog snapshot failed verification: \(detail)"
            }
        }
    }

    static func backupDirectory(onMount mountURL: URL) -> URL {
        mountURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Snapshots the catalog to the drive, verifies the copy is a readable
    /// SQLite database with the expected contents, then prunes old snapshots.
    /// Returns the snapshot that was written.
    @discardableResult
    static func writeSnapshot(
        from catalog: CatalogStore,
        toMount mountURL: URL,
        driveID: UUID?,
        expectedAssetCount: Int,
        now: Date = Date()
    ) throws -> CatalogSnapshot {
        let directory = backupDirectory(onMount: mountURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Write under a temporary name and rename only after verification, so
        // a partial or corrupt snapshot never sits among the good ones.
        let stamp = stampFormatter.string(from: now)
        let finalURL = directory.appendingPathComponent("catalog-\(stamp).sqlite")
        let temporaryURL = directory.appendingPathComponent("catalog-\(stamp).sqlite.writing")
        for candidate in [finalURL, temporaryURL] where FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }

        // VACUUM INTO takes a consistent snapshot even while the catalog is in
        // use, and compacts it in the process.
        try catalog.vacuumInto(path: temporaryURL.path)
        try verify(snapshotAt: temporaryURL, expectedAssetCount: expectedAssetCount)
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

        let size = Int64((try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        pruneOldSnapshots(in: directory)
        return CatalogSnapshot(url: finalURL, createdAt: now, sizeBytes: size, driveID: driveID)
    }

    /// Opens the snapshot as a database and confirms it is intact and complete.
    /// A backup that has never been read back is only a hope.
    static func verify(snapshotAt url: URL, expectedAssetCount: Int) throws {
        // Read-only: verification must never write to the backup.
        let probe = try SQLiteDatabase(path: url.path, readOnly: true)
        let integrity = try probe.query("PRAGMA integrity_check;") { $0.text(0) }
        guard integrity.first == "ok" else {
            throw BackupError.verificationFailed(integrity.first ?? "unreadable")
        }
        let counted = try probe.query("SELECT count(*) FROM assets;") { $0.int(0) }.first ?? 0
        guard counted >= Int64(expectedAssetCount) else {
            throw BackupError.verificationFailed(
                "holds \(counted) assets, expected at least \(expectedAssetCount)"
            )
        }
    }

    static func listSnapshots(onMount mountURL: URL, driveID: UUID?) -> [CatalogSnapshot] {
        let directory = backupDirectory(onMount: mountURL)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "sqlite" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return CatalogSnapshot(
                    url: url,
                    createdAt: values?.contentModificationDate ?? .distantPast,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    driveID: driveID
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Keeps the newest `retainCount` snapshots and any stray `.writing`
    /// leftovers are cleared too.
    static func pruneOldSnapshots(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        // Clears partial writes and any journal files left beside them
        // (`.writing`, `.writing-wal`, `.writing-shm`).
        for leftover in entries where leftover.lastPathComponent.contains(".writing") {
            try? FileManager.default.removeItem(at: leftover)
        }
        let snapshots = entries
            .filter { $0.pathExtension == "sqlite" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        for stale in snapshots.dropFirst(retainCount) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
