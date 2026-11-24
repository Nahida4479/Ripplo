package io.github.nahida4479.ripplo.mesh

import java.security.SecureRandom

internal class Packet(
    var type: Int,
    var ttl: Int,
    var hops: Int,
    var id: ByteArray,
    var dest: ByteArray,
    var payload: ByteArray,
) {
    fun encode(): ByteArray {
        val b = ByteArray(HEADER + payload.size)
        b[0] = 1
        b[1] = type.toByte()
        b[2] = ttl.toByte()
        b[3] = hops.toByte()
        System.arraycopy(id, 0, b, 4, 16)
        System.arraycopy(dest, 0, b, 20, 16)
        System.arraycopy(payload, 0, b, HEADER, payload.size)
        return b
    }

    fun copy(): Packet = Packet(type, ttl, hops, id, dest, payload)

    companion object {
        const val LINK_HELLO = 1
        const val PING = 2
        const val PONG = 3
        const val DATA = 10
        const val ACK = 11
        const val DEAD_END = 12
        const val DISCOVER = 13
        const val REPLY = 14
        const val APP = 20
        const val HEADER = 36
        const val MAX_PACKET = 65536
        const val TTL_DEFAULT = 8

        private const val HEX = "0123456789abcdef"
        private val rng = SecureRandom()

        fun newId(): ByteArray = ByteArray(16).also { rng.nextBytes(it) }

        fun make(type: Int, dest: ByteArray, payload: ByteArray): Packet =
            Packet(type, TTL_DEFAULT, 0, newId(), dest, payload)

        fun decode(b: ByteArray): Packet {
            if (b.size < HEADER || b.size > MAX_PACKET || b[0].toInt() != 1) throw IllegalArgumentException("bad packet")
            val id = ByteArray(16)
            val dest = ByteArray(16)
            val payload = ByteArray(b.size - HEADER)
            System.arraycopy(b, 4, id, 0, 16)
            System.arraycopy(b, 20, dest, 0, 16)
            System.arraycopy(b, HEADER, payload, 0, payload.size)
            return Packet(b[1].toInt() and 0xFF, b[2].toInt() and 0xFF, b[3].toInt() and 0xFF, id, dest, payload)
        }

        fun hex(b: ByteArray): String {
            val c = CharArray(b.size * 2)
            for (i in b.indices) {
                c[2 * i] = HEX[(b[i].toInt() shr 4) and 15]
                c[2 * i + 1] = HEX[b[i].toInt() and 15]
            }
            return String(c)
        }

        fun unhex(s: String): ByteArray {
            val b = ByteArray(s.length / 2)
            for (i in b.indices) b[i] = s.substring(2 * i, 2 * i + 2).toInt(16).toByte()
            return b
        }
    }
}
