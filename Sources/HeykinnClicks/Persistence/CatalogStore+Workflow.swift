import Foundation

extension CatalogStore {

    // MARK: - Policy rules

    func upsertPolicyRule(_ rule: PolicyRule) throws {
        try database.run("""
        INSERT INTO policy_rules (id, name, priority, enabled, match_origin, match_kind, min_file_size, target_residency)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            priority = excluded.priority,
            enabled = excluded.enabled,
            match_origin = excluded.match_origin,
            match_kind = excluded.match_kind,
            min_file_size = excluded.min_file_size,
            target_residency = excluded.target_residency;
        """, [
            .text(rule.id.uuidString),
            .text(rule.name),
            .int(Int64(rule.priority)),
            .bool(rule.isEnabled),
            .optionalText(rule.matchOrigin?.rawValue),
            .optionalText(rule.matchKind?.rawValue),
            .optionalInt(rule.minFileSize),
            .text(rule.targetResidency.rawValue),
        ])
    }

    func fetchPolicyRules() throws -> [PolicyRule] {
        try database.query("""
        SELECT id, name, priority, enabled, match_origin, match_kind, min_file_size, target_residency
        FROM policy_rules ORDER BY priority DESC;
        """) { row in
            PolicyRule(
                id: row.uuid(0),
                name: row.text(1),
                priority: Int(row.int(2)),
                isEnabled: row.bool(3),
                matchOrigin: row.optionalText(4).flatMap(ImportOrigin.init(rawValue:)),
                matchKind: row.optionalText(5).flatMap(AssetKind.init(rawValue:)),
                minFileSize: row.optionalInt(6),
                targetResidency: ResidencyDomain(rawValue: row.text(7)) ?? .local
            )
        }
    }

    func deletePolicyRule(id: UUID) throws {
        try database.run("DELETE FROM policy_rules WHERE id = ?;", [.text(id.uuidString)])
    }

    // MARK: - Migration jobs

    func upsertMigrationJob(_ job: MigrationJob) throws {
        try database.run("""
        INSERT INTO migration_jobs (id, asset_ids_json, from_domain, to_domain, state, created_at, updated_at, note)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            asset_ids_json = excluded.asset_ids_json,
            from_domain = excluded.from_domain,
            to_domain = excluded.to_domain,
            state = excluded.state,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            note = excluded.note;
        """, [
            .text(job.id.uuidString),
            .text(Self.encodeJSON(job.assetIDs)),
            .text(job.fromDomain.rawValue),
            .text(job.toDomain.rawValue),
            .text(job.state.rawValue),
            .date(job.createdAt),
            .date(job.updatedAt),
            .optionalText(job.note),
        ])
    }

    func fetchMigrationJobs() throws -> [MigrationJob] {
        try database.query("""
        SELECT id, asset_ids_json, from_domain, to_domain, state, created_at, updated_at, note
        FROM migration_jobs ORDER BY created_at DESC;
        """) { row in
            MigrationJob(
                id: row.uuid(0),
                assetIDs: Self.decodeJSON([UUID].self, from: row.optionalText(1)) ?? [],
                fromDomain: ResidencyDomain(rawValue: row.text(2)) ?? .local,
                toDomain: ResidencyDomain(rawValue: row.text(3)) ?? .local,
                state: MigrationState(rawValue: row.text(4)) ?? .pending,
                createdAt: row.date(5),
                updatedAt: row.date(6),
                note: row.optionalText(7)
            )
        }
    }

    // MARK: - Import batches

    func upsertImportBatch(_ batch: ImportBatch) throws {
        try database.run("""
        INSERT INTO import_batches (id, source_path, started_at, completed_at, imported_count, duplicate_count, failed_count)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            source_path = excluded.source_path,
            started_at = excluded.started_at,
            completed_at = excluded.completed_at,
            imported_count = excluded.imported_count,
            duplicate_count = excluded.duplicate_count,
            failed_count = excluded.failed_count;
        """, [
            .text(batch.id.uuidString),
            .text(batch.sourcePath),
            .date(batch.startedAt),
            .date(batch.completedAt),
            .int(Int64(batch.importedCount)),
            .int(Int64(batch.duplicateCount)),
            .int(Int64(batch.failedCount)),
        ])
    }

    func fetchImportBatches() throws -> [ImportBatch] {
        try database.query("""
        SELECT id, source_path, started_at, completed_at, imported_count, duplicate_count, failed_count
        FROM import_batches ORDER BY started_at DESC;
        """) { row in
            ImportBatch(
                id: row.uuid(0),
                sourcePath: row.text(1),
                startedAt: row.date(2),
                completedAt: row.optionalDate(3),
                importedCount: Int(row.int(4)),
                duplicateCount: Int(row.int(5)),
                failedCount: Int(row.int(6))
            )
        }
    }

    // MARK: - Audit events

    func appendAuditEvent(_ event: AuditEvent) throws {
        try database.run("""
        INSERT INTO audit_events (id, at, category, message, asset_id, drive_id)
        VALUES (?,?,?,?,?,?);
        """, [
            .text(event.id.uuidString),
            .date(event.at),
            .text(event.category.rawValue),
            .text(event.message),
            .uuid(event.assetID),
            .uuid(event.targetID),
        ])
    }

    func fetchAuditEvents(limit: Int = 500) throws -> [AuditEvent] {
        try database.query("""
        SELECT id, at, category, message, asset_id, drive_id
        FROM audit_events ORDER BY at DESC LIMIT ?;
        """, [.int(Int64(limit))]) { row in
            AuditEvent(
                id: row.uuid(0),
                at: row.date(1),
                category: AuditCategory(rawValue: row.text(2)) ?? .system,
                message: row.text(3),
                assetID: row.optionalUUID(4),
                targetID: row.optionalUUID(5)
            )
        }
    }
}
