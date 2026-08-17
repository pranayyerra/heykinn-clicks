import Foundation

/// Change capture that a write path cannot forget to use.
///
/// **Why this replaces wrapping each write.** The wrapper was opt-in: a caller
/// had to remember to go through it, and eleven write paths did not — assigning
/// a photo to a group, pointing it at a source, repointing a copy that moved,
/// deleting a photo. Every one produced changes no other device was ever told
/// about, and the symptom was not an error but one device quietly holding a
/// different answer. A trigger cannot be bypassed, so the question stops being
/// "did somebody remember" and becomes a property of the table.
///
/// It also does for free what the wrapper needed two extra row reads to do:
/// `WHEN OLD.x IS NOT NEW.x` is per-field diffing, `AFTER INSERT` is the
/// whole-row case, and a bulk `UPDATE` fires once per row rather than needing a
/// special path.
///
/// **How a trigger gets a clock reading.** It cannot call into Swift, and it
/// does not need to. One row holds the current wall time, a counter and this
/// device's id; the trigger formats them with `printf` into exactly the stamp
/// encoding of `SPEC-format.md` §1.3, then bumps the counter so the next firing
/// gets a distinct one. Plain SQL — no extension, and the same triggers work on
/// any platform that opens the catalog.
enum ChangeTriggers {

    /// Prefix for every trigger this installs, so they can all be found and
    /// dropped without touching anything else.
    static let prefix = "hk_change_"

    /// The stamp a firing trigger will use, formatted in SQL.
    ///
    /// `%015d-%06d-%s` is the encoding in `HLCTimestamp.encoded`, and the two
    /// agree character for character — SQLite's `printf` zero-pads the same way.
    private static let stampExpression = """
    (SELECT printf('%015d-%06d-%s', wall_millis, counter, device_id) \
    FROM change_pending_stamp WHERE id = 0)
    """

    private static let bumpCounter =
        "UPDATE change_pending_stamp SET counter = counter + 1 WHERE id = 0;"

    /// Every trigger is guarded by this.
    ///
    /// **Applying another device's change must not look like making one.** A
    /// merge writes rows, which would fire these triggers and stamp them with
    /// *this* device's clock — so a change received from another device would be
    /// recorded as one this device made, and published straight back. Two
    /// devices would then echo the same change at each other for ever, each
    /// seeing it as news.
    ///
    /// The merge sets this while it applies, and writes the incoming stamps
    /// itself. See `ChangeJournal.suppressingTriggers`.
    private static let notSuppressed =
        "(SELECT suppressed FROM change_pending_stamp WHERE id = 0) = 0"

    // MARK: - Installing

    /// Drops every trigger this owns and rebuilds them from the live schema.
    ///
    /// Rebuilt rather than created once, because a column added by a later
    /// migration needs a trigger of its own — and a trigger left behind for a
    /// column that has since gone is a broken write path. Running the whole set
    /// each time the schema is applied keeps them in step by construction.
    static func install(in database: SQLiteDatabase, tables: Set<String>) throws {
        try createStampTable(in: database)

        let existing = try database.query("""
        SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '\(prefix)%';
        """) { $0.text(0) }
        for name in existing {
            try database.exec("DROP TRIGGER IF EXISTS \"\(escape(name))\";")
        }

        for table in tables.sorted() {
            guard let columns = try columns(of: table, in: database), !columns.isEmpty else {
                continue
            }
            let keys = try keyColumns(of: table, in: database)
            guard !keys.isEmpty else { continue }

            try database.exec(insertTrigger(table: table, keys: keys))
            try database.exec(deleteTrigger(table: table, keys: keys))
            for column in columns {
                try database.exec(updateTrigger(table: table, column: column, keys: keys))
            }
        }
    }

    private static func createStampTable(in database: SQLiteDatabase) throws {
        try database.exec("""
        -- What a firing trigger stamps with. One row, set by the app.
        --
        -- The counter is bumped by the triggers themselves, so every firing
        -- gets a distinct stamp without the app having to issue one per write.
        -- The app refreshes the wall time; see `ChangeJournal.refreshStamp`.
        CREATE TABLE IF NOT EXISTS change_pending_stamp (
            id          INTEGER PRIMARY KEY CHECK (id = 0),
            wall_millis INTEGER NOT NULL,
            counter     INTEGER NOT NULL,
            device_id   TEXT    NOT NULL,
            -- Set while a merge applies another device's changes, so those are
            -- not recorded as changes this device made.
            suppressed  INTEGER NOT NULL DEFAULT 0
        );
        """)
    }

