import Foundation

extension CatalogStore {

    // MARK: - Device-local target state

    /// Where each target was last seen *from this device*.
    ///
    /// Split out of `drives` because those columns answer a different question
    /// from the rest of the row. `name`, `marker_token` and `replica_root` are
    /// facts about the archive and are the same wherever it is opened;
    /// `last_mount_path` is `/Volumes/My Passport` **on this device**, and on
    /// another device it names nothing — on Android it would not even be a
    /// path. Once metadata travels between devices on a drive, a table that
    /// mixes the two kinds is a table that cannot be shipped at all.
    ///
    /// `configured_path` moves for the same reason and one more: a host-device
    /// target belongs to exactly one device, so its folder is not merely
    /// useless elsewhere but actively misleading — another device would try to
    /// resolve a path that exists there under a different owner.
    ///
    /// Nothing is deleted from `drives`. The columns stay where they are and
    /// are still written (see `upsertTarget`), because a build that predates
    /// this split is installed right now and reads them. Reads here come from
    /// this table only, so the two cannot disagree about which is authoritative.
    func createDriveLocalStateSchema() throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS drive_local_state (
            drive_id TEXT PRIMARY KEY,
            last_seen_at REAL,
            last_mount_path TEXT,
            configured_path TEXT
        );
        """)

        // Carry across what the pre-split columns hold, once. Restricted to
        // targets with no row yet, so it is idempotent and so a later run
        // cannot overwrite this device's own state with whatever an older
        // build last wrote into `drives`.
        try database.exec("""
        INSERT INTO drive_local_state (drive_id, last_seen_at, last_mount_path, configured_path)
        SELECT id, last_seen_at, last_mount_path, configured_path FROM drives
         WHERE id NOT IN (SELECT drive_id FROM drive_local_state);
        """)
    }

    // MARK: - Replication targets

    // The table and its columns are still named "drives": renaming them would
    // be a destructive migration of the one table that says where the user's
    // archive lives, to buy nothing a mapping here does not.
    /// Writes a target's shared identity and this device's view of it.
    ///
    /// `ReplicationTarget` deliberately still carries both: it is the in-memory
    /// picture of a device, and every screen wants the name and the mount path
    /// together. The split is a storage boundary, not a domain one, so it stops
    /// here and nothing above the persistence layer changed.
    func upsertTarget(_ target: ReplicationTarget) throws {
        try journaled("drives", [target.id.uuidString]) {
            try database.run("""
            INSERT INTO drives (id, name, volume_uuid, marker_token, registered_at, last_seen_at, replica_root, last_mount_path, kind, configured_path, free_bytes)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                volume_uuid = excluded.volume_uuid,
                marker_token = excluded.marker_token,
                registered_at = excluded.registered_at,
                last_seen_at = excluded.last_seen_at,
                replica_root = excluded.replica_root,
                last_mount_path = excluded.last_mount_path,
                kind = excluded.kind,
                configured_path = excluded.configured_path,
                free_bytes = excluded.free_bytes;
            """, [
                .text(target.id.uuidString),
                .text(target.name),
                .optionalText(target.volumeUUID),
                .text(target.markerToken),
                .date(target.registeredAt),
                // `last_seen_at`, `last_mount_path` and `configured_path` are still
                // written into `drives` as well, and this is the only reason they
                // are: a build that predates the split is installed right now and
                // reads them there. Nothing here reads them back — `fetchTargets`
                // takes all three from `drive_local_state` — so there is no
                // question of which is authoritative. Drop them from this statement
                // once no build that reads them is still in use.
                .date(target.lastSeenAt),
                .text(target.replicaRootComponent),
                .optionalText(target.lastKnownPath),
                .text(target.kind.rawValue),
                .optionalText(target.configuredPath),
                .optionalInt(target.lastKnownFreeBytes),
            ])
        }

        try database.run("""
        INSERT INTO drive_local_state (drive_id, last_seen_at, last_mount_path, configured_path)
        VALUES (?,?,?,?)
        ON CONFLICT(drive_id) DO UPDATE SET
            last_seen_at = excluded.last_seen_at,
            last_mount_path = excluded.last_mount_path,
            configured_path = excluded.configured_path;
        """, [
            .text(target.id.uuidString),
            .date(target.lastSeenAt),
            .optionalText(target.lastKnownPath),
            .optionalText(target.configuredPath),
        ])
    }

    func fetchTargets() throws -> [ReplicationTarget] {
        // LEFT JOIN, so a target this device has never seen still comes back —
        // with no mount path, which is the truthful answer rather than a
        // missing row. That is exactly the state a device registered on another
        // device arrives in once targets travel.
        try database.query("""
        SELECT d.id, d.name, d.volume_uuid, d.marker_token, d.registered_at, d.replica_root, d.kind,
               l.last_seen_at, l.last_mount_path, l.configured_path, d.free_bytes
        FROM drives d
        LEFT JOIN drive_local_state l ON l.drive_id = d.id
        ORDER BY d.registered_at;
        """) { row in
            ReplicationTarget(
                id: row.uuid(0),
                name: row.text(1),
                // Rows written before targets existed are all external drives,
                // which is exactly what the app could register at the time.
                kind: TargetKind(rawValue: row.optionalText(6) ?? "") ?? .externalVolume,
                volumeUUID: row.optionalText(2),
                markerToken: row.text(3),
                registeredAt: row.date(4),
                lastSeenAt: row.optionalDate(7),
                lastKnownPath: row.optionalText(8),
                configuredPath: row.optionalText(9),
                replicaRootComponent: row.text(5),
                lastKnownFreeBytes: row.optionalInt(10)
            )
        }
    }

    /// Removes a target and everything the catalog tracked about it. Only
    /// catalog rows: files on the target itself are never touched.
    func deleteTarget(id: UUID) throws {
        // Every replica claim this device carried is tombstoned individually by
        // the delete trigger on `replica_states`, one per row — a row that
        // simply vanishes is indistinguishable, on another device, from one it
        // has never been told about, and the next merge would hand them all
        // back.
        //
        // `replication_tasks` and `drive_local_state` are this device's own and
        // have no triggers, because they never travelled: there is nothing to
        // tell anyone about.
        try database.run("DELETE FROM replica_states WHERE drive_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM replication_tasks WHERE drive_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM drive_local_state WHERE drive_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM drives WHERE id = ?;", [.text(id.uuidString)])
    }

    // MARK: - Replica states

    func upsertReplicaState(_ replica: TargetReplicaState) throws {
        try journaled("replica_states", [replica.assetID.uuidString, replica.targetID.uuidString]) {
            try database.run("""
            INSERT INTO replica_states (
                asset_id, drive_id, state, relative_path, last_verified_at,
                observed_size, observed_modified_at
            )
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(asset_id, drive_id) DO UPDATE SET
                state = excluded.state,
                relative_path = excluded.relative_path,
                last_verified_at = excluded.last_verified_at,
                observed_size = excluded.observed_size,
                observed_modified_at = excluded.observed_modified_at;
            """, [
                .text(replica.assetID.uuidString),
                .text(replica.targetID.uuidString),
                .text(replica.state.rawValue),
                .optionalText(replica.relativePath),
                .date(replica.lastVerifiedAt),
                .optionalInt(replica.observedSize),
                .date(replica.observedModifiedAt),
            ])
        }
    }

    /// Forgets one device's claim on one asset.
    ///
    /// Only for claims that were never made good — an intention to copy onto a
    /// device the asset's source no longer names. A row describing bytes that
    /// exist is never dropped this way: losing the record of a copy is how the
    /// app ends up unable to find, check, or reclaim it.
    func deleteReplicaState(assetID: UUID, targetID: UUID) throws {
        try database.run(
            "DELETE FROM replica_states WHERE asset_id = ? AND drive_id = ?;",
            [.text(assetID.uuidString), .text(targetID.uuidString)]
        )
    }

    func fetchReplicaStates() throws -> [TargetReplicaState] {
        try database.query("""
        SELECT asset_id, drive_id, state, relative_path, last_verified_at,
               observed_size, observed_modified_at
        FROM replica_states;
        """) { row in
            TargetReplicaState(
                assetID: row.uuid(0),
                targetID: row.uuid(1),
                state: ReplicaFileState(rawValue: row.text(2)) ?? .pending,
                relativePath: row.optionalText(3),
                lastVerifiedAt: row.optionalDate(4),
                observedSize: row.optionalInt(5),
                observedModifiedAt: row.optionalDate(6)
            )
        }
    }

    // MARK: - Replication tasks

    func upsertReplicationTask(_ task: ReplicationTask) throws {
        try database.run("""
        INSERT INTO replication_tasks (id, asset_id, drive_id, action, state, queued_at, completed_at, error_message)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            asset_id = excluded.asset_id,
            drive_id = excluded.drive_id,
            action = excluded.action,
            state = excluded.state,
            queued_at = excluded.queued_at,
            completed_at = excluded.completed_at,
            error_message = excluded.error_message;
        """, [
            .text(task.id.uuidString),
            .text(task.assetID.uuidString),
            .text(task.targetID.uuidString),
            .text(task.action.rawValue),
            .text(task.state.rawValue),
            .date(task.queuedAt),
            .date(task.completedAt),
            .optionalText(task.errorMessage),
        ])
    }

    /// Removes a queued unit of work. Only used to discard tasks that can be
    /// re-queued on demand; it never touches replica state or files.
    func deleteReplicationTask(id: UUID) throws {
        try database.run("DELETE FROM replication_tasks WHERE id = ?;", [.text(id.uuidString)])
    }

    func fetchReplicationTasks() throws -> [ReplicationTask] {
        try database.query("""
        SELECT id, asset_id, drive_id, action, state, queued_at, completed_at, error_message
        FROM replication_tasks ORDER BY queued_at;
        """) { row in
            ReplicationTask(
                id: row.uuid(0),
                assetID: row.uuid(1),
                targetID: row.uuid(2),
                action: ReplicationAction(rawValue: row.text(3)) ?? .copy,
                state: ReplicationTaskState(rawValue: row.text(4)) ?? .queued,
                queuedAt: row.date(5),
                completedAt: row.optionalDate(6),
                errorMessage: row.optionalText(7)
            )
        }
    }
}
