import Foundation
import UIKit
import UserNotifications

final class Inbox {
    static let maxEntries = 2000
    private let url: URL
    private var count = 0

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("ripplo-inbox.bin")
        count = read().count
    }

    private func encode(_ packet: Data, _ from: String) -> Data {
        let fb = Array(from.utf8.prefix(64))
        var rec = Data()
        rec.append(UInt8(fb.count >> 8))
        rec.append(UInt8(fb.count & 0xff))
        rec.append(contentsOf: fb)
        var n = UInt32(packet.count).bigEndian
        withUnsafeBytes(of: &n) { rec.append(contentsOf: $0) }
        rec.append(packet)
        return rec
    }

    private func read() -> [(Data, String)] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let b = [UInt8](d)
        var out = [(Data, String)]()
        var i = 0
        while i + 2 <= b.count {
            let fl = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2
            guard fl <= 64, i + fl + 4 <= b.count else { break }
            let from = String(decoding: b[i..<(i + fl)], as: UTF8.self)
            i += fl
            let pl = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            i += 4
            guard pl >= MeshConst.header, pl <= MeshConst.maxPacket, i + pl <= b.count else { break }
            out.append((Data(b[i..<(i + pl)]), from))
            i += pl
        }
        return out
    }

    func append(_ packet: Data, from: String) {
        let rec = encode(packet, from)
        if count >= Inbox.maxEntries {
            var all = read()
            all.append((packet, from))
            all.removeFirst(max(0, all.count - Inbox.maxEntries))
            var blob = Data()
            for e in all { blob.append(encode(e.0, e.1)) }
            try? blob.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            count = all.count
            return
        }
        if FileManager.default.fileExists(atPath: url.path), let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(rec)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: rec,
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        count += 1
    }

    func drain() -> [(Data, String)] {
        let all = read()
        try? FileManager.default.removeItem(at: url)
        count = 0
        return all
    }
}

final class MeshEngine {
    static let shared = MeshEngine()
    static let selfTagKey = "ripplo.selfTag"
    static let nominalKbps: [String: Double] = ["lan": 20000, "multipeer": 10000, "l2cap": 300, "ble": 50]

    let q = DispatchQueue(label: "ripplo.engine")
    let nodeTag = randomBytes(16)
    var emit: ((String, [String: Any]) -> Void)?

    private final class State {
        let link: MeshLink
        var reader = FrameReader()
        var node: String?
        var kbps: Double
        var rttMs = 0
        var lastRx = Date()
        var strikes = 0
        var lastPing = Date.distantPast
        var pings = [Data: (Date, Int)]()
        init(_ link: MeshLink) {
            self.link = link
            kbps = MeshEngine.nominalKbps[link.medium] ?? 50
        }
    }

    private let router = Router()
    private let inbox = Inbox()
    private var states = [ObjectIdentifier: State]()
    private var rate = [String: (sec: Int, count: Int)]()
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var running = false
    private var appActive = false
    private lazy var transports: [MeshTransport] = [BleTransport(), LanTransport(), MultipeerTransport()]

    var nodeHex: String { nodeTag.hex }

