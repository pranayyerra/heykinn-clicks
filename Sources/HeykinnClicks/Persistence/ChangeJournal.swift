import Foundation

/// What this device knows about when each field was last written, and by whom.
///
/// This is the state that makes two archives able to converge. The **values**
/// stay where they always were, in the ordinary tables; what is added here is a
/// stamp per field, so that when two devices have both written the same row the
/// question "which of these is later" has an answer both of them compute the
/// same way.
///
/// Per field rather than per row, because verifying a photo on one device and
/// re-grouping it on another are not in conflict and a row-scoped stamp cannot
/// say so — one of the two edits would be lost for no reason.
///
/// **Nothing ships yet.** No segment format exists, so this records and merges
/// but is not wired to a drive. That is deliberate: the merge rules are the part
/// that is hard to get right and easy to get wrong invisibly, and they are worth
/// proving on one device before removable media, torn writes and physical
/// latency join the debugging surface.
final class ChangeJournal {

    /// Stands for "every column of this row, at this stamp".
    ///
    /// Written when a row is created, where the alternative is one identical
    /// stamp per column — 29 rows per asset on this schema, and 16× the time
    /// for an import. A column can never be called this: SQLite would need it
    /// quoted, and nothing here quotes a name into a schema.
    ///
    /// A field's effective stamp is therefore the later of its own entry and
    /// its row's whole-row entry. Updates after creation still write per-column
    /// entries, so the per-field resolution that the whole design rests on is
    /// unaffected — this is a compression of "all of it, at once", not a
    /// coarsening of the merge.
    static let wholeRow = "*"

    private let database: SQLiteDatabase
    let device: DeviceIdentity
    private let clock: HybridLogicalClock
    /// Column names per table, read from the live schema and cached. This is
    /// also the allow-list — see `merge`.
    private var columnCache: [String: [String]] = [:]
    private var primaryKeyCache: [String: [String]] = [:]
    /// When the triggers' wall time was last moved forward. See `refreshStamp`.
    private var lastStampRefresh: Date?

    init(database: SQLiteDatabase, device: DeviceIdentity, physicalNow: (() -> Int64)? = nil) throws {
        self.database = database
        self.device = device
        try Self.createSchema(in: database)
        let resuming = try Self.storedClockState(in: database)
        if let physicalNow {
            clock = HybridLogicalClock(deviceID: device.id, resuming: resuming, physicalNow: physicalNow)
        } else {
            clock = HybridLogicalClock(deviceID: device.id, resuming: resuming)
        }
        try resumeFromRecordedStamps()
    }

    /// A stamp for something happening now, persisted before it is handed out.
    ///
    /// Persisted first, and every time: a stamp that has been used but not
    /// recorded can be issued again after a crash, and two changes sharing a
    /// stamp is the one thing the ordering cannot survive. See
    /// `SPEC-format.md` §1.5.
    func stamp() throws -> HLCTimestamp {
        let issued = clock.now()
        try persistClockState(issued)
        return issued
    }

    // MARK: - The stamp the triggers use

    /// Installs the capture triggers and points them at a fresh stamp.
    func installTriggers() throws {
        try ChangeTriggers.install(in: database, tables: CatalogScope.shared.union(CatalogScope.appendOnly))
        try refreshStamp(force: true)
    }

    /// Moves the triggers' wall time forward and restarts their counter.
    ///
    /// **Not per write.** The triggers bump the counter themselves, so every
    /// firing already gets a distinct stamp; this only keeps the wall time
    /// honest, which matters because a session left open for hours would
    /// otherwise stamp everything with the time it started.
    ///
    /// Doing it per write cost more than the row reads it replaced — two writes
    /// against two reads — and made an import *slower*. Once a second bounds how
    /// stale a stamp's wall time can be while costing nothing measurable.
    func refreshStamp(force: Bool = false) throws {
        let now = Date()
        if !force, let last = lastStampRefresh, now.timeIntervalSince(last) < 1 { return }
        lastStampRefresh = now

        // The triggers have been advancing the counter without telling the
        // clock, so the clock must be brought up past whatever they reached —
        // otherwise a refresh in the same millisecond hands back a counter they
        // have already used, and two changes share a stamp.
        if let used = try currentTriggerStamp() { _ = clock.observe(used) }

        let issued = try stamp()
        try database.run("""
        INSERT INTO change_pending_stamp (id, wall_millis, counter, device_id)
        VALUES (0, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            wall_millis = excluded.wall_millis,
            counter = excluded.counter,
            device_id = excluded.device_id;
        """, [.int(issued.wallMillis), .int(Int64(issued.counter)), .text(device.id)])
    }

