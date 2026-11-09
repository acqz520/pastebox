import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)

    var description: String {
        switch self {
        case .open(let m): return "open: \(m)"
        case .sql(let m): return "sql: \(m)"
        }
    }
}

struct Row {
    let stmt: OpaquePointer

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }

    func string(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func data(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// Thin SQLite wrapper. Callers serialize compound operations themselves.
final class Database {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw DBError.open(msg)
        }
    }

    deinit { sqlite3_close(handle) }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DBError.sql(msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.sql(lastError) }
        return sqlite3_last_insert_rowid(handle)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func query(_ sql: String, _ args: [Any?] = [], _ each: (Row) throws -> Void) throws {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW {
                try each(Row(stmt: st))
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw DBError.sql(lastError)
            }
        }
    }

    func scalar(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        var value: Int64 = 0
        try query(sql, args) { value = $0.int(0) }
        return value
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw DBError.sql("\(lastError) — \(sql)")
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            guard let arg else {
                sqlite3_bind_null(st, idx)
                continue
            }
            switch arg {
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as Bool: sqlite3_bind_int(st, idx, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                if v.isEmpty {
                    sqlite3_bind_zeroblob(st, idx, 0)
                } else {
                    v.withUnsafeBytes { _ = sqlite3_bind_blob(st, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
                }
            default: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }
}
