import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDB {
    private var h: OpaquePointer?

    init(path: String, wal: Bool) throws {
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(h)
            h = nil
            throw SignalFail(code: "db_error")
        }
        sqlite3_busy_timeout(h, 5000)
        if wal { try exec("PRAGMA journal_mode=WAL") }
        try exec("CREATE TABLE IF NOT EXISTS rows (store TEXT NOT NULL, key TEXT NOT NULL, idx TEXT, value BLOB NOT NULL, PRIMARY KEY (store, key))")
        try exec("CREATE INDEX IF NOT EXISTS rows_idx ON rows (store, idx)")
    }

    deinit { sqlite3_close(h) }

    func close() {
        sqlite3_close(h)
        h = nil
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else { throw SignalFail(code: "db_error") }
    }

    private func prepare(_ sql: String, _ binds: [Any?]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let s = st else {
            sqlite3_finalize(st)
            throw SignalFail(code: "db_error")
        }
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            var rc = SQLITE_OK
            switch b {
            case let t as String: rc = sqlite3_bind_text(s, n, t, -1, transient)
            case let d as Data:
                rc = d.withUnsafeBytes { p in
                    sqlite3_bind_blob(s, n, p.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(d.count), transient)
                }
            default: rc = sqlite3_bind_null(s, n)
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(s)
                throw SignalFail(code: "db_error")
            }
        }
        return s
    }

    func run(_ sql: String, _ binds: [Any?] = []) throws {
        let s = try prepare(sql, binds)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw SignalFail(code: "db_error") }
    }

    func put(_ store: String, _ key: String, _ idx: String?, _ value: Data) throws {
        try run("INSERT OR REPLACE INTO rows (store, key, idx, value) VALUES (?, ?, ?, ?)", [store, key, idx, value])
    }

    func query(_ sql: String, _ binds: [Any?], _ row: (OpaquePointer) throws -> Void) throws {
        let s = try prepare(sql, binds)
        defer { sqlite3_finalize(s) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { try row(s) } else if rc == SQLITE_DONE { return } else { throw SignalFail(code: "db_error") }
        }
    }

    static func text(_ s: OpaquePointer, _ c: Int32) -> String? {
        sqlite3_column_text(s, c).map { String(cString: $0) }
    }

    static func blob(_ s: OpaquePointer, _ c: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(s, c))
        guard n > 0, let p = sqlite3_column_blob(s, c) else { return Data() }
        return Data(bytes: p, count: n)
    }
}

final class NativeStore {
    static let shared = NativeStore()

    let queue = DispatchQueue(label: "app.ripplo.store")
    private var db: SQLiteDB?

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("store", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            var u = url
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
        }
        return url
    }

    static var dbURL: URL { dir.appendingPathComponent("ripplo.db") }

    private func handle() throws -> SQLiteDB {
        if let d = db { return d }
        let d = try SQLiteDB(path: NativeStore.dbURL.path, wal: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: NativeStore.dbURL.path
        )
        db = d
        return d
    }

    func perform<T>(_ work: @escaping (SQLiteDB) throws -> T, done: @escaping (Result<T, SignalFail>) -> Void) {
        queue.async {
            do {
                done(.success(try work(try self.handle())))
            } catch {
                done(.failure((error as? SignalFail) ?? SignalFail(code: "db_error")))
            }
        }
    }

    func sync<T>(_ work: (SQLiteDB) throws -> T) throws -> T {
        try queue.sync { try work(try handle()) }
    }

    func swap(in staging: URL) throws {
        try queue.sync {
            db?.close()
            db = nil
            let fm = FileManager.default
            let live = NativeStore.dbURL
            try? fm.removeItem(atPath: live.path + "-wal")
            try? fm.removeItem(atPath: live.path + "-shm")
            if fm.fileExists(atPath: live.path) {
                _ = try fm.replaceItemAt(live, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: live)
            }
        }
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}
