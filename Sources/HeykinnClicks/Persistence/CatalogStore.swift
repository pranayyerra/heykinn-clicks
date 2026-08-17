import Foundation

/// The canonical catalog, hosted on the device. Every fact the system relies on —
/// residency, replica state, backlog, policies, migrations, audit history —
/// lives here, so the device never needs a drive attached to know system state.
final class CatalogStore {
    /// Not a `let` because restoring a snapshot closes this connection and
    /// opens another over the replaced file. Read-only to everyone else.
    private(set) var database: SQLiteDatabase
    /// Kept so the connection can be reopened over the same path.
    let databasePath: String

    /// Sorted keys, because the output of this is **stored and compared**.
    ///
    /// Swift dictionaries have no defined iteration order, so encoding the same
    /// `[String: String]` twice can produce two different strings. Nothing
    /// noticed while a column was only ever written and read back — but the
    /// change journal compares a row before and after a write to see what
    /// moved, and re-saving an asset whose EXIF had not changed at all looked
    /// like a change every single time. A routine rescan would have read to
    /// every other device as the whole archive being rewritten.
    ///
    /// It is also a cross-platform requirement. Two clients encoding the same
    /// map in different orders produce different text for identical data, and
    /// would overwrite each other's `exif_json` forever without either being
    /// wrong. See `docs/SPEC-format.md` §2.2.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// The schema this build understands.
    ///
    /// Bump it whenever `applySchema` starts writing something an older build
    /// would not know to preserve. Not every additive column needs one — a
    /// column an old build never selects and never writes is harmless — but
    /// anything an old build would *overwrite* does, because every upsert here
    /// rewrites whole rows.
    ///
    /// 1 — the schema as of the version that introduced this stamp. Catalogs
    ///     written before it read as 0, which is SQLite's default for a file
    ///     nobody has stamped, and migrate forward normally.
    static let schemaVersion: Int64 = 1

    enum OpenError: Error, LocalizedError {
        /// The catalog was last written by a build newer than this one.
        case builtForNewerVersion(found: Int64, supported: Int64)

        var errorDescription: String? {
            switch self {
            case .builtForNewerVersion(let found, let supported):
                return """
                This archive was last opened by a newer version of Heykinn Clicks \
                (catalog version \(found); this copy understands \(supported)). Update the app \
                to open it.
                """
            }
        }
    }

    /// Records when each field was last written, so two devices holding the
    /// same archive can work out whose write is later. Not yet shipped
    /// anywhere — see `ChangeJournal`.
    private(set) var journal: ChangeJournal!

    init(databasePath: String) throws {
        self.databasePath = databasePath
        database = try SQLiteDatabase(path: databasePath)
        try checkSchemaVersion()
        try openJournal()
        try applySchema()
        // After the schema, because the triggers are generated from it — a
        // column added by a migration needs one, and a table that does not exist
        // yet cannot have one.
        try journal.installTriggers()
        try stampSchemaVersion()
    }

    /// Opens the journal, **before** `applySchema`.
    ///
    /// Ordering that matters: some schema migrations write rows — the move of
    /// per-source policies into storage groups is one — and a write that
    /// happens before the journal exists is a write nothing has stamped. The
    /// journal's own tables are independent of the rest of the schema, so it
    /// can be brought up first and is.
    ///
    /// The archive directory is derived rather than handed in, so the store
    /// stays openable from a path alone. Every test and every tool relies on
    /// that.
    private func openJournal() throws {
        journal = try ChangeJournal(
            database: database,
            device: DeviceIdentity.resolve(
                inDirectory: URL(fileURLWithPath: databasePath).deletingLastPathComponent()
            )
        )
    }

    /// Refuses a catalog written by a build newer than this one.
    ///
    /// Opening it would not fail — SQLite reads a newer file perfectly well,
    /// and every query here names its columns explicitly, so nothing would
    /// throw. That is the problem. The upserts rewrite whole rows, so a build
    /// that has never heard of a column writes the row back without it, and
    /// the catalog stays readable while quietly losing whatever the newer
    /// build recorded. It is the same failure `ArchiveLock` exists to prevent,
    /// arriving through time rather than through a second process.
    ///
    /// Refusing costs somebody the ability to open their archive on an old
    /// build, which is real. It buys not silently discarding their data, which
    /// is worth more — and once catalogs travel between devices on a drive,
    /// meeting a newer one stops being an edge case.
    private func checkSchemaVersion() throws {
        let found = try storedSchemaVersion()
        guard found <= Self.schemaVersion else {
            throw OpenError.builtForNewerVersion(found: found, supported: Self.schemaVersion)
        }
    }

