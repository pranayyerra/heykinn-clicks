import Foundation

/// A whole row as it stands right now, rather than the changes that made it so.
///
/// **Why a second record shape exists at all.** The log is four orders of
/// magnitude smaller than the archive for a day's work, and five times *larger*
/// for a first sync — measured, on a real archive: 111 MB of log against 21 MB
/// of state. The reason is arithmetic rather than anything subtle. A per-field
/// record carries a 60-character stamp, a table name and a row id to deliver one
/// value; at 29 fields per photograph the bookkeeping outweighs the data it is
/// describing. Sending state instead pays that overhead once per row.
///
/// So a checkpoint is a row: every column's value, **one** stamp for the row,
/// and per-column stamps only where a column disagrees with it. A row created
/// and never touched — the overwhelming majority — carries no overrides at all.
///
/// **It is not a second merge.** `expanded()` turns this straight back into the
/// ordinary `ChangeRecord`s the journal already knows how to merge, so nothing
/// downstream learns a new rule and nothing about conflict resolution changes.
/// This is a compression of the wire, and only that.
struct CheckpointRecord: Equatable, Codable {

    var table: String
    /// The row's primary key, encoded as in `ChangeJournal.rowID`.
    var rowID: String
    /// The stamp every column takes unless `stamps` says otherwise.
    var stamp: HLCTimestamp
    /// Column name → value. **Nil means the row is deleted** — a tombstone,
    /// carried in the checkpoint for the same reason it is kept in the catalog:
    /// a row that is merely absent is indistinguishable from one the reader has
    /// never been told about, and the next merge would bring it back.
    var values: [String: ChangeValue]?
    /// Columns whose stamp is not the row's. Absent when they all agree, which
    /// is the ordinary case.
    var stamps: [String: HLCTimestamp]?

    var isDeletion: Bool { values == nil }

    private enum CodingKeys: String, CodingKey {
        case table = "t"
        case rowID = "r"
        case stamp = "h"
        case values = "v"
        case stamps = "o"
    }

    static func row(
        table: String,
        rowID: String,
        stamp: HLCTimestamp,
        values: [String: ChangeValue],
        stamps: [String: HLCTimestamp] = [:]
    ) -> CheckpointRecord {
        CheckpointRecord(
            table: table, rowID: rowID, stamp: stamp,
            values: values, stamps: stamps.isEmpty ? nil : stamps
        )
    }

    static func deleted(table: String, rowID: String, stamp: HLCTimestamp) -> CheckpointRecord {
        CheckpointRecord(table: table, rowID: rowID, stamp: stamp, values: nil, stamps: nil)
    }

    /// The change records this row is worth, for the ordinary merge.
    ///
    /// Sorted by column so the expansion is deterministic — two implementations
    /// handed the same checkpoint produce the same sequence, which is what makes
    /// the format testable against something other than itself.
    func expanded() -> [ChangeRecord] {
        guard let values else {
            return [.delete(table: table, rowID: rowID, stamp: stamp)]
        }
        return values.keys.sorted().map { column in
            .set(
                table: table, rowID: rowID, column: column,
                value: values[column]!, stamp: stamps?[column] ?? stamp
            )
        }
    }

    /// The newest stamp this record claims, which is what a reader's watermark
    /// has to clear.
    var newestStamp: HLCTimestamp {
        guard let stamps, let highest = stamps.values.max() else { return stamp }
        return Swift.max(stamp, highest)
    }
}

/// What one checkpoint directory says about itself.
///
/// Written **last**, and atomically. Until it exists the parts beside it are not
/// a checkpoint but a half-finished write, and a reader ignores the whole
/// directory — which is how a checkpoint interrupted by a drive being pulled out
/// costs nothing at all rather than delivering a partial archive.
struct CheckpointInfo: Codable, Equatable {

    /// The line format and layout of `docs/SPEC-format.md` §4.
    var formatVersion: Int
    /// The catalog schema the writing device was using, checked for the same
    /// reason `manifest.json` carries it.
    var catalogSchemaVersion: Int64
    /// Increases with each checkpoint this device writes. Names the directory.
    var generation: Int
    /// The highest stamp anywhere in this checkpoint. A reader that applies the
    /// whole of it has, by definition, seen everything up to here.
    var horizon: String
    /// How many `.jsonl` parts sit beside this file. A missing one is then
    /// detectable rather than silently short.
    var parts: Int
    var rows: Int
    var byteCount: Int
    /// The first segment index written *after* this checkpoint was taken.
    ///
    /// Everything below it is covered by the checkpoint, so a reader can skip
    /// straight there and the writer can delete those segments. The segment is
    /// deliberately rolled when a checkpoint is taken, so no segment is ever
    /// half covered.
    var firstSegmentIndexAfter: Int
    /// The writer's own watermarks when it took this checkpoint.
    ///
    /// **Recorded, not acted on.** A reader that applied this whole checkpoint
    /// could in principle adopt these — the state here already incorporates
    /// everything the writer had merged, so the reader would be entitled to skip
    /// those peers' logs too. That argument is sound but it is the subtlest one
    /// in the design, and getting it wrong means silently skipping records for
    /// good. Not adopting them costs only re-reading, which is idempotent. The
    /// numbers are here so pruning can use them and so the choice stays open.
    var seen: [String: String]
    /// Seconds since the Unix epoch. For a person reading the drive; nothing
    /// depends on it.
    var writtenAt: Double

    static let currentFormatVersion = 1

    var horizonStamp: HLCTimestamp? { HLCTimestamp.decode(horizon) }
}
