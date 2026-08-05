import Foundation

/// The sweep memo: what each path looked like the last time it was read.
///
/// Deliberately its own table and its own file. It is a cache — it records
/// nothing about the archive, only about how expensive it would be to look at
/// the same folder again — and everything here is written so that losing the
/// whole table costs one slow sweep and nothing else.
extension CatalogStore {

    func fetchScanMemo() throws -> [String: ScanMemoEntry] {
        let entries: [ScanMemoEntry] = try database.query("""
        SELECT path, size, modified_at, content_hash, seen_at FROM import_scan_memo;
        """) { row in
            ScanMemoEntry(
                path: row.text(0),
                size: row.int(1),
                modifiedAt: row.date(2),
                contentHash: row.text(3),
                seenAt: row.date(4)
            )
        }
        return Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func upsertScanMemo(_ entries: [ScanMemoEntry]) throws {
        guard !entries.isEmpty else { return }
        // One transaction for the batch: a sweep of a large folder writes tens
        // of thousands of these, and a commit each would cost more than the
        // hashing they exist to avoid.
        try transaction {
            for entry in entries {
                try database.run("""
                INSERT INTO import_scan_memo (path, size, modified_at, content_hash, seen_at)
                VALUES (?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET
                    size = excluded.size,
                    modified_at = excluded.modified_at,
                    content_hash = excluded.content_hash,
                    seen_at = excluded.seen_at;
                """, [
                    .text(entry.path),
                    .int(entry.size),
                    .date(entry.modifiedAt),
                    .text(entry.contentHash),
                    .date(entry.seenAt),
                ])
            }
        }
    }

    /// Drops notes about paths nothing has looked at in a long time — folders
    /// that were imported once from a drive since put away, or deleted.
    func pruneScanMemo(before cutoff: Date) throws {
        try database.run(
            "DELETE FROM import_scan_memo WHERE seen_at < ?;",
            [.date(cutoff)]
        )
    }
}
