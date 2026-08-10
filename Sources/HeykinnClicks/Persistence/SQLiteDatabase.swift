import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String, sql: String)
    case stepFailed(String, sql: String)
    case execFailed(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "SQLite open failed: \(m)"
        case .prepareFailed(let m, let sql): return "SQLite prepare failed: \(m) — \(sql)"
        case .stepFailed(let m, let sql): return "SQLite step failed: \(m) — \(sql)"
        case .execFailed(let m, let sql): return "SQLite exec failed: \(m) — \(sql)"
        }
    }
}

enum SQLValue {
    case text(String)
    case int(Int64)
    case real(Double)
    case null

    static func uuid(_ value: UUID?) -> SQLValue {
        value.map { .text($0.uuidString) } ?? .null
    }

    static func date(_ value: Date?) -> SQLValue {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }

    static func bool(_ value: Bool) -> SQLValue {
        .int(value ? 1 : 0)
    }

    static func optionalInt(_ value: Int64?) -> SQLValue {
        value.map { .int($0) } ?? .null
    }

    static func optionalText(_ value: String?) -> SQLValue {
        value.map { .text($0) } ?? .null
    }
}

/// Minimal synchronous SQLite wrapper. All access happens on the main actor
/// via CatalogStore in v1; the connection is opened with FULLMUTEX so stray
/// background use is still safe.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// `readOnly` opens without creating or modifying anything — required when
    /// inspecting a backup, since a read-write open would switch it to WAL and
    /// leave `-shm`/`-wal` journals beside the snapshot.
    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.openFailed(message)
        }
        guard !readOnly else { return }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Folds the write-ahead log back into the database file itself.
    ///
    /// Must happen before the file is moved or copied. In WAL mode a committed
    /// transaction can still be living in `-wal`, so a copy of the database
    /// taken without it is missing the most recent work — and for the copy kept
    /// as the way back from a restore, that is precisely the work somebody
    /// would be trying to recover.
    func checkpoint() {
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Closes the connection and lets go of the file.
    ///
    /// Needed because restoring a snapshot replaces the database on disk, and
    /// SQLite holds its file open: swapping it underneath a live handle leaves
    /// the process reading a file that no longer has a name. Idempotent —
    /// `sqlite3_close_v2` on a null handle is a no-op, so `deinit` after this
    /// is harmless.
    func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    /// Runs `body` inside a transaction, committing on success and rolling
    /// back on any error. Groups related writes (an asset and its replica
    /// state) so a crash can never leave one without the other.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.execFailed(lastError, sql: sql)
        }
    }

    func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.stepFailed(lastError, sql: sql)
        }
    }

    func query<T>(_ sql: String, _ bindings: [SQLValue] = [], row: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                results.append(try row(Row(statement: statement)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(lastError, sql: sql)
            }
        }
        return results
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(lastError, sql: sql)
        }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let string):
                sqlite3_bind_text(statement, position, string, -1, SQLITE_TRANSIENT)
            case .int(let integer):
                sqlite3_bind_int64(statement, position, integer)
            case .real(let double):
                sqlite3_bind_double(statement, position, double)
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    /// One result row; column accessors are index-based in select order.
    struct Row {
        let statement: OpaquePointer

        func text(_ index: Int32) -> String {
            guard let cString = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: cString)
        }

        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index)
        }

        func int(_ index: Int32) -> Int64 {
            sqlite3_column_int64(statement, index)
        }

        func optionalInt(_ index: Int32) -> Int64? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int(index)
        }

        func real(_ index: Int32) -> Double {
            sqlite3_column_double(statement, index)
        }

        func bool(_ index: Int32) -> Bool {
            int(index) != 0
        }

        func uuid(_ index: Int32) -> UUID {
            UUID(uuidString: text(index)) ?? UUID()
        }

        func optionalUUID(_ index: Int32) -> UUID? {
            optionalText(index).flatMap { UUID(uuidString: $0) }
        }

        func date(_ index: Int32) -> Date {
            Date(timeIntervalSince1970: real(index))
        }

        func optionalDate(_ index: Int32) -> Date? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : date(index)
        }
    }
}
