import Foundation
import SQLite3

/// The system SQLite, with just enough around it to be pleasant from Swift.
///
/// Not thread-safe on its own: every database is owned by one actor, which serializes access.
public final class SQLiteDatabase: @unchecked Sendable {

    public struct Failure: Error, CustomStringConvertible {
        public let code: Int32
        public let message: String
        public var description: String { "SQLite error \(code): \(message)" }
    }

    private var handle: OpaquePointer?

    /// Opens or creates the database at `url`, or an in-memory one when `url` is `nil`.
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        let path = url?.path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            handle = nil
            throw Failure(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 3_000)
    }

    /// Opens an existing database without ever writing to it.
    public init(readOnly url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            handle = nil
            throw Failure(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 3_000)
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: Statements

    public final class Statement {
        fileprivate var raw: OpaquePointer?
        fileprivate unowned let database: SQLiteDatabase

        fileprivate init(_ database: SQLiteDatabase, sql: String) throws {
            self.database = database
            let status = sqlite3_prepare_v2(database.handle, sql, -1, &raw, nil)
            guard status == SQLITE_OK else { throw database.failure(status) }
        }

        deinit { sqlite3_finalize(raw) }

        @discardableResult
        public func bind(_ values: [SQLiteValue]) throws -> Statement {
            sqlite3_reset(raw)
            sqlite3_clear_bindings(raw)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .null: status = sqlite3_bind_null(raw, index)
                case .int(let int): status = sqlite3_bind_int64(raw, index, int)
                case .double(let double): status = sqlite3_bind_double(raw, index, double)
                case .text(let text): status = sqlite3_bind_text(raw, index, text, -1, SQLITE_TRANSIENT)
                case .blob(let data):
                    status = data.withUnsafeBytes {
                        sqlite3_bind_blob(raw, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
                    }
                }
                guard status == SQLITE_OK else { throw database.failure(status) }
            }
            return self
        }

        /// Steps once; `true` while a row is available.
        public func step() throws -> Bool {
            let status = sqlite3_step(raw)
            switch status {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw database.failure(status)
            }
        }

        public func run(_ values: [SQLiteValue] = []) throws {
            try bind(values)
            while try step() {}
        }

        public func rows(_ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
            try bind(values)
            var out: [SQLiteRow] = []
            while try step() { out.append(SQLiteRow(self)) }
            return out
        }

        public var columnCount: Int { Int(sqlite3_column_count(raw)) }

        public func int(_ column: Int) -> Int64 { sqlite3_column_int64(raw, Int32(column)) }
        public func double(_ column: Int) -> Double { sqlite3_column_double(raw, Int32(column)) }
        public func isNull(_ column: Int) -> Bool { sqlite3_column_type(raw, Int32(column)) == SQLITE_NULL }
        public func text(_ column: Int) -> String? {
            guard let pointer = sqlite3_column_text(raw, Int32(column)) else { return nil }
            return String(cString: pointer)
        }
        public func blob(_ column: Int) -> Data? {
            guard let pointer = sqlite3_column_blob(raw, Int32(column)) else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(raw, Int32(column))))
        }
    }

    public func prepare(_ sql: String) throws -> Statement { try Statement(self, sql: sql) }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw Failure(code: status, message: message)
        }
    }

    public func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try prepare(sql).run(values)
    }

    public func rows(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try prepare(sql).rows(values)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    public var userVersion: Int {
        get { (try? rows("PRAGMA user_version").first?.int(0)).map(Int.init) ?? 0 }
    }

    fileprivate func failure(_ status: Int32) -> Failure {
        Failure(code: status, message: String(cString: sqlite3_errmsg(handle)))
    }
}

public enum SQLiteValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public static func optional(_ text: String?) -> SQLiteValue { text.map(SQLiteValue.text) ?? .null }
    public static func optional(_ int: Int64?) -> SQLiteValue { int.map(SQLiteValue.int) ?? .null }
    public static func date(_ date: Date?) -> SQLiteValue {
        date.map { .double($0.timeIntervalSince1970) } ?? .null
    }
}

/// One result row, copied out of the statement so it outlives the next step.
public struct SQLiteRow: Sendable {
    public let values: [SQLiteValue]

    init(_ statement: SQLiteDatabase.Statement) {
        values = (0..<statement.columnCount).map { column in
            let raw = statement
            switch sqlite3_column_type(raw.rawPointer, Int32(column)) {
            case SQLITE_INTEGER: return .int(raw.int(column))
            case SQLITE_FLOAT: return .double(raw.double(column))
            case SQLITE_TEXT: return raw.text(column).map(SQLiteValue.text) ?? .null
            case SQLITE_BLOB: return raw.blob(column).map(SQLiteValue.blob) ?? .null
            default: return .null
            }
        }
    }

    public func int(_ column: Int) -> Int64 {
        switch values[column] {
        case .int(let int): return int
        case .double(let double): return Int64(double)
        default: return 0
        }
    }

    public func double(_ column: Int) -> Double {
        switch values[column] {
        case .int(let int): return Double(int)
        case .double(let double): return double
        default: return 0
        }
    }

    public func text(_ column: Int) -> String? {
        if case .text(let text) = values[column] { return text }
        return nil
    }

    public func date(_ column: Int) -> Date? {
        switch values[column] {
        case .int(let int): return Date(timeIntervalSince1970: Double(int))
        case .double(let double): return Date(timeIntervalSince1970: double)
        default: return nil
        }
    }
}

extension SQLiteDatabase.Statement {
    fileprivate var rawPointer: OpaquePointer? { raw }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
