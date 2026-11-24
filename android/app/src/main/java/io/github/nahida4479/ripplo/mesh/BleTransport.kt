package io.github.nahida4479.ripplo.mesh

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.io.IOException
import java.util.Collections
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.function.Consumer
import kotlin.math.max
import kotlin.math.min

internal class BleTransport(ctx: Context, engine: MeshEngine) : Transport(ctx, engine) {
    companion object {
        val SERVICE: UUID = UUID.fromString("6f2a0001-5c3e-4b7a-9d1e-2b9c6e1a0f01")
        val RX: UUID = UUID.fromString("6f2a0002-5c3e-4b7a-9d1e-2b9c6e1a0f01")
        val TX: UUID = UUID.fromString("6f2a0003-5c3e-4b7a-9d1e-2b9c6e1a0f01")
        val PSM: UUID = UUID.fromString("6f2a0004-5c3e-4b7a-9d1e-2b9c6e1a0f01")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val MAX_CLIENTS = 5

        private fun mask(coded: Boolean): Int =
            if (Build.VERSION.SDK_INT >= 26) (if (coded) BluetoothDevice.PHY_LE_CODED_MASK else BluetoothDevice.PHY_LE_1M_MASK) else 0

        private fun phyNote(rxPhy: Int): String =
            "phy " + when (rxPhy) {
                BluetoothDevice.PHY_LE_CODED -> "coded"
                BluetoothDevice.PHY_LE_2M -> "2M"
                else -> "1M"
            }
    }

    private var mgr: BluetoothManager? = null
    private var adapter: BluetoothAdapter? = null
    private var server: BluetoothGattServer? = null
    private var txChar: BluetoothGattCharacteristic? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var l2capServer: BluetoothServerSocket? = null
    @Volatile private var psmBytes = byteArrayOf(0, 0)
    private val serverLinks = ConcurrentHashMap<String, ServerLink>()
    private val mtus = ConcurrentHashMap<String, Int>()
    private val attempts = HashMap<String, Long>()
    private val addrNode = ConcurrentHashMap<String, String>()
    private val hits = ConcurrentHashMap<String, Hit>()
    private val phyNotes = ConcurrentHashMap<String, String>()
    private val inboundSock = ConcurrentHashMap<String, StreamLink>()
    private var codedAdvCb: AdvertisingSetCallback? = null
    @Volatile private var lastHitAt = 0L
    @Volatile private var lastScanStart = 0L
    @Volatile private var lastAdvStart = 0L
    @Volatile private var forceNode: String? = null
    @Volatile private var boostCoded = false
    private val active = HashSet<String>()
    private val l2capActive = HashSet<String>()
    private val mine: MutableSet<Link> = Collections.synchronizedSet(HashSet<Link>())
    private val main = Handler(Looper.getMainLooper())

    private class Hit(val device: BluetoothDevice, val phy: Int, val at: Long) {
        val isCoded: Boolean get() = Build.VERSION.SDK_INT >= 26 && phy == BluetoothDevice.PHY_LE_CODED
    }

    private fun codedOn(): Boolean {
        val a = adapter
        return Build.VERSION.SDK_INT >= 26 && a != null && a.isLeCodedPhySupported && a.isLeExtendedAdvertisingSupported
    }

    override fun name(): String = "ble"

    override fun startImpl() {
        if (!ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) throw UnsupportedOperationException("no ble")
        if (Build.VERSION.SDK_INT >= 31) {
            if (!has(Manifest.permission.BLUETOOTH_SCAN) || !has(Manifest.permission.BLUETOOTH_ADVERTISE) ||
                !has(Manifest.permission.BLUETOOTH_CONNECT)
            ) throw SecurityException("ble permissions")
        } else if (!has(Manifest.permission.ACCESS_FINE_LOCATION)) {
            throw SecurityException("location")
        }
        val m = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
        mgr = m
        val a = m?.adapter
        adapter = a
        if (a == null || !a.isEnabled) throw IllegalStateException("bluetooth off")
        if (Build.VERSION.SDK_INT >= 29) {
            try { startL2capServer() } catch (ignored: Exception) { }
        }
        openServer()
        startScan()
    }

