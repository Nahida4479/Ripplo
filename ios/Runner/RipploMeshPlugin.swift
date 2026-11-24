import AVFoundation
import CoreBluetooth
import Flutter
import Foundation
import Network
import Security
import SQLite3
import UIKit
import UserNotifications

struct Call {
    let args: [String: Any]
    private let reply: FlutterResult

    init(_ args: [String: Any], _ reply: @escaping FlutterResult) {
        self.args = args
        self.reply = reply
    }

    func string(_ key: String) -> String? { args[key] as? String }
    func bool(_ key: String) -> Bool? { args[key] as? Bool }
    func array(_ key: String) -> [Any]? { args[key] as? [Any] }
    func object(_ key: String) -> [String: Any]? { args[key] as? [String: Any] }

    func resolve(_ value: Any? = nil) {
        let r = reply
        if Thread.isMainThread {
            r(value)
        } else {
            DispatchQueue.main.async { r(value) }
        }
    }

    func reject(_ message: String, _ code: String? = nil, _ data: [String: Any]? = nil) {
        resolve(FlutterError(code: code ?? message, message: message, details: data))
    }
}

public final class RipploMeshPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static var instance: RipploMeshPlugin?

    private var sink: FlutterEventSink?
    private var btProbe: CBCentralManager?
    private var lanProbe: NWBrowser?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = RipploMeshPlugin()
        instance = plugin
        let codec = FlutterJSONMethodCodec.sharedInstance()
        let methods = FlutterMethodChannel(name: "ripplo/mesh", binaryMessenger: registrar.messenger(), codec: codec)
        registrar.addMethodCallDelegate(plugin, channel: methods)
        FlutterEventChannel(name: "ripplo/mesh/events", binaryMessenger: registrar.messenger(), codec: codec).setStreamHandler(plugin)
        CallAudio.register(with: registrar.messenger())
        AppLock.installCover()
        MeshEngine.shared.emit = { [weak plugin] name, data in
            if name == "neighbor" {
                let node = (data["node"] as? String).map { String($0.prefix(8)) } ?? "?"
                let up = (data["up"] as? Bool) == true
                let medium = data["medium"] as? String ?? ""
                Diag.add("neighbor \(up ? "up" : "down") \(node) \(medium)")
            }
            plugin?.emit(name, data)
        }
        Notifier.shared.onOpen = { [weak plugin] in
            plugin?.emit("open", [:])
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func emit(_ name: String, _ data: [String: Any]) {
        let message: [String: Any] = ["event": name, "data": data]
        DispatchQueue.main.async { self.sink?(message) }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let c = Call(call.arguments as? [String: Any] ?? [:], result)
        switch call.method {
        case "start": start(c)
        case "stop": stop(c)
        case "send": send(c)
        case "sendApp": sendApp(c)
        case "getNeighbors": getNeighbors(c)
        case "drainInbox": drainInbox(c)
        case "getDbKey": getDbKey(c)
        case "selfHash": c.resolve(["sha256": NSNull()])
        case "installUpdate": c.reject("unsupported")
        case "setAutoUpdate": c.resolve()
        case "requestBatteryExemption": c.resolve()
        case "keepAwake": keepAwake(c)
        case "endLockedCall": c.resolve()
        case "requestFullScreen": c.resolve()
        case "startRing": startRing(c)
        case "stopRing": stopRing(c)
        case "takeOpen": takeOpen(c)
        case "takeShare": c.resolve([:])
        case "isLocked": isLocked(c)
        case "fromPlay": c.resolve(["play": false])
        case "getDeviceInfo": c.resolve(["text": RipploMeshPlugin.deviceInfo()])
        case "getBleCaps": c.resolve(["coded": false, "extended": false])
        case "getDiag": c.resolve(["log": Diag.dump()])
        case "clearDiag": clearDiag(c)
        case "usbLog": usbLog(c)
        case "getTransports": c.resolve(["transports": MeshEngine.shared.transportInfo()])
        case "devConnect": c.resolve(["started": false])
        case "devDisconnect": c.resolve()
        case "notify": notify(c)
        case "checkPermissions": checkPermissions(c)
        case "requestPermissions": requestPermissions(c)
        case "signalInit": signalInit(c)
        case "signalAddContact": signalAddContact(c)
        case "signalSeal": signalSeal(c)
        case "signalOpen": signalOpen(c)
        case "signalProof": signalProof(c)
        case "signalSafetyNumber": signalSafetyNumber(c)
        case "signalForget": signalForget(c)
        case "dbPut": dbPut(c)
        case "dbPutMany": dbPutMany(c)
        case "dbGet": dbGet(c)
        case "dbDel": dbDel(c)
        case "dbKeys": dbKeys(c)
        case "dbAll": dbAll(c)
        case "dbByIdx": dbByIdx(c)
        case "dbCount": dbCount(c)
        case "authAvailable": authAvailable(c)
        case "authenticate": authenticate(c)
        case "setSecure": setSecure(c)
        case "backupStatus": c.resolve(BackupEngine.status())
        case "backupEnable": backupEnable(c)
        case "backupShowCode": backupShowCode(c)
        case "backupDisable": backupDisable(c)
        case "backupChooseFolder": backupChooseFolder(c)
        case "backupCreate": backupCreate(c)
        case "backupRestore": backupRestore(c)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private static func decodeTag(_ s: String) -> Data? {
        if let d = Data(base64Encoded: s), d.count == 16 { return d }
        if let d = Data(hex: s), d.count == 16 { return d }
        return nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private static func deviceInfo() -> String {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let d = UIDevice.current
        var s = "device Apple " + d.model + " (" + machine + ")\n"
        s += "ios " + d.systemVersion + "\n"
        s += "bluetooth " + bluetoothState() + " l2cap true coded false ext-adv false\n"
        s += "low-power " + String(ProcessInfo.processInfo.isLowPowerModeEnabled)
        return s
    }

    private func start(_ call: Call) {
        guard let s = call.string("selfTag"), let tag = RipploMeshPlugin.decodeTag(s) else {
            call.reject("bad selfTag")
            return
        }
        call.resolve(["nodeTag": MeshEngine.shared.start(selfTag: tag)])
    }

    private func stop(_ call: Call) {
        MeshEngine.shared.stop()
        call.resolve()
    }

    private func send(_ call: Call) {
        guard let b = call.string("packet"), let d = Data(base64Encoded: b), var p = Packet.decode(d),
              [PacketType.data, PacketType.ack, PacketType.discover, PacketType.reply].contains(p.type) else {
            call.reject("bad packet")
            return
        }
        p.ttl = min(p.ttl, MeshConst.ttlDefault)
        p.hops = 0
        MeshEngine.shared.jsSend(p) { n in call.resolve(["neighbors": n]) }
    }

    private func sendApp(_ call: Call) {
        guard let node = call.string("node"), node.count == 32, Data(hex: node) != nil,
              let b = call.string("payload"), let payload = Data(base64Encoded: b),
              payload.count <= MeshConst.maxPacket - MeshConst.header else {
            call.reject("bad args")
            return
        }
        MeshEngine.shared.sendApp(node: node.lowercased(), payload: payload)
        call.resolve()
    }

    private func getNeighbors(_ call: Call) {
        call.resolve(["neighbors": MeshEngine.shared.neighborInfo()])
    }

    private func drainInbox(_ call: Call) {
        MeshEngine.shared.drainInbox { items in
            call.resolve(["packets": items.map { ["packet": $0.0.base64EncodedString(), "from": $0.1] }])
        }
    }

    private func getDbKey(_ call: Call) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.ripplo.dbkey",
            kSecAttrAccount as String: "dbkey"
        ]
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess {
            if let d = out as? Data, d.count == 32 {
                call.resolve(["key": d.base64EncodedString()])
            } else {
                call.reject("keychain key invalid")
            }
            return
        }
        guard status == errSecItemNotFound else {
            call.reject("keychain unavailable")
            return
        }
        let key = randomBytes(32)
        var add = base
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            call.resolve(["key": key.base64EncodedString()])
        } else {
            call.reject("keychain write failed")
        }
    }

    private func keepAwake(_ call: Call) {
        UIApplication.shared.isIdleTimerDisabled = call.bool("on") ?? false
        call.resolve()
    }

    private func startRing(_ call: Call) {
        Ringer.shared.start()
        call.resolve()
    }

    private func stopRing(_ call: Call) {
        Ringer.shared.stop()
        call.resolve()
    }

    private func takeOpen(_ call: Call) {
        if let o = Notifier.shared.take() {
            call.resolve(["open": o])
        } else {
            call.resolve([:])
        }
    }

    private func isLocked(_ call: Call) {
        call.resolve(["locked": !UIApplication.shared.isProtectedDataAvailable])
    }

    private func clearDiag(_ call: Call) {
        Diag.clear()
        call.resolve()
    }

    private func usbLog(_ call: Call) {
        let text = call.string("text") ?? ""
        Diag.add(text)
#if DEBUG
        NSLog("ripplo %@", text)
#endif
        call.resolve(["usb": false])
    }

    private func notify(_ call: Call) {
        Notifier.shared.show(title: call.string("title") ?? "Ripplo", body: call.string("body") ?? "", chatId: call.string("chatId"))
        call.resolve()
    }

    private static func bluetoothState() -> String {
        switch CBManager.authorization {
        case .allowedAlways: return "granted"
        case .notDetermined: return "prompt"
        default: return "denied"
        }
    }

    private static func microphoneState() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .undetermined: return "prompt"
        default: return "denied"
        }
    }

    private func permissionState(_ done: @escaping ([String: Any]) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let n: String
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: n = "granted"
            case .notDetermined: n = "prompt"
            default: n = "denied"
            }
            let wifi = UserDefaults.standard.bool(forKey: "ripplo.lanTriggered") ? "granted" : "prompt"
            done([
                "bluetooth": RipploMeshPlugin.bluetoothState(),
                "wifi": wifi,
                "notifications": n,
                "microphone": RipploMeshPlugin.microphoneState(),
                "battery": "granted"
            ])
        }
    }

    private func checkPermissions(_ call: Call) {
        permissionState { call.resolve($0) }
    }

    private func requestPermissions(_ call: Call) {
        DispatchQueue.main.async {
            if CBManager.authorization == .notDetermined { self.btProbe = CBCentralManager(delegate: nil, queue: nil) }
            let b = NWBrowser(for: .bonjour(type: LanTransport.serviceType, domain: nil), using: .tcp)
            b.start(queue: .main)
            self.lanProbe = b
            UserDefaults.standard.set(true, forKey: "ripplo.lanTriggered")
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                self.lanProbe?.cancel()
                self.lanProbe = nil
                self.btProbe = nil
            }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            AVAudioSession.sharedInstance().requestRecordPermission { _ in
                self.waitForBluetooth(until: Date().addingTimeInterval(30)) {
                    self.permissionState { call.resolve($0) }
                }
            }
        }
    }

    private func waitForBluetooth(until deadline: Date, _ done: @escaping () -> Void) {
        if CBManager.authorization != .notDetermined || Date() > deadline {
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.waitForBluetooth(until: deadline, done)
        }
    }

    private func signalRun<T>(_ call: Call, _ work: @escaping (SignalCore) throws -> T, _ ok: @escaping (T) -> [String: Any]) {
        SignalCore.shared.perform(work) { result in
            switch result {
            case .success(let v): call.resolve(ok(v))
            case .failure(let e): call.reject(e.code, e.code, e.tag.map { ["tag": $0.hex] as [String: Any] })
            }
        }
    }

    private static func b64(_ call: Call, _ key: String) -> Data? {
        call.string(key).flatMap { Data(base64Encoded: $0) }
    }

    private func signalInit(_ call: Call) {
        signalRun(call, { try $0.initIdentity() }) { ["bundle": $0.bundle.base64EncodedString(), "ik": $0.ik.base64EncodedString()] }
    }

    private func signalAddContact(_ call: Call) {
        guard let bundle = RipploMeshPlugin.b64(call, "bundle") else {
            call.reject("bad_bundle", "bad_bundle")
            return
        }
        signalRun(call, { try $0.addContact(bundle) }) { ["tag": $0.hex] }
    }

    private func signalSeal(_ call: Call) {
        guard let t = call.string("tag"), let tag = Data(hex: t), let plain = RipploMeshPlugin.b64(call, "plaintext") else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { try $0.seal(tag: tag, plaintext: plain) }) { ["payload": $0.base64EncodedString()] }
    }

    private func signalOpen(_ call: Call) {
        guard let payload = RipploMeshPlugin.b64(call, "payload") else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { try $0.open(payload) }) {
            ["tag": $0.tag.hex, "ik": $0.ik.base64EncodedString(), "plaintext": $0.plaintext.base64EncodedString()]
        }
    }

    private func signalProof(_ call: Call) {
        guard let ik = RipploMeshPlugin.b64(call, "ik"), let n = RipploMeshPlugin.b64(call, "n"),
              let ct = RipploMeshPlugin.b64(call, "challengerTag"), ct.count == 16,
              let pt = RipploMeshPlugin.b64(call, "proverTag"), pt.count == 16 else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { try $0.proof(ik: ik, n: n, challengerTag: ct, proverTag: pt) }) { ["mac": $0.base64EncodedString()] }
    }

    private func signalSafetyNumber(_ call: Call) {
        guard let ik = RipploMeshPlugin.b64(call, "ik") else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { try $0.safetyNumber(ik: ik) }) { ["digits": $0] }
    }

    private func signalForget(_ call: Call) {
        guard let t = call.string("tag"), let tag = Data(hex: t), tag.count == 16 else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { $0.forget(tag: tag) }) { _ in [:] }
    }

    private func storeRun<T>(_ call: Call, _ work: @escaping (SQLiteDB) throws -> T, _ ok: @escaping (T) -> [String: Any]) {
        NativeStore.shared.perform(work) { result in
            switch result {
            case .success(let v): call.resolve(ok(v))
            case .failure(let e): call.reject(e.code, e.code)
            }
        }
    }

    private static func rowOf(_ s: OpaquePointer) -> [String: Any] {
        ["key": SQLiteDB.text(s, 0) ?? "", "value": SQLiteDB.blob(s, 1).base64EncodedString()]
    }

    private static func dbRow(_ o: [String: Any]) -> (String, String, String?, Data)? {
        guard let st = o["store"] as? String, let k = o["key"] as? String, let v = o["value"] as? String,
              let d = Data(base64Encoded: v) else { return nil }
        return (st, k, o["idx"] as? String, d)
    }

    private func dbPut(_ call: Call) {
        guard let r = RipploMeshPlugin.dbRow(call.args) else {
            call.reject("bad_args", "bad_args")
            return
        }
        storeRun(call, { try $0.put(r.0, r.1, r.2, r.3) }) { _ in [:] }
    }

    private func dbPutMany(_ call: Call) {
        let all = call.array("rows") ?? []
        let raw = all.compactMap { $0 as? [String: Any] }
        let rows = raw.compactMap { RipploMeshPlugin.dbRow($0) }
        guard rows.count == raw.count, raw.count == all.count else {
            call.reject("bad_args", "bad_args")
            return
        }
        storeRun(call, { db -> Int in
            try db.exec("BEGIN IMMEDIATE")
            do {
                for r in rows { try db.put(r.0, r.1, r.2, r.3) }
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
            return rows.count
        }) { ["count": $0] }
    }

    private func dbGet(_ call: Call) {
        guard let st = call.string("store"), let k = call.string("key") else {
            call.reject("bad_args", "bad_args")
            return
        }
        storeRun(call, { db -> String? in
            var out: String?
            try db.query("SELECT value FROM rows WHERE store = ? AND key = ?", [st, k]) { out = SQLiteDB.blob($0, 0).base64EncodedString() }
            return out
        }) { ["value": $0.map { $0 as Any } ?? NSNull()] }
    }

    private func dbDel(_ call: Call) {
        guard let st = call.string("store"), let k = call.string("key") else {
            call.reject("bad_args", "bad_args")
            return
        }
        storeRun(call, { try $0.run("DELETE FROM rows WHERE store = ? AND key = ?", [st, k]) }) { _ in [:] }
    }

    private func dbKeys(_ call: Call) {
        guard let st = call.string("store") else {
            call.reject("bad_args", "bad_args")
            return
        }
        let prefix = call.string("prefix")
        storeRun(call, { db -> [String] in
            var out: [String] = []
            if let p = prefix {
                try db.query("SELECT key FROM rows WHERE store = ? AND key LIKE ? ESCAPE '\\' ORDER BY key",
                             [st, NativeStore.escapeLike(p) + "/%"]) { out.append(SQLiteDB.text($0, 0) ?? "") }
            } else {
                try db.query("SELECT key FROM rows WHERE store = ? ORDER BY key", [st]) { out.append(SQLiteDB.text($0, 0) ?? "") }
            }
            return out
        }) { ["keys": $0] }
    }

    private func dbAll(_ call: Call) {
        guard let st = call.string("store") else {
            call.reject("bad_args", "bad_args")
            return
        }
        storeRun(call, { db -> [[String: Any]] in
            var out: [[String: Any]] = []
            try db.query("SELECT key, value FROM rows WHERE store = ? ORDER BY key", [st]) { out.append(RipploMeshPlugin.rowOf($0)) }
            return out
        }) { ["rows": $0] }
    }

    private func dbByIdx(_ call: Call) {
        guard let st = call.string("store"), let idx = call.string("idx") else {
            call.reject("bad_args", "bad_args")
            return
        }
        storeRun(call, { db -> [[String: Any]] in
            var out: [[String: Any]] = []
            try db.query("SELECT key, value FROM rows WHERE store = ? AND idx = ? ORDER BY key", [st, idx]) { out.append(RipploMeshPlugin.rowOf($0)) }
            return out
        }) { ["rows": $0] }
    }

    private func dbCount(_ call: Call) {
        storeRun(call, { db -> Int in
            var n = 0
            try db.query("SELECT COUNT(*) FROM rows", []) { n = Int(sqlite3_column_int64($0, 0)) }
            return n
        }) { ["count": $0] }
    }

    private func authAvailable(_ call: Call) {
        let a = AppLock.available()
        call.resolve(["biometric": a.biometric, "deviceCredential": a.credential])
    }

    private func authenticate(_ call: Call) {
        AppLock.authenticate(reason: call.string("reason") ?? "Ripplo") { call.resolve(["ok": $0]) }
    }

    private func setSecure(_ call: Call) {
        AppLock.secure = call.bool("on") ?? false
        call.resolve()
    }

    private func backupFail(_ call: Call, _ e: SignalFail) {
        call.reject(e.code, e.code)
    }

    private func backupEnable(_ call: Call) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                call.resolve(["code": try BackupEngine.enable()])
            } catch {
                self.backupFail(call, (error as? SignalFail) ?? SignalFail(code: "backup_failed"))
            }
        }
    }

    private func backupShowCode(_ call: Call) {
        AppLock.authenticate(reason: "Show recovery code") { ok in
            guard ok else {
                call.reject("auth_failed", "auth_failed")
                return
            }
            guard let c = BackupEngine.showCode() else {
                call.reject("not_enabled", "not_enabled")
                return
            }
            call.resolve(["code": c])
        }
    }

    private func backupDisable(_ call: Call) {
        AppLock.authenticate(reason: "Turn off backups") { ok in
            guard ok else {
                call.reject("auth_failed", "auth_failed")
                return
            }
            BackupEngine.disable()
            call.resolve()
        }
    }

    private func backupChooseFolder(_ call: Call) {
        BackupEngine.chooseFolder(from: RipploMeshPlugin.topViewController()) { r in
            switch r {
            case .success(let n): call.resolve(["folder": n])
            case .failure(let e): self.backupFail(call, e)
            }
        }
    }

    private func backupCreate(_ call: Call) {
        let mode = call.string("mode") ?? "pick"
        var meta = Data("{}".utf8)
        if let o = call.object("meta"), let d = try? JSONSerialization.data(withJSONObject: o) {
            meta = d
        } else if let s = call.string("meta") {
            meta = Data(s.utf8)
        }
        BackupEngine.create(mode: mode, meta: meta, from: RipploMeshPlugin.topViewController()) { r in
            switch r {
            case .success(let v): call.resolve(v)
            case .failure(let e): self.backupFail(call, e)
            }
        }
    }

    private func backupRestore(_ call: Call) {
        guard let code = call.string("code") else {
            call.reject("bad_code", "bad_code")
            return
        }
        AppLock.authenticate(reason: "Restore from backup") { ok in
            guard ok else {
                call.reject("auth_failed", "auth_failed")
                return
            }
            BackupEngine.restore(code: code, from: RipploMeshPlugin.topViewController()) { r in
                switch r {
                case .success(let v): call.resolve(v)
                case .failure(let e): self.backupFail(call, e)
                }
            }
        }
    }
}
