import Foundation

/// The canonical catalog, hosted on the Mac. Every fact the system relies on —
/// residency, replica state, backlog, policies, migrations, audit history —
/// lives here, so the Mac never needs a drive attached to know system state.
final class CatalogStore {
    let database: SQLiteDatabase

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    init(databasePath: String) throws {
        database = try SQLiteDatabase(path: databasePath)
        try createSchema()
    }

    private func createSchema() throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS assets (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            original_filename TEXT NOT NULL,
            import_origin TEXT NOT NULL,
            capture_date REAL,
            import_date REAL NOT NULL,
            updated_date REAL NOT NULL,
            file_size INTEGER NOT NULL,
            pixel_width INTEGER,
            pixel_height INTEGER,
            content_hash TEXT NOT NULL,
            residency TEXT NOT NULL,
            residency_source TEXT NOT NULL,
            presence_local INTEGER NOT NULL DEFAULT 0,
            presence_apple INTEGER NOT NULL DEFAULT 0,
            presence_google INTEGER NOT NULL DEFAULT 0,
            staging_relpath TEXT,
            import_batch_id TEXT,
            exif_json TEXT,
            cloud_evidence TEXT,
            cloud_checked_at REAL,
            live_photo_still_id TEXT,
            live_photo_checked_at REAL
        );

        CREATE INDEX IF NOT EXISTS idx_assets_hash ON assets(content_hash);

