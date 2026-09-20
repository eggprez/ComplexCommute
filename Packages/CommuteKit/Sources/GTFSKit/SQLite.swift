import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the system SQLite. Not thread-safe; confine each connection to one task or actor.
final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(url: URL, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let code = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(handle)
            throw SQLiteError(code: code, message: message)
        }
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteError(code: code, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(statement: statement, database: handle)
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private let database: OpaquePointer

    fileprivate init(statement: OpaquePointer, database: OpaquePointer) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    // Bind positions are 1-based, as in SQLite.

    func bind(_ value: Int?, at position: Int32) {
        if let value {
            sqlite3_bind_int64(statement, position, Int64(value))
        } else {
            sqlite3_bind_null(statement, position)
        }
    }

    func bind(_ value: Double?, at position: Int32) {
        if let value {
            sqlite3_bind_double(statement, position, value)
        } else {
            sqlite3_bind_null(statement, position)
        }
    }

    func bind(_ value: String?, at position: Int32) {
        if let value {
            sqlite3_bind_text(statement, position, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, position)
        }
    }

    /// Binds raw UTF-8 without going through String; empty becomes NULL.
    func bind(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int32) {
        if let base = bytes.baseAddress, !bytes.isEmpty {
            base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                _ = sqlite3_bind_text(statement, position, $0, Int32(bytes.count), transient)
            }
        } else {
            sqlite3_bind_null(statement, position)
        }
    }

    /// Runs a statement that returns no rows, then resets it for reuse.
    func run() throws {
        let code = sqlite3_step(statement)
        sqlite3_reset(statement)
        guard code == SQLITE_DONE else {
            throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(database)))
        }
    }

    /// Advances to the next result row; false when exhausted.
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let code: throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(database)))
        }
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    // Column indexes are 0-based, as in SQLite.

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func optionalInt(_ column: Int32) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func string(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
