import Foundation

extension CatalogStore {

    // MARK: - Managed drives

    func upsertDrive(_ drive: ManagedDrive) throws {
        try database.run("""
        INSERT INTO drives (id, name, volume_uuid, marker_token, registered_at, last_seen_at, replica_root)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            volume_uuid = excluded.volume_uuid,
            marker_token = excluded.marker_token,
            registered_at = excluded.registered_at,
            last_seen_at = excluded.last_seen_at,
            replica_root = excluded.replica_root;
        """, [
            .text(drive.id.uuidString),
            .text(drive.name),
            .optionalText(drive.volumeUUID),
            .text(drive.markerToken),
            .date(drive.registeredAt),
            .date(drive.lastSeenAt),
            .text(drive.replicaRootComponent),
        ])
    }

    func fetchDrives() throws -> [ManagedDrive] {
        try database.query("""
        SELECT id, name, volume_uuid, marker_token, registered_at, last_seen_at, replica_root
        FROM drives ORDER BY registered_at;
        """) { row in
            ManagedDrive(
                id: row.uuid(0),
                name: row.text(1),
                volumeUUID: row.optionalText(2),
                markerToken: row.text(3),
                registeredAt: row.date(4),
                lastSeenAt: row.optionalDate(5),
                replicaRootComponent: row.text(6)
            )
        }
    }

    // MARK: - Replica states

    func upsertReplicaState(_ replica: DriveReplicaState) throws {
        try database.run("""
        INSERT INTO replica_states (asset_id, drive_id, state, relative_path, last_verified_at)
        VALUES (?,?,?,?,?)
        ON CONFLICT(asset_id, drive_id) DO UPDATE SET
            state = excluded.state,
            relative_path = excluded.relative_path,
            last_verified_at = excluded.last_verified_at;
        """, [
            .text(replica.assetID.uuidString),
            .text(replica.driveID.uuidString),
            .text(replica.state.rawValue),
            .optionalText(replica.relativePath),
            .date(replica.lastVerifiedAt),
        ])
    }

    func fetchReplicaStates() throws -> [DriveReplicaState] {
        try database.query("""
        SELECT asset_id, drive_id, state, relative_path, last_verified_at FROM replica_states;
        """) { row in
            DriveReplicaState(
                assetID: row.uuid(0),
                driveID: row.uuid(1),
                state: ReplicaFileState(rawValue: row.text(2)) ?? .pending,
                relativePath: row.optionalText(3),
                lastVerifiedAt: row.optionalDate(4)
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
            .text(task.driveID.uuidString),
            .text(task.action.rawValue),
            .text(task.state.rawValue),
            .date(task.queuedAt),
            .date(task.completedAt),
            .optionalText(task.errorMessage),
        ])
    }

    func fetchReplicationTasks() throws -> [ReplicationTask] {
        try database.query("""
        SELECT id, asset_id, drive_id, action, state, queued_at, completed_at, error_message
        FROM replication_tasks ORDER BY queued_at;
        """) { row in
            ReplicationTask(
                id: row.uuid(0),
                assetID: row.uuid(1),
                driveID: row.uuid(2),
                action: ReplicationAction(rawValue: row.text(3)) ?? .copy,
                state: ReplicationTaskState(rawValue: row.text(4)) ?? .queued,
                queuedAt: row.date(5),
                completedAt: row.optionalDate(6),
                errorMessage: row.optionalText(7)
            )
        }
    }
}