    // MARK: - The triggers

    /// A new row: one whole-row stamp, and any tombstone for it is lifted
    /// because the row is live again.
    private static func insertTrigger(table: String, keys: [String]) -> String {
        """
        CREATE TRIGGER "\(prefix)\(escape(table))_ins" AFTER INSERT ON "\(escape(table))"
        WHEN \(notSuppressed)
        BEGIN
            INSERT INTO change_field_versions (table_name, row_id, column_name, hlc)
            VALUES ('\(quoted(table))', \(rowIDExpression(keys, "NEW")), '*', \(stampExpression))
            ON CONFLICT(table_name, row_id, column_name) DO UPDATE SET hlc = excluded.hlc;
            DELETE FROM change_row_tombstones
             WHERE table_name = '\(quoted(table))' AND row_id = \(rowIDExpression(keys, "NEW"));
            \(bumpCounter)
        END;
        """
    }

    /// One column moved. `IS NOT` rather than `<>` so a value becoming NULL, or
    /// arriving from NULL, counts as the change it is.
    private static func updateTrigger(table: String, column: String, keys: [String]) -> String {
        """
        CREATE TRIGGER "\(prefix)\(escape(table))_upd_\(escape(column))"
        AFTER UPDATE OF "\(escape(column))" ON "\(escape(table))"
        WHEN OLD."\(escape(column))" IS NOT NEW."\(escape(column))" AND \(notSuppressed)
        BEGIN
            INSERT INTO change_field_versions (table_name, row_id, column_name, hlc)
            VALUES ('\(quoted(table))', \(rowIDExpression(keys, "NEW")),
                    '\(quoted(column))', \(stampExpression))
            ON CONFLICT(table_name, row_id, column_name) DO UPDATE SET hlc = excluded.hlc;
            \(bumpCounter)
        END;
        """
    }

    /// A tombstone, and the row's field stamps go with it — a deleted row has
    /// no fields, and leaving them would let a later merge treat the row as
    /// still present.
    private static func deleteTrigger(table: String, keys: [String]) -> String {
        """
        CREATE TRIGGER "\(prefix)\(escape(table))_del" AFTER DELETE ON "\(escape(table))"
        WHEN \(notSuppressed)
        BEGIN
            INSERT INTO change_row_tombstones (table_name, row_id, hlc)
            VALUES ('\(quoted(table))', \(rowIDExpression(keys, "OLD")), \(stampExpression))
            ON CONFLICT(table_name, row_id) DO UPDATE SET hlc = excluded.hlc;
            DELETE FROM change_field_versions
             WHERE table_name = '\(quoted(table))' AND row_id = \(rowIDExpression(keys, "OLD"));
            \(bumpCounter)
        END;
        """
    }

    /// The row id, built in SQL to be byte-identical to `ChangeJournal.rowID`.
    ///
    /// `length(CAST(x AS BLOB))` rather than `length(x)`: the encoding counts
    /// **UTF-8 bytes**, and SQLite's `length` on text counts characters. On a
    /// name holding an accent the two differ, and a row id that differs is a row
    /// nobody can find.
    private static func rowIDExpression(_ keys: [String], _ row: String) -> String {
        keys.map { key in
            "printf('%d:%s', length(CAST(\(row).\"\(escape(key))\" AS BLOB)), \(row).\"\(escape(key))\")"
        }.joined(separator: " || ")
    }

    // MARK: - Schema questions

    private static func columns(of table: String, in database: SQLiteDatabase) throws -> [String]? {
        let known = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;", [.text(table)]
        ) { $0.text(0) }
        guard known.first != nil else { return nil }
        return try database.query("PRAGMA table_info(\"\(escape(table))\");") { $0.text(1) }
    }

    private static func keyColumns(of table: String, in database: SQLiteDatabase) throws -> [String] {
        try database.query("PRAGMA table_info(\"\(escape(table))\");") {
            (name: $0.text(1), position: $0.int(5))
        }
        .filter { $0.position > 0 }
        .sorted { $0.position < $1.position }
        .map(\.name)
    }

    private static func escape(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private static func quoted(_ literal: String) -> String {
        literal.replacingOccurrences(of: "'", with: "''")
    }
}
