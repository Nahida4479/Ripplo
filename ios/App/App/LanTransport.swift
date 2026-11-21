import Foundation
import Network

final class LanLink: MeshLink {
    let conn: NWConnection
    let key: String?
    let q: DispatchQueue
    private weak var transport: LanTransport?
    private var announced = false

    init(conn: NWConnection, key: String?, q: DispatchQueue, transport: LanTransport) {
        self.conn = conn
        self.key = key
        self.q = q
        self.transport = transport
        super.init(medium: "lan", initiated: key != nil)
    }

    func begin() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if !self.announced {
                    self.announced = true
                    MeshEngine.shared.linkUp(self)
                    self.receiveLoop()
                }
            case .waiting:
                if !self.announced { self.conn.cancel() }
            case .failed, .cancelled:
                self.conn.stateUpdateHandler = nil
                self.transport?.forget(self)
                if self.announced { self.ended() }
            default:
                break
            }
        }
        conn.start(queue: q)
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: MeshConst.maxPacket) { [weak self] data, _, complete, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty { self.received(d) }
            if error != nil || complete {
                self.conn.cancel()
            } else {
                self.receiveLoop()
            }
        }
    }

    override func write(_ frame: Data) -> Bool {
        if closed { return false }
        let n = frame.count
        addQueued(n)
        q.async {
            self.conn.send(content: frame, completion: .contentProcessed { [weak self] error in
                self?.addQueued(-n)
                if error != nil { self?.conn.cancel() }
            })
        }
        return true
    }

    override func close(block: Bool) {
        closed = true
        if block, let k = key { transport?.block(k) }
        q.async { self.conn.cancel() }
    }
}

final class LanTransport: NSObject, MeshTransport {
    static let serviceType = "_ripplo._tcp"
    private let q = DispatchQueue(label: "ripplo.lan")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var ownName = ""
    private var active = [String: LanLink]()
    private var blocked = [String: Date]()
    private var accepted = [ObjectIdentifier: LanLink]()

    private func params() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        return NWParameters(tls: nil, tcp: tcp)
    }

    func start(nodeTag: String) {
        UserDefaults.standard.set(true, forKey: "ripplo.lanTriggered")
        q.async {
            self.teardown()
            self.ownName = nodeTag
            if let l = try? NWListener(using: self.params()) {
                l.service = NWListener.Service(name: nodeTag, type: LanTransport.serviceType)
                l.newConnectionHandler = { [weak self] c in
                    guard let self = self else { return }
                    let link = LanLink(conn: c, key: nil, q: self.q, transport: self)
                    self.accepted[ObjectIdentifier(link)] = link
                    link.begin()
                }
                l.start(queue: self.q)
                self.listener = l
            }
            let b = NWBrowser(for: .bonjour(type: LanTransport.serviceType, domain: nil), using: self.params())
            b.browseResultsChangedHandler = { [weak self] results, _ in
                self?.consider(results)
            }
            b.start(queue: self.q)
            self.browser = b
        }
    }

    func stop() {
        q.async { self.teardown() }
    }

    func tick() {
        q.async {
            let now = Date()
            self.blocked = self.blocked.filter { $0.value > now }
            if let b = self.browser { self.consider(b.browseResults) }
        }
    }

    func block(_ key: String) {
        q.async { self.blocked[key] = Date().addingTimeInterval(120) }
    }

    func forget(_ link: LanLink) {
        q.async {
            if let k = link.key, self.active[k] === link { self.active.removeValue(forKey: k) }
            self.accepted.removeValue(forKey: ObjectIdentifier(link))
        }
    }

    private func teardown() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        let all = Array(active.values) + Array(accepted.values)
        active.removeAll()
        accepted.removeAll()
        all.forEach { $0.conn.cancel() }
    }

    private func consider(_ results: Set<NWBrowser.Result>) {
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, name != ownName, active[name] == nil,
                  (blocked[name] ?? .distantPast) < Date(),
                  !MeshEngine.shared.isLinked(node: name, medium: "lan") else { continue }
            let link = LanLink(conn: NWConnection(to: r.endpoint, using: params()), key: name, q: q, transport: self)
            active[name] = link
            link.begin()
        }
    }
}
