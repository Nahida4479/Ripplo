package io.github.nahida4479.ripplo.mesh

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import io.github.nahida4479.ripplo.data.Inbox
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.platform.Notifier
import io.github.nahida4479.ripplo.platform.Opener
import io.github.nahida4479.ripplo.transport.Link
import io.github.nahida4479.ripplo.transport.Transport
import io.github.nahida4479.ripplo.transport.ble.BleTransport
import io.github.nahida4479.ripplo.transport.lan.LanTransport
import io.github.nahida4479.ripplo.transport.wifiaware.WifiAwareTransport
import io.github.nahida4479.ripplo.transport.wifidirect.WifiDirectTransport
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

internal class MeshEngine private constructor(internal val ctx: Context) : Router.Host {
    interface Listener {
        fun onPacket(packet: ByteArray, from: String)
        fun onNeighbor(node: String, up: Boolean, medium: String, kbps: Long)
    }

    internal val rx: ExecutorService = Executors.newSingleThreadExecutor { r -> daemon(r, "ripplo-rx") }
    private val sched: ScheduledExecutorService = Executors.newScheduledThreadPool(2) { r -> daemon(r, "ripplo-sched") }
    private val prefs: SharedPreferences = ctx.getSharedPreferences("ripplo_mesh", Context.MODE_PRIVATE)
    private val inbox = Inbox(ctx)
    private val nodeTag: String = Packet.hex(Packet.newId())
    private val wake: PowerManager.WakeLock
    private val wifiLock: WifiManager.WifiLock
    private val multicastLock: WifiManager.MulticastLock
    private var tickCount = 0
    private val lock = Any()
    private val byNode = HashMap<String, MutableList<Link>>()
    private val pending = HashSet<Link>()
    private val transports = ArrayList<Transport>()
    private val seen = HashMap<String, MutableMap<String, Long>>()
    @Volatile private var router: Router? = null
    @Volatile private var running = false
    @Volatile private var selfTag: ByteArray? = null
    private var tickTask: ScheduledFuture<*>? = null
    @Volatile private var listener: Listener? = null
    @Volatile private var jsAttached = false

