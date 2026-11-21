import Foundation
import Security

enum PacketType {
    static let linkHello: UInt8 = 1
    static let ping: UInt8 = 2
    static let pong: UInt8 = 3
    static let data: UInt8 = 10
    static let ack: UInt8 = 11
    static let deadEnd: UInt8 = 12
    static let discover: UInt8 = 13
    static let reply: UInt8 = 14
    static let app: UInt8 = 20
}

enum MeshConst {
    static let ttlDefault: UInt8 = 8
    static let header = 36
    static let maxPacket = 65536
    static let entryLifetime: TimeInterval = 600
    static let seenCap = 20000
    static let maxPacketsPerSecond = 200
    static let maxQueuedBytes = 32 * 1024 * 1024
}

func randomBytes(_ n: Int) -> Data {
    var b = [UInt8](repeating: 0, count: n)
    if SecRandomCopyBytes(kSecRandomDefault, n, &b) != errSecSuccess {
        for i in 0..<n { b[i] = UInt8.random(in: 0...255) }
    }
    return Data(b)
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex s: String) {
        guard s.count % 2 == 0 else { return nil }
        var d = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let nxt = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<nxt], radix: 16) else { return nil }
            d.append(b)
            idx = nxt
        }
        self = d
    }
}

struct Packet {
    var type: UInt8
    var ttl: UInt8 = MeshConst.ttlDefault
    var hops: UInt8 = 0
    var id: Data = randomBytes(16)
    var dest: Data = Data(count: 16)
    var payload: Data = Data()

    static func decode(_ input: Data) -> Packet? {
        let d = Data(input)
        guard d.count >= MeshConst.header, d.count <= MeshConst.maxPacket, d[0] == 1 else { return nil }
        return Packet(type: d[1], ttl: d[2], hops: d[3],
                      id: d.subdata(in: 4..<20), dest: d.subdata(in: 20..<36),
                      payload: d.subdata(in: 36..<d.count))
    }

    func encode() -> Data {
        var d = Data(capacity: MeshConst.header + payload.count)
        d.append(contentsOf: [1, type, ttl, hops])
        d.append(id)
        d.append(dest)
        d.append(payload)
        return d
    }

    func frame() -> Data {
        let body = encode()
        var d = Data(capacity: body.count + 4)
        var n = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        d.append(body)
        return d
    }
}

struct FrameReader {
    private var buf = [UInt8]()

    mutating func feed(_ data: Data) -> [Data]? {
        buf.append(contentsOf: data)
        var out = [Data]()
        var off = 0
        while buf.count - off >= 4 {
            let len = Int(buf[off]) << 24 | Int(buf[off + 1]) << 16 | Int(buf[off + 2]) << 8 | Int(buf[off + 3])
            if len < MeshConst.header || len > MeshConst.maxPacket { return nil }
            if buf.count - off - 4 < len { break }
            out.append(Data(buf[(off + 4)..<(off + 4 + len)]))
            off += 4 + len
        }
        if off > 0 { buf.removeFirst(off) }
        return out
    }
}