        CREATE TABLE IF NOT EXISTS asset_variants (
            id TEXT PRIMARY KEY,
            asset_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            file_size INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS drives (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            volume_uuid TEXT,
            marker_token TEXT NOT NULL,
            registered_at REAL NOT NULL,
            last_seen_at REAL,
            replica_root TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS replica_states (
            asset_id TEXT NOT NULL,
            drive_id TEXT NOT NULL,
            state TEXT NOT NULL,
            relative_path TEXT,
            last_verified_at REAL,
            PRIMARY KEY (asset_id, drive_id)
        );

        CREATE TABLE IF NOT EXISTS replication_tasks (
            id TEXT PRIMARY KEY,
            asset_id TEXT NOT NULL,
            drive_id TEXT NOT NULL,
            action TEXT NOT NULL,
            state TEXT NOT NULL,
            queued_at REAL NOT NULL,
            completed_at REAL,
            error_message TEXT
        );

        CREATE TABLE IF NOT EXISTS policy_rules (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            priority INTEGER NOT NULL,
            enabled INTEGER NOT NULL,
            match_origin TEXT,
            match_kind TEXT,
            min_file_size INTEGER,
            target_residency TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS migration_jobs (
            id TEXT PRIMARY KEY,
            asset_ids_json TEXT NOT NULL,
            from_domain TEXT NOT NULL,
            to_domain TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            note TEXT
        );

        CREATE TABLE IF NOT EXISTS import_batches (
            id TEXT PRIMARY KEY,
            source_path TEXT NOT NULL,
            started_at REAL NOT NULL,
            completed_at REAL,
            imported_count INTEGER NOT NULL DEFAULT 0,
            duplicate_count INTEGER NOT NULL DEFAULT 0,
            failed_count INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS takeout_archives (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            kind TEXT NOT NULL,
            size_bytes INTEGER NOT NULL DEFAULT 0,
            drive_id TEXT,
            discovered_at REAL NOT NULL,
            imported_at REAL,
            import_batch_id TEXT,
            imported_asset_count INTEGER NOT NULL DEFAULT 0,
            skipped_duplicate_count INTEGER NOT NULL DEFAULT 0,
            note TEXT,
            export_set_id TEXT,
            part_number INTEGER,
            imported_through_index INTEGER NOT NULL DEFAULT 0,
            imported_file_total INTEGER NOT NULL DEFAULT 0
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_takeout_path ON takeout_archives(path);

        CREATE TABLE IF NOT EXISTS audit_events (
            id TEXT PRIMARY KEY,
            at REAL NOT NULL,
            category TEXT NOT NULL,
            message TEXT NOT NULL,
            asset_id TEXT,
            drive_id TEXT
        );
        """)

        // Additive migrations for catalogs created before these columns
        // existed; "duplicate column" failures on fresh databases are expected.
        try? database.exec("ALTER TABLE takeout_archives ADD COLUMN export_set_id TEXT;")
        try? database.exec("ALTER TABLE takeout_archives ADD COLUMN part_number INTEGER;")
        try? database.exec("ALTER TABLE takeout_archives ADD COLUMN content_hash TEXT;")
        try? database.exec("ALTER TABLE assets ADD COLUMN cloud_evidence TEXT;")
        try? database.exec("ALTER TABLE assets ADD COLUMN cloud_checked_at REAL;")
        try? database.exec("ALTER TABLE takeout_archives ADD COLUMN imported_through_index INTEGER NOT NULL DEFAULT 0;")
        try? database.exec("ALTER TABLE takeout_archives ADD COLUMN imported_file_total INTEGER NOT NULL DEFAULT 0;")
        try? database.exec("ALTER TABLE assets ADD COLUMN live_photo_still_id TEXT;")
        try? database.exec("ALTER TABLE assets ADD COLUMN live_photo_checked_at REAL;")
    }

    /// Writes a consistent, compacted copy of the whole catalog to `path`.
    /// Safe to run while the catalog is in use; the destination must not exist.
    func vacuumInto(path: String) throws {
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        try database.exec("VACUUM INTO '\(escaped)';")
    }

    /// Groups writes into one atomic unit; see `SQLiteDatabase.transaction`.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try database.transaction(body)
    }

    // MARK: - JSON helpers

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let data = string?.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    // MARK: - Assets

    func upsertAsset(_ asset: Asset) throws {
        try database.run("""
        INSERT INTO assets (id, kind, original_filename, import_origin, capture_date,
            import_date, updated_date, file_size, pixel_width, pixel_height, content_hash,
            residency, residency_source, presence_local, presence_apple, presence_google,
            staging_relpath, import_batch_id, exif_json, cloud_evidence, cloud_checked_at, live_photo_still_id, live_photo_checked_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            original_filename = excluded.original_filename,
            import_origin = excluded.import_origin,
            capture_date = excluded.capture_date,
            import_date = excluded.import_date,
            updated_date = excluded.updated_date,
            file_size = excluded.file_size,
            pixel_width = excluded.pixel_width,
            pixel_height = excluded.pixel_height,
            content_hash = excluded.content_hash,
            residency = excluded.residency,
            residency_source = excluded.residency_source,
            presence_local = excluded.presence_local,
            presence_apple = excluded.presence_apple,
            presence_google = excluded.presence_google,
            staging_relpath = excluded.staging_relpath,
            import_batch_id = excluded.import_batch_id,
            exif_json = excluded.exif_json,
            cloud_evidence = excluded.cloud_evidence,
            cloud_checked_at = excluded.cloud_checked_at,
            live_photo_still_id = excluded.live_photo_still_id,
            live_photo_checked_at = excluded.live_photo_checked_at;
        """, [
            .text(asset.id.uuidString),
            .text(asset.kind.rawValue),
            .text(asset.originalFilename),
            .text(asset.importOrigin.rawValue),
            .date(asset.captureDate),
            .date(asset.importDate),
            .date(asset.updatedDate),
            .int(asset.fileSize),
            .optionalInt(asset.pixelWidth.map(Int64.init)),
            .optionalInt(asset.pixelHeight.map(Int64.init)),
            .text(asset.contentHash),
            .text(asset.residency.rawValue),
            .text(asset.residencySource.rawValue),
            .bool(asset.presence.local),
            .bool(asset.presence.appleCloud),
            .bool(asset.presence.googleCloud),
            .optionalText(asset.stagingRelativePath),
            .uuid(asset.importBatchID),
            .text(Self.encodeJSON(asset.exifSummary)),
            .text(asset.cloudPresenceEvidence.rawValue),
            .date(asset.cloudPresenceCheckedAt),
            .uuid(asset.livePhotoStillID),
            .date(asset.livePhotoCheckedAt),
        ])
    }

    func fetchAssets() throws -> [Asset] {
        try database.query("""
        SELECT id, kind, original_filename, import_origin, capture_date, import_date,
               updated_date, file_size, pixel_width, pixel_height, content_hash,
               residency, residency_source, presence_local, presence_apple, presence_google,
               staging_relpath, import_batch_id, exif_json, cloud_evidence, cloud_checked_at, live_photo_still_id, live_photo_checked_at
        FROM assets ORDER BY COALESCE(capture_date, import_date) DESC;
        """) { row in
            Asset(
                id: row.uuid(0),
                kind: AssetKind(rawValue: row.text(1)) ?? .unknown,
                originalFilename: row.text(2),
                importOrigin: ImportOrigin(rawValue: row.text(3)) ?? .unknown,
                captureDate: row.optionalDate(4),
                importDate: row.date(5),
                updatedDate: row.date(6),
                fileSize: row.int(7),
                pixelWidth: row.optionalInt(8).map(Int.init),
                pixelHeight: row.optionalInt(9).map(Int.init),
                contentHash: row.text(10),
                residency: ResidencyDomain(rawValue: row.text(11)) ?? .local,
                residencySource: ResidencyAssignmentSource(rawValue: row.text(12)) ?? .importDefault,
                presence: DomainPresence(
                    local: row.bool(13),
                    appleCloud: row.bool(14),
                    googleCloud: row.bool(15)
                ),
                stagingRelativePath: row.optionalText(16),
                importBatchID: row.optionalUUID(17),
                exifSummary: Self.decodeJSON([String: String].self, from: row.optionalText(18)) ?? [:],
                cloudPresenceEvidence: row.optionalText(19).flatMap(CloudPresenceEvidence.init(rawValue:)) ?? .none,
                cloudPresenceCheckedAt: row.optionalDate(20),
                livePhotoStillID: row.optionalUUID(21),
                livePhotoCheckedAt: row.optionalDate(22)
            )
        }
    }

    func deleteAsset(id: UUID) throws {
        try database.run("DELETE FROM assets WHERE id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM asset_variants WHERE asset_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM replica_states WHERE asset_id = ?;", [.text(id.uuidString)])
    }

    // MARK: - Asset variants

    func upsertVariant(_ variant: AssetVariant) throws {
        try database.run("""
        INSERT INTO asset_variants (id, asset_id, kind, relative_path, file_size)
        VALUES (?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            asset_id = excluded.asset_id,
            kind = excluded.kind,
            relative_path = excluded.relative_path,
            file_size = excluded.file_size;
        """, [
            .text(variant.id.uuidString),
            .text(variant.assetID.uuidString),
            .text(variant.kind.rawValue),
            .text(variant.relativePath),
            .int(variant.fileSize),
        ])
    }

    func fetchVariants() throws -> [AssetVariant] {
        try database.query("SELECT id, asset_id, kind, relative_path, file_size FROM asset_variants;") { row in
            AssetVariant(
                id: row.uuid(0),
                assetID: row.uuid(1),
                kind: AssetVariantKind(rawValue: row.text(2)) ?? .original,
                relativePath: row.text(3),
                fileSize: row.int(4)
            )
        }
    }
}