    /// The stamp the next trigger firing would use, or nil before any is set.
    private func currentTriggerStamp() throws -> HLCTimestamp? {
        try database.query("""
        SELECT printf('%015d-%06d-%s', wall_millis, counter, device_id)
          FROM change_pending_stamp WHERE id = 0;
        """) { $0.text(0) }.first.flatMap(HLCTimestamp.decode)
    }

    /// Runs `body` with the capture triggers switched off.
    ///
    /// For applying another device's changes. Those already carry the stamp the
    /// device that made them issued, and letting the triggers stamp them again
    /// with this device's clock would turn every received change into one this
    /// device appears to have made — which it would then publish back, and the
    /// two would echo it at each other indefinitely.
    ///
    /// Restored in a `defer`, so a merge that throws does not leave capture off.
    func suppressingTriggers<T>(_ body: () throws -> T) throws -> T {
        try database.run("UPDATE change_pending_stamp SET suppressed = 1 WHERE id = 0;")
        defer { try? database.run("UPDATE change_pending_stamp SET suppressed = 0 WHERE id = 0;") }
        return try body()
    }

    /// Brings this device's clock up to anything already recorded.
    ///
    /// The triggers advance their own counter without telling the clock, so
    /// after a session the highest stamp in the journal can be ahead of what the
    /// clock believes it issued. Reading it back on open is what stops the next
    /// launch reissuing a stamp that has already been used.
    private func resumeFromRecordedStamps() throws {
        guard let stamp = try horizon() else { return }
        _ = clock.observe(stamp)
        try persistClockState(clock.now())
    }

    /// The newest stamp this archive holds, from any device.
    ///
    /// What a checkpoint of it is worth: a reader that has applied the whole
    /// checkpoint has seen everything up to here, whoever wrote it.
    func horizon() throws -> HLCTimestamp? {
        try database.query("""
        SELECT max(hlc) FROM (
            SELECT hlc FROM change_field_versions
            UNION ALL SELECT hlc FROM change_row_tombstones
        );
        """) { $0.optionalText(0) }.compactMap { $0 }.first.flatMap(HLCTimestamp.decode)
    }

    /// Takes account of a stamp from another device, so everything this device
    /// does next sorts after it.
    @discardableResult
    func observe(_ remote: HLCTimestamp) throws -> HLCTimestamp {
        let issued = clock.observe(remote)
        try persistClockState(issued)
        return issued
    }

    /// Stamps refused for claiming a wall time implausibly far ahead — a device
    /// whose clock is wrong rather than merely inaccurate.
    var refusedFutureStamps: [HLCTimestamp] { clock.refusedFutureStamps }

    private func persistClockState(_ stamp: HLCTimestamp) throws {
        try database.run("""
        INSERT INTO change_clock (id, hlc) VALUES (0, ?)
        ON CONFLICT(id) DO UPDATE SET hlc = excluded.hlc;
        """, [.text(stamp.encoded)])
    }

    private static func storedClockState(in database: SQLiteDatabase) throws -> HLCTimestamp? {
        try database.query("SELECT hlc FROM change_clock WHERE id = 0;") { $0.text(0) }
            .first.flatMap(HLCTimestamp.decode)
    }

    // MARK: - Schema

    private static func createSchema(in database: SQLiteDatabase) throws {
        try database.exec("""
        -- One row per field that has ever been written, holding the stamp of
        -- the write that last won it. The value is not duplicated here; it is
        -- in the table it belongs to, and keeping one copy is what stops the
        -- two disagreeing.
        CREATE TABLE IF NOT EXISTS change_field_versions (
            table_name  TEXT NOT NULL,
            row_id      TEXT NOT NULL,
            column_name TEXT NOT NULL,
            hlc         TEXT NOT NULL,
            PRIMARY KEY (table_name, row_id, column_name)
        );

        CREATE INDEX IF NOT EXISTS idx_change_field_versions_hlc
            ON change_field_versions(hlc);

        -- A deleted row cannot simply be absent: absent here and absent on
        -- another device are indistinguishable from never-seen, so a merge
        -- would resurrect it. The stamp is what lets a later write legitimately
        -- bring it back and an earlier one fail to.
        CREATE TABLE IF NOT EXISTS change_row_tombstones (
            table_name TEXT NOT NULL,
            row_id     TEXT NOT NULL,
            hlc        TEXT NOT NULL,
            PRIMARY KEY (table_name, row_id)
        );

        -- The last stamp this archive issued. Single-row by construction.
        --
        -- In the catalog rather than beside it on purpose: a catalog restored
        -- from a snapshot then carries a clock that is already ahead, and a
        -- clock that only ever moves forward is exactly what is wanted. The
        -- device *id* deliberately does not travel this way — see
        -- `DeviceIdentity` — so a restored archive advances its clock without
        -- ever claiming to be the device that wrote the snapshot.
        CREATE TABLE IF NOT EXISTS change_clock (
            id  INTEGER PRIMARY KEY CHECK (id = 0),
            hlc TEXT NOT NULL
        );

        -- How far this device has read each other device's log.
        --
        -- Purely an optimisation: merges are idempotent, so re-reading from the
        -- beginning is correct and only slow. That is worth keeping true — a
        -- watermark lost with a corrupted catalog then costs time and nothing
        -- else, and a device can always be told to start over.
        CREATE TABLE IF NOT EXISTS change_watermarks (
            peer_id TEXT PRIMARY KEY,
            hlc     TEXT NOT NULL
        );
        """)
    }

