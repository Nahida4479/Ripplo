import Foundation

final class Router {
    static let SELF = "self"

    struct Reverse {
        var prev: String
        var dest: Data
        var pending: Int
        var done: Bool
        var ts: TimeInterval
    }

    var selfTag = Data(count: 16)
    var neighbors: () -> [String] = { [] }
    var send: (String, Packet) -> Bool = { _, _ in false }
    var deliver: (Packet, String) -> Void = { _, _ in }

    private var seen = [Data: TimeInterval]()
    private var reverse = [Data: Reverse]()
    private var routes = [Data: (node: String, ts: TimeInterval)]()

    private func now() -> TimeInterval { Date().timeIntervalSince1970 }
    private func key(_ p: Packet) -> Data { Data([p.type]) + p.id }
    private func make(_ type: UInt8, dest: Data, id: Data = randomBytes(16)) -> Packet {
        Packet(type: type, ttl: MeshConst.ttlDefault, hops: 0, id: id, dest: dest, payload: Data())
    }

    func onPacket(_ p: Packet, from: String) {
        let t = now()
        switch p.type {
        case PacketType.app:
            deliver(p, from)

        case PacketType.data, PacketType.discover:
            if seen[key(p)] != nil {
                if from != Router.SELF { _ = send(from, make(PacketType.deadEnd, dest: p.id)) }
                return
            }
            seen[key(p)] = t
            reverse[p.id] = Reverse(prev: from, dest: p.dest, pending: 0, done: false, ts: t)
            if p.type == PacketType.data && p.dest == selfTag {
                deliver(p, from)
                if from != Router.SELF { _ = send(from, make(PacketType.ack, dest: p.id)) }
                return
            }
            if p.type == PacketType.discover && from != Router.SELF { deliver(p, from) }
            var q = p
            if from != Router.SELF { q.hops = UInt8(min(Int(p.hops) + 1, 255)) }
            let targets: [String]
            if p.type == PacketType.data, let r = routes[p.dest], t - r.ts < MeshConst.entryLifetime,
               r.node != from, neighbors().contains(r.node) {
                targets = [r.node]
            } else {
                targets = neighbors().filter { $0 != from }
            }
            var sent = 0
            for n in targets where send(n, q) { sent += 1 }
            if sent == 0 { deadEnd(p.id) } else { reverse[p.id]?.pending = sent }

        case PacketType.ack, PacketType.reply:
            if seen[key(p)] != nil { return }
            seen[key(p)] = t
            guard var r = reverse[p.dest] else { return }
            if p.type == PacketType.ack {
                if from != Router.SELF { routes[r.dest] = (from, t) }
                r.done = true
                reverse[p.dest] = r
            }
            var q = p
            q.hops = UInt8(min(Int(p.hops) + 1, 255))
            if r.prev == Router.SELF {
                deliver(q, Router.SELF)
            } else {
                _ = send(r.prev, q)
            }

        case PacketType.deadEnd:
            if seen[key(p)] != nil { return }
            seen[key(p)] = t
            guard var r = reverse[p.dest], !r.done else { return }
            r.pending -= 1
            reverse[p.dest] = r
            if r.pending <= 0 { deadEnd(p.dest) }

        default:
            break
        }
    }

    private func deadEnd(_ id: Data) {
        guard var r = reverse[id] else { return }
        r.done = true
        reverse[id] = r
        if r.prev == Router.SELF {
            deliver(make(PacketType.deadEnd, dest: id), Router.SELF)
        } else {
            _ = send(r.prev, make(PacketType.deadEnd, dest: id))
        }
    }

    func dropRoutes(to node: String) {
        routes = routes.filter { $0.value.node != node }
    }

    func prune() {
        let cutoff = now() - MeshConst.entryLifetime
        seen = seen.filter { $0.value > cutoff }
        reverse = reverse.filter { $0.value.ts > cutoff }
        routes = routes.filter { $0.value.ts > cutoff }
        if seen.count > MeshConst.seenCap {
            let keep = seen.sorted { $0.value > $1.value }.prefix(MeshConst.seenCap)
            seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}