    init {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ripplo:mesh")
        wake.setReferenceCounted(false)
        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "ripplo:wifi")
        wifiLock.setReferenceCounted(false)
        multicastLock = wm.createMulticastLock("ripplo:mdns")
        multicastLock.setReferenceCounted(false)
    }

    private fun holdLocks(hold: Boolean) {
        try {
            if (hold) {
                wake.acquire()
                wifiLock.acquire()
                multicastLock.acquire()
            } else {
                if (wake.isHeld) wake.release()
                if (wifiLock.isHeld) wifiLock.release()
                if (multicastLock.isHeld) multicastLock.release()
            }
        } catch (ignored: RuntimeException) {
        }
    }

    fun nodeTag(): String = nodeTag

    fun isRunning(): Boolean = running

    fun background(): Boolean = prefs.getBoolean("background", true)

    fun setListener(l: Listener?) {
        listener = l
    }

    fun setJsAttached(v: Boolean) {
        jsAttached = v
    }

    @Synchronized
    fun start(self: ByteArray, background: Boolean, launchService: Boolean) {
        prefs.edit().putString("selfTag", Packet.hex(self)).putBoolean("background", background).apply()
        if (running && self.contentEquals(selfTag)) {
            if (launchService) MeshService.launch(ctx)
            return
        }
        if (running) stop(false)
        selfTag = self
        router = Router(this, self)
        running = true
        Diag.i("engine start node=" + nodeTag.substring(0, 8) + " self=" + Packet.hex(self).substring(0, 8))
        holdLocks(true)
        if (Build.VERSION.SDK_INT >= 29) transports.add(WifiAwareTransport(ctx, this))
        transports.add(BleTransport(ctx, this))
        transports.add(LanTransport(ctx, this))
        try {
            val k = Class.forName("io.github.nahida4479.ripplo.transport.nearby.NearbyTransport")
            transports.add(k.getDeclaredConstructor(Context::class.java, MeshEngine::class.java).newInstance(ctx, this) as Transport)
        } catch (ignored: ReflectiveOperationException) {
            transports.add(WifiDirectTransport(ctx, this))
        }
        for (t in transports) sched.execute { t.start() }
        tickTask = sched.scheduleWithFixedDelay({ tick() }, TICK_SECONDS, TICK_SECONDS, TimeUnit.SECONDS)
        if (launchService) MeshService.launch(ctx)
    }

    @Synchronized
    fun resumeFromPrefs(): Boolean {
        val s = prefs.getString("selfTag", null)
        if (s == null || s.length != 32 || !background()) return false
        start(Packet.unhex(s), true, false)
        return true
    }

    fun stop() {
        stop(true)
    }

    @Synchronized
    private fun stop(clear: Boolean) {
        running = false
        Diag.i("engine stop clear=$clear")
        holdLocks(false)
        tickTask?.cancel(false)
        for (t in transports) t.stop()
        transports.clear()
        val all = ArrayList<Link>()
        synchronized(lock) {
            for (l in byNode.values) all.addAll(l)
            all.addAll(pending)
        }
        for (l in all) l.close()
        router = null
        if (clear) {
            prefs.edit().remove("selfTag").apply()
            ctx.stopService(Intent(ctx, MeshService::class.java))
        }
    }

    private fun tick() {
        val all = ArrayList<Link>()
        synchronized(lock) {
            for (l in byNode.values) all.addAll(l)
        }
        val now = System.nanoTime()
        tickCount++
        val stuck = ArrayList<Link>()
        synchronized(lock) {
            for (l in pending) if (now - l.born > 30L * 1000000000L) stuck.add(l)
        }
        for (l in stuck) {
            Diag.i("hello timeout close " + l.medium)
            l.close()
        }
        for (l in all) {
            if (now - l.lastRx > QUIET_NANOS) {
                // BLE peers with the screen off answer slowly (radio duty-cycling): allow more missed checks
                if (++l.strikes >= (if (l.medium == "ble" || l.medium == "l2cap") 6 else 2)) {
                    val node = l.node
                    Diag.i("quiet close " + l.medium + " node=" + (node?.substring(0, 8) ?: "none"))
                    l.close()
                }
                continue
            }
            l.strikes = 0
            val asked = l.pingStartNanos
            val due = asked == 0L || now - asked > QUIET_NANOS
            if (due && (l.medium != "ble" || tickCount % 3 == 0)) sendPing(l)
        }
        val fn = forceNode
        if (fn != null) {
            if (System.currentTimeMillis() >= forceUntil) forceEnd(fn) else forceEnforce(fn)
        }
        for (t in transports.toList()) t.tick()
        if (tickCount % LONELY_TICKS == 0 && synchronized(lock) { byNode.isEmpty() } && forceNode == null) {
            for (t in transports.toList()) sched.execute { t.rescanNow() }
        }
        if (tickCount % PROBE_TICKS == 0 && forceNode == null && !forcing()) {
            val name = if ((tickCount / PROBE_TICKS) % 2 == 0) "ble" else "wifi-direct"
            for (t in transports.toList()) if (t.name() == name) sched.execute { t.probeNow() }
        }
    }

    private val helloAt = HashMap<String, Long>()

    private fun touchWake() {
        if (wake.isHeld) return
        try {
            wake.acquire(30000)
        } catch (ignored: RuntimeException) {
        }
    }

    internal fun addLink(link: Link): Boolean {
        if (!running) {
            link.close()
            return false
        }
        synchronized(lock) { pending.add(link) }
        Diag.i("link add " + link.medium + " outbound=" + link.outbound)
        link.start()
        link.send(Packet.make(Packet.LINK_HELLO, ByteArray(16), Packet.unhex(nodeTag)).encode())
        return true
    }

    internal fun hasFastLink(node: String): Boolean = synchronized(lock) {
        byNode[node]?.any { k ->
            val bleish = k.medium == "ble" || k.medium == "l2cap"
            k.medium == "lan" || k.medium == "wifi-aware" || (bleish && !k.note.contains("coded"))
        } ?: false
    }

    internal fun hasLink(node: String, medium: String): Boolean = synchronized(lock) {
        byNode[node]?.any { it.medium == medium } ?: false
    }

    internal fun linkDown(link: Link) {
        var down = false
        val node = link.node
        synchronized(lock) {
            pending.remove(link)
            if (node != null) {
                val l = byNode[node]
                if (l != null && l.remove(link) && l.isEmpty()) {
                    byNode.remove(node)
                    down = true
                }
            }
        }
        Diag.i("link down " + link.medium + " node=" + (node?.substring(0, 8) ?: "none") + " last=" + down)
        if (node != null) Diag.stage(link.medium, node, "closed", "link down, last=$down")
        if (down && node != null) {
            router?.linkDown(node)
            emitNeighbor(node, false, link.medium, link.kbps)
            scheduleRescan()
        } else if (node != null) {
            emitBest(node)
        }
    }

    private var lastRescan = 0L

    private fun scheduleRescan() {
        if (!running || forceNode != null) return
        val now = System.currentTimeMillis()
        synchronized(lock) {
            if (now - lastRescan < RESCAN_GAP_MS) return
            lastRescan = now
        }
        sched.schedule({
            if (running) {
                Diag.i("rescan after losing a neighbor")
                for (t in transports.toList()) t.rescanNow()
            }
        }, 1500, TimeUnit.MILLISECONDS)
    }

    private fun emitBest(node: String) {
        val best = sortedLinks(node).firstOrNull() ?: return
        emitNeighbor(node, true, best.medium, best.kbps)
    }

    private fun emitNeighbor(node: String, up: Boolean, medium: String, kbps: Long) {
        listener?.onNeighbor(node, up, medium, kbps)
    }

    private fun sortedLinks(node: String): List<Link> {
        val out = synchronized(lock) { byNode[node]?.let { ArrayList(it) } ?: ArrayList<Link>() }
        out.sortByDescending { it.kbps }
        return out
    }

    internal fun onFrame(link: Link, frame: ByteArray) {
        val r = router
        if (r == null || !link.alive.get()) return
        val now = System.currentTimeMillis()
        if (now - link.windowStart >= 1000) {
            link.windowStart = now
            link.windowCount = 0
        }
        if (++link.windowCount > 200) return
        val p = try {
            Packet.decode(frame)
        } catch (e: IllegalArgumentException) {
            if (frame.size < Packet.HEADER || frame[0].toInt() == 1) link.close()
            return
        }
        when (p.type) {
            Packet.LINK_HELLO -> {
                if (p.payload.size < 16) {
                    link.close()
                    return
                }
                onHello(link, Packet.hex(p.payload.copyOf(16)))
            }
            Packet.PING -> {
                if (link.node != null && p.payload.size >= 16) {
                    link.send(Packet.make(Packet.PONG, ByteArray(16), p.payload.copyOf(16)).encode())
                }
            }
            Packet.PONG -> onPong(link, p)
            else -> {
                val from = link.node ?: return
                if (p.type == Packet.APP && p.payload.size == 2 && p.payload[0] == 0xFE.toByte()) {
                    for (t in transports.toList()) t.onPeerRequest(p.payload[1].toInt())
                    return
                }
                if (p.type == Packet.DATA || p.type == Packet.ACK) touchWake()
                if (p.type == Packet.APP && p.payload.isNotEmpty() && p.payload[0] == '{'.code.toByte()) {
                    Diag.i("app in " + from.substring(0, 8) + " via " + link.medium + " " + p.payload.size + "B js=" + jsAttached)
                }
                r.onPacket(p, from)
            }
        }
    }

    private fun onHello(link: Link, tag: String) {
        if (link.node != null) return
        link.helloTag = tag
        link.helloHook?.accept(tag)
        if (tag == nodeTag) {
            link.close()
            return
        }
        if (forceVetoes(tag, link)) {
            Diag.stage("force", tag, "closed", "refused a ${link.medium} link while ${forceSpec} is forced")
            link.close()
            return
        }
        val toClose = ArrayList<Link>()
        var loser = false
        val first: Boolean
        synchronized(lock) {
            pending.remove(link)
            val list = byNode.getOrPut(tag) { ArrayList() }
            first = list.isEmpty()
            val initNew = if (link.outbound) nodeTag else tag
            for (o in list) {
                if (o.medium != link.medium) continue
                val initOld = if (o.outbound) nodeTag else tag
                if (initNew < initOld) {
                    toClose.add(o)
                } else {
                    loser = true
                }
            }
            if (loser) {
                if (list.isEmpty()) byNode.remove(tag)
            } else {
                link.node = tag
                list.add(link)
            }
        }
        Diag.i("hello " + tag.substring(0, 8) + " via " + link.medium + " outbound=" + link.outbound + " loser=" + loser + " replaced=" + toClose.size)
        if (loser) {
            link.close()
            return
        }
        for (o in toClose) o.close()
        if (first) emitNeighbor(tag, true, link.medium, link.kbps) else emitBest(tag)
        sendPing(link)
    }

    private fun sendPing(link: Link) {
        if (link.node == null || !link.alive.get()) return
        val now = System.nanoTime()
        val slow = link.medium == "ble" || link.medium == "l2cap" || link.note.contains("coded")
        val probe = !slow && (link.probeAt == 0L || now - link.probeAt > PROBE_NANOS)
        val filler = if (probe) 16384 else 0
        val b = ByteBuffer.allocate(16 + filler)
        val nonce = SecureRandom().nextLong()
        b.putLong(nonce).putLong(System.currentTimeMillis())
        val p = Packet.make(Packet.PING, ByteArray(16), b.array())
        link.pingNonce = nonce
        link.pingBits = (Packet.HEADER + b.capacity() + 4) * 8
        link.pingProbe = probe
        if (probe) link.probeAt = now
        link.pingStartNanos = now
        link.send(p.encode())
    }

    private fun onPong(link: Link, p: Packet) {
        val node = link.node
        if (node == null || p.payload.size < 8 || link.pingStartNanos == 0L) return
        if (ByteBuffer.wrap(p.payload).long != link.pingNonce) return
        val ms = maxOf(1L, (System.nanoTime() - link.pingStartNanos) / 1000000L)
        link.pingStartNanos = 0
        link.rttMs = ms
        if (!link.pingProbe) return
        link.kbps = maxOf(1L, link.pingBits / ms)
        val sorted = sortedLinks(node)
        if (sorted.isNotEmpty()) emitNeighbor(node, true, sorted[0].medium, sorted[0].kbps)
    }

    override fun send(to: String, p: Packet): Boolean {
        val bytes = p.encode()
        if (p.type == Packet.DATA || p.type == Packet.ACK) touchWake()
        val links = sortedLinks(to)
        val now = System.nanoTime()
        for (l in links) if (!l.stale(now) && l.send(bytes)) return true
        for (l in links) if (l.stale(now) && l.send(bytes)) return true
        return false
    }

    override fun neighbors(): List<String> = synchronized(lock) { ArrayList(byNode.keys) }

    override fun deliver(p: Packet, from: String) {
        val l = listener
        if (l != null && jsAttached) l.onPacket(p.encode(), from) else if (p.type == Packet.APP) answerHello(p, from)
    }

    fun setHello(card: String, hidden: Boolean) {
        prefs.edit().putString("helloCard", card).putBoolean("helloHidden", hidden).apply()
    }

    private fun answerHello(p: Packet, from: String) {
        val card = prefs.getString("helloCard", null) ?: return
        if (prefs.getBoolean("helloHidden", false) || p.payload.isEmpty() || p.payload[0] != '{'.code.toByte()) return
        val now = System.currentTimeMillis()
        synchronized(lock) {
            if (now - (helloAt[from] ?: 0L) < 5000L) return
            helloAt[from] = now
        }
        try {
            val o = JSONObject(String(p.payload, Charsets.UTF_8))
            if (o.optString("t") != "hello" || o.optInt("r", 0) != 1) return
            sendApp(from, JSONObject().put("t", "hello").put("card", card).toString().toByteArray(Charsets.UTF_8))
        } catch (ignored: JSONException) {
        }
    }

    override fun persist(p: Packet, from: String): Boolean {
        if (jsAttached && listener != null) return true
        if (p.payload.isNotEmpty() && p.payload[0].toInt() == 1) {
            if (!inbox.hasRoom()) return false
            val r = Opener.process(ctx, p.payload)
            if (r != null) return inbox.addOpened(r.sealed, r.callId)
        }
        if (!inbox.add(p.encode(), from)) return false
        if (p.payload.isNotEmpty() && p.payload[0].toInt() == 1) Notifier.newMessage(ctx)
        return true
    }

    fun drainInbox(): List<Inbox.Item> = inbox.drain()

    fun dropCall(callId: String?) {
        inbox.removeCall(callId)
    }

    fun requeue(it: Inbox.Item) {
        inbox.requeue(it)
    }

    fun sendFromJs(bytes: ByteArray): Int {
        val r = router ?: throw IllegalStateException("not started")
        val p = Packet.decode(bytes)
        if (p.type != Packet.DATA && p.type != Packet.DISCOVER && p.type != Packet.REPLY) throw IllegalArgumentException("type")
        val n = r.onPacket(p, Router.SELF)
        return if (p.type == Packet.REPLY) neighbors().size else n
    }

    fun sendApp(node: String, payload: ByteArray): Boolean {
        val p = Packet(Packet.APP, 1, 0, Packet.newId(), ByteArray(16), payload)
        if (p.encode().size > Packet.MAX_PACKET) throw IllegalArgumentException("size")
        return send(node, p)
    }

    internal fun noteSeen(node: String?, medium: String) {
        if (node.isNullOrEmpty()) return
        synchronized(lock) {
            seen.getOrPut(node) { HashMap() }[medium] = System.currentTimeMillis()
        }
    }

    internal fun askPeerAdvertise(node: String): Boolean = try {
        sendApp(node, byteArrayOf(0xFE.toByte(), 1))
    } catch (e: RuntimeException) {
        false
    }

    private val forceLock = Any()
    @Volatile private var forceNode: String? = null
    @Volatile private var forceSpec = ""
    @Volatile private var forceUntil = 0L
    @Volatile private var forceDial = 0L
    @Volatile private var forceDialAt = 0L

    internal fun forcing(): Boolean = System.currentTimeMillis() < forceDial

    private fun forceFamily(medium: String, spec: String): Boolean {
        val m = spec.substringBefore(":")
        return if (m == "ble") medium == "ble" || medium == "l2cap" else medium == m
    }

    private fun phyWrong(l: Link, spec: String): Boolean {
        if (l.note.isEmpty()) return false
        val coded = l.note.contains("coded")
        return (spec == "ble:coded" && !coded) || (spec == "ble:1m" && coded)
    }

    private fun forceMatches(l: Link, spec: String): Boolean {
        if (!forceFamily(l.medium, spec)) return false
        val coded = l.note.contains("coded")
        return when (spec) {
            "ble:coded" -> coded
            "ble:1m" -> !coded
            else -> true
        }
    }

    private fun forceVetoes(node: String, link: Link): Boolean {
        if (node != forceNode || System.currentTimeMillis() >= forceUntil) return false
        return !forceFamily(link.medium, forceSpec) || phyWrong(link, forceSpec)
    }

    private fun forceEnforce(node: String) {
        val spec = forceSpec
        val out = synchronized(lock) { byNode[node]?.filter { !forceFamily(it.medium, spec) || phyWrong(it, spec) } ?: emptyList() }
        for (l in out) {
            Diag.stage("force", node, "closed", "dropped a ${l.medium} link that does not match $spec")
            l.close()
        }
    }

    internal fun forceDialing() {
        val n = forceNode ?: return
        if (forceDialAt != 0L || System.currentTimeMillis() >= forceDial) return
        forceDialAt = System.currentTimeMillis()
        Diag.stage("force", n, "dialing", "peer found, ${FORCE_MS / 1000} s to bring the link up")
    }

    fun forceEnd(node: String?) {
        synchronized(forceLock) {
            if (node != null && node != forceNode) return
            forceDialAt = 0L
            forceNode = null
            forceSpec = ""
            forceUntil = 0L
            forceDial = 0L
        }
    }

    private fun describeLinks(node: String): String = synchronized(lock) {
        byNode[node]?.joinToString(", ") { it.medium + (if (it.note.isEmpty()) "" else " (" + it.note + ")") }
    } ?: "none"

    fun forceConnect(node: String, spec: String): String? {
        val p = spec.split(":", limit = 2)
        val t = transports.toList().firstOrNull { it.name() == p[0] }
            ?: return "Forced $spec to ${node.take(8)} failed: transport ${p[0]} does not exist in this build"
        val mark = Diag.mark()
        val start = System.currentTimeMillis()
        val before = describeLinks(node)
        synchronized(forceLock) {
            if (start < forceDial) return "Forced connection to ${node.take(8)} not started: another forced attempt is still running"
            forceNode = node
            forceSpec = spec
            forceDialAt = 0L
            forceDial = start + FORCE_FIND_MS + FORCE_MS
            forceUntil = start + FORCE_HOLD_MS
        }
        Diag.stage("force", node, "attempt", "$spec: up to ${FORCE_FIND_MS / 1000} s to find the peer, then ${FORCE_MS / 1000} s to connect; links before: $before; dropping them")
        val doomed = synchronized(lock) { byNode[node]?.let { ArrayList(it) } ?: ArrayList<Link>() }
        for (l in doomed) l.close()
        val res = java.util.concurrent.atomic.AtomicReference<Boolean?>(null)
        val worker = Thread({
            res.set(try { t.forceConnect(node, if (p.size > 1) p[1] else "") } catch (e: Exception) {
                Diag.w("force ${p[0]} threw $e")
                false
            })
        }, "ripplo-force")
        worker.isDaemon = true
        worker.start()
        var matched: Link? = null
        while (System.currentTimeMillis() < (if (forceDialAt == 0L) start + FORCE_FIND_MS else forceDialAt + FORCE_MS)) {
            matched = synchronized(lock) { byNode[node]?.firstOrNull { forceMatches(it, spec) } }
            if (matched != null || res.get() == false) break
            try { Thread.sleep(150) } catch (e: InterruptedException) { break }
        }
        if (matched == null) matched = synchronized(lock) { byNode[node]?.firstOrNull { forceMatches(it, spec) } }
        if (matched != null) {
            forceDial = 0L
            Diag.stage("force", node, "linked", "${matched.medium} up after ${System.currentTimeMillis() - start} ms; other links to this phone stay blocked until Close")
            return null
        }
        val now = describeLinks(node)
        val dialed = forceDialAt != 0L
        val why = when {
            res.get() == false -> "the transport refused to start (see its last step below)"
            !dialed -> "the peer was not found over $spec within ${FORCE_FIND_MS / 1000} s, so no connection was even attempted"
            else -> "the peer was found and dialed, but no $spec link came up within ${FORCE_MS / 1000} s"
        }
        val n8 = node.take(8)
        val steps = Diag.since(mark).filter { (it.contains(" $n8 ") || it.contains("force") || it.contains(" ${p[0]} ")) && !it.contains("scan hit") }.takeLast(16)
        forceEnd(node)
        for (x in transports.toList()) sched.execute { x.tick() }
        val msg = "Forced $spec to $n8 failed: $why. Links before: $before. Links now: $now. Steps:\n" + steps.joinToString("\n").ifEmpty { "(no transport reported any step)" }
        Diag.stage("force", node, "failed", msg)
        return msg
    }

    fun closeLinks(node: String, medium: String) {
        val out = synchronized(lock) {
            byNode[node]?.filter { k -> k.medium == medium || (medium == "ble" && k.medium == "l2cap") } ?: emptyList()
        }
        for (k in out) k.close()
    }

    fun transportsJson(): JSONArray {
        val out = JSONArray()
        for (t in transports.toList()) {
            try {
                out.put(JSONObject().put("name", t.name()).put("running", t.running).put("unsupported", t.unsupported()))
            } catch (ignored: JSONException) {
            }
        }
        return out
    }

    fun neighborsJson(): JSONArray {
        val out = JSONArray()
        for (node in neighbors()) {
            val links = sortedLinks(node)
            if (links.isEmpty()) continue
            try {
                val o = JSONObject()
                o.put("node", node)
                o.put("medium", links[0].medium)
                o.put("kbps", links[0].kbps)
                o.put("rttMs", links[0].rttMs)
                val ls = JSONArray()
                for (l in links) ls.put(JSONObject().put("medium", l.medium).put("kbps", l.kbps).put("rttMs", l.rttMs).put("outbound", l.outbound).put("note", l.note))
                o.put("links", ls)
                val sn = JSONArray()
                val now = System.currentTimeMillis()
                synchronized(lock) {
                    seen[node]?.forEach { (k, v) -> if (now - v < 120000L) sn.put(k) }
                }
                o.put("seen", sn)
                out.put(o)
            } catch (ignored: JSONException) {
            }
        }
        return out
    }

    companion object {
        private const val QUIET_NANOS = 30L * 1000000000L
        private const val TICK_SECONDS = 5L
        private const val PROBE_TICKS = 3
        private const val LONELY_TICKS = 6
        private const val RESCAN_GAP_MS = 8000L
        private const val FORCE_MS = 7000L
        private const val FORCE_FIND_MS = 15000L
        private const val FORCE_HOLD_MS = 10L * 60L * 1000L
        private const val PROBE_NANOS = 120L * 1000000000L
        private var instance: MeshEngine? = null

        @JvmStatic
        @Synchronized
        fun get(ctx: Context): MeshEngine =
            instance ?: MeshEngine(ctx.applicationContext).also { instance = it }

        internal fun nominalKbps(medium: String): Long = when (medium) {
            "lan", "wifi-aware", "wifi-direct" -> 20000
            "l2cap" -> 300
            else -> 50
        }

        private fun daemon(r: Runnable, name: String): Thread = Thread(r, name).apply { isDaemon = true }
    }
}