    private func storedSchemaVersion() throws -> Int64 {
        try database.query("PRAGMA user_version;") { Int64($0.int(0)) }.first ?? 0
    }

    /// The version stamped on a catalog this store is not connected to — a
    /// snapshot being considered for restore, or one found on a drive.
    ///
    /// Read-only, so inspecting a snapshot cannot switch it to WAL or leave
    /// journals beside it, for the same reason `SQLiteDatabase(readOnly:)`
    /// exists.
    static func schemaVersion(ofDatabaseAt url: URL) throws -> Int64 {
        let probe = try SQLiteDatabase(path: url.path, readOnly: true)
        defer { probe.close() }
        return try probe.query("PRAGMA user_version;") { Int64($0.int(0)) }.first ?? 0
    }

    /// Records the version this build just brought the file up to.
    ///
    /// Interpolated rather than bound: `PRAGMA` does not accept a parameter for
    /// its value. The interpolated value is an `Int64` constant defined above,
    /// never anything read from outside.
    private func stampSchemaVersion() throws {
        guard try storedSchemaVersion() != Self.schemaVersion else { return }
        try database.exec("PRAGMA user_version = \(Self.schemaVersion);")
    }

    /// Opens the file at `databasePath` and brings it up to the current schema.
    ///
    /// Shared by the initialiser and by `replaceContents`: a restored snapshot
    /// can predate a column that has since been added, and it must be migrated
    /// on the way in rather than left to fail at the first query that expects
    /// it.
    private func applySchema() throws {
        try createSchema()
        // Additive, and after the base schema so the tables it alters exist.
        // `CREATE TABLE IF NOT EXISTS` cannot add a column to a table that is
        // already there, so anything introduced after the first release has to
        // come through here — see `CatalogStore+Sources.swift`.
        try createSourceSchema()
        try createMetadataSchema()
        try createTagSchema()
        try createDriveLocalStateSchema()
    }

