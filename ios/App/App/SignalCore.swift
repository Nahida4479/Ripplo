import Foundation
import CryptoKit
import Security
import RipploSignal

struct SignalFail: Error {
    let code: String
}

final class SignalCore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore {
    static let shared = SignalCore()

    private let queue = DispatchQueue(label: "app.ripplo.signal")
    private let ctx = NullContext()
    private var identityCache: IdentityKeyPair?
    private var regIdCache: UInt32?
    private var keyCache: SymmetricKey?

    private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("signal", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    func perform<T>(_ work: @escaping (SignalCore) throws -> T, done: @escaping (Result<T, SignalFail>) -> Void) {
        queue.async {
            do {
                done(.success(try work(self)))
            } catch {
                done(.failure(SignalFail(code: SignalCore.code(error))))
            }
        }
    }

    static func code(_ e: Error) -> String {
        if let f = e as? SignalFail { return f.code }
        switch e as? SignalError {
        case .sessionNotFound?: return "no_session"
        case .untrustedIdentity?: return "untrusted_identity"
        default: return "bad_message"
        }
    }

    private func storeKey() throws -> SymmetricKey {
        if let k = keyCache { return k }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.ripplo.signalkey",
            kSecAttrAccount as String: "signalkey"
        ]
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess {
            guard let d = out as? Data, d.count == 32 else { throw SignalFail(code: "bad_message") }
            keyCache = SymmetricKey(data: d)
            return keyCache!
        }
        guard status == errSecItemNotFound else { throw SignalFail(code: "bad_message") }
        let key = SymmetricKey(size: .bits256)
        var add = base
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SignalFail(code: "bad_message") }
        keyCache = key
        return key
    }

    private func file(_ name: String) -> URL {
        let h = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(h)
    }

    private func put(_ name: String, _ data: Data) throws {
        guard let sealed = try AES.GCM.seal(data, using: storeKey()).combined else { throw SignalFail(code: "bad_message") }
        try sealed.write(to: file(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func get(_ name: String) throws -> Data? {
        guard let raw = try? Data(contentsOf: file(name)) else { return nil }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: storeKey())
    }

    private func drop(_ name: String) {
        try? FileManager.default.removeItem(at: file(name))
    }

    private static func tagOf(_ ik33: Data) -> Data {
        Data(SHA256.hash(data: ik33).prefix(16))
    }

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)])
    }

    private static func readBE32(_ d: Data) -> UInt32 {
        d.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func ensureIdentity() throws {
        if try get("identity") != nil { return }
        let pair = IdentityKeyPair.generate()
        let spk = PrivateKey.generate()
        let spkRecord = try SignedPreKeyRecord(
            id: 1,
            timestamp: SignalCore.nowMs(),
            privateKey: spk,
            signature: pair.privateKey.generateSignature(message: spk.publicKey.serialize())
        )
        let kem = KEMKeyPair.generate()
        let kyberRecord = try KyberPreKeyRecord(
            id: 1,
            timestamp: SignalCore.nowMs(),
            keyPair: kem,
            signature: pair.privateKey.generateSignature(message: kem.publicKey.serialize())
        )
        try put("regid", SignalCore.be32(UInt32.random(in: 1...0x3FFF)))
        try put("spk:1", spkRecord.serialize())
        try put("kyber:1", kyberRecord.serialize())
        try put("identity", pair.serialize())
    }

    private func myPair() throws -> IdentityKeyPair {
        if let p = identityCache { return p }
        try ensureIdentity()
        guard let d = try get("identity") else { throw SignalFail(code: "bad_message") }
        let p = try IdentityKeyPair(bytes: d)
        identityCache = p
        return p
    }

    private func myTag() throws -> Data {
        SignalCore.tagOf(try myPair().publicKey.serialize())
    }

    private func address(_ tag: Data) throws -> ProtocolAddress {
        try ProtocolAddress(name: tag.hex, deviceId: 1)
    }

    private func myAddress() throws -> ProtocolAddress {
        try address(myTag())
    }

    func initIdentity() throws -> (bundle: Data, ik: Data) {
        let pair = try myPair()
        guard let regRaw = try get("regid"), let spkRaw = try get("spk:1"), let kyberRaw = try get("kyber:1") else {
            throw SignalFail(code: "bad_message")
        }
        let spk = try SignedPreKeyRecord(bytes: spkRaw)
        let kyber = try KyberPreKeyRecord(bytes: kyberRaw)
        var out = Data([0x02])
        out += regRaw
        out += pair.publicKey.serialize()
        out += SignalCore.be32(spk.id)
        out += try spk.publicKey().serialize()
        out += spk.signature
        out += SignalCore.be32(kyber.id)
        out += try kyber.publicKey().serialize()
        out += kyber.signature
        guard out.count == 1776 else { throw SignalFail(code: "bad_message") }
        return (out, pair.publicKey.serialize())
    }

    func addContact(_ bundle: Data) throws -> Data {
        do {
            guard bundle.count == 1776, bundle[bundle.startIndex] == 0x02 else { throw SignalFail(code: "bad_bundle") }
            let b = Data(bundle)
            let ikBytes = b.subdata(in: 5..<38)
            let ik = try IdentityKey(bytes: ikBytes)
            let pre = try PreKeyBundle(
                registrationId: SignalCore.readBE32(b.subdata(in: 1..<5)),
                deviceId: 1,
                signedPrekeyId: SignalCore.readBE32(b.subdata(in: 38..<42)),
                signedPrekey: try PublicKey(b.subdata(in: 42..<75)),
                signedPrekeySignature: b.subdata(in: 75..<139),
                identity: ik,
                kyberPrekeyId: SignalCore.readBE32(b.subdata(in: 139..<143)),
                kyberPrekey: try KEMPublicKey(b.subdata(in: 143..<1712)),
                kyberPrekeySignature: b.subdata(in: 1712..<1776)
            )
            let tag = SignalCore.tagOf(ikBytes)
            try ensureIdentity()
            try processPreKeyBundle(
                pre,
                for: address(tag),
                ourAddress: myAddress(),
                sessionStore: self,
                identityStore: self,
                context: ctx
            )
            return tag
        } catch {
            throw SignalFail(code: "bad_bundle")
        }
    }

    func seal(tag: Data, plaintext: Data) throws -> Data {
        guard tag.count == 16, let rik = try identity(for: address(tag), context: ctx) else {
            throw SignalFail(code: "no_session")
        }
        let me = try myTag()
        let ct = try signalEncrypt(
            message: plaintext,
            for: address(tag),
            localAddress: myAddress(),
            sessionStore: self,
            identityStore: self,
            context: ctx
        )
        var inner = Data([0x02])
        inner += me
        inner.append(ct.messageType == .preKey ? 3 : 2)
        inner += ct.serialize()
        let eph = PrivateKey.generate()
        let key = SignalCore.sealedKey(eph.keyAgreement(with: rik.publicKey), salt: tag)
        let box = try AES.GCM.seal(inner, using: key)
        var out = Data([0x01])
        out += eph.publicKey.serialize().dropFirst()
        out += box.nonce.withUnsafeBytes { Data($0) }
        out += box.ciphertext
        out += box.tag
        return out
    }

    private static func sealedKey(_ shared: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: salt,
            info: Data("ripplo-sealed-v2".utf8),
            outputByteCount: 32
        )
    }

    func open(_ sealed: Data) throws -> (tag: Data, ik: Data, plaintext: Data) {
        let s = Data(sealed)
        guard s.count >= 1 + 32 + 12 + 16 + 18, s[0] == 0x01 else { throw SignalFail(code: "bad_message") }
        let pair = try myPair()
        let me = SignalCore.tagOf(pair.publicKey.serialize())
        let eph = try PublicKey(Data([0x05]) + s.subdata(in: 1..<33))
        let key = SignalCore.sealedKey(pair.privateKey.keyAgreement(with: eph), salt: me)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: s.subdata(in: 33..<45)),
            ciphertext: s.subdata(in: 45..<(s.count - 16)),
            tag: s.subdata(in: (s.count - 16)..<s.count)
        )
        let inner = try AES.GCM.open(box, using: key)
        guard inner.count > 18, inner[0] == 0x02 else { throw SignalFail(code: "bad_message") }
        let senderTag = inner.subdata(in: 1..<17)
        let type = inner[17]
        let body = inner.subdata(in: 18..<inner.count)
        let from = try address(senderTag)
        let plain: Data
        if type == 3 {
            let msg = try PreKeySignalMessage(bytes: body)
            guard SignalCore.tagOf(msg.identityKey.serialize()) == senderTag else { throw SignalFail(code: "bad_message") }
            plain = try signalDecryptPreKey(
                message: msg,
                from: from,
                localAddress: myAddress(),
                sessionStore: self,
                identityStore: self,
                preKeyStore: self,
                signedPreKeyStore: self,
                kyberPreKeyStore: self,
                context: ctx
            )
        } else if type == 2 {
            plain = try signalDecrypt(
                message: SignalMessage(bytes: body),
                from: from,
                to: myAddress(),
                sessionStore: self,
                identityStore: self,
                context: ctx
            )
        } else {
            throw SignalFail(code: "bad_message")
        }
        guard let ik = try identity(for: from, context: ctx) else { throw SignalFail(code: "bad_message") }
        return (senderTag, ik.serialize(), plain)
    }

    private static func publicKey(_ ik: Data) throws -> PublicKey {
        try PublicKey(ik.count == 32 ? Data([0x05]) + ik : ik)
    }

    func proof(ik: Data, n: Data, challengerTag: Data, proverTag: Data) throws -> Data {
        let shared = try myPair().privateKey.keyAgreement(with: SignalCore.publicKey(ik))
        let info = Data("ripplo-proof-v1".utf8)
        let k = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: n,
            info: info,
            outputByteCount: 32
        )
        return Data(HMAC<SHA256>.authenticationCode(for: info + n + challengerTag + proverTag, using: k))
    }

    func safetyNumber(ik: Data) throws -> String {
        let pair = try myPair()
        let theirs = try SignalCore.publicKey(ik)
        let fp = try NumericFingerprintGenerator(iterations: 5200).create(
            version: 1,
            localIdentifier: SignalCore.tagOf(pair.publicKey.serialize()),
            localKey: pair.publicKey,
            remoteIdentifier: SignalCore.tagOf(theirs.serialize()),
            remoteKey: theirs
        )
        return fp.displayable.formatted.filter { $0.isNumber }
    }

    func forget(tag: Data) {
        drop("session:" + tag.hex)
        drop("ident:" + tag.hex)
    }

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        try myPair()
    }

    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        if let r = regIdCache { return r }
        try ensureIdentity()
        guard let d = try get("regid") else { throw SignalFail(code: "bad_message") }
        regIdCache = SignalCore.readBE32(d)
        return regIdCache!
    }

    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let ik = identity.serialize()
        guard SignalCore.tagOf(ik).hex == address.name else { throw SignalFail(code: "untrusted_identity") }
        let old = try get("ident:" + address.name)
        try put("ident:" + address.name, ik)
        return old == nil || old == ik ? .newOrUnchanged : .replacedExisting
    }

    func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        SignalCore.tagOf(identity.serialize()).hex == address.name
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        guard let d = try get("ident:" + address.name) else { return nil }
        return try IdentityKey(bytes: d)
    }

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let d = try get("prekey:\(id)") else { throw SignalError.invalidKeyIdentifier("no prekey") }
        return try PreKeyRecord(bytes: d)
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try put("prekey:\(id)", record.serialize())
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        drop("prekey:\(id)")
    }

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let d = try get("spk:\(id)") else { throw SignalError.invalidKeyIdentifier("no signed prekey") }
        return try SignedPreKeyRecord(bytes: d)
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try put("spk:\(id)", record.serialize())
    }

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let d = try get("kyber:\(id)") else { throw SignalError.invalidKeyIdentifier("no kyber prekey") }
        return try KyberPreKeyRecord(bytes: d)
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try put("kyber:\(id)", record.serialize())
    }

    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {}

    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        guard let d = try get("session:" + address.name) else { return nil }
        return try SessionRecord(bytes: d)
    }

    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map {
            guard let s = try loadSession(for: $0, context: context) else { throw SignalError.sessionNotFound($0.name) }
            return s
        }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try put("session:" + address.name, record.serialize())
    }
}
