package io.github.nahida4479.ripplo.mesh

internal class Router(private val host: Host, private val selfTag: ByteArray) {
    interface Host {
        fun send(to: String, p: Packet): Boolean
        fun neighbors(): List<String>
        fun deliver(p: Packet, from: String)
        fun persist(p: Packet, from: String): Boolean
    }

    private class Rev(val prev: String, val dest: String, val t: Long) {
        var pending = 0
        var done = false
    }

    private class Route(val n: String, val t: Long)

    companion object {
        const val SELF = "self"
        private const val EXPIRY_MS = 10 * 60 * 1000L
        private const val SEEN_CAP = 20000
    }

    private val seen = LinkedHashMap<String, Long>()
    private val reverse = LinkedHashMap<String, Rev>()
    private val routes = HashMap<String, Route>()

    @Synchronized
    fun linkDown(n: String) {
        routes.values.removeAll { it.n == n }
    }

    @Synchronized
    fun onPacket(p: Packet, from: String): Int {
        expire()
        val id = Packet.hex(p.id)
        val dest = Packet.hex(p.dest)
        val fromSelf = SELF == from
        when (p.type) {
            Packet.APP -> {
                host.deliver(p, from)
                return 0
            }
            Packet.DATA, Packet.DISCOVER -> {
                if (isSeen(p, id)) {
                    if (!fromSelf) sendDeadEnd(from, id)
                    return 0
                }
                markSeen(p, id)
                val r = Rev(from, dest, System.currentTimeMillis())
                reverse[id] = r
                if (p.type == Packet.DATA && p.dest.contentEquals(selfTag)) {
                    if (!host.persist(p, from)) {
                        deadEnd(id)
                        return 0
                    }
                    if (!fromSelf) send(from, Packet.ACK, p.id)
                    host.deliver(p, from)
                    return 0
                }
                if (p.type == Packet.DISCOVER && !fromSelf) host.deliver(p, from)
                val q = p.copy()
                if (!fromSelf) q.hops = minOf(p.hops + 1, 255)
                val route = if (p.type == Packet.DATA) routes[dest] else null
                val nb = host.neighbors()
                val targets = if (route != null && nb.contains(route.n) && route.n != from) listOf(route.n) else nb.filter { it != from }
                val sent = targets.count { host.send(it, q) }
                if (sent == 0) {
                    deadEnd(id)
                    return 0
                }
                r.pending = sent
                return sent
            }
            Packet.ACK, Packet.REPLY -> {
                if (isSeen(p, id)) return 0
                markSeen(p, id)
                val r = reverse[dest] ?: return 0
                if (p.type == Packet.ACK) {
                    if (!fromSelf) routes[r.dest] = Route(from, System.currentTimeMillis())
                    r.done = true
                }
                val q = p.copy()
                q.hops = minOf(p.hops + 1, 255)
                if (SELF == r.prev) host.deliver(q, SELF) else host.send(r.prev, q)
                return 0
            }
            Packet.DEAD_END -> {
                if (isSeen(p, id)) return 0
                markSeen(p, id)
                val r = reverse[dest]
                if (r == null || r.done) return 0
                if (--r.pending <= 0) deadEnd(dest)
                return 0
            }
            else -> return 0
        }
    }

    private fun deadEnd(id: String) {
        val r = reverse[id] ?: return
        r.done = true
        if (SELF == r.prev) host.deliver(Packet.make(Packet.DEAD_END, Packet.unhex(id), ByteArray(0)), SELF)
        else sendDeadEnd(r.prev, id)
    }

    private fun sendDeadEnd(to: String, id: String) {
        send(to, Packet.DEAD_END, Packet.unhex(id))
    }

    private fun send(to: String, type: Int, dest: ByteArray) {
        host.send(to, Packet.make(type, dest, ByteArray(0)))
    }

    private fun isSeen(p: Packet, id: String): Boolean = seen.containsKey("${p.type}:$id")

    private fun markSeen(p: Packet, id: String) {
        seen["${p.type}:$id"] = System.currentTimeMillis()
        if (seen.size > SEEN_CAP) seen.remove(seen.keys.first())
    }

    private fun expire() {
        val cutoff = System.currentTimeMillis() - EXPIRY_MS
        val seenIt = seen.values.iterator()
        while (seenIt.hasNext()) {
            if (seenIt.next() > cutoff) break
            seenIt.remove()
        }
        val reverseIt = reverse.values.iterator()
        while (reverseIt.hasNext()) {
            if (reverseIt.next().t > cutoff) break
            reverseIt.remove()
        }
        routes.values.removeAll { it.t <= cutoff }
    }
}
