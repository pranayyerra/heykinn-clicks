import Foundation

extension CatalogStore {

    func upsertTakeoutArchive(_ archive: TakeoutArchive) throws {
        try database.run("""
        INSERT INTO takeout_archives (id, path, kind, size_bytes, drive_id, discovered_at,
            imported_at, import_batch_id, imported_asset_count, skipped_duplicate_count, note,
            export_set_id, part_number, content_hash, imported_through_index, imported_file_total, quick_checksum)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            kind = excluded.kind,
            size_bytes = excluded.size_bytes,
            drive_id = excluded.drive_id,
            discovered_at = excluded.discovered_at,
            imported_at = excluded.imported_at,
            import_batch_id = excluded.import_batch_id,
            imported_asset_count = excluded.imported_asset_count,
            skipped_duplicate_count = excluded.skipped_duplicate_count,
            note = excluded.note,
            export_set_id = excluded.export_set_id,
            part_number = excluded.part_number,
            content_hash = excluded.content_hash,
            imported_through_index = excluded.imported_through_index,
            imported_file_total = excluded.imported_file_total,
            quick_checksum = excluded.quick_checksum;
        """, [
            .text(archive.id.uuidString),
            .text(archive.path),
            .text(archive.kind.rawValue),
            .int(archive.sizeBytes),
            .uuid(archive.targetID),
            .date(archive.discoveredAt),
            .date(archive.importedAt),
            .uuid(archive.importBatchID),
            .int(Int64(archive.importedAssetCount)),
            .int(Int64(archive.skippedDuplicateCount)),
            .optionalText(archive.note),
            .optionalText(archive.exportSetID),
            .optionalInt(archive.partNumber.map(Int64.init)),
            .optionalText(archive.contentHash),
            .int(Int64(archive.importedThroughIndex)),
            .int(Int64(archive.importedFileTotal)),
            .optionalText(archive.quickChecksum),
        ])
    }

    func fetchTakeoutArchives() throws -> [TakeoutArchive] {
        try database.query("""
        SELECT id, path, kind, size_bytes, drive_id, discovered_at, imported_at,
               import_batch_id, imported_asset_count, skipped_duplicate_count, note,
               export_set_id, part_number, content_hash, imported_through_index, imported_file_total, quick_checksum
        FROM takeout_archives ORDER BY discovered_at DESC;
        """) { row in
            TakeoutArchive(
                id: row.uuid(0),
                path: row.text(1),
                kind: TakeoutArchiveKind(rawValue: row.text(2)) ?? .zip,
                sizeBytes: row.int(3),
                targetID: row.optionalUUID(4),
                discoveredAt: row.date(5),
                importedAt: row.optionalDate(6),
                importBatchID: row.optionalUUID(7),
                importedAssetCount: Int(row.int(8)),
                skippedDuplicateCount: Int(row.int(9)),
                note: row.optionalText(10),
                exportSetID: row.optionalText(11),
                partNumber: row.optionalInt(12).map(Int.init),
                importedThroughIndex: Int(row.int(14)),
                importedFileTotal: Int(row.int(15)),
                contentHash: row.optionalText(13),
                quickChecksum: row.optionalText(16)
            )
        }
    }

    func deleteTakeoutArchive(id: UUID) throws {
        try database.run("DELETE FROM takeout_archives WHERE id = ?;", [.text(id.uuidString)])
    }
}
