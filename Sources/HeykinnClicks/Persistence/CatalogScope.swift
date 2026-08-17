import Foundation

/// Which catalog tables describe the archive, and which describe this device.
///
/// **Why this is code and not a paragraph in a document.** The archive is meant
/// to be one thing across several devices, reached by carrying metadata on the
/// drives (`docs/MULTI_DEVICE_STATE.md`). The moment anything ships state
/// between devices it has to know what is safe to ship, and a list that lives
/// only in prose is a list somebody forgets to add to. `CatalogScopeTests`
/// fails when a table exists in the schema and is not named here, so the
/// question gets asked when the table is written rather than a year later when
/// something syncs a `/Volumes` path onto a device that has no such path.
///
/// Nothing reads this yet. It is written before the change journal that needs
/// it, because deciding what a table *is* while adding it is cheap, and
/// deciding retrospectively for sixteen tables at once is how the wrong answer
/// gets picked for one of them.
enum CatalogScope {

    /// Facts about the archive. True regardless of which device is asking, so
    /// these are what "one archive across several devices" is made of.
    ///
    /// Anything here needs per-field ordering metadata before it can travel —
    /// see `MULTI_DEVICE_STATE.md` §6.3. Being listed here is a statement that
    /// it *should* travel, not that it can yet.
    static let shared: Set<String> = [
        "assets",
        "asset_tags",
        "drives",
        "export_capture_versions",
        "import_batches",
        "metadata_records",
        "metadata_schemas",
        "migration_jobs",
        "policy_rules",
        "replica_states",
        "sources",
        "storage_groups",
        // One row per (group, destination), so two devices each adding a
        // different drive merge instead of one overwriting the other.
        "storage_group_destinations",
        "takeout_archives",
    ]

    /// Facts about *this* device. Meaningless anywhere else, and actively
    /// wrong if carried: a mount path from another device names nothing here, and
    /// on Android would not even be a path.
    static let deviceLocal: Set<String> = [
        // Where each target was last seen *from this device*, and the folder a
        // host-device target occupies on it. Split out of `drives` rather than
        // left mixed into it — see `CatalogStore+Drives.swift`.
        "drive_local_state",
        // An intention to copy bytes onto a target *this device can reach*.
        // Carrying it would have one device queueing work against a drive
        // plugged into another. Each device derives its own from the shared
        // `replica_states`.
        "replication_tasks",
        // Explicitly a cache — "losing it costs time and nothing else" — and
        // keyed by local path, which makes it meaningless elsewhere twice over.
        "import_scan_memo",
    ]

    /// Append-only, and therefore free: the union of two devices' logs is a
    /// valid log, so this needs no conflict rules at all.
    ///
    /// Kept apart from `shared` because that difference is the whole reason it
    /// is easy, and folding it in would hide the one table nothing has to be
    /// decided about.
    static let appendOnly: Set<String> = [
        "audit_events",
    ]

    /// The journal's own bookkeeping — when each field was last written, which
    /// rows are deleted, and this archive's clock.
    ///
    /// A fourth category rather than forced into one of the three above,
    /// because these are not *about* the archive or the device: they are how
    /// changes to the other tables are ordered and merged. They travel as
    /// derived change records rather than as rows, which is a different
    /// mechanism from anything else here and is worth not blurring.
    static let journal: Set<String> = [
        "change_field_versions",
        "change_row_tombstones",
        "change_clock",
        "change_watermarks",
        // What a firing trigger stamps with, and whether capture is suppressed
        // while a merge applies somebody else's changes.
        "change_pending_stamp",
    ]

    /// Everything classified, for the test that nothing has been missed.
    static let allClassified: Set<String> =
        shared.union(deviceLocal).union(appendOnly).union(journal)

    /// Whether a table's rows may be carried to another device.
    ///
    /// This is also the allow-list the merge checks a record's table name
    /// against. Records arrive from a file on a removable drive, so a table
    /// name in one is input rather than instruction, and nothing outside this
    /// set may reach a statement.
    static func travels(_ table: String) -> Bool {
        shared.contains(table) || appendOnly.contains(table)
    }
}
