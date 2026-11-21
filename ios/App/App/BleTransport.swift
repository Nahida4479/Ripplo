import Foundation
import CoreBluetooth

enum BleIds {
    static let service = CBUUID(string: "6f2a0001-5c3e-4b7a-9d1e-2b9c6e1a0f01")
    static let rx = CBUUID(string: "6f2a0002-5c3e-4b7a-9d1e-2b9c6e1a0f01")
    static let tx = CBUUID(string: "6f2a0003-5c3e-4b7a-9d1e-2b9c6e1a0f01")
    static let psm = CBUUID(string: "6f2a0004-5c3e-4b7a-9d1e-2b9c6e1a0f01")
}

final class BleConn {
    let peripheral: CBPeripheral
    var rx: CBCharacteristic?
    var tx: CBCharacteristic?
    var psm: CBCharacteristic?
    var gatt: BleCentralLink?
    var l2cap: L2capLink?
    var l2capRequested = false
    init(_ p: CBPeripheral) { peripheral = p }
}

final class BleCentralLink: MeshLink {
    let conn: BleConn
    unowned let transport: BleTransport
    private var pending = [Data]()
    private var writing = false

    init(conn: BleConn, transport: BleTransport) {
        self.conn = conn
        self.transport = transport
        super.init(medium: "ble", initiated: true)
    }

    override func write(_ frame: Data) -> Bool {
        if closed { return false }
        addQueued(frame.count)
        transport.q.async { self.enqueue(frame) }
        return true
    }

    override func close(block: Bool) {
        closed = true
        transport.q.async { self.transport.closeCentral(self, block: block) }
    }

    private func enqueue(_ frame: Data) {
        let mtu = max(20, conn.peripheral.maximumWriteValueLength(for: .withResponse))
        var i = 0
        while i < frame.count {
            let e = min(i + mtu, frame.count)
            pending.append(frame.subdata(in: i..<e))
            i = e
        }
        pump()
    }

    private func pump() {
        guard !writing, !closed, let chunk = pending.first, let rx = conn.rx else { return }
        writing = true
        conn.peripheral.writeValue(chunk, for: rx, type: .withResponse)
    }

    func wrote(error: Error?) {
        guard writing else { return }
        writing = false
        if error != nil {
            closed = true
            ended()
            return
        }
        if !pending.isEmpty {
            let c = pending.removeFirst()
            addQueued(-c.count)
        }
        pump()
    }
}

final class BlePeripheralLink: MeshLink {
    let central: CBCentral
    unowned let transport: BleTransport
    private var pending = [Data]()

    init(central: CBCentral, transport: BleTransport) {
        self.central = central
        self.transport = transport
        super.init(medium: "ble", initiated: false)
    }

    override func write(_ frame: Data) -> Bool {
        if closed { return false }
        addQueued(frame.count)
        transport.q.async { self.enqueue(frame) }
        return true
    }

    private func enqueue(_ frame: Data) {
        let mtu = max(20, central.maximumUpdateValueLength)
        var i = 0
        while i < frame.count {
            let e = min(i + mtu, frame.count)
            pending.append(frame.subdata(in: i..<e))
            i = e
        }
        pump()
    }

    func pump() {
        guard !closed, let tx = transport.txChar, let pm = transport.periph else { return }
        while let c = pending.first {
            if pm.updateValue(c, for: tx, onSubscribedCentrals: [central]) {
                pending.removeFirst()
                addQueued(-c.count)
            } else {
                break
            }
        }
    }
}

final class L2capLink: MeshLink, StreamDelegate {
    private let channel: CBL2CAPChannel
    private let onClosed: (() -> Void)?
    private var out = [Data]()
    private var offset = 0
    private var finished = false

    init(channel: CBL2CAPChannel, initiated: Bool, onClosed: (() -> Void)?) {
        self.channel = channel
        self.onClosed = onClosed
        super.init(medium: "l2cap", initiated: initiated)
        IOThread.shared.async { self.open() }
    }

    private func open() {
        guard let i = channel.inputStream, let o = channel.outputStream else {
            finish()
            return
        }
        let streams: [Stream] = [i, o]
        for s in streams {
            s.delegate = self
            s.schedule(in: RunLoop.current, forMode: .default)
            s.open()
        }
    }

    override func write(_ frame: Data) -> Bool {
        if closed { return false }
        addQueued(frame.count)
        IOThread.shared.async {
            self.out.append(frame)
            self.pump()
        }
        return true
    }

    override func close(block: Bool) {
        closed = true
        IOThread.shared.async { self.finish() }
    }

