package io.github.nahida4479.ripplo.mesh

import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class SignalFileStore private constructor(private val dir: File, private val key: SecretKeySpec) : SignalCore.Storage {
    constructor(filesDir: File, dbKey: ByteArray) : this(File(filesDir, "signal").apply { mkdirs() }, SecretKeySpec(dbKey, "AES"))

    companion object {
        private const val INDEX = "names.idx"
        private const val INDEX_AAD = "\u0000names"
        private val FIXED = listOf("identity", "regid", "spk:1", "kyber:1")

        @JvmStatic
        fun at(dir: File, dbKey: ByteArray): SignalFileStore =
            SignalFileStore(dir.apply { mkdirs() }, SecretKeySpec(dbKey, "AES"))
    }

    private val rng = SecureRandom()
    private var names: MutableSet<String>? = null

    private fun file(name: String): File {
        try {
            val h = MessageDigest.getInstance("SHA-256").digest(name.toByteArray(Charsets.UTF_8))
            return File(dir, SignalCore.hex(h))
        } catch (e: Exception) {
            throw IllegalStateException(e)
        }
    }

    private fun read(f: File, aad: String): ByteArray =
        DataInputStream(FileInputStream(f)).use { input ->
            val blob = ByteArray(f.length().toInt())
            input.readFully(blob)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, blob, 0, 12))
            c.updateAAD(aad.toByteArray(Charsets.UTF_8))
            c.doFinal(blob, 12, blob.size - 12)
        }

    private fun write(f: File, aad: String, value: ByteArray) {
        val tmp = File(dir, f.name + ".tmp")
        try {
            val nonce = ByteArray(12)
            rng.nextBytes(nonce)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce))
            c.updateAAD(aad.toByteArray(Charsets.UTF_8))
            val ct = c.doFinal(value)
            FileOutputStream(tmp).use { out ->
                out.write(nonce)
                out.write(ct)
                out.fd.sync()
            }
            if (!tmp.renameTo(f)) throw IllegalStateException("storage")
        } catch (e: Exception) {
            tmp.delete()
            throw e
        }
    }

    private fun index(): MutableSet<String> {
        var set = names
        if (set == null) {
            set = LinkedHashSet()
            names = set
            val f = File(dir, INDEX)
            if (f.exists()) {
                val s = String(read(f, INDEX_AAD), Charsets.UTF_8)
                for (n in s.split("\n")) if (n.isNotEmpty()) set.add(n)
            }
        }
        return set
    }

    private fun saveIndex(set: Set<String>) {
        write(File(dir, INDEX), INDEX_AAD, set.joinToString("\n").toByteArray(Charsets.UTF_8))
    }

    @Synchronized
    override fun get(name: String): ByteArray? {
        val f = file(name)
        if (!f.exists()) return null
        try {
            return read(f, name)
        } catch (e: Exception) {
            throw IllegalStateException("storage")
        }
    }

    @Synchronized
    override fun put(name: String, value: ByteArray) {
        try {
            write(file(name), name, value)
            val set = index()
            if (set.add(name)) saveIndex(set)
        } catch (e: Exception) {
            throw IllegalStateException("storage")
        }
    }

    @Synchronized
    override fun delete(name: String) {
        file(name).delete()
        try {
            val set = index()
            if (set.remove(name)) saveIndex(set)
        } catch (e: Exception) {
            throw IllegalStateException("storage")
        }
    }

    @Synchronized
    fun names(): List<String> = try {
        val all = LinkedHashSet(index())
        all.addAll(FIXED)
        all.filter { file(it).exists() }
    } catch (e: Exception) {
        throw IllegalStateException("storage")
    }
}
