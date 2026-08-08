import Foundation

extension CatalogStore {

    // MARK: - Schema

    /// Creates the sources table and adds the columns that reference it.
    ///
    /// Separate from `createSchema` and additive, because `CREATE TABLE IF NOT
    /// EXISTS` does nothing to a table that already exists — an installed
    /// catalog would keep its old `assets` and silently lack `source_id`. The
    /// SPEC's note that there are no migrations to replay was true of a schema
    /// nothing had been added to since; this adds something.
    ///
    /// Written to be safe to run on every launch: the table creation is
    /// conditional, and the column is added only when a check confirms it is
    /// absent.
    func createSourceSchema() throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            label TEXT NOT NULL,
            origin_path TEXT,
            desired_copies INTEGER NOT NULL,
            destination_ids_json TEXT NOT NULL,
            added_at REAL NOT NULL
        );
        """)
        try database.exec("""
        CREATE TABLE IF NOT EXISTS storage_groups (
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            desired_copies INTEGER NOT NULL,
            destination_ids_json TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
        // Added after `storage_groups` shipped. Defaults to `chosen` so a row
        // nobody has looked at behaves exactly as it did — the list it holds is
        // treated as deliberate until something establishes otherwise.
        try addColumnIfMissing(
            table: "storage_groups", column: "destination_mode",
            declaration: "TEXT NOT NULL DEFAULT 'chosen'"
        )
        try addColumnIfMissing(table: "assets", column: "source_id", declaration: "TEXT")
        try addColumnIfMissing(table: "assets", column: "storage_group_id", declaration: "TEXT")
        try database.exec(
            "CREATE INDEX IF NOT EXISTS idx_assets_storage_group ON assets(storage_group_id);"
        )
        // Added after `sources` shipped, so it cannot go in the CREATE above:
        // an installed catalog keeps its existing table.
        try addColumnIfMissing(table: "sources", column: "export_set_id", declaration: "TEXT")
        // Placement asks "which of this source's assets is device X missing"
        // on every audit, connect and redraw. Without this it is a full scan
        // of the assets table each time.
        try database.exec("CREATE INDEX IF NOT EXISTS idx_assets_source ON assets(source_id);")

        // `import_batches.source_id` and `takeout_archives.source_id` were
        // added here at the same time as the asset column, on the assumption
        // that a batch and an archive would each want to name their source.
        // Neither ever did: membership is carried by `assets.source_id` alone,
        // which is what makes it a strict partition. Nothing has read or
        // written either column.
        //
        // Removed rather than left in place. An unused column in a schema is
        // read as a fact about the model by the next person to look, and the
        // next person is going to be deciding whether a batch belongs to a
        // source — which is exactly the question these two would answer wrong.
        try dropColumnIfPresent(table: "import_batches", column: "source_id")
        try dropColumnIfPresent(table: "takeout_archives", column: "source_id")

        // Carries a pre-split catalog's policy onto the groups that now own it.
        // Runs here rather than from `AppStore` so a store opened by a test, a
        // backup restore, or the diagnostics path sees the same shape as one
        // opened by the app.
        _ = try migrateSourcePoliciesIntoStorageGroups()
    }

    /// SQLite has no `ADD COLUMN IF NOT EXISTS`, and adding one that is already
    /// there is an error rather than a no-op — so the check has to be explicit.
    private func addColumnIfMissing(table: String, column: String, declaration: String) throws {
        let existing = try database.query("PRAGMA table_info(\(table));") { row in
            row.text(1)
        }
        guard !existing.contains(column) else { return }
        try database.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration);")
    }

    /// Removes a column that turned out to carry nothing.
    ///
    /// Deliberately forgiving. `DROP COLUMN` arrived in SQLite 3.35 and refuses
    /// a column that is indexed or referenced by a view or a generated column;
    /// on a build or a catalog where it will not go through, a spare column
    /// holding nothing but NULLs is harmless. Failing a launch over tidiness
    /// would be the worse trade by a wide margin, so the attempt is best-effort
    /// and the next launch simply tries again.
    private func dropColumnIfPresent(table: String, column: String) throws {
        let existing = try database.query("PRAGMA table_info(\(table));") { row in
            row.text(1)
        }
        guard existing.contains(column) else { return }
        try? database.exec("ALTER TABLE \(table) DROP COLUMN \(column);")
    }

    // MARK: - Storage groups

    func upsertStorageGroup(_ group: StorageGroup) throws {
        try database.run("""
        INSERT INTO storage_groups
            (id, label, desired_copies, destination_ids_json, created_at, destination_mode)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            label = excluded.label,
            desired_copies = excluded.desired_copies,
            destination_ids_json = excluded.destination_ids_json,
            destination_mode = excluded.destination_mode;
        """, [
            .text(group.id.uuidString),
            .text(group.label),
            .int(Int64(group.desiredCopies)),
            .text(Self.encodeJSON(group.destinationTargetIDs.map(\.uuidString))),
            .real(group.createdAt.timeIntervalSince1970),
            .text(group.destinationMode.rawValue),
        ])
    }

    func fetchStorageGroups() throws -> [StorageGroup] {
        try database.query("""
        SELECT id, label, desired_copies, destination_ids_json, created_at, destination_mode
        FROM storage_groups ORDER BY created_at DESC;
        """) { row in
            StorageGroup(
                id: row.uuid(0),
                label: row.text(1),
                desiredCopies: Int(row.int(2)),
                destinationTargetIDs: (Self.decodeJSON([String].self, from: row.text(3)) ?? [])
                    .compactMap(UUID.init(uuidString:)),
                destinationMode: StorageGroup.DestinationMode(rawValue: row.text(5)) ?? .chosen,
                createdAt: Date(timeIntervalSince1970: row.real(4))
            )
        }
    }

    func deleteStorageGroup(id: UUID) throws {
        // Assets are left pointing at nothing rather than deleted with the
        // group. `AppStore` re-homes them; losing photos must never be a side
        // effect of tidying up a setting.
        try database.run(
            "UPDATE assets SET storage_group_id = NULL WHERE storage_group_id = ?;",
            [.text(id.uuidString)]
        )
        try database.run("DELETE FROM storage_groups WHERE id = ?;", [.text(id.uuidString)])
    }

    /// Puts a set of assets in a group. Membership is a strict partition, so
    /// this replaces whatever they were in before.
    func assignStorageGroup(_ groupID: UUID, toAssets assetIDs: [UUID]) throws {
        guard !assetIDs.isEmpty else { return }
        for assetID in assetIDs {
            try database.run(
                "UPDATE assets SET storage_group_id = ? WHERE id = ?;",
                [.text(groupID.uuidString), .text(assetID.uuidString)]
            )
        }
    }

    /// Every asset's group, in one query — the map placement reads constantly.
    func fetchStorageGroupIDsByAsset() throws -> [UUID: UUID] {
        let pairs = try database.query(
            "SELECT id, storage_group_id FROM assets WHERE storage_group_id IS NOT NULL;"
        ) { row in (row.uuid(0), row.optionalUUID(1)) }
        return pairs.reduce(into: [UUID: UUID]()) { map, pair in
            if let groupID = pair.1 { map[pair.0] = groupID }
        }
    }

    /// Moves every source's policy into a group of its own, once.
    ///
    /// Catalogs written before the split carry the copy count and destinations
    /// on the source row. Read straight across: one group per source, same
    /// label, same settings, the source's assets pointed at it. Nothing is
    /// guessed and nothing changes about where a photo is kept — the same
    /// numbers come out the other side under a different name.
    ///
    /// Keyed on the source's own id so it is idempotent: a second run finds the
    /// group already there and the assets already pointing at it.
    /// Marks as worked-out every group whose devices were never a choice.
    ///
    /// Before `destination_mode` existed, a group stored a plain list and there
    /// was no way to ask how it got there. This reads the answer off the
    /// evidence: a group naming *every* external drive was not choosing between
    /// them — there was nothing to choose. A group naming some but not all was,
    /// and is left alone.
    ///
    /// The host device is excluded from the comparison on purpose. It is the
    /// machine the drives exist to survive, so it is never one of the devices a
    /// group is simply spread across, and a group that names it named it
    /// deliberately.
    ///
    /// Conservative in the direction that matters: getting this wrong towards
    /// `chosen` leaves a group behaving exactly as it does today, while getting
    /// it wrong towards `automatic` could move somebody's deliberate placement.
    @discardableResult
    func markUnchosenStorageGroupsAutomatic() throws -> Int {
        let externals = Set(try database.query(
            "SELECT id FROM drives WHERE kind = ?;", [.text(TargetKind.externalVolume.rawValue)]
        ) { $0.text(0) })
        guard !externals.isEmpty else { return 0 }

        var marked = 0
        for group in try fetchStorageGroups() where group.destinationMode == .chosen {
            guard Set(group.destinationTargetIDs.map(\.uuidString)) == externals else { continue }
            var updated = group
            updated.destinationMode = .automatic
            try upsertStorageGroup(updated)
            marked += 1
        }
        return marked
    }

    func migrateSourcePoliciesIntoStorageGroups() throws -> Int {
        let existing = Set(try fetchStorageGroups().map(\.id))
        struct Legacy { let id: UUID; let label: String; let copies: Int; let json: String; let at: Double }
        let legacy = try database.query("""
        SELECT id, label, desired_copies, destination_ids_json, added_at FROM sources;
        """) { row in
            Legacy(
                id: row.uuid(0), label: row.text(1), copies: Int(row.int(2)),
                json: row.text(3), at: row.real(4)
            )
        }

        var migrated = 0
        for source in legacy where !existing.contains(source.id) {
            // A source whose policy has already been moved writes zeros back on
            // every save (see `upsertSource`), so a zero-copy row with no
            // destinations is a source that has been through this, not one
            // asking for nothing.
            let destinations = (Self.decodeJSON([String].self, from: source.json) ?? [])
                .compactMap(UUID.init(uuidString:))
            guard source.copies > 0 || !destinations.isEmpty else { continue }

            try upsertStorageGroup(StorageGroup(
                id: source.id,
                label: source.label,
                desiredCopies: source.copies,
                destinationTargetIDs: destinations,
                createdAt: Date(timeIntervalSince1970: source.at)
            ))
            try database.run("""
            UPDATE assets SET storage_group_id = ?
            WHERE source_id = ? AND storage_group_id IS NULL;
            """, [.text(source.id.uuidString), .text(source.id.uuidString)])
            migrated += 1
        }
        return migrated
    }

    // MARK: - Sources

    func upsertSource(_ source: PhotoArchiveSource) throws {
        try database.run("""
        INSERT INTO sources (id, kind, label, origin_path, desired_copies, destination_ids_json, added_at, export_set_id)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            label = excluded.label,
            origin_path = excluded.origin_path,
            export_set_id = excluded.export_set_id;
        """, [
            .text(source.id.uuidString),
            .text(source.kind.rawValue),
            .text(source.label),
            source.originPath.map { SQLValue.text($0) } ?? .null,
            // `desired_copies` and `destination_ids_json` are NOT NULL on
            // catalogs written before policy moved to `storage_groups`, and
            // SQLite has no DROP for a NOT NULL column without rebuilding the
            // table. They are written once with placeholders and never read:
            // the group is the only answer to what a photo owes.
            .int(0),
            .text("[]"),
            .real(source.addedAt.timeIntervalSince1970),
            source.exportSetID.map { SQLValue.text($0) } ?? .null,
        ])
    }

    func fetchSources() throws -> [PhotoArchiveSource] {
        try database.query("""
        SELECT id, kind, label, origin_path, added_at, export_set_id
        FROM sources ORDER BY added_at DESC;
        """) { row in
            PhotoArchiveSource(
                id: row.uuid(0),
                kind: PhotoArchiveSource.Kind(rawValue: row.text(1)) ?? .folder,
                label: row.text(2),
                originPath: row.optionalText(3),
                exportSetID: row.optionalText(5),
                addedAt: Date(timeIntervalSince1970: row.real(4))
            )
        }
    }

    func deleteSource(id: UUID) throws {
        // Assets keep pointing at a source that is gone rather than being
        // deleted with it: forgetting how photos arrived must never be the
        // same action as forgetting the photos. `AppStore` re-homes them.
        try database.run("UPDATE assets SET source_id = NULL WHERE source_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM sources WHERE id = ?;", [.text(id.uuidString)])
    }

    /// Points a set of assets at a source. Used by import and by the backfill.
    func assignSource(_ sourceID: UUID, toAssets assetIDs: [UUID]) throws {
        guard !assetIDs.isEmpty else { return }
        for assetID in assetIDs {
            try database.run(
                "UPDATE assets SET source_id = ? WHERE id = ?;",
                [.text(sourceID.uuidString), .text(assetID.uuidString)]
            )
        }
    }

    /// Asset ids that belong to no source yet — what the backfill has to place.
    func fetchAssetIDsWithoutSource() throws -> [UUID] {
        try database.query("SELECT id FROM assets WHERE source_id IS NULL;") { $0.uuid(0) }
    }

    /// One source's asset ids, for placement and status without loading rows.
    func fetchAssetIDs(forSource sourceID: UUID) throws -> [UUID] {
        try database.query(
            "SELECT id FROM assets WHERE source_id = ?;",
            [.text(sourceID.uuidString)]
        ) { $0.uuid(0) }
    }

    /// Every asset's source, in one query.
    ///
    /// Deliberately a side map rather than a field on `Asset`. Placement needs
    /// asset → source constantly, and threading a new column through the asset
    /// row, its insert, its select and every construction site is a large
    /// diff for a lookup that is one query and a dictionary. If `Asset` ever
    /// needs its source for its own sake, that is the moment to move it.
    func fetchSourceIDsByAsset() throws -> [UUID: UUID] {
        let pairs = try database.query(
            "SELECT id, source_id FROM assets WHERE source_id IS NOT NULL;"
        ) { row in (row.uuid(0), row.optionalUUID(1)) }
        return pairs.reduce(into: [UUID: UUID]()) { map, pair in
            if let sourceID = pair.1 { map[pair.0] = sourceID }
        }
    }
}
