import Foundation
import SQLite3

/// Small wrapper over the system SQLite. Only what this app needs: prepared
/// statements, typed bindings and one transaction helper. No ORM.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(pointer)
            throw PackTraceError.storage("open failed: \(message)")
        }
        self.handle = pointer
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
        try execute("PRAGMA synchronous = FULL")
    }

    /// Opens someone else's database without any chance of writing to it.
    ///
    /// Used for tool storage this app only reads: no journal-mode change, no
    /// migration, no `immutable` shortcut that would pretend a live WAL file is
    /// a settled one. A short timeout keeps a busy writer from blocking us and
    /// keeps us from blocking it.
    init(readOnlyPath path: String, busyTimeoutMilliseconds: Int32 = 1_000) throws {
        self.path = path
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(pointer)
            throw PackTraceError.storage("read-only open failed: \(message)")
        }
        self.handle = pointer
        sqlite3_busy_timeout(pointer, busyTimeoutMilliseconds)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Closes the connection now. Used before a restore swaps the file.
    func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    var filePath: String { path }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw PackTraceError.storage("exec failed: \(message) [\(sql)]")
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PackTraceError.storage("prepare failed: \(lastErrorMessage) [\(sql)]")
        }
        return SQLiteStatement(statement: statement, database: self)
    }

    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        try statement.stepToCompletion()
    }

    func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int? {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        guard try statement.step() else { return nil }
        return statement.int(at: 0)
    }

    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], map: (SQLiteStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        var rows: [T] = []
        while try statement.step() {
            rows.append(try map(statement))
        }
        return rows
    }

    /// One write transaction at a time. `BEGIN IMMEDIATE` takes the write lock
    /// up front so a balance check and the rows that depend on it cannot be
    /// interleaved with another writer.
    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    func withTransaction<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        try transaction { try body(self) }
    }

    var userVersion: Int32 {
        get { (try? scalarInt("PRAGMA user_version").map { Int32($0) }) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    /// Consistent snapshot of this database into `destination`, using the
    /// SQLite online backup API so a WAL database is copied at a single
    /// committed point rather than by copying the main file.
    ///
    /// init, each step's result and finish are all checked separately: reaching
    /// SQLITE_DONE is what proves the copy completed, not merely a successful
    /// finish call.
    func backup(to destination: String, maxBusyRetries: Int = 5) throws {
        var destinationHandle: OpaquePointer?
        guard sqlite3_open_v2(
            destination,
            &destinationHandle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let destinationHandle else {
            let message = destinationHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(destinationHandle)
            throw PackTraceError.storage("backup destination open failed: \(message)")
        }
        defer { sqlite3_close_v2(destinationHandle) }

        guard let backupHandle = sqlite3_backup_init(destinationHandle, "main", handle, "main") else {
            let message = String(cString: sqlite3_errmsg(destinationHandle))
            throw PackTraceError.storage("backup init failed: \(message)")
        }

        var attempts = 0
        var stepResult: Int32 = SQLITE_OK
        while true {
            stepResult = sqlite3_backup_step(backupHandle, 256)
            switch stepResult {
            case SQLITE_DONE, SQLITE_OK:
                attempts = 0
            case SQLITE_BUSY, SQLITE_LOCKED:
                attempts += 1
                if attempts > maxBusyRetries {
                    sqlite3_backup_finish(backupHandle)
                    throw PackTraceError.storage("backup blocked by another writer (busy/locked)")
                }
                sqlite3_sleep(50)
            default:
                let code = stepResult
                sqlite3_backup_finish(backupHandle)
                throw PackTraceError.storage("backup step failed with code \(code)")
            }
            if stepResult == SQLITE_DONE { break }
        }

        let finishResult = sqlite3_backup_finish(backupHandle)
        guard finishResult == SQLITE_OK else {
            throw PackTraceError.storage(
                "backup finish failed with code \(finishResult): \(String(cString: sqlite3_errmsg(destinationHandle)))"
            )
        }
    }

    var lastErrorMessage: String {
        guard let handle else { return "closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: SQLiteValue) {
        switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case let .int(number):
            sqlite3_bind_int64(statement, index, Int64(number))
        case let .double(number):
            sqlite3_bind_double(statement, index, number)
        case let .text(string):
            sqlite3_bind_text(statement, index, string, -1, transient)
        }
    }
}

enum SQLiteValue {
    case null
    case int(Int)
    case double(Double)
    case text(String)

    static func opt(_ value: String?) -> SQLiteValue {
        value.map { .text($0) } ?? .null
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer?
    private unowned let database: SQLiteDatabase

    init(statement: OpaquePointer?, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            SQLiteDatabase.bind(statement, Int32(offset + 1), value)
        }
    }

    /// Returns true when a row is available, false when the statement is done.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw PackTraceError.storage("step failed: \(database.lastErrorMessage)")
        }
    }

    func stepToCompletion() throws {
        while try step() {}
    }

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func text(at index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    func optionalText(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(at: index)
    }
}