    // MARK: - How far each peer has been read

    func watermark(forPeer peerID: String) throws -> HLCTimestamp? {
        try database.query(
            "SELECT hlc FROM change_watermarks WHERE peer_id = ?;", [.text(peerID)]
        ) { $0.text(0) }.first.flatMap(HLCTimestamp.decode)
    }

    func setWatermark(_ stamp: HLCTimestamp, forPeer peerID: String) throws {
        try database.run("""
        INSERT INTO change_watermarks (peer_id, hlc) VALUES (?,?)
        ON CONFLICT(peer_id) DO UPDATE SET hlc = excluded.hlc;
        """, [.text(peerID), .text(stamp.encoded)])
    }

    /// Every peer this device has read anything from, and how far.
    func watermarks() throws -> [String: String] {
        let rows = try database.query("SELECT peer_id, hlc FROM change_watermarks;") {
            (peer: $0.text(0), hlc: $0.text(1))
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.peer, $0.hlc) })
    }

    // MARK: - Schema questions, and the allow-list

    /// Every column the live schema has for `table`, or nil when there is no
    /// such table.
    private func columns(of table: String) throws -> [String]? {
        if let cached = columnCache[table] { return cached }
        // `table` is not interpolated until it has been matched against
        // `sqlite_master`, so a name arriving from a file cannot reach SQL.
        let known = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;", [.text(table)]
        ) { $0.text(0) }
        // A miss is deliberately **not** cached. The journal is opened before
        // the rest of the schema so that schema-time migrations can be stamped,
        // which means a table can legitimately be absent now and present a
        // moment later — and a cached "no such table" would outlive the
        // condition and silently stop stamping it forever.
        guard known.first != nil else { return nil }
        let names = try database.query("PRAGMA table_info(\"\(escape(table))\");") { $0.text(1) }
        columnCache[table] = names
        return names
    }

    /// The primary-key columns, in key order.
    ///
    /// Ordered by the position SQLite reports rather than by the order columns
    /// happen to be declared in — those differ, and a row id assembled in the
    /// wrong order would name a different row on a device that got it right.
    private func primaryKeyColumns(of table: String) throws -> [String] {
        if let cached = primaryKeyCache[table] { return cached }
        // Same reasoning as `columns(of:)`: absent now does not mean absent later.
        guard try columns(of: table) != nil else { return [] }
        let keys = try database.query("PRAGMA table_info(\"\(escape(table))\");") { row in
            (name: row.text(1), position: row.int(5))
        }
        .filter { $0.position > 0 }
        .sorted { $0.position < $1.position }
        .map(\.name)
        primaryKeyCache[table] = keys
        return keys
    }

    /// Identifies a row in a record, for a table keyed by any number of columns.
    ///
    /// **Length-prefixed, not delimited.** A key component is arbitrary text —
    /// a filename, a tag value — so any separator can appear inside one, and an
    /// escaping scheme is a second thing every platform has to implement
    /// identically. `3:abc` cannot be misread whatever `abc` contains, and the
    /// length is in UTF-8 **bytes** so the count does not depend on how a
    /// language defines a character.
    ///
    /// A single-column key encodes the same way, so there is one rule rather
    /// than two and no table sits on a boundary between them.
    static func rowID(_ components: [String]) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Reverses `rowID`. Returns nil on anything malformed, because these
    /// arrive from a file on a drive.
    static func rowComponents(_ rowID: String) -> [String]? {
        var remaining = Substring(rowID)
        var components: [String] = []
        while !remaining.isEmpty {
            guard let colon = remaining.firstIndex(of: ":"),
                  let byteCount = Int(remaining[remaining.startIndex..<colon]),
                  byteCount >= 0
            else { return nil }
            let valueStart = remaining.index(after: colon)
            let bytes = Array(remaining[valueStart...].utf8)
            guard bytes.count >= byteCount,
                  let value = String(bytes: bytes.prefix(byteCount), encoding: .utf8)
            else { return nil }
            components.append(value)
            remaining = remaining[valueStart...].dropFirst(value.count)
        }
        return components
    }

    /// `"a" = ? AND "b" = ?` for a table's key columns, with the values to bind.
    private func keyPredicate(
        columns keyColumns: [String], rowID: String
    ) -> (clause: String, bindings: [SQLValue])? {
        guard let components = Self.rowComponents(rowID),
              components.count == keyColumns.count
        else { return nil }
        let clause = keyColumns.map { "\"\(escape($0))\" = ?" }.joined(separator: " AND ")
        // Bound as text throughout. SQLite applies the column's affinity to the
        // comparison, so an INTEGER key column still matches — `part_number` is
        // one, and binding "3" against it finds the row holding 3.
        return (clause, components.map { .text($0) })
    }

    private func escape(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "\"", with: "\"\"")
    }

    // MARK: - Recording local writes

    /// Runs a write and stamps the columns it actually changed.
    ///
    /// **Only the changed ones, and this is the whole point.** Every upsert in
    /// this catalog rewrites a whole row, so stamping every column would have
    /// each write claim authorship of every field — and a device that changed
    /// only `desired_copies` would overwrite another device's rename with the
    /// stale label it happened to be carrying. That is per-row last-writer-wins
    /// wearing per-field clothing, and it loses edits that were never in
    /// conflict.
    ///
    /// Wrapping the write is what makes the difference visible: the row has to
    /// be read before and after, because the caller's statement is an upsert
    /// and does not itself know which values moved. Two extra reads per write,
    /// which is nothing beside re-hashing a photograph.
    ///
    /// Creating a row stamps every column, because against a row that did not
    /// exist every column has changed — which is also what lets another device
    /// build it from scratch.
    /// Runs a write. The triggers record what it changed.
    ///
    /// **Almost nothing left.** This used to read the row before and after the
    /// write and stamp the columns that differed, because an upsert statement
    /// cannot say which values it moved. `ChangeTriggers` does that in SQL —
    /// `WHEN OLD.x IS NOT NEW.x` — so the two reads, the comparison and the
    /// whole-row special case are gone.
    ///
    /// What remains is moving the wall time forward before a unit of work, so
    /// stamps stay honest in a long session. The `table` and `rowID` arguments
    /// are kept because the call sites read better naming what they are about,
    /// and because they are what a future non-trigger backend would need.
    ///
    /// Calling this is no longer what makes a write recorded. A path that never
    /// calls it is captured just the same, which was the entire point.
    @discardableResult
    func recordingWrite<T>(table: String, rowID: String, _ write: () throws -> T) throws -> T {
        try refreshStamp()
        return try write()
    }

    func recordDeletion(table: String, rowID: String, at stamp: HLCTimestamp) throws {
        try database.run("""
        INSERT INTO change_row_tombstones (table_name, row_id, hlc)
        VALUES (?,?,?)
        ON CONFLICT(table_name, row_id) DO UPDATE SET hlc = excluded.hlc;
        """, [.text(table), .text(rowID), .text(stamp.encoded)])
        try database.run(
            "DELETE FROM change_field_versions WHERE table_name = ? AND row_id = ?;",
            [.text(table), .text(rowID)]
        )
    }

    // MARK: - Reading out what to send

    /// Every change stamped after `watermark`, oldest first.
    ///
    /// Passing nil means everything, which is what a device that has never been
    /// heard from needs. The stamp encoding sorts as text, so this is a plain
    /// string comparison — see `SPEC-format.md` §1.3.
    func changes(since watermark: HLCTimestamp?) throws -> [ChangeRecord] {
        let bound = watermark?.encoded ?? ""
        var records: [ChangeRecord] = []

        let tombstones = try database.query("""
        SELECT table_name, row_id, hlc FROM change_row_tombstones
         WHERE hlc > ? ORDER BY hlc;
        """, [.text(bound)]) { row in
            (table: row.text(0), rowID: row.text(1), hlc: row.text(2))
        }
        for tombstone in tombstones {
            guard let stamp = HLCTimestamp.decode(tombstone.hlc) else { continue }
            records.append(.delete(table: tombstone.table, rowID: tombstone.rowID, stamp: stamp))
        }

        let fields = try database.query("""
        SELECT table_name, row_id, column_name, hlc FROM change_field_versions
         WHERE hlc > ? ORDER BY hlc;
        """, [.text(bound)]) { row in
            (table: row.text(0), rowID: row.text(1), column: row.text(2), hlc: row.text(3))
        }

        // Grouped so each row's values are read once rather than once per
        // column.
        let byRow = Dictionary(grouping: fields) { "\($0.table)\u{1f}\($0.rowID)" }
        for (_, group) in byRow {
            guard let first = group.first,
                  let tableColumns = try columns(of: first.table),
                  let values = try readRow(
                      table: first.table,
                      keyColumns: try primaryKeyColumns(of: first.table),
                      rowID: first.rowID
                  )
            else { continue }

            // A whole-row entry expands to every column, so the receiver gets
            // a complete row and can create it. Where a column also has its own
            // newer entry, that one is sent instead — the expansion is a floor,
            // not an override.
            var effective: [String: HLCTimestamp] = [:]
            if let wildcard = group.first(where: { $0.column == Self.wholeRow }),
               let stamp = HLCTimestamp.decode(wildcard.hlc) {
                for column in tableColumns { effective[column] = stamp }
            }
            for field in group where field.column != Self.wholeRow {
                guard let stamp = HLCTimestamp.decode(field.hlc),
                      tableColumns.contains(field.column) else { continue }
                if let held = effective[field.column], stamp <= held { continue }
                effective[field.column] = stamp
            }

            for (column, stamp) in effective {
                guard let value = values[column] else { continue }
                records.append(.set(
                    table: first.table, rowID: first.rowID,
                    column: column, value: value, stamp: stamp
                ))
            }
        }

        return records.sorted { $0.stamp < $1.stamp }
    }

    // MARK: - Writing out the whole state

    /// Hands `emit` every row and every tombstone this archive holds, as state
    /// rather than as the changes that produced it.
    ///
    /// **Why this exists at all** is measured, not assumed: replaying the log
    /// onto a device that has never seen this archive cost 111 MB where writing
    /// the state out costs 21 MB. See `CheckpointRecord` for the arithmetic.
    ///
    /// **One pass per table, not one query per row.** The stamps for a table are
    /// read once into memory and each row is matched against them as it goes
    /// past. The alternative — reading each row by key — is 21,400 queries for
    /// this archive to produce a file it will write once. The stamps are small
    /// because creating a row records a single whole-row entry rather than one
    /// per column.
    ///
    /// Rows with no stamp at all are skipped, exactly as the log skips them:
    /// with no stamp there is nothing for another device to compare against, and
    /// sending a value that cannot lose a conflict is worse than not sending it.
    ///
    /// - Returns: how many records were emitted.
    @discardableResult
    func writeCheckpoint(_ emit: (CheckpointRecord) throws -> Void) throws -> Int {
        var emitted = 0

        let tombstones = try database.query("""
        SELECT table_name, row_id, hlc FROM change_row_tombstones
         ORDER BY table_name, row_id;
        """) { (table: $0.text(0), rowID: $0.text(1), hlc: $0.text(2)) }
        for tombstone in tombstones {
            guard CatalogScope.travels(tombstone.table),
                  let stamp = HLCTimestamp.decode(tombstone.hlc) else { continue }
            try emit(.deleted(table: tombstone.table, rowID: tombstone.rowID, stamp: stamp))
            emitted += 1
        }

        let tables = try database.query("""
        SELECT DISTINCT table_name FROM change_field_versions ORDER BY table_name;
        """) { $0.text(0) }

        for table in tables {
            guard CatalogScope.travels(table),
                  let tableColumns = try columns(of: table), !tableColumns.isEmpty
            else { continue }
            let keyColumns = try primaryKeyColumns(of: table)
            // Where the key columns sit in the select, so a row can name itself
            // without a second lookup.
            let keyIndices = keyColumns.compactMap { tableColumns.firstIndex(of: $0) }
            guard !keyColumns.isEmpty, keyIndices.count == keyColumns.count else { continue }

            var stampsByRow: [String: [String: HLCTimestamp]] = [:]
            let versions = try database.query("""
            SELECT row_id, column_name, hlc FROM change_field_versions WHERE table_name = ?;
            """, [.text(table)]) { (rowID: $0.text(0), column: $0.text(1), hlc: $0.text(2)) }
            for version in versions {
                guard let stamp = HLCTimestamp.decode(version.hlc) else { continue }
                stampsByRow[version.rowID, default: [:]][version.column] = stamp
            }
            guard !stampsByRow.isEmpty else { continue }

            let selected = tableColumns.map { "\"\(escape($0))\"" }.joined(separator: ", ")
            // The results are `Void`; the work happens in `emit` as each row
            // arrives, so a large table is never held whole in memory.
            _ = try database.query("SELECT \(selected) FROM \"\(escape(table))\";") { row -> Void in
                let rowID = Self.rowID(keyIndices.map { row.text(Int32($0)) })
                guard let stamps = stampsByRow[rowID] else { return }

                // A column's stamp is its own entry or its row's whole-row one,
                // whichever is later — the same rule the log uses when it
                // expands a creation on the way out.
                let wholeRow = stamps[Self.wholeRow]
                var effective: [String: HLCTimestamp] = [:]
                var values: [String: ChangeValue] = [:]
                for (index, column) in tableColumns.enumerated() {
                    guard let stamp = [stamps[column], wholeRow].compactMap({ $0 }).max()
                    else { continue }
                    effective[column] = stamp
                    values[column] = row.changeValue(Int32(index))
                }
                guard let base = Self.mostCommon(effective.values) else { return }

                try emit(.row(
                    table: table, rowID: rowID, stamp: base, values: values,
                    stamps: effective.filter { $0.value != base }
                ))
                emitted += 1
            }
        }

        return emitted
    }

    /// The stamp to make the row's base, so the fewest columns need one of their
    /// own. Ties break on the stamp itself, so two implementations handed the
    /// same row produce the same bytes.
    private static func mostCommon(_ stamps: some Collection<HLCTimestamp>) -> HLCTimestamp? {
        var frequency: [HLCTimestamp: Int] = [:]
        for stamp in stamps { frequency[stamp, default: 0] += 1 }
        return frequency.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key
        }?.key
    }

    private func readRow(
        table: String, keyColumns: [String], rowID: String
    ) throws -> [String: ChangeValue]? {
        guard let columns = try columns(of: table),
              let key = keyPredicate(columns: keyColumns, rowID: rowID)
        else { return nil }
        let selected = columns.map { "\"\(escape($0))\"" }.joined(separator: ", ")
        let rows = try database.query(
            "SELECT \(selected) FROM \"\(escape(table))\" WHERE \(key.clause);",
            key.bindings
        ) { row -> [String: ChangeValue] in
            var values: [String: ChangeValue] = [:]
            for (index, column) in columns.enumerated() {
                values[column] = row.changeValue(Int32(index))
            }
            return values
        }
        return rows.first
    }

    // MARK: - Merging what another device sent

    /// Applies changes from another device, field by field, keeping whichever
    /// write is later.
    ///
    /// **Everything here is untrusted.** These records arrive from a file on a
    /// removable drive, so a table or column name in one is input, not
    /// instruction. Names are matched against the live schema before they can
    /// reach a statement, and anything unrecognised is rejected and counted
    /// rather than interpolated hopefully.
    ///
    /// Idempotent by construction: a record whose stamp does not beat the local
    /// one is counted as superseded and changes nothing, so re-reading a drive
    /// costs time and nothing else.
    /// - Parameter rowIndex: every record the sender has pending, grouped by
    ///   row, when `records` is only a slice of it. **A row that does not exist
    ///   here yet can only be built from all of its columns**, and its columns
    ///   do not arrive together: a creation sends one stamp for the whole row,
    ///   but any column edited since carries its own later stamp and sorts
    ///   somewhere else entirely. Slicing by stamp — which is what keeps the
    ///   watermark honest — therefore cuts rows in half, and half a row is
    ///   rejected rather than half applied. Passing the whole index lets a slice
    ///   build a complete row without giving up ordered slices. See
    ///   `ChangeJournal.rowIndex`.
    @discardableResult
    func merge(
        _ records: [ChangeRecord], rowIndex: [String: [ChangeRecord]]? = nil
    ) throws -> MergeOutcome {
        // Capture off throughout: these rows carry stamps from the device that
        // wrote them, and the triggers would replace those with this device's.
        try suppressingTriggers {
            try applyMergeInTransaction(records, rowIndex: rowIndex)
        }
    }

    /// Groups records by the row they belong to, for `merge(_:rowIndex:)`.
    ///
    /// Built once for a sender's whole batch rather than once per slice: finding
    /// a row's records by scanning made the merge quadratic, and 2,000 new rows
    /// against 58,000 records is 116 million comparisons to answer a question
    /// one pass answers for all of them.
    static func rowIndex(of records: [ChangeRecord]) -> [String: [ChangeRecord]] {
        var index: [String: [ChangeRecord]] = [:]
        for record in records where !record.isDeletion {
            index["\(record.table)\u{1f}\(record.rowID)", default: []].append(record)
        }
        return index
    }

    private func applyMergeInTransaction(
        _ records: [ChangeRecord], rowIndex: [String: [ChangeRecord]]?
    ) throws -> MergeOutcome {
        // One transaction for the whole batch.
        //
        // Without it every statement is its own implicit transaction, and
        // SQLite flushes to disk at the end of each — which for a first sync of
        // a real archive was 58,000 records' worth of separate commits. It is
        // also the right unit of atomicity: a merge interrupted half way should
        // leave the catalog as it was, not holding an arbitrary prefix of
        // another device's history.
        try database.transaction { try applyMerge(records, rowIndex: rowIndex) }
    }

    private func applyMerge(
        _ records: [ChangeRecord], rowIndex: [String: [ChangeRecord]]?
    ) throws -> MergeOutcome {
        var outcome = MergeOutcome()

        // The sender's whole batch when there is one, so a row split across
        // slices is still built from all of its columns. Falling back to this
        // slice alone is right only when this slice *is* the batch.
        let byRow = rowIndex ?? Self.rowIndex(of: records)

        // Rows this batch has just built. `createRow` takes the newest record
        // per column from the whole group, so every other record for that row
        // is by definition already accounted for — and re-checking each one
        // costs three queries to reach the answer "superseded". On a first sync
        // that is 28 wasted lookups per photograph.
        var justCreated: Set<String> = []

        // Oldest first, so a deletion and a later re-creation in the same batch
        // land in the order they happened.
        for record in records.sorted(by: { $0.stamp < $1.stamp }) {
            guard CatalogScope.travels(record.table) else {
                outcome.rejected.append("\(record.table): not a table that travels")
                continue
            }
            let keyColumns = try primaryKeyColumns(of: record.table)
            guard let tableColumns = try columns(of: record.table), !keyColumns.isEmpty else {
                outcome.rejected.append("\(record.table): unknown table, or has no primary key")
                continue
            }
            guard let key = keyPredicate(columns: keyColumns, rowID: record.rowID) else {
                outcome.rejected.append("\(record.table): row id does not match the key columns")
                continue
            }

            if record.isDeletion {
                try applyDeletion(record, key: key, outcome: &outcome)
                continue
            }

            let rowKey = "\(record.table)\u{1f}\(record.rowID)"
            if justCreated.contains(rowKey) {
                outcome.superseded += 1
                continue
            }

            guard let column = record.column, tableColumns.contains(column) else {
                outcome.rejected.append("\(record.table).\(record.column ?? "?"): unknown column")
                continue
            }
            guard let value = record.value else {
                outcome.rejected.append("\(record.table).\(column): no value")
                continue
            }

            // A deletion later than this write wins; the row stays gone.
            if let tombstone = try tombstone(table: record.table, rowID: record.rowID),
               record.stamp < tombstone {
                outcome.superseded += 1
                continue
            }
            if let local = try fieldVersion(
                table: record.table, rowID: record.rowID, column: column
            ), record.stamp <= local {
                outcome.superseded += 1
                continue
            }

            guard try rowExists(table: record.table, keyColumns: keyColumns, rowID: record.rowID)
            else {
                // The row is new here. It can only be created from a set of
                // records carrying every NOT NULL column, which is what
                // `recordingWrite` guarantees the sender produced for a
                // creation — so a row that cannot be built means an incomplete
                // batch, and half a row is worse than none.
                let created = try createRow(
                    record: record, keyColumns: keyColumns,
                    from: byRow[rowKey] ?? [record],
                    tableColumns: tableColumns, outcome: &outcome
                )
                if created { justCreated.insert(rowKey) }
                continue
            }

            try database.run(
                """
                UPDATE "\(escape(record.table))" SET "\(escape(column))" = ?
                 WHERE \(key.clause);
                """,
                [value.asSQL] + key.bindings
            )
            try stampField(
                table: record.table, rowID: record.rowID, column: column, stamp: record.stamp
            )
            try clearTombstoneOlderThan(record.stamp, table: record.table, rowID: record.rowID)
            outcome.applied += 1
        }

        return outcome
    }

    private func applyDeletion(
        _ record: ChangeRecord,
        key: (clause: String, bindings: [SQLValue]),
        outcome: inout MergeOutcome
    ) throws {
        if let existing = try tombstone(table: record.table, rowID: record.rowID),
           record.stamp <= existing {
            outcome.superseded += 1
            return
        }
        // A field written after this deletion means the row was legitimately
        // brought back, and the older deletion must not take it away again.
        let newestField = try newestFieldVersion(table: record.table, rowID: record.rowID)
        if let newestField, record.stamp < newestField {
            outcome.superseded += 1
            return
        }
        try database.run(
            "DELETE FROM \"\(escape(record.table))\" WHERE \(key.clause);", key.bindings
        )
        try recordDeletion(table: record.table, rowID: record.rowID, at: record.stamp)
        outcome.applied += 1
    }

    /// Returns whether the row was built, so the caller can skip the rest of
    /// its records instead of re-deciding each one.
    @discardableResult
    private func createRow(
        record: ChangeRecord,
        keyColumns: [String],
        from batch: [ChangeRecord],
        tableColumns: [String],
        outcome: inout MergeOutcome
    ) throws -> Bool {
        // `batch` is already only this row's records — grouped once by `merge`.
        var values: [String: (value: ChangeValue, stamp: HLCTimestamp)] = [:]
        for candidate in batch {
            guard let column = candidate.column, let value = candidate.value,
                  tableColumns.contains(column) else { continue }
            if let held = values[column], candidate.stamp <= held.stamp { continue }
            values[column] = (value, candidate.stamp)
        }
        // The key columns come from the row id itself, so a row can be created
        // even when the batch carries no record for them — which is the normal
        // case, since a key never changes and so never shows up as a change.
        if let components = Self.rowComponents(record.rowID),
           components.count == keyColumns.count {
            for (column, component) in zip(keyColumns, components) {
                values[column] = values[column] ?? (.text(component), record.stamp)
            }
        }

        let ordered = tableColumns.filter { values[$0] != nil }
        let columnList = ordered.map { "\"\(escape($0))\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ", ")

        do {
            try database.run(
                "INSERT INTO \"\(escape(record.table))\" (\(columnList)) VALUES (\(placeholders));",
                ordered.map { values[$0]!.value.asSQL }
            )
        } catch {
            // Almost always a NOT NULL column the batch did not carry. Reported
            // rather than retried: the sender did not send a whole row, and
            // guessing a value for a column somebody's archive depends on is
            // not something a merge should do.
            outcome.rejected.append("\(record.table)/\(record.rowID): could not create row")
            return false
        }
        for column in ordered {
            try stampField(
                table: record.table, rowID: record.rowID,
                column: column, stamp: values[column]!.stamp
            )
        }
        try clearTombstoneOlderThan(record.stamp, table: record.table, rowID: record.rowID)
        outcome.applied += 1
        return true
    }

    // MARK: - Journal reads

    /// The later of the column's own stamp and its row's whole-row stamp.
    ///
    /// Both have to be consulted. A row created and never touched has only the
    /// whole-row entry; a column edited afterwards has both, and its own entry
    /// is the newer one.
    private func fieldVersion(table: String, rowID: String, column: String) throws -> HLCTimestamp? {
        let stamps = try database.query("""
        SELECT hlc FROM change_field_versions
         WHERE table_name = ? AND row_id = ? AND column_name IN (?, ?);
        """, [.text(table), .text(rowID), .text(column), .text(Self.wholeRow)]) { $0.text(0) }
        return stamps.compactMap(HLCTimestamp.decode).max()
    }

    private func newestFieldVersion(table: String, rowID: String) throws -> HLCTimestamp? {
        try database.query("""
        SELECT max(hlc) FROM change_field_versions WHERE table_name = ? AND row_id = ?;
        """, [.text(table), .text(rowID)]) { $0.optionalText(0) }
            .compactMap { $0 }.first.flatMap(HLCTimestamp.decode)
    }

    private func tombstone(table: String, rowID: String) throws -> HLCTimestamp? {
        try database.query(
            "SELECT hlc FROM change_row_tombstones WHERE table_name = ? AND row_id = ?;",
            [.text(table), .text(rowID)]
        ) { $0.text(0) }.first.flatMap(HLCTimestamp.decode)
    }

    private func rowExists(table: String, keyColumns: [String], rowID: String) throws -> Bool {
        guard let key = keyPredicate(columns: keyColumns, rowID: rowID) else { return false }
        return try !database.query(
            "SELECT 1 FROM \"\(escape(table))\" WHERE \(key.clause) LIMIT 1;", key.bindings
        ) { $0.int(0) }.isEmpty
    }

    private func stampField(
        table: String, rowID: String, column: String, stamp: HLCTimestamp
    ) throws {
        try database.run("""
        INSERT INTO change_field_versions (table_name, row_id, column_name, hlc)
        VALUES (?,?,?,?)
        ON CONFLICT(table_name, row_id, column_name) DO UPDATE SET hlc = excluded.hlc;
        """, [.text(table), .text(rowID), .text(column), .text(stamp.encoded)])
    }

    private func clearTombstoneOlderThan(
        _ stamp: HLCTimestamp, table: String, rowID: String
    ) throws {
        try database.run("""
        DELETE FROM change_row_tombstones
         WHERE table_name = ? AND row_id = ? AND hlc < ?;
        """, [.text(table), .text(rowID), .text(stamp.encoded)])
    }
}