    override fun stopImpl() {
        try { scanner?.stopScan(scanCb) } catch (ignored: Exception) { }
        try { scanner?.stopScan(codedScanCb) } catch (ignored: Exception) { }
        try { advertiser?.stopAdvertising(advCb) } catch (ignored: Exception) { }
        stopCodedAdvertise()
        hits.clear()
        scanner = null
        advertiser = null
        val all = synchronized(mine) { mine.toTypedArray() }
        for (l in all) l.close()
        try { server?.close() } catch (ignored: Exception) { }
        server = null
        try { l2capServer?.close() } catch (ignored: Exception) { }
        l2capServer = null
        synchronized(active) {
            active.clear()
            l2capActive.clear()
        }
        psmBytes = byteArrayOf(0, 0)
    }

    private fun stopCodedAdvertise() {
        try {
            val adv = advertiser
            val cb = codedAdvCb
            if (adv != null && cb != null) adv.stopAdvertisingSet(cb)
        } catch (ignored: Exception) { }
        codedAdvCb = null
    }

    override fun forceConnect(node: String, option: String): Boolean {
        val coded = "coded" == option
        val phy = if (coded) "coded" else "1m"
        if (adapter == null || !running) {
            Diag.stage("ble", node, "rejected", "BLE transport not running")
            return false
        }
        Diag.stage("ble", node, "attempt", phy)
        forceNode = node
        var started = 0
        if (!hasHit(coded)) {
            val asked = engine.askPeerAdvertise(node)
            Diag.stage("ble", node, "scanning", (if (asked) "asked the other phone to advertise, " else "") + "restarting scan, waiting for a $phy hit")
            boostCoded = coded
            restartScan()
            val end = System.currentTimeMillis() + 15000
            while (!hasHit(coded) && System.currentTimeMillis() < end && running) {
                try { Thread.sleep(500) } catch (e: InterruptedException) { break }
            }
            if (coded) {
                main.postDelayed({
                    boostCoded = false
                    restartScan()
                }, 3000)
            }
        }
        if (hasHit(coded)) {
            if (freeHit(coded)) {
                engine.closeLinks(node, "ble")
                started = connectHits(coded)
            } else {
                Diag.stage("ble", node, "rejected", "a $phy connection attempt is already running, the existing link was kept; try again in 20 s")
                return false
            }
        }
        Diag.i("ble force $phy started=$started")
        if (started == 0) Diag.stage("ble", node, "rejected", "no $phy advertising seen from the other phone (is it on the new version, Bluetooth on, in range?)")
        return started > 0
    }

    private fun dialInProgress(): Boolean = synchronized(mine) {
        mine.any { it is ClientLink && !it.registered && it.alive.get() }
    }

    private fun freeHit(coded: Boolean): Boolean {
        val now = System.currentTimeMillis()
        for (h in hits.values) {
            if (now - h.at > 20000 || h.isCoded != coded) continue
            synchronized(active) { if (!active.contains(h.device.address)) return true }
        }
        return false
    }

    private fun hasHit(coded: Boolean): Boolean {
        val now = System.currentTimeMillis()
        return hits.values.any { now - it.at <= 20000 && it.isCoded == coded }
    }

    override fun onPeerRequest(kind: Int) {
        if (kind == 1) {
            Diag.i("peer asked us to advertise")
            main.postDelayed({ restartAdvertising() }, 2500)
        }
    }

    private fun connectHits(coded: Boolean): Int {
        val now = System.currentTimeMillis()
        var started = 0
        val want = forceNode
        val mapped = want != null && hits.values.any { want == addrNode[it.device.address] }
        for (h in ArrayList(hits.values)) {
            if (now - h.at > 60000 || h.isCoded != coded) continue
            val a = h.device.address
            if (mapped && want != addrNode[a]) continue
            val added = synchronized(active) { active.add(a) }
            if (!added) continue
            ClientLink(h.device, mask(coded)).connect()
            started++
        }
        return started
    }

    override fun tickImpl() {
        val a = adapter
        if (a == null || !a.isEnabled) return
        val now = System.currentTimeMillis()
        if (server != null && serverLinks.isEmpty() && engine.neighbors().isEmpty() && now - lastAdvStart > 120000) restartAdvertising()
        if (now - lastScanStart > 300000 || (now - lastHit() > 90000 && now - lastScanStart > 30000)) restartScan()
    }

    private fun lastHit(): Long = if (lastHitAt == 0L) lastScanStart else lastHitAt

