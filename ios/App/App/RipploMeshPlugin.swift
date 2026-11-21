import Foundation
import Capacitor
import CoreBluetooth
import Network
import Security
import UserNotifications

@objc(RipploMeshPlugin)
public class RipploMeshPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "RipploMeshPlugin"
    public let jsName = "RipploMesh"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "send", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendApp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getNeighbors", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "drainInbox", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDbKey", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "selfHash", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "installUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestBatteryExemption", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "signalInit", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "signalAddContact", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "signalSeal", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "signalOpen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "signalProof", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "signalSafetyNumber", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "signalForget", returnType: CAPPluginReturnPromise)
    ]

    private var btProbe: CBCentralManager?
    private var lanProbe: NWBrowser?

    override public func load() {
        MeshEngine.shared.emit = { [weak self] name, data in
            self?.notifyListeners(name, data: data)
        }
    }

    private static func decodeTag(_ s: String) -> Data? {
        if let d = Data(base64Encoded: s), d.count == 16 { return d }
        if let d = Data(hex: s), d.count == 16 { return d }
        return nil
    }

    @objc func start(_ call: CAPPluginCall) {
        guard let s = call.getString("selfTag"), let tag = RipploMeshPlugin.decodeTag(s) else {
            call.reject("bad selfTag")
            return
        }
        call.resolve(["nodeTag": MeshEngine.shared.start(selfTag: tag)])
    }

    @objc func stop(_ call: CAPPluginCall) {
        MeshEngine.shared.stop()
        call.resolve()
    }

    @objc func send(_ call: CAPPluginCall) {
        guard let b = call.getString("packet"), let d = Data(base64Encoded: b), var p = Packet.decode(d),
              [PacketType.data, PacketType.ack, PacketType.discover, PacketType.reply].contains(p.type) else {
            call.reject("bad packet")
            return
        }
        p.ttl = min(p.ttl, MeshConst.ttlDefault)
        p.hops = 0
        MeshEngine.shared.jsSend(p) { n in call.resolve(["neighbors": n]) }
    }

    @objc func sendApp(_ call: CAPPluginCall) {
        guard let node = call.getString("node"), node.count == 32, Data(hex: node) != nil,
              let b = call.getString("payload"), let payload = Data(base64Encoded: b),
              payload.count <= MeshConst.maxPacket - MeshConst.header else {
            call.reject("bad args")
            return
        }
        MeshEngine.shared.sendApp(node: node.lowercased(), payload: payload)
        call.resolve()
    }

    @objc func getNeighbors(_ call: CAPPluginCall) {
        call.resolve(["neighbors": MeshEngine.shared.neighborInfo()])
    }

    @objc func drainInbox(_ call: CAPPluginCall) {
        MeshEngine.shared.drainInbox { items in
            call.resolve(["packets": items.map { ["packet": $0.0.base64EncodedString(), "from": $0.1] }])
        }
    }

    @objc func getDbKey(_ call: CAPPluginCall) {
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

    @objc func selfHash(_ call: CAPPluginCall) {
        call.resolve(["sha256": NSNull()])
    }

    @objc func installUpdate(_ call: CAPPluginCall) {
        call.reject("unsupported")
    }

    @objc func requestBatteryExemption(_ call: CAPPluginCall) {
        call.resolve()
    }

    private static func bluetoothState() -> String {
        switch CBManager.authorization {
        case .allowedAlways: return "granted"
        case .notDetermined: return "prompt"
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
            done(["bluetooth": RipploMeshPlugin.bluetoothState(), "wifi": wifi, "notifications": n])
        }
    }

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        permissionState { call.resolve($0) }
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
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
            self.waitForBluetooth(until: Date().addingTimeInterval(30)) {
                self.permissionState { call.resolve($0) }
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

    private func signalRun<T>(_ call: CAPPluginCall, _ work: @escaping (SignalCore) throws -> T, _ ok: @escaping (T) -> [String: Any]) {
        SignalCore.shared.perform(work) { result in
            switch result {
            case .success(let v): call.resolve(ok(v))
            case .failure(let e): call.reject(e.code, e.code)
            }
        }
    }

    private static func b64(_ call: CAPPluginCall, _ key: String) -> Data? {
        call.getString(key).flatMap { Data(base64Encoded: $0) }
    }

    @objc func signalInit(_ call: CAPPluginCall) {
        signalRun(call, { try $0.initIdentity() }) { ["bundle": $0.bundle.base64EncodedString(), "ik": $0.ik.base64EncodedString()] }
    }

    @objc func signalAddContact(_ call: CAPPluginCall) {
        guard let bundle = RipploMeshPlugin.b64(call, "bundle") else {
            call.reject("bad_bundle", "bad_bundle")
            return
        }
        signalRun(call, { try $0.addContact(bundle) }) { ["tag": $0.hex] }
    }

    @objc func signalSeal(_ call: CAPPluginCall) {
        guard let t = call.getString("tag"), let tag = Data(hex: t), let plain = RipploMeshPlugin.b64(call, "plaintext") else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { try $0.seal(tag: tag, plaintext: plain) }) { ["payload": $0.base64EncodedString()] }
    }

    @objc func signalOpen(_ call: CAPPluginCall) {
        guard let payload = RipploMeshPlugin.b64(call, "payload") else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { try $0.open(payload) }) {
            ["tag": $0.tag.hex, "ik": $0.ik.base64EncodedString(), "plaintext": $0.plaintext.base64EncodedString()]
        }
    }

    @objc func signalProof(_ call: CAPPluginCall) {
        guard let ik = RipploMeshPlugin.b64(call, "ik"), let n = RipploMeshPlugin.b64(call, "n"),
              let c = call.getString("challengerTag"), let ct = Data(hex: c), ct.count == 16,
              let p = call.getString("proverTag"), let pt = Data(hex: p), pt.count == 16 else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { try $0.proof(ik: ik, n: n, challengerTag: ct, proverTag: pt) }) { ["mac": $0.base64EncodedString()] }
    }

    @objc func signalSafetyNumber(_ call: CAPPluginCall) {
        guard let ik = RipploMeshPlugin.b64(call, "ik") else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { try $0.safetyNumber(ik: ik) }) { ["digits": $0] }
    }

    @objc func signalForget(_ call: CAPPluginCall) {
        guard let t = call.getString("tag"), let tag = Data(hex: t), tag.count == 16 else {
            call.reject("bad_message", "bad_message")
            return
        }
        signalRun(call, { $0.forget(tag: tag) }) { _ in [:] }
    }
}
