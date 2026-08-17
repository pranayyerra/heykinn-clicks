import Foundation

/// One column's value, in a form every platform can represent exactly.
///
/// Tagged rather than relying on JSON's own types, because JSON does not
/// distinguish an integer from a float and SQLite does. `1` and `1.0` are the
/// same JSON number and different SQLite values, and a column that silently
/// changed storage class on the way through another device would be a very
/// quiet bug.
enum ChangeValue: Equatable, Codable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null

    private enum CodingKeys: String, CodingKey {
        case text = "s"
        case integer = "i"
        case real = "r"
        case null = "n"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(value)
        } else if let value = try container.decodeIfPresent(Int64.self, forKey: .integer) {
            self = .integer(value)
        } else if let value = try container.decodeIfPresent(Double.self, forKey: .real) {
            self = .real(value)
        } else if try container.decodeIfPresent(Bool.self, forKey: .null) != nil {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .null, in: container, debugDescription: "No recognised value tag"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value): try container.encode(value, forKey: .text)
        case .integer(let value): try container.encode(value, forKey: .integer)
        case .real(let value): try container.encode(value, forKey: .real)
        case .null: try container.encode(true, forKey: .null)
        }
    }

    var asSQL: SQLValue {
        switch self {
        case .text(let value): return .text(value)
        case .integer(let value): return .int(value)
        case .real(let value): return .real(value)
        case .null: return .null
        }
    }
}

/// One change to one field, or one row deletion — the unit that travels.
///
/// Deliberately field-scoped. A whole-row record would mean two devices editing
/// different columns of the same row lose one edit for no reason: verifying a
/// photo on one device and re-grouping it on another are not in conflict, and only
/// a per-field record can say so. See `docs/MULTI_DEVICE_STATE.md` §6.3.
struct ChangeRecord: Equatable, Codable {

    /// Which table. Checked against the live schema before it is ever used in
    /// SQL — see `ChangeJournal.merge`.
    var table: String
    /// The row's primary key, as text.
    var rowID: String
    /// The column, or **nil for a row deletion**. A deletion is not a value; it
    /// is the absence of the whole row, and encoding it as a column would make
    /// "which column is deleted" a question with no answer.
    var column: String?
    var value: ChangeValue?
    var stamp: HLCTimestamp

    var isDeletion: Bool { column == nil }

    private enum CodingKeys: String, CodingKey {
        case table = "t"
        case rowID = "r"
        case column = "c"
        case value = "v"
        case stamp = "h"
    }

    static func set(
        table: String, rowID: String, column: String, value: ChangeValue, stamp: HLCTimestamp
    ) -> ChangeRecord {
        ChangeRecord(table: table, rowID: rowID, column: column, value: value, stamp: stamp)
    }

    static func delete(table: String, rowID: String, stamp: HLCTimestamp) -> ChangeRecord {
        ChangeRecord(table: table, rowID: rowID, column: nil, value: nil, stamp: stamp)
    }
}

/// What a merge did, so the caller can report it and tests can assert on it.
struct MergeOutcome: Equatable {
    /// Records whose stamp beat what was held locally.
    var applied: Int = 0
    /// Records an equal-or-newer local value already answered. Not an error:
    /// re-reading a drive is expected, and a merge that is not idempotent is
    /// a merge that cannot be retried.
    var superseded: Int = 0
    /// Records naming a table or column this build does not have, or a row that
    /// arrived without enough columns to create it. Skipped and counted rather
    /// than applied partially.
    var rejected: [String] = []

    var isEmpty: Bool { applied == 0 && superseded == 0 && rejected.isEmpty }
}
