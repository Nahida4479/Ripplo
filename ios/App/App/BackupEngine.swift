import UIKit
import UniformTypeIdentifiers
import CryptoKit
import CommonCrypto
import Security

enum BackupEngine {
    private static let queue = DispatchQueue(label: "app.ripplo.backup")
    private static let magic = Data("RIPPLOBK".utf8)
    private static let iterations: UInt32 = 600_000
    private static let chunk = 1 << 20
    private static let maxRecord = 128 << 20
    private static let keepFiles = 3
    private static let udLast = "ripplo.backup.lastAt"
    private static let udMark = "ripplo.backup.bookmark"
    private static let udName = "ripplo.backup.folder"
    private static let secretService = "app.ripplo.backup"

    private static func fail(_ c: String) -> SignalFail { SignalFail(code: c) }

    static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)])
    }

    private static func be64(_ v: UInt64) -> Data {
        Data((0..<8).map { UInt8(v >> UInt64(56 - 8 * $0) & 255) })
    }

    private static func be16(_ v: Int) -> Data {
        Data([UInt8(v >> 8 & 255), UInt8(v & 255)])
    }

    private static func lp(_ s: String?) throws -> Data {
        guard let s = s else { return Data([0xFF, 0xFF]) }
        let b = Data(s.utf8)
        guard b.count < 0xFFFF else { throw fail("bad_file") }
        return be16(b.count) + b
    }

    private static func kcBase(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func kcRead(_ service: String, _ account: String) -> Data? {
        var q = kcBase(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func kcWrite(_ service: String, _ account: String, _ data: Data) throws {
        SecItemDelete(kcBase(service, account) as CFDictionary)
        var add = kcBase(service, account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw fail("keychain_failed") }
    }

    private struct Secret {
        let code: String
        let salt: Data
        let key: Data
    }

    private static func secret() -> Secret? {
        guard let d = kcRead(secretService, "backup"), d.count == 78 else { return nil }
        return Secret(
            code: String(decoding: d.subdata(in: 0..<30), as: UTF8.self),
            salt: d.subdata(in: 30..<46),
            key: d.subdata(in: 46..<78)
        )
    }

    private static func derive(_ code: String, _ salt: Data, _ iter: UInt32) -> Data? {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(code.utf8)
        let rc = salt.withUnsafeBytes { (sp: UnsafeRawBufferPointer) -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.map { Int8(bitPattern: $0) },
                pw.count,
                sp.bindMemory(to: UInt8.self).baseAddress,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iter,
                &out,
                32
            )
        }
        return rc == Int32(kCCSuccess) ? Data(out) : nil
    }

    private static func newCode() -> String {
        var digits = ""
        while digits.count < 30 {
            for b in randomBytes(64) where b < 250 && digits.count < 30 { digits.append(String(b % 10)) }
        }
        return digits
    }

    static func dbKey() -> Data? {
        kcRead("app.ripplo.dbkey", "dbkey")
    }

    private static func setDbKey(_ k: Data) throws {
        try kcWrite("app.ripplo.dbkey", "dbkey", k)
    }

    static func status() -> [String: Any] {
        let ud = UserDefaults.standard
        return [
            "enabled": secret() != nil,
            "lastAt": Int(ud.double(forKey: udLast)),
            "folder": ud.string(forKey: udName).map { $0 as Any } ?? NSNull()
        ]
    }

    static func enable() throws -> String {
        let code = newCode()
        let salt = randomBytes(16)
        guard let key = derive(code, salt, iterations) else { throw fail("kdf_failed") }
        try kcWrite(secretService, "backup", Data(code.utf8) + salt + key)
        return code
    }

    static func showCode() -> String? {
        secret()?.code
    }

    static func disable() {
        SecItemDelete(kcBase(secretService, "backup") as CFDictionary)
        let ud = UserDefaults.standard
        for k in [udLast, udMark, udName] { ud.removeObject(forKey: k) }
    }

    static func chooseFolder(from vc: UIViewController?, _ done: @escaping (Result<String, SignalFail>) -> Void) {
        PickerDelegate.present({ UIDocumentPickerViewController(forOpeningContentTypes: [.folder]) }, from: vc) { url in
            guard let url = url else {
                done(.failure(fail("cancelled")))
                return
            }
            let on = url.startAccessingSecurityScopedResource()
            defer { if on { url.stopAccessingSecurityScopedResource() } }
            guard let mark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                done(.failure(fail("bookmark_failed")))
                return
            }
            let ud = UserDefaults.standard
            ud.set(mark, forKey: udMark)
            ud.set(url.lastPathComponent, forKey: udName)
            done(.success(url.lastPathComponent))
        }
    }

    private static func folderURL() -> URL? {
        guard let mark = UserDefaults.standard.data(forKey: udMark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: mark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: udMark)
        }
        return url
    }

    private final class FrameWriter {
        private let h: FileHandle
        private let key: SymmetricKey
        private let aad: Data
        private var index: UInt64 = 0
        private var buf = Data()

        init(_ h: FileHandle, key: Data, header: Data) {
            self.h = h
            self.key = SymmetricKey(data: key)
            aad = Data(SHA256.hash(data: header))
        }

        func add(_ type: UInt8, _ body: Data) throws {
            buf.append(type)
            buf.append(BackupEngine.be32(UInt32(body.count)))
            buf.append(body)
            while buf.count > BackupEngine.chunk {
                try emit(buf.subdata(in: 0..<BackupEngine.chunk), last: false)
                buf = buf.subdata(in: BackupEngine.chunk..<buf.count)
            }
        }

        func finish() throws {
            try emit(buf, last: true)
            buf = Data()
        }

        private func emit(_ plain: Data, last: Bool) throws {
            let box = try AES.GCM.seal(
                plain,
                using: key,
                nonce: AES.GCM.Nonce(),
                authenticating: aad + BackupEngine.be64(index) + Data([last ? 1 : 0])
            )
            let nonce = box.nonce.withUnsafeBytes { Data($0) }
            let frame = nonce + box.ciphertext + box.tag
            try h.write(contentsOf: BackupEngine.be32(UInt32(frame.count)) + frame)
            index += 1
        }
    }

    private static func writeFile(_ url: URL, meta: Data, secret s: Secret) throws {
        guard let dbKey = dbKey() else { throw fail("no_db_key") }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw fail("write_failed")
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        let header = magic + Data([1, 0]) + be32(iterations) + s.salt
        try h.write(contentsOf: header)
        let w = FrameWriter(h, key: s.key, header: header)
        try w.add(1, meta)
        try w.add(2, dbKey)
        for (name, value) in try SignalCore.shared.exportRecords() {
            let k = Data(name.utf8)
            try w.add(3, be16(k.count) + k + value)
        }
        try NativeStore.shared.sync { db in
            try db.query("SELECT store, key, idx, value FROM rows", []) { st in
                let head = try lp(SQLiteDB.text(st, 0) ?? "") + lp(SQLiteDB.text(st, 1) ?? "") + lp(SQLiteDB.text(st, 2))
                try w.add(4, head + SQLiteDB.blob(st, 3))
            }
        }
        try w.finish()
    }

    private static func fileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "Ripplo-backup-" + f.string(from: Date()) + ".rbk"
    }

    private static func prune(_ folder: URL) {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let mine = all.filter { $0.lastPathComponent.hasPrefix("Ripplo-backup-") && $0.pathExtension == "rbk" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for u in mine.dropFirst(keepFiles) { try? fm.removeItem(at: u) }
    }

    static func create(mode: String, meta: Data, from vc: UIViewController?, _ done: @escaping (Result<[String: Any], SignalFail>) -> Void) {
        queue.async {
            do {
                guard let s = secret() else { throw fail("not_enabled") }
                let name = fileName()
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                let now = Date().timeIntervalSince1970 * 1000
                if mode == "auto" {
                    guard let folder = folderURL() else { throw fail("no_folder") }
                    if now - UserDefaults.standard.double(forKey: udLast) < 24 * 3600 * 1000 {
                        done(.success(["skipped": true]))
                        return
                    }
                    try writeFile(tmp, meta: meta, secret: s)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.intValue ?? 0
                    let on = folder.startAccessingSecurityScopedResource()
                    defer { if on { folder.stopAccessingSecurityScopedResource() } }
                    let dest = folder.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: tmp, to: dest)
                    prune(folder)
                    UserDefaults.standard.set(now, forKey: udLast)
                    done(.success(["ok": true, "name": name, "size": size]))
                } else {
                    try writeFile(tmp, meta: meta, secret: s)
                    let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.intValue ?? 0
                    PickerDelegate.present({ UIDocumentPickerViewController(forExporting: [tmp], asCopy: true) }, from: vc) { url in
                        try? FileManager.default.removeItem(at: tmp)
                        guard let url = url else {
                            done(.failure(fail("cancelled")))
                            return
                        }
                        UserDefaults.standard.set(now, forKey: udLast)
                        done(.success(["ok": true, "name": url.lastPathComponent, "size": size]))
                    }
                }
            } catch {
                done(.failure((error as? SignalFail) ?? fail("write_failed")))
            }
        }
    }

    private struct Cursor {
        let d: Data
        var p = 0

        mutating func take(_ n: Int) throws -> Data {
            guard n >= 0, p + n <= d.count else { throw SignalFail(code: "bad_file") }
            defer { p += n }
            return d.subdata(in: p..<(p + n))
        }

        mutating func u16() throws -> Int {
            let b = try take(2)
            return Int(b[0]) << 8 | Int(b[1])
        }

        mutating func lp() throws -> String? {
            let n = try u16()
            return n == 0xFFFF ? nil : String(decoding: try take(n), as: UTF8.self)
        }

        var rest: Data { d.subdata(in: p..<d.count) }
    }

    private struct Staged {
        var meta: Data?
        var dbKey: Data?
        var signal: [(String, Data)] = []
        let dbURL: URL
    }

    private static func readExact(_ h: FileHandle, _ n: Int) throws -> Data {
        guard let d = try h.read(upToCount: n), d.count == n else { throw fail("bad_file") }
        return d
    }

    private static func stage(_ url: URL, code: String, _ st: inout Staged, _ db: SQLiteDB) throws {
        let digits = code.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 30 else { throw fail("bad_code") }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = Int((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0)
        let header = try readExact(h, 30)
        guard header.prefix(8) == magic, header[8] == 1 else { throw fail("bad_file") }
        if header[9] & 1 != 0 { throw fail("need_factor") }
        guard header[9] == 0 else { throw fail("bad_file") }
        let iter = header.subdata(in: 10..<14).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard iter >= 1, iter <= 5_000_000 else { throw fail("bad_file") }
        guard let kd = derive(digits, header.subdata(in: 14..<30), iter) else { throw fail("kdf_failed") }
        let key = SymmetricKey(data: kd)
        let hh = Data(SHA256.hash(data: header))
        var offset = 30
        var index: UInt64 = 0
        var buf = Data()
        guard size > offset else { throw fail("bad_file") }
        try db.exec("BEGIN")
        while offset < size {
            let len = Int(try readExact(h, 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard len >= 28, len <= 28 + chunk, offset + 4 + len <= size else { throw fail("bad_file") }
            let frame = try readExact(h, len)
            let last = offset + 4 + len == size
            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: frame.subdata(in: 0..<12)),
                    ciphertext: frame.subdata(in: 12..<(len - 16)),
                    tag: frame.subdata(in: (len - 16)..<len)
                )
                plain = try AES.GCM.open(box, using: key, authenticating: hh + be64(index) + Data([last ? 1 : 0]))
            } catch {
                throw fail(index == 0 ? "bad_code" : "bad_file")
            }
            buf.append(plain)
            var pos = 0
            while buf.count - pos >= 5 {
                let n = Int(buf.subdata(in: (pos + 1)..<(pos + 5)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard n <= maxRecord else { throw fail("bad_file") }
                guard buf.count - pos - 5 >= n else { break }
                let type = buf[pos]
                var c = Cursor(d: buf.subdata(in: (pos + 5)..<(pos + 5 + n)))
                switch type {
                case 1: st.meta = c.d
                case 2:
                    guard c.d.count == 32 else { throw fail("bad_file") }
                    st.dbKey = c.d
                case 3:
                    let kl = try c.u16()
                    st.signal.append((String(decoding: try c.take(kl), as: UTF8.self), c.rest))
                case 4:
                    guard let store = try c.lp(), let k = try c.lp() else { throw fail("bad_file") }
                    let idx = try c.lp()
                    try db.put(store, k, idx, c.rest)
                default: throw fail("bad_file")
                }
                pos += 5 + n
            }
            buf = buf.subdata(in: pos..<buf.count)
            offset += 4 + len
            index += 1
        }
        guard buf.isEmpty, st.meta != nil, st.dbKey != nil else { throw fail("bad_file") }
        try db.exec("COMMIT")
    }

    static func restore(code: String, from vc: UIViewController?, _ done: @escaping (Result<[String: Any], SignalFail>) -> Void) {
        PickerDelegate.present({ UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true) }, from: vc) { url in
            guard let url = url else {
                done(.failure(fail("cancelled")))
                return
            }
            queue.async {
                let fm = FileManager.default
                let stagePath = NativeStore.dir.appendingPathComponent("restore.db")
                defer {
                    try? fm.removeItem(at: url)
                    try? fm.removeItem(at: stagePath)
                }
                do {
                    for suffix in ["", "-journal", "-wal", "-shm"] { try? fm.removeItem(atPath: stagePath.path + suffix) }
                    let db = try SQLiteDB(path: stagePath.path, wal: false)
                    var st = Staged(dbURL: stagePath)
                    try stage(url, code: code, &st, db)
                    db.close()
                    guard let meta = st.meta, let key = st.dbKey else { throw fail("bad_file") }
                    try NativeStore.shared.swap(in: stagePath)
                    try SignalCore.shared.importRecords(st.signal)
                    try setDbKey(key)
                    let obj = (try? JSONSerialization.jsonObject(with: meta)) as? [String: Any] ?? [:]
                    done(.success(["meta": obj]))
                } catch {
                    done(.failure((error as? SignalFail) ?? fail("bad_file")))
                }
            }
        }
    }
}
