package io.github.nahida4479.ripplo.transport.wifiaware

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareNetworkInfo
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.net.wifi.aware.WifiAwareSession
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.transport.StreamLink
import io.github.nahida4479.ripplo.transport.Transport
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

internal class WifiAwareTransport(ctx: Context, engine: MeshEngine) : Transport(ctx, engine) {

    private var cm: ConnectivityManager? = null
    private var session: WifiAwareSession? = null
    private var pub: PublishDiscoverySession? = null
    private var sub: SubscribeDiscoverySession? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var server: ServerSocket? = null
    private var messageId = 0
    private val attempts = HashMap<String, Long>()
    private val callbacks = HashMap<Int, ConnectivityManager.NetworkCallback>()
    private val pendingPeers = HashMap<Int, PeerHandle?>()
    private val handles = ConcurrentHashMap<String, PeerHandle>()

    override fun name(): String = "wifi-aware"

    @SuppressLint("MissingPermission")
    override fun startImpl() {
        if (Build.VERSION.SDK_INT < 29 || !ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) throw UnsupportedOperationException("no aware")
        val perm = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        if (!has(perm)) throw SecurityException("wifi permission")
        val manager = ctx.getSystemService(Context.WIFI_AWARE_SERVICE) as WifiAwareManager?
        val c = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager?
        cm = c
        if (manager == null || c == null || !manager.isAvailable) throw IllegalStateException("aware unavailable")
        val ht = HandlerThread("ripplo-aware")
        thread = ht
        ht.start()
        val h = Handler(ht.looper)
        handler = h

        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(PORT))
        server = ss
        Thread({
            try {
                while (!ss.isClosed) open(ss.accept(), false)
            } catch (ignored: Exception) {
            }
        }, "ripplo-aware-accept").apply {
            isDaemon = true
            start()
        }

        manager.attach(object : AttachCallback() {
            override fun onAttached(s: WifiAwareSession?) {
                log("attached")
                session = s
                publish()
                subscribe()
            }
        }, h)
    }

    @SuppressLint("MissingPermission")
    private fun publish() {
        val cfg = PublishConfig.Builder()
            .setServiceName(SERVICE)
            .setServiceSpecificInfo(engine.nodeTag().toByteArray(Charsets.US_ASCII))
            .build()
        session!!.publish(cfg, object : DiscoverySessionCallback() {
            override fun onPublishStarted(s: PublishDiscoverySession) {
                pub = s
            }

            override fun onMessageReceived(peer: PeerHandle?, message: ByteArray?) = respond(peer)
        }, handler)
    }

    @SuppressLint("MissingPermission")
    private fun subscribe() {
        val cfg = SubscribeConfig.Builder().setServiceName(SERVICE).build()
        session!!.subscribe(cfg, object : DiscoverySessionCallback() {
            override fun onSubscribeStarted(s: SubscribeDiscoverySession) {
                sub = s
            }

            override fun onServiceDiscovered(peer: PeerHandle?, info: ByteArray?, filter: List<ByteArray>?) {
                if (info == null) return
                val tag = String(info, Charsets.US_ASCII)
                log("discovered " + tag.take(8))
                if (tag != engine.nodeTag()) {
                    engine.noteSeen(tag, "wifi-aware")
                    handles[tag] = peer!!
                }
                if (engine.forcing() || engine.nodeTag() >= tag || engine.hasLink(tag, "wifi-aware")) return
                val now = System.currentTimeMillis()
                synchronized(attempts) {
                    val last = attempts[tag]
                    if (last != null && now - last < 20000) return
                    attempts[tag] = now
                }
                initiate(peer)
            }

            override fun onMessageSendSucceeded(id: Int) {
                val peer = synchronized(pendingPeers) { pendingPeers.remove(id) }
                if (peer != null) requestInitiator(peer)
            }
        }, handler)
    }

    override fun forceConnect(node: String, option: String): Boolean {
        val h = handles[node]
        if (h == null || sub == null) {
            log("force: peer not discovered")
            Diag.stage("wifi-aware", node, "rejected", "peer not discovered")
            return false
        }
        Diag.stage("wifi-aware", node, "attempt", "")
        engine.forceDialing()
        initiate(h)
        return true
    }

    private fun initiate(peer: PeerHandle?) {
        val s = sub ?: return
        val id = synchronized(pendingPeers) { (++messageId).also { pendingPeers[it] = peer } }
        s.sendMessage(peer!!, id, byteArrayOf(1))
    }

    private fun respond(peer: PeerHandle?) {
        val s = pub
        if (s == null || cm == null) return
        val spec = WifiAwareNetworkSpecifier.Builder(s, peer!!).setPskPassphrase(PSK).setPort(PORT).build()
        request(spec, false)
    }

    private fun requestInitiator(peer: PeerHandle) {
        val s = sub
        if (s == null || cm == null) return
        val spec = WifiAwareNetworkSpecifier.Builder(s, peer).setPskPassphrase(PSK).build()
        request(spec, true)
    }

    private fun request(spec: WifiAwareNetworkSpecifier, initiator: Boolean) {
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(spec)
            .build()
        val key = synchronized(callbacks) { callbacks.size + (System.nanoTime() and 0xFFFFFL).toInt() }
        val cb = object : ConnectivityManager.NetworkCallback() {
            private var connected = false

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                if (!initiator || connected) return
                val info = caps.transportInfo as? WifiAwareNetworkInfo ?: return
                val addr = info.peerIpv6Addr
                val port = info.port
                if (addr == null || port <= 0) return
                connected = true
                log("network ready port=$port")
                Thread({
                    try {
                        open(network.socketFactory.createSocket(addr, port), true)
                    } catch (ignored: Exception) {
                    }
                }, "ripplo-aware-connect").apply {
                    isDaemon = true
                    start()
                }
            }

            override fun onLost(network: Network) = release(key)

            override fun onUnavailable() {
                log("network unavailable")
                release(key)
            }
        }
        synchronized(callbacks) { callbacks[key] = cb }
        try {
            cm!!.requestNetwork(req, cb, 30000)
        } catch (e: RuntimeException) {
            release(key)
        }
    }

    private fun release(key: Int) {
        val cb = synchronized(callbacks) { callbacks.remove(key) }
        val c = cm
        if (cb != null && c != null) {
            try {
                c.unregisterNetworkCallback(cb)
            } catch (ignored: RuntimeException) {
            }
        }
    }

    private fun open(s: Socket, outbound: Boolean) {
        s.tcpNoDelay = true
        StreamLink(engine, "wifi-aware", outbound, s.getInputStream(), s.getOutputStream(), s).open()
    }

    override fun stopImpl() {
        val keys = synchronized(callbacks) { callbacks.keys.toList() }
        for (k in keys) release(k)
        try {
            pub?.close()
        } catch (ignored: Exception) {
        }
        try {
            sub?.close()
        } catch (ignored: Exception) {
        }
        try {
            session?.close()
        } catch (ignored: Exception) {
        }
        try {
            server?.close()
        } catch (ignored: Exception) {
        }
        thread?.quitSafely()
        handles.clear()
        pub = null
        sub = null
        session = null
        server = null
        thread = null
    }

    companion object {
        private const val SERVICE = "ripplo"
        private const val PSK = "ripplo-mesh-aware-v1"
        private const val PORT = 47322
    }
}
