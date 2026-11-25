package io.github.nahida4479.ripplo.data

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.PushbackInputStream
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object BackupFormat {
    const val FRAME = 1 shl 20
    const val MAX_RECORD = 256 shl 20
    const val VERSION = 1
    const val FLAG_FACTOR = 1
    const val BAD_CODE = "bad_code"
    const val BAD_FILE = "bad_file"
    const val NEED_FACTOR = "need_factor"
    private val MAGIC = "RIPPLOBK".toByteArray(StandardCharsets.US_ASCII)
    private val RNG = SecureRandom()

    class BackupException(val code: String) : IOException(code)

    class Header internal constructor(
        val flags: Int,
        val iterations: Int,
        val salt: ByteArray,
        internal val raw: ByteArray,
    )

    class Record internal constructor(val type: Int, val data: ByteArray)

    fun header(iterations: Int, salt: ByteArray): Header {
        require(salt.size == 16) { "salt" }
        val b = ByteBuffer.allocate(8 + 1 + 1 + 4 + 16)
        b.put(MAGIC).put(VERSION.toByte()).put(0.toByte()).putInt(iterations).put(salt)
        return Header(0, iterations, salt.clone(), b.array())
    }

    fun readHeader(input: InputStream): Header {
        val raw = readFully(input, 30)
        if (!raw.copyOf(8).contentEquals(MAGIC) || raw[8].toInt() != VERSION) throw BackupException(BAD_FILE)
        val flags = raw[9].toInt() and 0xff
        if (flags and FLAG_FACTOR.inv() != 0) throw BackupException(BAD_FILE)
        if (flags and FLAG_FACTOR != 0) throw BackupException(NEED_FACTOR)
        val iterations = ByteBuffer.wrap(raw, 10, 4).int
        if (iterations < 1 || iterations > 10_000_000) throw BackupException(BAD_FILE)
        return Header(flags, iterations, raw.copyOfRange(14, 30), raw)
    }

    internal fun readFully(input: InputStream, n: Int): ByteArray {
        val b = ByteArray(n)
        var o = 0
        while (o < n) {
            val r = input.read(b, o, n - o)
            if (r < 0) throw BackupException(BAD_FILE)
            o += r
        }
        return b
    }

    fun pbkdf2(password: ByteArray, salt: ByteArray, iterations: Int, length: Int): ByteArray {
        try {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(password, "HmacSHA256"))
            val out = ByteArray(length)
            val blocks = (length + 31) / 32
            for (i in 1..blocks) {
                mac.update(salt)
                var u = mac.doFinal(ByteBuffer.allocate(4).putInt(i).array())
                val t = u.clone()
                for (j in 1 until iterations) {
                    u = mac.doFinal(u)
                    for (k in t.indices) t[k] = (t[k].toInt() xor u[k].toInt()).toByte()
                }
                System.arraycopy(t, 0, out, (i - 1) * 32, minOf(32, length - (i - 1) * 32))
            }
            return out
        } catch (e: GeneralSecurityException) {
            throw IllegalStateException(e)
        }
    }

    private fun aad(headerHash: ByteArray, index: Long, last: Boolean): ByteArray =
        ByteBuffer.allocate(41).put(headerHash).putLong(index).put((if (last) 1 else 0).toByte()).array()

    private fun sha256(b: ByteArray): ByteArray =
        try {
            MessageDigest.getInstance("SHA-256").digest(b)
        } catch (e: GeneralSecurityException) {
            throw IllegalStateException(e)
        }

    class Writer(private val out: OutputStream, h: Header, private val key: ByteArray) : Closeable {
        private val headerHash: ByteArray = sha256(h.raw)
        private val buf = ByteArray(FRAME)
        private var n = 0
        private var index = 0L
        private var closed = false

        init {
            out.write(h.raw)
        }

        fun record(type: Int, data: ByteArray) {
            write(ByteBuffer.allocate(5).put(type.toByte()).putInt(data.size).array())
            write(data)
        }

        private fun write(b: ByteArray) {
            var o = 0
            while (o < b.size) {
                if (n == FRAME) frame(false)
                val c = minOf(FRAME - n, b.size - o)
                System.arraycopy(b, o, buf, n, c)
                n += c
                o += c
            }
        }

        private fun frame(last: Boolean) {
            try {
                val nonce = ByteArray(12)
                RNG.nextBytes(nonce)
                val c = Cipher.getInstance("AES/GCM/NoPadding")
                c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
                c.updateAAD(aad(headerHash, index, last))
                val ct = c.doFinal(buf, 0, n)
                out.write(ByteBuffer.allocate(4).putInt(12 + ct.size).array())
                out.write(nonce)
                out.write(ct)
            } catch (e: GeneralSecurityException) {
                throw IOException("encrypt")
            }
            index++
            n = 0
        }

        override fun close() {
            if (closed) return
            closed = true
            try {
                frame(true)
                out.flush()
            } finally {
                out.close()
            }
        }
    }

    class Reader(input: InputStream, h: Header, private val key: ByteArray) {
        private val input = PushbackInputStream(input, 1)
        private val headerHash: ByteArray = sha256(h.raw)
        private var cur = ByteArray(0)
        private var pos = 0
        private var index = 0L
        private var ended = false

        private fun open(frame: ByteArray, last: Boolean): ByteArray {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, frame, 0, 12))
            c.updateAAD(aad(headerHash, index, last))
            return c.doFinal(frame, 12, frame.size - 12)
        }

        private fun nextFrame() {
            val b0 = input.read()
            if (b0 < 0) throw BackupException(BAD_FILE)
            input.unread(b0)
            val len = ByteBuffer.wrap(readFully(input, 4)).int
            if (len < 28 || len > 12 + FRAME + 16) throw BackupException(BAD_FILE)
            val frame = readFully(input, len)
            val peek = input.read()
            val last = peek < 0
            if (!last) input.unread(peek)
            val pt = try {
                open(frame, last)
            } catch (e: GeneralSecurityException) {
                val other = try {
                    open(frame, !last)
                    true
                } catch (ignored: GeneralSecurityException) {
                    false
                }
                throw BackupException(if (index == 0L && !other) BAD_CODE else BAD_FILE)
            }
            cur = pt
            pos = 0
            ended = last
            index++
        }

        private fun ensure(need: Int): Boolean {
            while (cur.size - pos < need) {
                if (ended) return false
                val rest = cur.copyOfRange(pos, cur.size)
                nextFrame()
                if (rest.isNotEmpty()) cur = rest + cur
            }
            return true
        }

        fun next(): Record? {
            if (!ensure(1)) return null
            if (!ensure(5)) throw BackupException(BAD_FILE)
            val type = cur[pos].toInt() and 0xff
            val len = ByteBuffer.wrap(cur, pos + 1, 4).int
            if (len < 0 || len > MAX_RECORD) throw BackupException(BAD_FILE)
            pos += 5
            val bo = ByteArrayOutputStream(minOf(len, 1 shl 16))
            var left = len
            while (left > 0) {
                if (pos == cur.size && !ensure(1)) throw BackupException(BAD_FILE)
                val c = minOf(left, cur.size - pos)
                bo.write(cur, pos, c)
                pos += c
                left -= c
            }
            return Record(type, bo.toByteArray())
        }
    }
}
