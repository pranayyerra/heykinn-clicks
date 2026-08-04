import Foundation

extension CatalogStore {

    // MARK: - Replication targets

    // The table and its columns are still named "drives": renaming them would
    // be a destructive migration of the one table that says where the user's
    // archive lives, to buy nothing a mapping here does not.
    func upsertTarget(_ target: ReplicationTarget) throws {
        try database.run("""
        INSERT INTO drives (id, name, volume_uuid, marker_token, registered_at, last_seen_at, replica_root, last_mount_path, kind, configured_path)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            volume_uuid = excluded.volume_uuid,
            marker_token = excluded.marker_token,
            registered_at = excluded.registered_at,
            last_seen_at = excluded.last_seen_at,
            replica_root = excluded.replica_root,
            last_mount_path = excluded.last_mount_path,
            kind = excluded.kind,
            configured_path = excluded.configured_path;
        """, [
            .text(target.id.uuidString),
            .text(target.name),
            .optionalText(target.volumeUUID),
            .text(target.markerToken),
            .date(target.registeredAt),
            .date(target.lastSeenAt),
            .text(target.replicaRootComponent),
            .optionalText(target.lastKnownPath),
            .text(target.kind.rawValue),
            .optionalText(target.configuredPath),
        ])
    }

    func fetchTargets() throws -> [ReplicationTarget] {
        try database.query("""
        SELECT id, name, volume_uuid, marker_token, registered_at, last_seen_at, replica_root, last_mount_path, kind, configured_path
        FROM drives ORDER BY registered_at;
        """) { row in
            ReplicationTarget(
                id: row.uuid(0),
                name: row.text(1),
                // Rows written before targets existed are all external drives,
                // which is exactly what the app could register at the time.
                kind: TargetKind(rawValue: row.optionalText(8) ?? "") ?? .externalVolume,
                volumeUUID: row.optionalText(2),
                markerToken: row.text(3),
                registeredAt: row.date(4),
                lastSeenAt: row.optionalDate(5),
                lastKnownPath: row.optionalText(7),
                configuredPath: row.optionalText(9),
                replicaRootComponent: row.text(6)
            )
        }
    }

    /// Removes a target and everything the catalog tracked about it. Only
    /// catalog rows: files on the target itself are never touched.
    func deleteTarget(id: UUID) throws {
        try database.run("DELETE FROM replica_states WHERE drive_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM replication_tasks WHERE drive_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM drives WHERE id = ?;", [.text(id.uuidString)])
    }

    // MARK: - Replica states

    func upsertReplicaState(_ replica: TargetReplicaState) throws {
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