    /// Swaps the live catalog for the database at `url`, keeping the outgoing
    /// one beside it.
    ///
    /// The connection is closed first and reopened after, and the `-wal` and
    /// `-shm` journals are cleared with it: those describe the database being
    /// replaced, and a journal left beside a different file is how a good
    /// snapshot opens as a corrupt one.
    ///
    /// Returns where the outgoing catalog was kept. Nothing is deleted — if the
    /// restored snapshot turns out to be the wrong one, that file is the way
    /// back. A failure part-way puts the original back and reopens it, so the
    /// app is never left running on no catalog at all.
    @discardableResult
    func replaceContents(withDatabaseAt url: URL) throws -> URL {
        // Before anything is moved. A snapshot is written by whichever build
        // was running when the drive was last connected, and once catalogs
        // travel between devices that is routinely not this one. Restoring a
        // newer snapshot and then refusing to open it would leave somebody with
        // no working archive and their previous one renamed out from under
        // them; checking first means a refused restore changes nothing at all.
        let incoming = try Self.schemaVersion(ofDatabaseAt: url)
        guard incoming <= Self.schemaVersion else {
            throw OpenError.builtForNewerVersion(found: incoming, supported: Self.schemaVersion)
        }

        let live = URL(fileURLWithPath: databasePath)
        let stamp = Self.replacedStampFormatter.string(from: Date())
        let keptAside = live.deletingLastPathComponent()
            .appendingPathComponent("catalog-replaced-\(stamp).sqlite")

        // Before the file moves: anything still in the write-ahead log belongs
        // in the copy being kept, and the journals are deleted a few lines
        // below.
        database.checkpoint()
        database.close()
        do {
            if FileManager.default.fileExists(atPath: live.path) {
                try FileManager.default.moveItem(at: live, to: keptAside)
            }
            for journal in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: live.path + journal)
            }
            try FileManager.default.copyItem(at: url, to: live)
        } catch {
            if !FileManager.default.fileExists(atPath: live.path),
               FileManager.default.fileExists(atPath: keptAside.path) {
                try? FileManager.default.moveItem(at: keptAside, to: live)
            }
            database = try SQLiteDatabase(path: databasePath)
            try openJournal()
            try applySchema()
            try journal.installTriggers()
            throw error
        }
        database = try SQLiteDatabase(path: databasePath)
        // The journal holds the connection it was opened on, and that one has
        // just been closed and replaced. Without this it would go on stamping
        // into a dead handle — and the restored catalog would carry the *old*
        // catalog's clock, which is the state this is meant to resume.
        try openJournal()
        try applySchema()
        // And the triggers, which live *in* the file that was just replaced.
        //
        // A snapshot carries whatever triggers it had — possibly none, if it
        // predates them — and carries `change_pending_stamp` with the id of the
        // device that wrote it. Without this, a restored archive either records
        // nothing at all, or records this device's changes under another
        // device's identity: the exact thing `DeviceIdentity` living outside the
        // catalog exists to prevent. Reinstalling rebuilds both.
        try journal.installTriggers()
        return keptAside
    }

    private static let replacedStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

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
            live_photo_checked_at REAL,
            capture_date_source TEXT,
            edited_from_asset_id TEXT,
            -- Assets indexed from a provider library carry that library's own
            -- id, so re-indexing updates rather than duplicates. A counterpart
            -- links the same photograph across domains when the bytes differ.
            provider_local_id TEXT,
            counterpart_asset_id TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_assets_hash ON assets(content_hash);

        -- `asset_variants` was here and is gone. Nothing ever inserted a row:
        -- it was empty on every catalog, including one with 24,000 assets in
        -- it. Not dropped, only no longer created — an empty table on an
        -- existing catalog costs nothing, and a DROP is a destructive migration
        -- run for tidiness, which is the wrong trade against somebody's
        -- archive.

        -- Targets: a registered place that holds a copy, which may be an
        -- external volume or a folder on any disk the user pointed at.
        -- Still called `drives` because the marker files that identify them
        -- are already sitting on users' volumes under that name.
        CREATE TABLE IF NOT EXISTS drives (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            volume_uuid TEXT,
            marker_token TEXT NOT NULL,
            registered_at REAL NOT NULL,
            last_seen_at REAL,
            replica_root TEXT NOT NULL,
            last_mount_path TEXT,
            kind TEXT,
            configured_path TEXT
        );

        CREATE TABLE IF NOT EXISTS replica_states (
            asset_id TEXT NOT NULL,
            drive_id TEXT NOT NULL,
            state TEXT NOT NULL,
            relative_path TEXT,
            last_verified_at REAL,
            -- What this replica's file looked like when the app last knew it
            -- was right, so a connect can aim its reads at the files that
            -- changed underneath it rather than re-reading the target.
            observed_size INTEGER,
            observed_modified_at REAL,
            PRIMARY KEY (asset_id, drive_id)
        );

        -- The primary key is led by `asset_id`, so it answers "where is this
        -- photo" and nothing else. Every per-drive question — what this drive
        -- holds inside a zip, what to repoint when an export moves, what to
        -- forget when a device is unregistered — asks by `drive_id` alone, and
        -- without this walked all of the largest table in the catalog.
        CREATE INDEX IF NOT EXISTS idx_replica_states_drive ON replica_states(drive_id);

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
            failed_count INTEGER NOT NULL DEFAULT 0,
            -- What kind of import a batch was. `source_path` holds a label
            -- rather than a path for three of the four things that write it,
            -- so it cannot be used to tell a folder somebody chose from a
            -- Takeout the app unpacked — which is a question the Sources
            -- screen has to answer.
            origin TEXT
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
            imported_file_total INTEGER NOT NULL DEFAULT 0,
            content_hash TEXT,
            quick_checksum TEXT,
            -- An export archive the app looked for on a connected target and
            -- did not find. The row stays for the import history it carries;
            -- this is what stops it counting as a copy of its part.
            missing_since REAL
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

        -- What a sweep last saw at a path, so pointing the app at the same
        -- folder again does not re-hash every byte of it to arrive at answers
        -- it already has. Keyed by path: this is a note about a place on disk,
        -- not about an asset, and the same bytes at a new path are new work.
        -- Cache, not record — losing it costs time and nothing else.
        CREATE TABLE IF NOT EXISTS import_scan_memo (
            path TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            content_hash TEXT NOT NULL,
            seen_at REAL NOT NULL
        );
        """)
    }

    /// Writes a consistent, compacted copy of the whole catalog to `path`.
    /// Safe to run while the catalog is in use; the destination must not exist.
    func vacuumInto(path: String) throws {
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        try database.exec("VACUUM INTO '\(escaped)';")
    }

    /// Every table currently holding at least one row.
    ///
    /// Asked of the schema rather than listed by hand, because a hand-written
    /// list is a list somebody forgets to add to. A table added next year is
    /// covered the day it holds anything.
    func nonEmptyTables() throws -> Set<String> {
        let names = try database.query(
            """
            SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
             ORDER BY name;
            """
        ) { $0.text(0) }
        var populated: Set<String> = []
        for name in names {
            // Identifier, not a bindable value, so it is quoted rather than
            // parameterised — and it came from `sqlite_master`, not from input.
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            let count = try database.query("SELECT count(*) FROM \"\(escaped)\";") { $0.int(0) }
            if (count.first ?? 0) > 0 { populated.insert(name) }
        }
        return populated
    }

    /// Groups writes into one atomic unit; see `SQLiteDatabase.transaction`.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try database.transaction(body)
    }

    // MARK: - Journalling

    /// Runs a write to a shared table and records which columns it changed, so
    /// another device can be told about it.
    ///
    /// `key` is the row's primary-key values, in key order — one for most
    /// tables, several for the few keyed by a combination.
    ///
    /// Wrapping rather than being called afterwards because the journal has to
    /// see the row on both sides of the write: every statement here is an
    /// upsert, and an upsert cannot say which values it moved.
    @discardableResult
    func journaled<T>(_ table: String, _ key: [String], _ write: () throws -> T) throws -> T {
        try journal.recordingWrite(table: table, rowID: ChangeJournal.rowID(key), write)
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
        try journaled("assets", [asset.id.uuidString]) {
            try database.run("""
            INSERT INTO assets (id, kind, original_filename, import_origin, capture_date,
                import_date, updated_date, file_size, pixel_width, pixel_height, content_hash,
                residency, residency_source, presence_local, presence_apple, presence_google,
                staging_relpath, import_batch_id, exif_json, cloud_evidence, cloud_checked_at, live_photo_still_id, live_photo_checked_at, capture_date_source, edited_from_asset_id, provider_local_id, counterpart_asset_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
                live_photo_checked_at = excluded.live_photo_checked_at,
                capture_date_source = excluded.capture_date_source,
                edited_from_asset_id = excluded.edited_from_asset_id,
                provider_local_id = excluded.provider_local_id,
                counterpart_asset_id = excluded.counterpart_asset_id;
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
                .text(asset.captureDateSource.rawValue),
                .uuid(asset.editedFromAssetID),
                .optionalText(asset.providerLocalID),
                .uuid(asset.counterpartAssetID),
            ])
        }
    }

    func fetchAssets() throws -> [Asset] {
        try database.query("""
        SELECT id, kind, original_filename, import_origin, capture_date, import_date,
               updated_date, file_size, pixel_width, pixel_height, content_hash,
               residency, residency_source, presence_local, presence_apple, presence_google,
               staging_relpath, import_batch_id, exif_json, cloud_evidence, cloud_checked_at, live_photo_still_id, live_photo_checked_at, capture_date_source, edited_from_asset_id, provider_local_id, counterpart_asset_id
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
                providerLocalID: row.optionalText(25),
                counterpartAssetID: row.optionalUUID(26),
                livePhotoStillID: row.optionalUUID(21),
                captureDateSource: row.optionalText(23).flatMap(CaptureDateSource.init(rawValue:)) ?? .unknown,
                editedFromAssetID: row.optionalUUID(24),
                livePhotoCheckedAt: row.optionalDate(22)
            )
        }
    }

    func deleteAsset(id: UUID) throws {
        // Both deletes are tombstoned by their tables' triggers — the photo,
        // and every claim about where its copies live. A row that merely
        // vanishes is indistinguishable, on another device, from one it has
        // never been told about, and the next merge would hand it back.
        try database.run("DELETE FROM assets WHERE id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM replica_states WHERE asset_id = ?;", [.text(id.uuidString)])
    }

}