    private fun restartAdvertising() {
        if (!running || server == null) return
        try { advertiser?.stopAdvertising(advCb) } catch (ignored: Exception) { }
        stopCodedAdvertise()
        try { startAdvertise() } catch (e: Exception) { Diag.w("ble re-advertise failed $e") }
    }

    private fun restartScan() {
        if (!running || adapter == null) return
        try { scanner?.stopScan(scanCb) } catch (ignored: Exception) { }
        try { scanner?.stopScan(codedScanCb) } catch (ignored: Exception) { }
        try { startScan() } catch (e: Exception) { Diag.w("ble re-scan failed $e") }
    }

    private fun startL2capServer() {
        val ss = adapter!!.listenUsingInsecureL2capChannel()
        l2capServer = ss
        val psm = ss.psm
        psmBytes = byteArrayOf((psm shr 8).toByte(), psm.toByte())
        Thread({
            try {
                while (running || l2capServer === ss) {
                    val s = ss.accept()
                    openSocket(s, false)
                }
            } catch (ignored: IOException) {
            }
        }, "ripplo-l2cap-accept").apply {
            isDaemon = true
            start()
        }
    }

    private fun openSocket(s: BluetoothSocket, outbound: Boolean): StreamLink {
        val l = StreamLink(engine, "l2cap", outbound, s.inputStream, s.outputStream, s)
        val mtu = if (Build.VERSION.SDK_INT >= 23) s.maxTransmitPacketSize else 0
        l.chunk = if (mtu > 0) mtu else 672
        val raddr = s.remoteDevice.address
        if (outbound) {
            l.helloHook = Consumer<String> { tag -> addrNode[raddr] = tag }
        } else {
            inboundSock[raddr] = l
            val pn = phyNotes[raddr]
            if (pn != null) l.note = pn
        }
        l.open()
        return l
    }

    private fun connectL2cap(dev: BluetoothDevice, psm: Int, note: String?) {
        val addr = dev.address
        synchronized(active) { if (!l2capActive.add(addr)) return }
        Thread({
            try {
                val s = dev.createInsecureL2capChannel(psm)
                s.connect()
                val sl = openSocket(s, true)
                if (!note.isNullOrEmpty()) sl.note = note
            } catch (e: Exception) {
                Diag.i("l2cap connect failed $addr $e")
            }
            synchronized(active) { l2capActive.remove(addr) }
        }, "ripplo-l2cap-connect").apply {
            isDaemon = true
            start()
        }
    }