    private func pump() {
        guard !finished, let o = channel.outputStream else { return }
        while let d = out.first, o.hasSpaceAvailable {
            let start = offset
            let n = d.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Int in
                guard let base = p.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return o.write(base.advanced(by: start), maxLength: d.count - start)
            }
            if n <= 0 {
                if n < 0 { finish() }
                return
            }
            offset += n
            addQueued(-n)
            if offset >= d.count {
                out.removeFirst()
                offset = 0
            }
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let i = channel.inputStream else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while i.hasBytesAvailable {
                let n = i.read(&buf, maxLength: buf.count)
                if n > 0 {
                    received(Data(buf[0..<n]))
                } else {
                    if n < 0 { finish() }
                    break
                }
            }
        case .hasSpaceAvailable:
            pump()
        case .endEncountered, .errorOccurred:
            finish()
        default:
            break
        }
    }

    private func finish() {
        if finished { return }
        finished = true
        closed = true
        let streams: [Stream?] = [channel.inputStream, channel.outputStream]
        for s in streams {
            s?.delegate = nil
            s?.remove(from: RunLoop.current, forMode: .default)
            s?.close()
        }
        ended()
        onClosed?()
    }
}

final class BleTransport: NSObject, MeshTransport, CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate {
    let q = DispatchQueue(label: "ripplo.ble")
    var periph: CBPeripheralManager?
    var txChar: CBMutableCharacteristic?
    private var central: CBCentralManager?
    private var wanted = false
    private var conns = [UUID: BleConn]()
    private var blocked = [UUID: Date]()
    private var plinks = [UUID: BlePeripheralLink]()
    private var psm: CBL2CAPPSM?
    private var starting = false
    private var serviceAdded = false
    private var scanTick = 0

