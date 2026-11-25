package io.github.nahida4479.ripplo.transport.wifidirect

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.WpsInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.transport.StreamLink
import io.github.nahida4479.ripplo.transport.Transport
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

internal class WifiDirectTransport(ctx: Context, engine: MeshEngine) : Transport(ctx, engine) {

    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var server: ServerSocket? = null
    private var lastDiscover = 0L
    private var receiver: BroadcastReceiver? = null
    private var localService: WifiP2pDnsSdServiceInfo? = null
    private var request: WifiP2pDnsSdServiceRequest? = null
    @Volatile
    private var clientConnecting = false
    private val attempts = HashMap<String, Long>()
    private var busyRetries = 0
    private val devices = ConcurrentHashMap<String, WifiP2pDevice>()

    override fun name(): String = "wifi-direct"

    @SuppressLint("MissingPermission")
    override fun startImpl() {
        if (!ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)) throw IllegalStateException("no p2p")
        val perm = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        if (!has(perm)) throw SecurityException("wifi permission")
        val m = ctx.getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager?
        manager = m
        if (m == null) throw IllegalStateException("no p2p")
        val ch: WifiP2pManager.Channel? = m.initialize(ctx, Looper.getMainLooper(), null)
        channel = ch
        if (ch == null) throw IllegalStateException("no channel")

        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                manager!!.requestConnectionInfo(channel!!) { info -> onConnectionInfo(info) }
            }
        }
        receiver = r
        ContextCompat.registerReceiver(ctx, r, IntentFilter(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION), ContextCompat.RECEIVER_NOT_EXPORTED)

        val txt = hashMapOf("nt" to engine.nodeTag())
        localService = WifiP2pDnsSdServiceInfo.newInstance("ripplo-" + engine.nodeTag().substring(0, 8), "_ripplo._tcp", txt)
        m.setDnsSdResponseListeners(ch, { name, type, dev -> log("service response " + name + " " + type + " from " + dev.deviceName) }, { _, record, dev ->
            val tag = record?.get("nt")
            if (tag != null) onPeer(tag, dev) else log("txt record without node tag from " + dev.deviceName)
        })
        request = WifiP2pDnsSdServiceRequest.newInstance()
        m.clearLocalServices(ch, null)
        m.clearServiceRequests(ch, null)
        step { manager?.addLocalService(channel!!, localService, stepListener("add local service")) }
    }

    private fun step(r: Runnable) {
        Handler(Looper.getMainLooper()).postDelayed(r, 400)
    }

    private fun addServiceRequest() {
        manager?.addServiceRequest(channel!!, request, stepListener("add service request"))
    }

    private fun stepListener(what: String) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() {
            Diag.stage("wifi-direct", "", "started", "$what ok")
            when (what) {
                "add local service" -> step { addServiceRequest() }
                "add service request" -> step { discover() }
            }
        }

        override fun onFailure(reason: Int) {
            Diag.stage("wifi-direct", "", "failed", "$what reason=$reason" + reasonText(reason))
            if (what == "add local service") step { addServiceRequest() } else step { discover() }
        }
    }

    @SuppressLint("MissingPermission")
    private fun discover() {
        val m = manager ?: return
        val ch = channel ?: return
        lastDiscover = System.currentTimeMillis()
        m.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                busyRetries = 0
                log("discover ok")
                Diag.stage("wifi-direct", "", "started", "discovery running")
                step {
                    manager?.discoverServices(channel!!, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() = Diag.stage("wifi-direct", "", "started", "service discovery running")
                        override fun onFailure(reason: Int) = Diag.stage("wifi-direct", "", "failed", "service discovery reason=$reason" + reasonText(reason))
                    })
                }
            }

            override fun onFailure(reason: Int) {
                log("discover failed reason=$reason")
                Diag.stage("wifi-direct", "", "failed", "discovery reason=$reason" + reasonText(reason))
                if (reason == WifiP2pManager.BUSY && ++busyRetries <= 5) {
                    try {
                        m.stopPeerDiscovery(channel!!, null)
                    } catch (ignored: Exception) {
                    }
                    Handler(Looper.getMainLooper()).postDelayed({ discover() }, 3000L * busyRetries)
                }
            }
        })
    }

    private fun onPeer(tag: String, dev: WifiP2pDevice) {
        if (tag != engine.nodeTag()) {
            devices[tag] = dev
            engine.noteSeen(tag, "wifi-direct")
        }
        log("peer " + tag.take(8) + " " + dev.deviceName + " initiator=" + (engine.nodeTag() < tag))
        if (engine.forcing() || engine.nodeTag() >= tag || engine.hasLink(tag, "wifi-direct")) return
        if (engine.hasFastLink(tag)) return
        val now = System.currentTimeMillis()
        synchronized(attempts) {
            val last = attempts[tag]
            if (last != null && now - last < 60000) return
            attempts[tag] = now
        }
        requestConnect(tag, dev)
    }

    @SuppressLint("MissingPermission")
    override fun forceConnect(node: String, option: String): Boolean {
        if (manager == null || channel == null) {
            Diag.stage("wifi-direct", node, "rejected", "Wi-Fi Direct is not running (Wi-Fi off or no permission)")
            return false
        }
        var dev = devices[node]
        if (dev == null) {
            Diag.stage("wifi-direct", node, "scanning", "peer not discovered yet, restarting discovery (up to 15 s)")
            discover()
            val end = System.currentTimeMillis() + 15000
            var lastSvc = 0L
            while (dev == null && System.currentTimeMillis() < end && running && engine.forcing()) {
                try {
                    Thread.sleep(500)
                } catch (e: InterruptedException) {
                    break
                }
                val now = System.currentTimeMillis()
                if (now - lastSvc > 4000) {
                    lastSvc = now
                    try {
                        manager?.discoverServices(channel!!, null)
                    } catch (ignored: Exception) {
                    }
                }
                dev = devices[node]
            }
            if (dev == null) {
                logPeers()
                try {
                    Thread.sleep(700)
                } catch (ignored: InterruptedException) {
                }
                Diag.stage("wifi-direct", node, "rejected", "peer not found over Wi-Fi Direct service discovery (other phone needs Wi-Fi on, Ripplo running and its own Wi-Fi Direct discovery active)")
                return false
            }
        }
        Diag.stage("wifi-direct", node, "attempt", dev.deviceName ?: "")
        engine.forceDialing()
        requestConnect(node, dev)
        return true
    }

    @SuppressLint("MissingPermission")
    private fun logPeers() {
        try {
            manager!!.requestPeers(channel!!) { list ->
                Diag.stage("wifi-direct", "", "started", "p2p peers in range: " + (if (list == null) "0" else list.deviceList.size.toString() + " " + list.deviceList.joinToString { it.deviceName + " status=" + it.status }))
            }
        } catch (ignored: Exception) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun requestConnect(tag: String, dev: WifiP2pDevice) {
        val cfg = WifiP2pConfig()
        cfg.deviceAddress = dev.deviceAddress
        cfg.wps.setup = WpsInfo.PBC
        log("connect " + tag.take(8))
        manager!!.connect(channel!!, cfg, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                log("connect requested")
                Diag.stage("wifi-direct", tag, "connecting", "request accepted by system")
            }

            override fun onFailure(reason: Int) {
                log("connect failed reason=$reason")
                Diag.stage("wifi-direct", tag, "rejected", "system refused, reason=$reason")
            }
        })
    }

    private fun onConnectionInfo(info: WifiP2pInfo?) {
        if (info == null || !info.groupFormed) return
        val go = info.groupOwnerAddress ?: return
        log("group formed owner=" + info.isGroupOwner)
        if (info.isGroupOwner) {
            startServer()
        } else if (!clientConnecting) {
            clientConnecting = true
            Thread({
                try {
                    for (attempt in 0 until 8) {
                        if (!running) break
                        try {
                            val s = Socket()
                            s.connect(InetSocketAddress(go, PORT), 4000)
                            open(s, true)
                            break
                        } catch (e: Exception) {
                            Thread.sleep(1500)
                        }
                    }
                } catch (ignored: InterruptedException) {
                }
                clientConnecting = false
            }, "ripplo-p2p-connect").apply {
                isDaemon = true
                start()
            }
        }
    }

    @Synchronized
    private fun startServer() {
        if (server?.isClosed == false) return
        try {
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(InetSocketAddress(PORT))
            server = ss
            Thread({
                try {
                    while (!ss.isClosed) open(ss.accept(), false)
                } catch (ignored: Exception) {
                }
            }, "ripplo-p2p-accept").apply {
                isDaemon = true
                start()
            }
        } catch (ignored: Exception) {
        }
    }

    private fun open(s: Socket, outbound: Boolean) {
        s.tcpNoDelay = true
        StreamLink(engine, "wifi-direct", outbound, s.getInputStream(), s.getOutputStream(), s).open()
    }

    override fun tickImpl() {
        val now = System.currentTimeMillis()
        val direct = engine.neighbors().any { engine.hasLink(it, "wifi-direct") }
        if (manager != null && channel != null && !direct && now - lastDiscover > 90000) {
            lastDiscover = now
            discover()
        }
    }

    override fun rescan() {
        if (manager == null || channel == null || clientConnecting || engine.forcing()) return
        lastDiscover = System.currentTimeMillis()
        discover()
    }

    override fun probe() {
        if (manager == null || channel == null || clientConnecting || engine.forcing()) return
        Diag.stage("wifi-direct", "", "scanning", "periodic Wi-Fi Direct scan")
        lastDiscover = System.currentTimeMillis()
        discover()
    }

    @SuppressLint("MissingPermission")
    override fun stopImpl() {
        try {
            receiver?.let { ctx.unregisterReceiver(it) }
        } catch (ignored: Exception) {
        }
        receiver = null
        try {
            val m = manager
            val ch = channel
            if (m != null && ch != null) {
                request?.let { m.removeServiceRequest(ch, it, null) }
                localService?.let { m.removeLocalService(ch, it, null) }
                m.stopPeerDiscovery(ch, null)
                m.removeGroup(ch, null)
            }
        } catch (ignored: Exception) {
        }
        try {
            server?.close()
        } catch (ignored: Exception) {
        }
        server = null
        try {
            if (Build.VERSION.SDK_INT >= 27) channel?.close()
        } catch (ignored: Exception) {
        }
        channel = null
        manager = null
        devices.clear()
    }

    companion object {
        private const val PORT = 47321

        private fun reasonText(r: Int): String = when (r) {
            2 -> " (busy)"
            1 -> " (not supported)"
            0 -> " (internal error)"
            3 -> " (no service requests)"
            else -> ""
        }
    }
}