    private fun openServer() {
        val srv = mgr!!.openGattServer(ctx, serverCb)
        server = srv
        if (srv == null) throw IllegalStateException("no gatt server")
        val svc = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val rx = BluetoothGattCharacteristic(RX, BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE)
        val tx = BluetoothGattCharacteristic(TX, BluetoothGattCharacteristic.PROPERTY_NOTIFY, 0)
        txChar = tx
        tx.addDescriptor(BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
        val psm = BluetoothGattCharacteristic(PSM, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ)
        svc.addCharacteristic(rx)
        svc.addCharacteristic(tx)
        svc.addCharacteristic(psm)
        srv.addService(svc)
    }

    private fun startAdvertise() {
        lastAdvStart = System.currentTimeMillis()
        val adv = adapter!!.bluetoothLeAdvertiser
        advertiser = adv
        if (adv == null) return
        val s = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val d = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE))
            .build()
        adv.startAdvertising(s, d, advCb)
        if (codedOn()) startCodedAdvertise(adv, d)
    }

    private fun startCodedAdvertise(adv: BluetoothLeAdvertiser, d: AdvertiseData) {
        try {
            val p = AdvertisingSetParameters.Builder()
                .setLegacyMode(false)
                .setConnectable(true)
                .setScannable(false)
                .setPrimaryPhy(BluetoothDevice.PHY_LE_CODED)
                .setSecondaryPhy(BluetoothDevice.PHY_LE_CODED)
                .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
                .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
                .build()
            val cb = object : AdvertisingSetCallback() {
                override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
                    Diag.i("ble coded advertising status=$status")
                    if (status == AdvertisingSetCallback.ADVERTISE_SUCCESS) Diag.stage("ble", "", "started", "advertising coded")
                    else Diag.stage("ble", "", "failed", "coded advertise status=$status")
                }
            }
            codedAdvCb = cb
            adv.startAdvertisingSet(p, d, null, null, null, cb)
        } catch (e: Exception) {
            Diag.w("ble coded advertise failed $e")
            Diag.stage("ble", "", "failed", "coded advertise: " + e.javaClass.simpleName)
        }
    }

    private fun startScan() {
        lastScanStart = System.currentTimeMillis()
        val sc = adapter!!.bluetoothLeScanner
        scanner = sc
        if (sc == null) return
        val f = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
        if (!codedOn()) {
            sc.startScan(listOf(f), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(), scanCb)
        } else {
            val boost = boostCoded
            if (!boost) {
                sc.startScan(listOf(f), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).setLegacy(false).setPhy(BluetoothDevice.PHY_LE_1M).build(), scanCb)
            }
            sc.startScan(
                listOf(f),
                ScanSettings.Builder()
                    .setScanMode(if (boost) ScanSettings.SCAN_MODE_LOW_LATENCY else ScanSettings.SCAN_MODE_BALANCED)
                    .setLegacy(false).setPhy(BluetoothDevice.PHY_LE_CODED).build(),
                codedScanCb
            )
        }
        Diag.stage("ble", "", "started", if (codedOn()) "scanning 1M + coded" else "scanning 1M")
    }

    private val advCb = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Diag.i("ble advertising")
            Diag.stage("ble", "", "started", "advertising 1M")
        }

        override fun onStartFailure(errorCode: Int) {
            Diag.w("ble advertise failed $errorCode")
            Diag.stage("ble", "", "failed", "advertise errorCode=$errorCode")
        }
    }

    private val scanCb = ScanCb()
    private val codedScanCb = ScanCb()

    private inner class ScanCb : ScanCallback() {
        override fun onScanFailed(errorCode: Int) {
            Diag.w("ble scan failed $errorCode")
            Diag.stage("ble", "", "failed", "scan errorCode=$errorCode")
        }

        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            val d = result!!.device
            val a = d.address
            val phy = if (Build.VERSION.SDK_INT >= 26) result.primaryPhy else BluetoothDevice.PHY_LE_1M
            val coded = Build.VERSION.SDK_INT >= 26 && phy == BluetoothDevice.PHY_LE_CODED
            Diag.i("ble scan hit " + a + (if (coded) " coded" else ""))
            val now = System.currentTimeMillis()
            lastHitAt = now
            hits[a + (if (coded) "/c" else "/1")] = Hit(d, phy, now)
            if (coded) {
                val oneM = hits[a + "/1"]
                if (oneM != null && now - oneM.at < 20000) return
            }
            val known = addrNode[a]
            if (known != null && (engine.hasLink(known, "ble") || engine.hasLink(known, "l2cap"))) return
            if (coded && known != null && engine.hasFastLink(known)) return
            if (dialInProgress()) return
            synchronized(active) {
                if (active.contains(a) || active.size >= MAX_CLIENTS) return
                val last = attempts[a]
                if (last != null && now - last < 15000) return
                attempts[a] = now
                if (attempts.size > 200) attempts.clear()
                active.add(a)
            }
            ClientLink(d, mask(coded)).connect()
        }
    }

    private val serverCb = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            if (status == BluetoothGatt.GATT_SUCCESS) startAdvertise()
        }

        override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val a = device!!.address
                mtus.remove(a)
                serverLinks.remove(a)?.close()
                main.postDelayed({
                    if (mine.isEmpty() && System.currentTimeMillis() - lastAdvStart > 20000) restartAdvertising()
                }, 1500)
            }
        }

        override fun onPhyRead(device: BluetoothDevice?, txPhy: Int, rxPhy: Int, status: Int) {
            val a = device!!.address
            val n = phyNote(rxPhy)
            phyNotes[a] = n
            serverLinks[a]?.note = n
            val l2 = inboundSock[a]
            if (l2 != null && l2.alive.get()) l2.note = n
            Diag.i("ble server $n $a")
        }

        override fun onMtuChanged(device: BluetoothDevice?, mtu: Int) {
            Diag.i("ble server mtu $mtu")
            mtus[device!!.address] = mtu
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice?, requestId: Int, descriptor: BluetoothGattDescriptor?,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            if (CCCD != descriptor!!.uuid || value == null || value.isEmpty()) return
            val a = device!!.address
            if (value[0].toInt() != 0) {
                Diag.i("ble server link up $a")
                if (serverLinks.containsKey(a)) return
                val l = ServerLink(device)
                serverLinks[a] = l
                mine.add(l)
                engine.addLink(l)
                if (Build.VERSION.SDK_INT >= 26) {
                    try { server?.readPhy(device) } catch (ignored: Exception) { }
                }
            } else {
                serverLinks.remove(a)?.close()
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?, requestId: Int, characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            val l = serverLinks[device!!.address]
            if (l == null || value == null || RX != characteristic!!.uuid) return
            val v = value.clone()
            engine.rx.execute { l.onBytes(v, 0, v.size) }
        }

        override fun onCharacteristicReadRequest(device: BluetoothDevice?, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic?) {
            val srv = server ?: return
            if (PSM != characteristic!!.uuid) {
                srv.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                return
            }
            val v = psmBytes
            if (offset > v.size) {
                srv.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                return
            }
            srv.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, v.copyOfRange(offset, v.size))
        }

        override fun onNotificationSent(device: BluetoothDevice?, status: Int) {
            serverLinks[device!!.address]?.notifyDone?.signal(status == BluetoothGatt.GATT_SUCCESS)
        }
    }

    private inner class ServerLink(val device: BluetoothDevice) : Link(this@BleTransport.engine, "ble", false) {
        val notifyDone = Awaiter()

        override fun writeFrame(frame: ByteArray) {
            val m = mtus[device.address]
            val chunk = max(20, min((m ?: 23) - 3, 512))
            for (o in 0 until frame.size step chunk) {
                val slice = frame.copyOfRange(o, o + min(chunk, frame.size - o))
                notifyDone.reset()
                if (!notify(slice)) throw IOException("notify failed")
                if (!notifyDone.await(8000)) throw IOException("notify timeout")
            }
        }

        @Suppress("DEPRECATION")
        private fun notify(slice: ByteArray): Boolean {
            val s = server ?: return false
            val c = txChar!!
            synchronized(c) {
                if (Build.VERSION.SDK_INT >= 33) {
                    return s.notifyCharacteristicChanged(device, c, false, slice) == BluetoothStatusCodes.SUCCESS
                }
                c.setValue(slice)
                return s.notifyCharacteristicChanged(device, c, false)
            }
        }

        override fun closeImpl() {
            mine.remove(this)
            serverLinks.remove(device.address, this)
            try { server?.cancelConnection(device) } catch (ignored: Exception) { }
        }
    }

    private inner class ClientLink(val device: BluetoothDevice, val phyMask: Int) : Link(this@BleTransport.engine, "ble", true) {
        val writeDone = Awaiter()
        @Volatile var gatt: BluetoothGatt? = null
        @Volatile var mtu = 23
        @Volatile var registered = false
        var rxChar: BluetoothGattCharacteristic? = null
        var psmChar: BluetoothGattCharacteristic? = null

        fun connect() {
            gatt = try {
                if (Build.VERSION.SDK_INT >= 26) device.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE, phyMask)
                else device.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)
            } catch (e: Exception) {
                null
            }
            if (gatt == null) {
                Diag.stage("ble", device.address, "failed", "connectGatt error")
                close()
                return
            }
            Diag.stage("ble", device.address, "connecting", "")
            main.postDelayed({
                if (!registered) {
                    Diag.stage("ble", device.address, "timeout", "no link after 20 s")
                    close()
                }
            }, 20000)
        }

        private fun finish(psm: Int) {
            if (!alive.get()) return
            registered = true
            Diag.i("ble client link up ${device.address} psm=$psm")
            if (!engine.addLink(this)) {
                Diag.stage("ble", device.address, "rejected", "engine did not accept the link")
                close()
                return
            }
            Diag.stage("ble", device.address, "linked", "psm=$psm")
            if (psm > 0 && Build.VERSION.SDK_INT >= 29) connectL2cap(device, psm, note)
        }

        private fun psmRead(v: ByteArray?, status: Int) {
            val psm = if (status == BluetoothGatt.GATT_SUCCESS && v != null && v.size >= 2) {
                ((v[0].toInt() and 0xFF) shl 8) or (v[1].toInt() and 0xFF)
            } else {
                0
            }
            finish(psm)
        }

        private val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt?, status: Int, newState: Int) {
                Diag.i("ble client state ${device.address} status=$status new=$newState")
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    Diag.stage("ble", device.address, "connected", "GATT up, discovering services")
                    if (Build.VERSION.SDK_INT >= 26) g!!.readPhy()
                    if (!g!!.requestMtu(517)) g.discoverServices()
                } else {
                    if (!registered) Diag.stage("ble", device.address, "failed", "GATT status=$status new=$newState")
                    else Diag.stage("ble", device.address, "closed", "status=$status")
                    close()
                }
            }

            override fun onPhyRead(g: BluetoothGatt?, txPhy: Int, rxPhy: Int, status: Int) {
                note = phyNote(rxPhy)
                Diag.i("ble client $note ${device.address}")
            }

            override fun onMtuChanged(g: BluetoothGatt?, m: Int, status: Int) {
                Diag.i("ble client mtu $m status=$status")
                if (status == BluetoothGatt.GATT_SUCCESS) mtu = m
                g!!.discoverServices()
            }

            override fun onServicesDiscovered(g: BluetoothGatt?, status: Int) {
                val svc = if (status == BluetoothGatt.GATT_SUCCESS) g!!.getService(SERVICE) else null
                if (svc == null) {
                    Diag.i("ble no service ${device.address} status=$status")
                    close()
                    return
                }
                rxChar = svc.getCharacteristic(RX)
                val tx = svc.getCharacteristic(TX)
                psmChar = svc.getCharacteristic(PSM)
                val d = tx?.getDescriptor(CCCD)
                if (rxChar == null || tx == null || d == null) {
                    close()
                    return
                }
                g!!.setCharacteristicNotification(tx, true)
                if (!writeDescriptor(g, d)) close()
            }

            override fun onDescriptorWrite(g: BluetoothGatt?, d: BluetoothGattDescriptor?, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    close()
                    return
                }
                val pc = psmChar
                if (pc != null && Build.VERSION.SDK_INT >= 29) {
                    if (!g!!.readCharacteristic(pc)) finish(0)
                } else {
                    finish(0)
                }
            }

            override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
                psmRead(value, status)
            }

            @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
            override fun onCharacteristicRead(g: BluetoothGatt?, c: BluetoothGattCharacteristic?, status: Int) {
                if (Build.VERSION.SDK_INT < 33) psmRead(c!!.value, status)
            }

            override fun onCharacteristicWrite(g: BluetoothGatt?, c: BluetoothGattCharacteristic?, status: Int) {
                writeDone.signal(status == BluetoothGatt.GATT_SUCCESS)
            }

            override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
                feed(value)
            }

            @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
            override fun onCharacteristicChanged(g: BluetoothGatt?, c: BluetoothGattCharacteristic?) {
                if (Build.VERSION.SDK_INT < 33) feed(c!!.value)
            }
        }

        init {
            mine.add(this)
        }

        private fun feed(value: ByteArray?) {
            if (value == null || !registered) return
            val v = value.clone()
            engine.rx.execute { onBytes(v, 0, v.size) }
        }

        @Suppress("DEPRECATION")
        private fun writeDescriptor(g: BluetoothGatt, d: BluetoothGattDescriptor): Boolean {
            if (Build.VERSION.SDK_INT >= 33) {
                return g.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
            }
            d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            return g.writeDescriptor(d)
        }

        @Suppress("DEPRECATION")
        private fun writeChar(v: ByteArray): Boolean {
            val g = gatt ?: return false
            val c = rxChar!!
            if (Build.VERSION.SDK_INT >= 33) {
                return g.writeCharacteristic(c, v, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
            }
            c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            c.setValue(v)
            return g.writeCharacteristic(c)
        }

        override fun writeFrame(frame: ByteArray) {
            val chunk = max(20, min(mtu - 3, 512))
            for (o in 0 until frame.size step chunk) {
                val slice = frame.copyOfRange(o, o + min(chunk, frame.size - o))
                writeDone.reset()
                if (!writeChar(slice)) throw IOException("write failed")
                if (!writeDone.await(8000)) throw IOException("write timeout")
            }
        }

        override fun closeImpl() {
            mine.remove(this)
            val peer = node ?: helloTag
            if (peer != null) addrNode[device.address] = peer
            synchronized(active) { active.remove(device.address) }
            val g = gatt
            if (g != null) {
                try { g.disconnect() } catch (ignored: Exception) { }
                try { g.close() } catch (ignored: Exception) { }
            }
        }
    }
}
