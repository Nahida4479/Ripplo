package io.github.nahida4479.ripplo.mesh

import java.io.IOException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

internal abstract class Link(val engine: MeshEngine, val medium: String, val outbound: Boolean) {
    companion object {
        const val QUEUE_CAP = 32L * 1024 * 1024
        const val STALE_NANOS = 12L * 1000000000L
    }

    @Volatile
    var node: String? = null

    @Volatile
    var note: String = ""

    @Volatile
    var helloTag: String? = null

    @Volatile
    var helloHook: java.util.function.Consumer<String>? = null

    @Volatile
    var kbps: Long = 0L

    @Volatile
    var rttMs: Long = 0L

    @Volatile
    var lastRx: Long = System.nanoTime()

    var strikes: Int = 0

    @Volatile
    var pingNonce: Long = 0L

    @Volatile
    var pingStartNanos: Long = 0L

    @Volatile
    var pingBits: Int = 0

    var windowStart: Long = 0L
    var windowCount: Int = 0
    val alive = AtomicBoolean(true)
    private val queue = LinkedBlockingQueue<ByteArray>()
    private val queued = AtomicLong()
    private val lenBuf = ByteArray(4)
    private var lenGot = 0
    private var body: ByteArray? = null
    private var bodyGot = 0
    val born = System.nanoTime()

    init {
        kbps = MeshEngine.nominalKbps(medium)
    }

    @Throws(IOException::class)
    abstract fun writeFrame(frame: ByteArray)

    abstract fun closeImpl()

    fun start() {
        val writer = Thread({
            try {
                while (alive.get()) {
                    val f = queue.poll(1, TimeUnit.SECONDS) ?: continue
                    writeFrame(f)
                    queued.addAndGet(-f.size.toLong())
                }
            } catch (e: Exception) {
                Diag.i("write failed $medium node=${node?.substring(0, 8) ?: "none"} $e")
                close()
            }
        }, "ripplo-link-w")
        writer.isDaemon = true
        writer.start()
    }

    fun stale(nowNanos: Long): Boolean = nowNanos - lastRx > STALE_NANOS

    fun send(packet: ByteArray): Boolean {
        if (!alive.get()) return false
        val n = packet.size
        val f = ByteArray(n + 4)
        f[0] = (n ushr 24).toByte()
        f[1] = (n ushr 16).toByte()
        f[2] = (n ushr 8).toByte()
        f[3] = n.toByte()
        packet.copyInto(f, 4)
        if (queued.addAndGet(f.size.toLong()) > QUEUE_CAP) {
            queued.addAndGet(-f.size.toLong())
            return false
        }
        return queue.offer(f)
    }

    fun onBytes(d: ByteArray, off: Int, len: Int) {
        lastRx = System.nanoTime()
        var pos = off
        var left = len
        try {
            while (left > 0) {
                val b = body
                if (b == null) {
                    val n = minOf(4 - lenGot, left)
                    System.arraycopy(d, pos, lenBuf, lenGot, n)
                    lenGot += n
                    pos += n
                    left -= n
                    if (lenGot < 4) return
                    val frameLen = ((lenBuf[0].toInt() and 0xFF) shl 24) or
                        ((lenBuf[1].toInt() and 0xFF) shl 16) or
                        ((lenBuf[2].toInt() and 0xFF) shl 8) or
                        (lenBuf[3].toInt() and 0xFF)
                    if (frameLen < Packet.HEADER || frameLen > Packet.MAX_PACKET) throw IOException("bad frame")
                    body = ByteArray(frameLen)
                    bodyGot = 0
                } else {
                    val n = minOf(b.size - bodyGot, left)
                    System.arraycopy(d, pos, b, bodyGot, n)
                    bodyGot += n
                    pos += n
                    left -= n
                    if (bodyGot == b.size) {
                        body = null
                        lenGot = 0
                        engine.onFrame(this, b)
                    }
                }
            }
        } catch (e: IOException) {
            Diag.i("rx error $medium $e")
            close()
        }
    }

    fun close() {
        if (alive.compareAndSet(true, false)) {
            Diag.i("close $medium out=$outbound node=${node?.substring(0, 8) ?: "none"} age=${(System.nanoTime() - born) / 1000000L}ms")
            try {
                closeImpl()
            } catch (ignored: Exception) {
            }
            engine.linkDown(this)
        }
    }
}
