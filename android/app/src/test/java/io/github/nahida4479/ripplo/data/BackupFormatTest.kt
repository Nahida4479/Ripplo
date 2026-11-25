package io.github.nahida4479.ripplo.data

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class BackupFormatTest {
    private fun hexb(s: String): ByteArray =
        ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }

    private fun write(recs: List<ByteArray>): ByteArray {
        val bo = ByteArrayOutputStream()
        BackupFormat.Writer(bo, BackupFormat.header(3, SALT), KEY).use { w ->
            recs.forEachIndexed { i, r -> w.record(i % 5 + 1, r) }
        }
        return bo.toByteArray()
    }

    private fun read(file: ByteArray, key: ByteArray): List<BackupFormat.Record> {
        val input = ByteArrayInputStream(file)
        val r = BackupFormat.Reader(input, BackupFormat.readHeader(input), key)
        val out = ArrayList<BackupFormat.Record>()
        while (true) out.add(r.next() ?: break)
        return out
    }

    private fun codeOf(file: ByteArray, key: ByteArray): String? =
        try {
            read(file, key)
            null
        } catch (e: BackupFormat.BackupException) {
            e.code
        } catch (e: IOException) {
            "io"
        }

    private fun frameLen(file: ByteArray, off: Int): Int =
        (file[off].toInt() and 0xff shl 24) or (file[off + 1].toInt() and 0xff shl 16) or
            (file[off + 2].toInt() and 0xff shl 8) or (file[off + 3].toInt() and 0xff)

    @Test
    fun pbkdf2Vectors() {
        assertArrayEquals(
            hexb("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
            BackupFormat.pbkdf2("password".toByteArray(), "salt".toByteArray(), 1, 32),
        )
        assertArrayEquals(
            hexb("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
            BackupFormat.pbkdf2("password".toByteArray(), "salt".toByteArray(), 2, 32),
        )
    }

    @Test
    fun roundtripSpansFrames() {
        val rnd = Random(1)
        val recs = List(48) {
            ByteArray(64 * 1024 + rnd.nextInt(1000)).also { rnd.nextBytes(it) }
        }
        val file = write(recs)
        val got = read(file, KEY)
        assertEquals(recs.size, got.size)
        for (i in recs.indices) {
            assertEquals(i % 5 + 1, got[i].type)
            assertArrayEquals(recs[i], got[i].data)
        }
    }

    @Test
    fun emptyAndHugeRecord() {
        val big = ByteArray(BackupFormat.FRAME + 5)
        Random(2).nextBytes(big)
        val got = read(write(listOf(ByteArray(0), big)), KEY)
        assertEquals(2, got.size)
        assertEquals(0, got[0].data.size)
        assertArrayEquals(big, got[1].data)
    }

    @Test
    fun wrongCodeRejected() {
        val file = write(listOf(ByteArray(100)))
        val other = BackupFormat.pbkdf2("000000000000000000000000000000".toByteArray(), SALT, 3, 32)
        assertEquals(BackupFormat.BAD_CODE, codeOf(file, other))
    }

    @Test
    fun truncatedLastFrameRejected() {
        val b = ByteArray(3 * BackupFormat.FRAME)
        Random(3).nextBytes(b)
        val file = write(listOf(b))
        var off = 30
        var frames = 0
        val ends = ArrayList<Int>()
        while (off < file.size) {
            off += 4 + frameLen(file, off)
            ends.add(off)
            frames++
        }
        assertEquals(4, frames)
        assertNull(codeOf(file, KEY))
        assertEquals(BackupFormat.BAD_FILE, codeOf(file.copyOf(ends[2]), KEY))
        assertEquals(BackupFormat.BAD_FILE, codeOf(file.copyOf(ends[0]), KEY))
        assertEquals(BackupFormat.BAD_FILE, codeOf(file.copyOf(file.size - 1), KEY))
    }

    @Test
    fun tamperAndHeaderBindingRejected() {
        val file = write(listOf(ByteArray(1000)))
        val flipped = file.clone()
        flipped[flipped.size - 20] = (flipped[flipped.size - 20].toInt() xor 1).toByte()
        assertNotNull(codeOf(flipped, KEY))
        val hdr = file.clone()
        hdr[20] = (hdr[20].toInt() xor 1).toByte()
        assertNotNull(codeOf(hdr, KEY))
        val factor = file.clone()
        factor[9] = 1
        assertEquals(BackupFormat.NEED_FACTOR, codeOf(factor, KEY))
        try {
            read(ByteArray(10), KEY)
            fail()
        } catch (e: BackupFormat.BackupException) {
            assertEquals(BackupFormat.BAD_FILE, e.code)
        }
    }

    @Test
    fun reorderedFramesRejected() {
        val b = ByteArray(2 * BackupFormat.FRAME + 10)
        val file = write(listOf(b))
        val l0 = 4 + frameLen(file, 30)
        val s1 = 30 + l0
        val l1 = 4 + frameLen(file, s1)
        val sw = ByteArray(file.size)
        System.arraycopy(file, 0, sw, 0, 30)
        System.arraycopy(file, s1, sw, 30, l1)
        System.arraycopy(file, 30, sw, 30 + l1, l0)
        System.arraycopy(file, s1 + l1, sw, 30 + l1 + l0, file.size - s1 - l1)
        assertNotNull(codeOf(sw, KEY))
    }

    companion object {
        private val SALT = ByteArray(16)
        private val KEY = BackupFormat.pbkdf2("123456789012345678901234567890".toByteArray(), SALT, 3, 32)
    }
}
