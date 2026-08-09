import Foundation

extension CatalogStore {

    // MARK: - Schema

    /// The capture layer: provider metadata kept verbatim, and a census of the
    /// shapes it has arrived in.
    ///
    /// Two tables rather than one. `metadata_records` is bulk — one row per
    /// sidecar, ~24,600 of them on a real archive — and is read only when
    /// somebody looks at a photo. `metadata_schemas` is a handful of rows that
    /// answer "has the format changed?" without scanning the bulk.
    func createMetadataSchema() throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS metadata_records (
            id TEXT PRIMARY KEY,
            asset_id TEXT,
            source_id TEXT NOT NULL,
            scope TEXT NOT NULL,
            provider TEXT NOT NULL,
            origin_path TEXT NOT NULL,
            captured_at REAL NOT NULL,
            schema_fingerprint TEXT NOT NULL,
            payload TEXT NOT NULL,
            projected_version INTEGER NOT NULL DEFAULT 0
        );
        """)
        // The lookup that happens on every asset detail. Without it, opening
        // one photo scans every payload in the archive.
        try database.exec(
            "CREATE INDEX IF NOT EXISTS idx_metadata_asset ON metadata_records(asset_id);"
        )
        try database.exec(
            "CREATE INDEX IF NOT EXISTS idx_metadata_source ON metadata_records(source_id);"
        )
        // One payload per path per source: re-reading an export must update
        // what is there rather than pile a second copy beside it.
        try database.exec("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_metadata_origin
        ON metadata_records(source_id, origin_path);
        """)
        try database.exec("""
        CREATE TABLE IF NOT EXISTS metadata_schemas (
            fingerprint TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            scope TEXT NOT NULL,
            keys_json TEXT NOT NULL,
            example_path TEXT NOT NULL,
            example_payload TEXT NOT NULL DEFAULT '',
            first_seen_at REAL NOT NULL
        );
        """)
        // Both added after the tables shipped, so they cannot go in the CREATEs
        // above: an installed catalog keeps the table it already has.
        try addMetadataColumnIfMissing(
            table: "metadata_records", column: "projected_version",
            declaration: "INTEGER NOT NULL DEFAULT 0"
        )
        try addMetadataColumnIfMissing(
            table: "metadata_schemas", column: "example_payload",
            declaration: "TEXT NOT NULL DEFAULT ''"
        )

        // Which reader last read each part of an export.
        //
        // Keyed by the *part*, not by the archive row that was read. A part is
        // one piece of content that happens to exist as a zip on one drive and
        // an unzipped folder on another; reading either one reads the same
        // sidecars, so recording it against a drive's copy would leave the
        // other copy looking unread and invite the work to be done twice.
        //
        // This is the missing half of keeping the exports. Projection is
        // already versioned and re-runs from payloads the catalog holds; the
        // exports are kept for the other case — going back for something the
        // reader never stored at all — and until now nothing recorded which
        // reader had been over which part, so "re-run in case we missed
        // something" had no way to know what to re-run or whether it was
        // needed.
        try database.exec("""
        CREATE TABLE IF NOT EXISTS export_capture_versions (
            set_id TEXT NOT NULL,
            part_number INTEGER NOT NULL,
            version INTEGER NOT NULL,
            captured_at REAL NOT NULL,
            PRIMARY KEY (set_id, part_number)
        );
        """)
    }

    /// What the app currently *reads out of* an export.
    ///
    /// Distinct from `currentProjectionVersion`, and the distinction is the
    /// whole architecture. Projection interprets payloads the catalog already
    /// holds: being wrong is cheap, and bumping it re-derives everything from
    /// rows that never left. Capture decides what is worth taking out of the
    /// export in the first place — and being wrong there is only recoverable
    /// while the export still exists, which is why they are kept.
    ///
    /// Bump this when the reader learns to take something it used to walk
    /// past: a sidecar kind it ignored, a field it dropped, a folder it did
    /// not descend into. Parts below it are worth re-reading; parts at it are
    /// not, and a 127 GB read that would find nothing is worth not offering.
    static let currentCaptureVersion = 1

    func recordCapture(
        setID: String, partNumber: Int,
        version: Int = CatalogStore.currentCaptureVersion,
        at moment: Date = Date()
    ) throws {
        try database.run("""
        INSERT INTO export_capture_versions (set_id, part_number, version, captured_at)
        VALUES (?,?,?,?)
        ON CONFLICT(set_id, part_number) DO UPDATE SET
            version = excluded.version,
            captured_at = excluded.captured_at;
        """, [
            .text(setID), .int(Int64(partNumber)),
            .int(Int64(version)), .date(moment),
        ])
    }

    /// Set id → part number → the reader that last read it.
    func fetchCaptureVersions() throws -> [String: [Int: Int]] {
        try database.query(
            "SELECT set_id, part_number, version FROM export_capture_versions;"
        ) { ($0.text(0), Int($0.int(1)), Int($0.int(2))) }
        .reduce(into: [:]) { result, row in
            result[row.0, default: [:]][row.1] = row.2
        }
    }

    private func addMetadataColumnIfMissing(
        table: String, column: String, declaration: String
    ) throws {
        let existing = try database.query("PRAGMA table_info(\(table));") { $0.text(1) }
        guard !existing.contains(column) else { return }
        try database.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration);")
    }

    /// How the app currently reads a payload.
    ///
    /// Bumped whenever the projection logic changes its mind — a field read
    /// differently, a new one acted on, a bug in how albums were derived. Rows
    /// below it are stale and can be re-derived in the background, which is the
    /// property the whole design rests on: being wrong about interpretation is
    /// cheap as long as the raw payload was kept.
    /// 2: matching a sidecar to its photo allows a timezone's difference
    /// between the provider's UTC timestamp and a capture date read from EXIF,
    /// which carries no zone. Version 1 compared them exactly and missed every
    /// photo whose camera clock was not on UTC.
    /// 3: a description is matched against every photo in the archive, not
    /// only those from its own source. The archive keeps one row per
    /// photograph however many imports found it, so a picture that came from
    /// the Photos library and also sits in a Google export had its description
    /// filed under a source its asset does not belong to.
    /// 4: albums and people are derived into `asset_tags`. Album membership
    /// is a directory in an export rather than a field, so it comes from
    /// `origin_path` — which is why that was captured.
    static let currentProjectionVersion = 4

    /// What a photo is *called* by, as opposed to where it is kept.
    ///
    /// Many-to-many on purpose, and carrying no behaviour: a photo is in as
    /// many albums and has as many people in it as it has, and none of that
    /// decides where its bytes live. That is the line between a tag and a
    /// storage group — a policy needs one answer per photo, and "this is in
    /// three albums" has three.
    ///
    /// Entirely derived from `metadata_records`, and rebuilt rather than
    /// migrated whenever the projection changes its mind.
    func createTagSchema() throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS asset_tags (
            asset_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (asset_id, kind, value)
        );
        """)
        // "show me everyone in this album" and "show me every photo of this
        // person" are the two questions, and both start from the tag.
        try database.exec(
            "CREATE INDEX IF NOT EXISTS idx_tags_lookup ON asset_tags(kind, value);"
        )
    }

    func addTag(_ tag: AssetTag) throws {
        try database.run("""
        INSERT INTO asset_tags (asset_id, kind, value) VALUES (?,?,?)
        ON CONFLICT(asset_id, kind, value) DO NOTHING;
        """, [.text(tag.assetID.uuidString), .text(tag.kind.rawValue), .text(tag.value)])
    }

    /// Throws away every derived tag, for a rebuild.
    func deleteAllTags() throws {
        try database.run("DELETE FROM asset_tags;", [])
    }

    /// Every tag in the archive.
    ///
    /// Loaded whole, unlike the payloads they came from: 8,722 rows of two
    /// short strings is nothing, and browsing needs all of them at once to
    /// answer "which photos are in this album" without a query per redraw.
    func fetchAllTags() throws -> [AssetTag] {
        try database.query("SELECT asset_id, kind, value FROM asset_tags;") { row in
            AssetTag(
                assetID: row.uuid(0),
                kind: AssetTag.Kind(rawValue: row.text(1)) ?? .album,
                value: row.text(2)
            )
        }
    }

    func fetchTags(forAsset assetID: UUID) throws -> [AssetTag] {
        try database.query("""
        SELECT asset_id, kind, value FROM asset_tags WHERE asset_id = ? ORDER BY kind, value;
        """, [.text(assetID.uuidString)]) { row in
            AssetTag(
                assetID: row.uuid(0),
                kind: AssetTag.Kind(rawValue: row.text(1)) ?? .album,
                value: row.text(2)
            )
        }
    }

    /// Every value of one kind, with how many photos carry it — the album list
    /// and the people list.
    func fetchTagSummary(kind: AssetTag.Kind) throws -> [(value: String, count: Int)] {
        try database.query("""
        SELECT value, count(*) FROM asset_tags WHERE kind = ?
        GROUP BY value ORDER BY count(*) DESC, value;
        """, [.text(kind.rawValue)]) { row in (row.text(0), Int(row.int(1))) }
    }

    func fetchAssetIDs(taggedWith kind: AssetTag.Kind, value: String) throws -> [UUID] {
        try database.query(
            "SELECT asset_id FROM asset_tags WHERE kind = ? AND value = ?;",
            [.text(kind.rawValue), .text(value)]
        ) { $0.uuid(0) }
    }

    // MARK: - Records

    /// Stores one payload, and counts its shape.
    ///
    /// Keyed on `(source_id, origin_path)` rather than on the record's own id,
    /// so re-reading an export you already have replaces each payload instead
    /// of doubling it. The census is kept in the same transaction as the row it
    /// describes — a count that can drift from the thing it counts is worse
    /// than no count.
    func upsertMetadataRecord(_ record: MetadataRecord) throws {
        try database.run("""
        INSERT INTO metadata_records
            (id, asset_id, source_id, scope, provider, origin_path, captured_at,
             schema_fingerprint, payload)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(source_id, origin_path) DO UPDATE SET
            asset_id = excluded.asset_id,
            scope = excluded.scope,
            provider = excluded.provider,
            captured_at = excluded.captured_at,
            schema_fingerprint = excluded.schema_fingerprint,
            payload = excluded.payload,
            -- New bytes have been read by nothing, whatever was true of the
            -- ones they replace.
            projected_version = 0;
        """, [
            .text(record.id.uuidString),
            record.assetID.map { SQLValue.text($0.uuidString) } ?? .null,
            .text(record.sourceID.uuidString),
            .text(record.scope.rawValue),
            .text(record.provider),
            .text(record.originPath),
            .real(record.capturedAt.timeIntervalSince1970),
            .text(record.schemaFingerprint),
            .text(record.payload),
        ])
        try noteSchema(of: record)
    }

    /// Everything recorded about one photo.
    func fetchMetadataRecords(forAsset assetID: UUID) throws -> [MetadataRecord] {
        try database.query("""
        SELECT id, asset_id, source_id, scope, provider, origin_path, captured_at,
               schema_fingerprint, payload
        FROM metadata_records WHERE asset_id = ?;
        """, [.text(assetID.uuidString)], row: decodeMetadataRecord)
    }

    /// Everything recorded for one source — albums and export-level payloads
    /// included, which belong to no single photo.
    func fetchMetadataRecords(forSource sourceID: UUID, scope: MetadataRecord.Scope? = nil) throws -> [MetadataRecord] {
        var sql = """
        SELECT id, asset_id, source_id, scope, provider, origin_path, captured_at,
               schema_fingerprint, payload
        FROM metadata_records WHERE source_id = ?
        """
        var bindings: [SQLValue] = [.text(sourceID.uuidString)]
        if let scope {
            sql += " AND scope = ?"
            bindings.append(.text(scope.rawValue))
        }
        return try database.query(sql + ";", bindings, row: decodeMetadataRecord)
    }

    /// How many payloads are held, without loading any of them.
    func metadataRecordCount() throws -> Int {
        try database.query("SELECT count(*) FROM metadata_records;") { Int($0.int(0)) }.first ?? 0
    }

    /// How many photos carry at least one description.
    ///
    /// One query. Asking per asset is 24,639 of them for a number nobody needs
    /// that badly.
    func photosCarryingMetadata() throws -> Int {
        try database.query(
            "SELECT count(DISTINCT asset_id) FROM metadata_records WHERE asset_id IS NOT NULL;"
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// Origin paths already captured for a source, so a re-read can skip what
    /// it already has without pulling every payload into memory.
    func capturedOriginPaths(forSource sourceID: UUID) throws -> Set<String> {
        let paths = try database.query(
            "SELECT origin_path FROM metadata_records WHERE source_id = ?;",
            [.text(sourceID.uuidString)]
        ) { $0.text(0) }
        return Set(paths)
    }

    private func decodeMetadataRecord(_ row: SQLiteDatabase.Row) -> MetadataRecord {
        MetadataRecord(
            id: row.uuid(0),
            assetID: row.optionalUUID(1),
            sourceID: row.uuid(2),
            scope: MetadataRecord.Scope(rawValue: row.text(3)) ?? .asset,
            provider: row.text(4),
            originPath: row.text(5),
            capturedAt: Date(timeIntervalSince1970: row.real(6)),
            schemaFingerprint: row.text(7),
            payload: row.text(8)
        )
    }

    // MARK: - The census

    /// Records a payload's shape, or bumps the count for one already seen.
    private func noteSchema(of record: MetadataRecord) throws {
        let keys = record.payload.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { $0 as? [String: Any] }
            .map { $0.keys.sorted() } ?? []

        // One whole payload per shape, kept forever.
        //
        // A path goes stale the moment a drive is reorganised, and then the
        // census can tell you a shape exists but not what it looked like. A few
        // KB buys a permanent corpus of every shape the app has ever seen —
        // which is the regression suite for a format that changes on somebody
        // else's schedule, and the evidence when a projection looks wrong.
        // Nothing is counted here. A tally kept beside the thing it counts
        // drifts the moment a payload is replaced rather than added — re-read
        // an export and the census claims more records than exist. The count is
        // taken from the records themselves at read time, so it cannot be
        // wrong; this table holds only what a count cannot give you.
        try database.run("""
        INSERT INTO metadata_schemas
            (fingerprint, provider, scope, keys_json, example_path,
             example_payload, first_seen_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(fingerprint) DO NOTHING;
        """, [
            .text(record.schemaFingerprint),
            .text(record.provider),
            .text(record.scope.rawValue),
            .text(Self.encodeJSON(keys)),
            .text(record.originPath),
            .text(record.payload),
            .real(record.capturedAt.timeIntervalSince1970),
        ])
    }

    /// Applies what a projection worked out, without touching the payload.
    ///
    /// The raw layer is append-only in spirit: what arrived is never rewritten,
    /// only what was concluded about it. Which is what makes a wrong conclusion
    /// a re-run rather than a loss.
    func applyProjection(
        to recordID: UUID,
        assetID: UUID?,
        scope: MetadataRecord.Scope,
        version: Int = CatalogStore.currentProjectionVersion
    ) throws {
        try database.run("""
        UPDATE metadata_records
        SET asset_id = ?, scope = ?, projected_version = ?
        WHERE id = ?;
        """, [
            assetID.map { SQLValue.text($0.uuidString) } ?? .null,
            .text(scope.rawValue),
            .int(Int64(version)),
            .text(recordID.uuidString),
        ])
    }

    /// Payloads the current projection logic has not been over.
    ///
    /// The re-derivation queue. Batched rather than fetched whole: the point of
    /// keeping raw is that a re-read of 24,639 payloads is *possible*, not that
    /// it should happen in one allocation.
    func fetchMetadataRecordsNeedingProjection(
        below version: Int = CatalogStore.currentProjectionVersion,
        limit: Int = 500
    ) throws -> [MetadataRecord] {
        try database.query("""
        SELECT id, asset_id, source_id, scope, provider, origin_path, captured_at,
               schema_fingerprint, payload
        FROM metadata_records WHERE projected_version < ? LIMIT ?;
        """, [.int(Int64(version)), .int(Int64(limit))], row: decodeMetadataRecord)
    }

    /// Marks payloads as read by the current projection logic.
    func markProjected(_ recordIDs: [UUID], version: Int = CatalogStore.currentProjectionVersion) throws {
        for id in recordIDs {
            try database.run(
                "UPDATE metadata_records SET projected_version = ? WHERE id = ?;",
                [.int(Int64(version)), .text(id.uuidString)]
            )
        }
    }

    /// How many payloads are waiting to be re-read.
    func metadataRecordsAwaitingProjection(
        below version: Int = CatalogStore.currentProjectionVersion
    ) throws -> Int {
        try database.query(
            "SELECT count(*) FROM metadata_records WHERE projected_version < ?;",
            [.int(Int64(version))]
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// Every payload shape seen, commonest first.
    ///
    /// The report that turns "Google changed the format" from silent loss into
    /// something a person can look at: an unfamiliar fingerprint with a small
    /// count and one example path to go and read.
    func fetchMetadataSchemas() throws -> [MetadataSchema] {
        try database.query("""
        SELECT s.fingerprint, s.provider, s.scope, s.keys_json,
               (SELECT count(*) FROM metadata_records r
                 WHERE r.schema_fingerprint = s.fingerprint) AS record_count,
               s.example_path, s.example_payload, s.first_seen_at
        FROM metadata_schemas s ORDER BY record_count DESC;
        """) { row in
            MetadataSchema(
                fingerprint: row.text(0),
                provider: row.text(1),
                scope: MetadataRecord.Scope(rawValue: row.text(2)) ?? .asset,
                keys: Self.decodeJSON([String].self, from: row.text(3)) ?? [],
                recordCount: Int(row.int(4)),
                examplePath: row.text(5),
                examplePayload: row.text(6),
                firstSeenAt: Date(timeIntervalSince1970: row.real(7))
            )
        }
    }
}
