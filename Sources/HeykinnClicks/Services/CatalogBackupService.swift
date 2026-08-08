import Foundation

/// A catalog snapshot found on a drive.
struct CatalogSnapshot: Identifiable, Hashable {
    var url: URL
    var createdAt: Date
    var sizeBytes: Int64
    var targetID: UUID?

    var id: String { url.path }
    var displayName: String { url.lastPathComponent }
}

/// Writes verified point-in-time copies of the catalog onto the managed
/// targets.
///
/// The catalog is the one thing in the system that cannot be re-derived
/// cheaply: the media survives on the targets, but residency, replica state,
/// duplicate grouping, and import history exist only in SQLite. Snapshots ride
/// along with the archive they describe, so losing the Mac does not lose the
/// metadata.
enum CatalogBackupService {

    /// Directory holding snapshots. Beside the replica root under the app's
    /// folder, deliberately not *inside* it, so replica cleanup can never
    /// remove the backups.
    static let directoryName = ReplicationTarget.appFolderName + "/CatalogBackups"
    /// Snapshots retained per drive; older ones are pruned oldest-first.
    ///
    /// Three rather than more because a snapshot is only written when a drive
    /// is actually connected and the newest on it is over an hour old — so
    /// three is roughly three times the drive was plugged in, not three hours.
    /// On a real archive the five held spanned a day and a half.
    ///
    /// What retention buys is a way back from a catalog that went wrong without
    /// anyone noticing. It does not buy safety from losing the Mac: any one
    /// good snapshot does that, and there is a copy on every drive.
    static let retainCount = 3

    enum BackupError: Error, LocalizedError {
        case verificationFailed(String)
        case incomplete(tables: [String])
        case accessBlocked(volumeName: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .verificationFailed(let detail):
                return "Catalog snapshot failed verification: \(detail)"
            case .incomplete(let tables):
                return """
                Catalog snapshot is missing everything this archive knows about \
                \(tables.joined(separator: ", ")). The copy is readable and holds the photos' \
                records, so it would have looked fine — it simply does not contain that.
                """
            case .accessBlocked(let volumeName, let underlying):
                return """
                Could not write to \(volumeName): the volume is mounted and has room, but this app \
                cannot write to it. macOS gates access to external volumes — grant it under System \
                Settings → Privacy & Security → Files and Folders, then try again. (\(underlying))
                """
            }
        }
    }

    /// Distinguishes "macOS is blocking this app from the volume" from a
    /// genuine storage failure.
    ///
    /// SQLite reports a blocked destination as `unable to open database`, which
    /// reads like corruption and sends you looking at the wrong thing. The
    /// difference is observable: try to create a file next to where the
    /// snapshot would go. If that fails too on a volume that is mounted and
    /// writable by other processes, the app is being denied, not the disk.
    private static func classify(_ error: Error, writingInto directory: URL, mountURL: URL) -> Error {
        let probe = directory.appendingPathComponent(".heykinn-write-probe")
        do {
            try Data().write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
            return error
        } catch {
            return BackupError.accessBlocked(
                volumeName: mountURL.lastPathComponent,
                underlying: error.localizedDescription
            )
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
        targetID: UUID?,
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
        // Asked before the copy, so the snapshot is measured against what the
        // catalog actually held rather than against a list written once.
        let populated = (try? catalog.nonEmptyTables()) ?? []
        do {
            try catalog.vacuumInto(path: temporaryURL.path)
        } catch {
            throw classify(error, writingInto: directory, mountURL: mountURL)
        }
        try verify(
            snapshotAt: temporaryURL,
            expectedAssetCount: expectedAssetCount,
            mustHoldRowsIn: populated
        )
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

        let size = Int64((try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        pruneOldSnapshots(in: directory)
        return CatalogSnapshot(url: finalURL, createdAt: now, sizeBytes: size, targetID: targetID)
    }

    /// Opens the snapshot as a database and confirms it is intact and complete.
    /// A backup that has never been read back is only a hope.
    ///
    /// "Complete" once meant the right number of assets, which was true when the
    /// catalog was assets and replicas. It stopped being true. A real snapshot
    /// passed this check today holding all 24,639 assets and **none** of the
    /// 24,417 provider payloads captured beside them — the `asset_tags` table
    /// was not even present — and was written into the audit log as verified.
    /// The one part of the catalog that cannot be rebuilt without re-reading
    /// 127 GB of export zips was the part nobody was checking for.
    ///
    /// So the test is now the general one: **no kind of knowledge may go
    /// missing.** Any table the live catalog holds rows in must hold rows here
    /// too. Row counts are deliberately not compared — tables legitimately
    /// shrink, and a snapshot that is a few rows behind a moving catalog is
    /// fine. A whole category silently absent is not.
    static func verify(
        snapshotAt url: URL,
        expectedAssetCount: Int,
        mustHoldRowsIn populated: Set<String> = []
    ) throws {
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

        let present = Set(try probe.query(
            "SELECT name FROM sqlite_master WHERE type = 'table';"
        ) { $0.text(0) })
        var missing: [String] = []
        for table in populated.sorted() {
            guard present.contains(table) else { missing.append(table); continue }
            let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
            let rows = try probe.query("SELECT count(*) FROM \"\(escaped)\";") { $0.int(0) }
            if (rows.first ?? 0) == 0 { missing.append(table) }
        }
        guard missing.isEmpty else { throw BackupError.incomplete(tables: missing) }
    }

    static func listSnapshots(onMount mountURL: URL, targetID: UUID?) -> [CatalogSnapshot] {
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
                    targetID: targetID
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
