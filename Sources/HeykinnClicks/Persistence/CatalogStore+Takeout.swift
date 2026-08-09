import Foundation

extension CatalogStore {

    func upsertTakeoutArchive(_ archive: TakeoutArchive) throws {
        try database.run("""
        INSERT INTO takeout_archives (id, path, kind, size_bytes, drive_id, discovered_at,
            imported_at, import_batch_id, imported_asset_count, skipped_duplicate_count, note,
            export_set_id, part_number, content_hash, imported_through_index, imported_file_total, quick_checksum,
            missing_since)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
            quick_checksum = excluded.quick_checksum,
            missing_since = excluded.missing_since;
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
            .date(archive.missingSince),
        ])
    }

    func fetchTakeoutArchives() throws -> [TakeoutArchive] {
        try database.query("""
        SELECT id, path, kind, size_bytes, drive_id, discovered_at, imported_at,
               import_batch_id, imported_asset_count, skipped_duplicate_count, note,
               export_set_id, part_number, content_hash, imported_through_index, imported_file_total, quick_checksum,
               missing_since
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
                quickChecksum: row.optionalText(16),
                missingSince: row.optionalDate(17)
            )
        }
    }

    func deleteTakeoutArchive(id: UUID) throws {
        try database.run("DELETE FROM takeout_archives WHERE id = ?;", [.text(id.uuidString)])
    }
}

extension CatalogStore {

    /// How many recorded copies name each mount-relative directory inside
    /// themselves, for one drive.
    ///
    /// A photo counted inside a zip records that zip's path — moving the zip
    /// without rewriting them leaves every one of those copies pointing at
    /// nothing while still reading as present. This is what lets the move be
    /// planned with that number on the table instead of discovering it after.
    func zipMemberReplicaCountsByDirectory(onTarget targetID: UUID) throws -> [String: Int] {
        let prefix = ReplicationService.zipMemberPrefix
        return try database.query("""
        SELECT relative_path FROM replica_states
        WHERE drive_id = ? AND substr(relative_path, 1, ?) = ?;
        """, [
            .text(targetID.uuidString),
            .int(Int64(prefix.count)),
            .text(prefix),
        ]) { $0.text(0) }
        .reduce(into: [:]) { counts, path in
            let payload = String(path.dropFirst(prefix.count))
            guard let bang = payload.firstIndex(of: "!") else { return }
            let zipRelative = String(payload[payload.startIndex..<bang])
            counts[(zipRelative as NSString).deletingLastPathComponent, default: 0] += 1
        }
    }

    /// Repoints every copy recorded inside a zip that has moved.
    ///
    /// A prefix swap rather than a `replace`: the old directory name could
    /// legitimately occur again further along the path — inside the zip's own
    /// entry list, after the `!` — and replacing every occurrence would corrupt
    /// the entry while fixing the location.
    @discardableResult
    func repointZipMembers(
        onTarget targetID: UUID, from oldDirectory: String, to newDirectory: String
    ) throws -> Int {
        guard oldDirectory != newDirectory else { return 0 }
        let old = ReplicationService.zipMemberPrefix + oldDirectory + "/"
        let new = ReplicationService.zipMemberPrefix + newDirectory + "/"
        let affected = try database.query("""
        SELECT count(*) FROM replica_states
        WHERE drive_id = ? AND substr(relative_path, 1, ?) = ?;
        """, [
            .text(targetID.uuidString), .int(Int64(old.count)), .text(old),
        ]) { Int($0.int(0)) }.first ?? 0
        guard affected > 0 else { return 0 }

        try database.run("""
        UPDATE replica_states
        SET relative_path = ? || substr(relative_path, ?)
        WHERE drive_id = ? AND substr(relative_path, 1, ?) = ?;
        """, [
            .text(new),
            .int(Int64(old.count + 1)),
            .text(targetID.uuidString),
            .int(Int64(old.count)),
            .text(old),
        ])
        return affected
    }
}