    private init() {
        router.neighbors = { [unowned self] in self.neighborNodes() }
        router.send = { [unowned self] node, p in self.send(to: node, p) }
        router.deliver = { [unowned self] p, from in self.deliverToJS(p, from) }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.q.async { self?.appActive = true }
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.q.async { self?.appActive = false }
        }
    }

    func startIfStored() {
        if let d = UserDefaults.standard.data(forKey: MeshEngine.selfTagKey), d.count == 16 {
            _ = start(selfTag: d)
        }
    }

    func start(selfTag: Data) -> String {
        UserDefaults.standard.set(selfTag, forKey: MeshEngine.selfTagKey)
        DispatchQueue.main.async {
            let active = UIApplication.shared.applicationState == .active
            self.q.async { self.appActive = active }
        }
        return q.sync {
            router.selfTag = selfTag
            if !running {
                running = true
                let hex = nodeHex
                transports.forEach { $0.start(nodeTag: hex) }
                let t = DispatchSource.makeTimerSource(queue: q)
                t.schedule(deadline: .now() + 5, repeating: 5)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
            return nodeHex
        }
    }

    func stop() {
        UserDefaults.standard.removeObject(forKey: MeshEngine.selfTagKey)
        q.async {
            guard self.running else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            let all = Array(self.states.values)
            self.states.removeAll()
            all.forEach { $0.link.close(block: false) }
            var seenNodes = Set<String>()
            for s in all where s.node != nil && seenNodes.insert(s.node!).inserted { self.nodeLost(s) }
            self.transports.forEach { $0.stop() }
        }
    }

    func isLinked(node: String, medium: String) -> Bool {
        q.sync { states.values.contains { $0.node == node && $0.link.medium == medium && !$0.link.closed } }
    }

    func drainInbox(_ done: @escaping ([(Data, String)]) -> Void) {
        q.async { done(self.inbox.drain()) }
    }

    func jsSend(_ p: Packet, _ done: @escaping (Int) -> Void) {
        q.async {
            guard self.running else { done(0); return }
            var count = 0
            let original = self.router.send
            self.router.send = { node, pkt in
                let ok = original(node, pkt)
                if ok && pkt.id == p.id { count += 1 }
                return ok
            }
            self.router.onPacket(p, from: Router.SELF)
            self.router.send = original
            done(count)
        }
    }

    func sendApp(node: String, payload: Data) {
        q.async {
            _ = self.send(to: node, Packet(type: PacketType.app, ttl: 1, payload: payload))
        }
    }

    func neighborInfo() -> [[String: Any]] {
        q.sync {
            neighborNodes().compactMap { node in
                let links = states.values.filter { $0.node == node && !$0.link.closed }.sorted { $0.kbps > $1.kbps }
                guard let best = links.first else { return nil }
                return ["node": node, "medium": best.link.medium, "kbps": Int(best.kbps), "rttMs": best.rttMs,
                        "links": links.map { ["medium": $0.link.medium, "kbps": Int($0.kbps)] }]
            }
        }
    }

    func linkUp(_ link: MeshLink) {
        q.async {
            guard self.running else { link.close(block: false); return }
            let s = State(link)
            self.states[ObjectIdentifier(link)] = s
            let hello = Packet(type: PacketType.linkHello, ttl: 1, payload: self.nodeTag)
            _ = link.write(hello.frame())
        }
    }

    func linkDown(_ link: MeshLink) {
        guard let s = states.removeValue(forKey: ObjectIdentifier(link)) else { return }
        nodeLost(s)
    }

    func linkData(_ link: MeshLink, _ data: Data) {
        guard let s = states[ObjectIdentifier(link)] else { return }
        s.lastRx = Date()
        guard let frames = s.reader.feed(data) else {
            states.removeValue(forKey: ObjectIdentifier(link))
            link.close(block: false)
            nodeLost(s)
            return
        }
        for f in frames {
            if states[ObjectIdentifier(link)] == nil { return }
            handle(s, f)
        }
    }

    private func handle(_ s: State, _ frame: Data) {
        guard let p = Packet.decode(frame) else { return }
        if p.type == PacketType.linkHello {
            onHello(s, p)
            return
        }
        guard let node = s.node, allow(node) else { return }
        switch p.type {
        case PacketType.ping:
            let pong = Packet(type: PacketType.pong, ttl: 1, payload: p.payload.prefix(16))
            _ = s.link.write(pong.frame())
        case PacketType.pong:
            guard p.payload.count >= 16, let sent = s.pings.removeValue(forKey: Data(p.payload.prefix(8))) else { return }
            let rtt = max(1, Int(Date().timeIntervalSince(sent.0) * 1000))
            s.rttMs = rtt
            s.kbps = max(1, Double(sent.1 * 8) / Double(rtt))
            emitNeighbor(node, up: true)
        default:
            router.onPacket(p, from: node)
        }
    }

    private func onHello(_ s: State, _ p: Packet) {
        guard s.node == nil, p.payload.count == 16, p.payload != nodeTag else { return }
        let node = p.payload.hex
        s.node = node
        let known = states.values.contains { $0 !== s && $0.node == node }
        let keepInitiated = nodeHex < node
        for other in Array(states.values) where other !== s && other.node == node && other.link.medium == s.link.medium {
            let sMatches = s.link.initiated == keepInitiated
            let oMatches = other.link.initiated == keepInitiated
            if sMatches && !oMatches {
                closeState(other)
            } else {
                closeState(s)
                return
            }
        }
        if !known { emitNeighbor(node, up: true) }
        sendPing(s)
    }

    private func closeState(_ s: State) {
        states.removeValue(forKey: ObjectIdentifier(s.link))
        s.link.close(block: true)
        nodeLost(s)
    }

    private func nodeLost(_ s: State) {
        guard let node = s.node, !states.values.contains(where: { $0.node == node }) else { return }
        router.dropRoutes(to: node)
        rate.removeValue(forKey: node)
        let data: [String: Any] = ["node": node, "up": false, "medium": s.link.medium, "kbps": 0]
        DispatchQueue.main.async { self.emit?("neighbor", data) }
    }

    private func emitNeighbor(_ node: String, up: Bool) {
        guard let best = states.values.filter({ $0.node == node && !$0.link.closed }).max(by: { $0.kbps < $1.kbps }) else { return }
        let data: [String: Any] = ["node": node, "up": up, "medium": best.link.medium, "kbps": Int(best.kbps)]
        DispatchQueue.main.async { self.emit?("neighbor", data) }
    }

    private func neighborNodes() -> [String] {
        Array(Set(states.values.compactMap { $0.node }))
    }

    private func send(to node: String, _ p: Packet) -> Bool {
        let frame = p.frame()
        let now = Date()
        let sorted = states.values.filter { $0.node == node && !$0.link.closed }.sorted { $0.kbps > $1.kbps }
        let cands = sorted.filter { now.timeIntervalSince($0.lastRx) <= 12 } + sorted.filter { now.timeIntervalSince($0.lastRx) > 12 }
        for s in cands where s.link.queuedBytes + frame.count <= MeshConst.maxQueuedBytes {
            if s.link.write(frame) { return true }
        }
        return false
    }

    private func allow(_ node: String) -> Bool {
        let sec = Int(Date().timeIntervalSince1970)
        if let r = rate[node], r.sec == sec {
            rate[node] = (sec, r.count + 1)
            return r.count + 1 <= MeshConst.maxPacketsPerSecond
        }
        rate[node] = (sec, 1)
        return true
    }

    private func sendPing(_ s: State) {
        let nonce = randomBytes(8)
        var ms = UInt64(Date().timeIntervalSince1970 * 1000).bigEndian
        var payload = nonce
        withUnsafeBytes(of: &ms) { payload.append(contentsOf: $0) }
        payload.append(Data(count: s.link.medium == "ble" ? 2048 : 16384))
        let frame = Packet(type: PacketType.ping, ttl: 1, payload: payload).frame()
        s.pings[nonce] = (Date(), frame.count)
        s.lastPing = Date()
        _ = s.link.write(frame)
    }

    private func tick() {
        tickCount += 1
        transports.forEach { $0.tick() }
        for s in states.values {
            if Date().timeIntervalSince(s.lastRx) > 30 { s.strikes += 1 } else { s.strikes = 0 }
        }
        let dead = states.values.filter { $0.strikes >= 2 }
        for s in dead {
            states.removeValue(forKey: ObjectIdentifier(s.link))
            s.link.close(block: false)
            nodeLost(s)
        }
        let cutoff = Date().addingTimeInterval(-60)
        for s in states.values {
            s.pings = s.pings.filter { $0.value.0 > cutoff }
            let every: TimeInterval = s.link.medium == "ble" ? 15 : 5
            if s.node != nil, Date().timeIntervalSince(s.lastPing) >= every - 0.5 { sendPing(s) }
        }
        if tickCount % 12 == 0 { router.prune() }
    }

    private func deliverToJS(_ p: Packet, _ from: String) {
        let raw = p.encode()
        if appActive, let emit = emit {
            let data: [String: Any] = ["packet": raw.base64EncodedString(), "from": from]
            DispatchQueue.main.async { emit("packet", data) }
            return
        }
        inbox.append(raw, from: from)
        if p.type == PacketType.data && p.dest == router.selfTag && p.payload.first == 0x01 {
            let c = UNMutableNotificationContent()
            c.title = "Ripplo"
            c.body = "New message"
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
