package io.github.nahida4479.ripplo.transport.lan

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.transport.StreamLink
import io.github.nahida4479.ripplo.transport.Transport
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.ArrayDeque

internal class LanTransport(ctx: Context, engine: MeshEngine) : Transport(ctx, engine) {

    private class Peer(val host: InetAddress, val port: Int, val tag: String) {
        var lastTry = 0L
        var fails = 0
    }

    private var nsd: NsdManager? = null
    private var server: ServerSocket? = null
    private val peers = HashMap<String, Peer>()
    private val connecting = HashSet<String>()
    private val resolveTries = HashMap<String, Int>()
    private val toResolve = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var resolveStart = 0L
    private var serviceName: String? = null
    private var regListener: NsdManager.RegistrationListener? = null
    private var discListener: NsdManager.DiscoveryListener? = null

    override fun name(): String = "lan"

    override fun startImpl() {
        val n = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager?
        nsd = n
        if (n == null) throw IllegalStateException("no nsd")
        val ss = ServerSocket(0)
        server = ss
        Thread({
            try {
                while (!ss.isClosed) open(ss.accept(), false)
            } catch (ignored: Exception) {
            }
        }, "ripplo-lan-accept").apply {
            isDaemon = true
            start()
        }

        val name = "ripplo-" + engine.nodeTag().substring(0, 8)
        serviceName = name
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = TYPE
            port = ss.localPort
            setAttribute("nt", engine.nodeTag())
        }
        val reg = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(i: NsdServiceInfo?, e: Int) = log("register failed $e")
            override fun onUnregistrationFailed(i: NsdServiceInfo?, e: Int) {}
            override fun onServiceRegistered(i: NsdServiceInfo?) {}
            override fun onServiceUnregistered(i: NsdServiceInfo?) {}
        }
        regListener = reg
        n.registerService(info, NsdManager.PROTOCOL_DNS_SD, reg)

        val disc = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(s: String?, e: Int) = log("discovery failed $e")
            override fun onStopDiscoveryFailed(s: String?, e: Int) {}
            override fun onDiscoveryStarted(s: String?) {}
            override fun onDiscoveryStopped(s: String?) {}

            override fun onServiceFound(i: NsdServiceInfo?) {
                if (serviceName == i!!.serviceName) return
                log("found " + i.serviceName)
                synchronized(this@LanTransport) { toResolve.add(i) }
                resolveNext()
            }

            override fun onServiceLost(i: NsdServiceInfo?) {
                synchronized(this@LanTransport) { peers.remove(i!!.serviceName) }
            }
        }
        discListener = disc
        n.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, disc)
    }

    private fun resolveNext() {
        val next: NsdServiceInfo
        val n: NsdManager
        synchronized(this) {
            n = nsd ?: return
            if (resolving || toResolve.isEmpty()) return
            next = toResolve.poll()!!
            resolving = true
            resolveStart = System.currentTimeMillis()
        }
        try {
            n.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(i: NsdServiceInfo?, e: Int) {
                    log("resolve failed $e")
                    retryResolve(i!!)
                    done()
                }

                override fun onServiceResolved(i: NsdServiceInfo?) {
                    try {
                        handleResolved(i!!)
                    } finally {
                        done()
                    }
                }
            })
        } catch (e: Exception) {
            done()
        }
    }

    private fun retryResolve(i: NsdServiceInfo) {
        val name = i.serviceName
        val n: Int
        synchronized(this) {
            n = (resolveTries[name] ?: 0) + 1
            resolveTries[name] = n
        }
        if (n > 5) return
        Thread(retry@{
            try {
                Thread.sleep(1500L * n)
            } catch (e: InterruptedException) {
                return@retry
            }
            synchronized(this@LanTransport) {
                if (nsd == null) return@retry
                toResolve.add(i)
            }
            resolveNext()
        }, "ripplo-lan-resolve").apply {
            isDaemon = true
            start()
        }
    }

    private fun done() {
        synchronized(this) { resolving = false }
        resolveNext()
    }

    private fun handleResolved(i: NsdServiceInfo) {
        val host = i.host ?: return
        log("resolved " + i.serviceName + " " + host.hostAddress + ":" + i.port)
        val nt = i.attributes?.get("nt")
        val tag = if (nt == null) "" else String(nt, Charsets.US_ASCII)
        if (tag == engine.nodeTag()) return
        if (isLocal(host)) {
            log("skip own address " + host.hostAddress + " " + i.serviceName)
            return
        }
        engine.noteSeen(tag, "lan")
        val p = Peer(host, i.port, tag)
        synchronized(this) {
            peers[i.serviceName] = p
            resolveTries.remove(i.serviceName)
        }
        connect(p)
    }

    override fun forceConnect(node: String, option: String): Boolean {
        val target = synchronized(this) { peers.values.lastOrNull { it.tag == node } }
        if (target == null) {
            log("force: no lan peer for node")
            Diag.stage("lan", node, "rejected", "no LAN peer for this node")
            return false
        }
        Diag.stage("lan", node, "attempt", target.host.hostAddress + ":" + target.port)
        connect(target, true)
        return true
    }

    private fun connect(p: Peer, force: Boolean = false) {
        val key = p.host.hostAddress + ":" + p.port
        synchronized(this) {
            if (connecting.contains(key)) return
            if (!force && engine.forcing()) return
            if (!force && p.tag.isNotEmpty() && engine.hasLink(p.tag, "lan")) return
            connecting.add(key)
            p.lastTry = System.currentTimeMillis()
        }
        Thread({
            try {
                val s = Socket()
                if (force) Diag.stage("lan", p.tag, "connecting", key)
                s.connect(InetSocketAddress(p.host, p.port), 5000)
                open(s, true)
                if (force) Diag.stage("lan", p.tag, "linked", "link ready $key")
                p.fails = 0
            } catch (e: Exception) {
                if (force) Diag.stage("lan", p.tag, "failed", e.javaClass.simpleName + " " + e.message)
                log("connect failed " + p.host.hostAddress + " " + e)
                val refused = e.message?.contains("ECONNREFUSED") == true
                p.fails++
                if (refused && p.fails >= 6) {
                    synchronized(this@LanTransport) { peers.values.remove(p) }
                    log("dropped peer " + p.host.hostAddress + ":" + p.port)
                }
            }
            synchronized(this@LanTransport) { connecting.remove(key) }
        }, "ripplo-lan-connect").apply {
            isDaemon = true
            start()
        }
    }

    private fun open(s: Socket, outbound: Boolean) {
        s.tcpNoDelay = true
        StreamLink(engine, "lan", outbound, s.getInputStream(), s.getOutputStream(), s).open()
    }

    override fun tickImpl() {
        val now = System.currentTimeMillis()
        val stuck = synchronized(this) { resolving && now - resolveStart > 10000L }
        if (stuck) {
            log("resolve timeout")
            done()
        }
        val list = synchronized(this) { ArrayList(peers.values) }
        for (p in list) if (now - p.lastTry > minOf(4000L shl minOf(p.fails, 3), 30000L)) connect(p)
    }

    override fun stopImpl() {
        try {
            val n = nsd
            val d = discListener
            if (n != null && d != null) n.stopServiceDiscovery(d)
        } catch (ignored: Exception) {
        }
        try {
            val n = nsd
            val r = regListener
            if (n != null && r != null) n.unregisterService(r)
        } catch (ignored: Exception) {
        }
        try {
            server?.close()
        } catch (ignored: Exception) {
        }
        discListener = null
        regListener = null
        server = null
        synchronized(this) {
            peers.clear()
            resolveTries.clear()
            toResolve.clear()
            resolving = false
        }
    }

    companion object {
        private const val TYPE = "_ripplo._tcp."

        private fun isLocal(a: InetAddress): Boolean {
            if (a.isLoopbackAddress || a.isAnyLocalAddress) return true
            return try {
                NetworkInterface.getByInetAddress(a) != null
            } catch (e: Exception) {
                false
            }
        }
    }
}