    func start(nodeTag: String) {
        q.async {
            self.wanted = true
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.q,
                                                options: [CBCentralManagerOptionRestoreIdentifierKey: "app.ripplo.central"])
                self.periph = CBPeripheralManager(delegate: self, queue: self.q,
                                                  options: [CBPeripheralManagerOptionRestoreIdentifierKey: "app.ripplo.peripheral"])
            } else {
                self.startCentral()
                self.startPeripheral()
            }
        }
    }

    func stop() {
        q.async {
            self.wanted = false
            self.central?.stopScan()
            for c in self.conns.values { self.central?.cancelPeripheralConnection(c.peripheral) }
            self.conns.removeAll()
            self.plinks.removeAll()
            self.periph?.stopAdvertising()
            self.periph?.removeAllServices()
            if let p = self.psm { self.periph?.unpublishL2CAPChannel(p) }
            self.psm = nil
            self.serviceAdded = false
            self.starting = false
        }
    }

    func tick() {
        q.async {
            self.scanTick += 1
            let now = Date()
            self.blocked = self.blocked.filter { $0.value > now }
            if self.wanted, self.scanTick % 2 == 0, self.central?.state == .poweredOn {
                self.central?.stopScan()
                self.startCentral()
            }
        }
    }

    func closeCentral(_ link: BleCentralLink, block: Bool) {
        let conn = link.conn
        if block { blocked[conn.peripheral.identifier] = Date().addingTimeInterval(120) }
        if let tx = conn.tx { conn.peripheral.setNotifyValue(false, for: tx) }
        maybeCancel(conn)
    }

    private func maybeCancel(_ conn: BleConn) {
        let gattDead = conn.gatt?.closed ?? true
        let l2capDead = conn.l2cap?.closed ?? true
        if gattDead && l2capDead { central?.cancelPeripheralConnection(conn.peripheral) }
    }

    private func startCentral() {
        guard wanted, let c = central, c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [BleIds.service], options: nil)
        for conn in conns.values where conn.rx == nil {
            if conn.peripheral.state == .connected {
                conn.peripheral.discoverServices([BleIds.service])
            } else if conn.peripheral.state == .disconnected {
                c.connect(conn.peripheral, options: nil)
            }
        }
    }

    private func startPeripheral() {
        guard wanted, let p = periph, p.state == .poweredOn, !starting, !serviceAdded else { return }
        starting = true
        p.removeAllServices()
        if psm == nil {
            p.publishL2CAPChannel(withEncryption: false)
        } else {
            addService()
        }
    }

    private func addService() {
        guard let p = periph else { return }
        let rx = CBMutableCharacteristic(type: BleIds.rx, properties: .write, value: nil, permissions: .writeable)
        let tx = CBMutableCharacteristic(type: BleIds.tx, properties: .notify, value: nil, permissions: .readable)
        let ps = CBMutableCharacteristic(type: BleIds.psm, properties: .read, value: nil, permissions: .readable)
        txChar = tx
        let svc = CBMutableService(type: BleIds.service, primary: true)
        svc.characteristics = [rx, tx, ps]
        p.add(svc)
    }

    private func reconnect(_ p: CBPeripheral, after delay: TimeInterval) {
        q.asyncAfter(deadline: .now() + delay) {
            guard self.wanted, self.conns[p.identifier] == nil, self.conns.count < 8,
                  (self.blocked[p.identifier] ?? .distantPast) < Date(), let c = self.central, c.state == .poweredOn else { return }
            self.conns[p.identifier] = BleConn(p)
            c.connect(p, options: nil)
        }
    }

    private func finishConn(_ p: CBPeripheral) {
        guard let conn = conns.removeValue(forKey: p.identifier) else { return }
        conn.gatt?.ended()
        conn.l2cap?.close(block: false)
        reconnect(p, after: 3)
    }

    private func plink(for c: CBCentral) -> BlePeripheralLink? {
        if let l = plinks[c.identifier] { return l.closed ? nil : l }
        let l = BlePeripheralLink(central: c, transport: self)
        plinks[c.identifier] = l
        MeshEngine.shared.linkUp(l)
        return l
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startCentral() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for p in ps {
            p.delegate = self
            conns[p.identifier] = BleConn(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wanted, conns[peripheral.identifier] == nil, conns.count < 8,
              (blocked[peripheral.identifier] ?? .distantPast) < Date() else { return }
        conns[peripheral.identifier] = BleConn(peripheral)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([BleIds.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        conns.removeValue(forKey: peripheral.identifier)
        reconnect(peripheral, after: 5)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finishConn(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let svc = peripheral.services?.first(where: { $0.uuid == BleIds.service }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([BleIds.rx, BleIds.tx, BleIds.psm], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let conn = conns[peripheral.identifier] else { return }
        for ch in service.characteristics ?? [] {
            if ch.uuid == BleIds.rx { conn.rx = ch }
            if ch.uuid == BleIds.tx { conn.tx = ch }
            if ch.uuid == BleIds.psm { conn.psm = ch }
        }
        guard conn.rx != nil, let tx = conn.tx else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: tx)
        if let ps = conn.psm { peripheral.readValue(for: ps) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let conn = conns[peripheral.identifier], characteristic.uuid == BleIds.tx,
              error == nil, characteristic.isNotifying, conn.gatt == nil else { return }
        let l = BleCentralLink(conn: conn, transport: self)
        conn.gatt = l
        MeshEngine.shared.linkUp(l)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let conn = conns[peripheral.identifier], let v = characteristic.value else { return }
        if characteristic.uuid == BleIds.tx {
            conn.gatt?.received(v)
        } else if characteristic.uuid == BleIds.psm, v.count == 2, !conn.l2capRequested {
            let port = CBL2CAPPSM(v[v.startIndex]) << 8 | CBL2CAPPSM(v[v.startIndex + 1])
            if port != 0 {
                conn.l2capRequested = true
                peripheral.openL2CAPChannel(port)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        conns[peripheral.identifier]?.gatt?.wrote(error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let ch = channel, error == nil, let conn = conns[peripheral.identifier] else { return }
        let l = L2capLink(channel: ch, initiated: true, onClosed: { [weak self] in
            self?.q.async { self?.maybeCancel(conn) }
        })
        conn.l2cap = l
        MeshEngine.shared.linkUp(l)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            startPeripheral()
        } else {
            starting = false
            serviceAdded = false
            psm = nil
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if error == nil { psm = PSM }
        addService()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didUnpublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        starting = false
        guard error == nil else { return }
        serviceAdded = true
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [BleIds.service]])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let ch = channel, error == nil else { return }
        MeshEngine.shared.linkUp(L2capLink(channel: ch, initiated: false, onClosed: nil))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == BleIds.tx { _ = plink(for: central) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == BleIds.tx, let l = plinks.removeValue(forKey: central.identifier) { l.ended() }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        plinks.values.forEach { $0.pump() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == BleIds.psm, let port = psm else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        let v = Data([UInt8(port >> 8), UInt8(port & 0xff)])
        guard request.offset <= v.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = v.subdata(in: request.offset..<v.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == BleIds.rx {
            if let v = r.value { plink(for: r.central)?.received(v) }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }
}
