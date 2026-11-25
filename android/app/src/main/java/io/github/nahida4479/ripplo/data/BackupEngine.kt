package io.github.nahida4479.ripplo.data

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.github.nahida4479.ripplo.crypto.SignalFileStore
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class BackupEngine(ctx: Context) {
    internal class Secrets(val code: String, val salt: ByteArray, val key: ByteArray)

    internal class Staged(val rows: NativeStore) {
        var meta: String? = null
        var dbKey: ByteArray? = null
        val signal: MutableMap<String, ByteArray> = LinkedHashMap()
    }

    private val ctx: Context = ctx.applicationContext
    private val rng = SecureRandom()

    fun prefs(): SharedPreferences = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun enabled(): Boolean = prefs().getString("wrapped", null) != null

    private fun wrapKey(): SecretKey? {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        if (!ks.containsAlias(ALIAS)) {
            val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            kg.init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
            kg.generateKey()
        }
        return ks.getKey(ALIAS, null) as SecretKey?
    }

    fun enable(): String {
        val code = buildString { repeat(CODE_DIGITS) { append(rng.nextInt(10)) } }
        val salt = ByteArray(16)
        rng.nextBytes(salt)
        val key = BackupFormat.pbkdf2(code.toByteArray(StandardCharsets.US_ASCII), salt, ITERATIONS, 32)
        val plain = ByteBuffer.allocate(CODE_DIGITS + 16 + 32)
            .put(code.toByteArray(StandardCharsets.US_ASCII)).put(salt).put(key).array()
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, wrapKey())
        val blob = c.iv + c.doFinal(plain)
        prefs().edit().putString("wrapped", Base64.encodeToString(blob, Base64.NO_WRAP)).remove("lastAt").commit()
        return code
    }

    fun secrets(): Secrets? {
        val s = prefs().getString("wrapped", null) ?: return null
        val blob = Base64.decode(s, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, blob, 0, 12))
        val p = c.doFinal(blob, 12, blob.size - 12)
        return Secrets(
            String(p, 0, CODE_DIGITS, StandardCharsets.US_ASCII),
            p.copyOfRange(CODE_DIGITS, CODE_DIGITS + 16),
            p.copyOfRange(CODE_DIGITS + 16, p.size),
        )
    }

    fun write(out: OutputStream, meta: String, dbKey: ByteArray, s: Secrets, signal: SignalFileStore, rows: NativeStore) {
        BackupFormat.Writer(out, BackupFormat.header(ITERATIONS, s.salt), s.key).use { w ->
            w.record(1, meta.toByteArray(StandardCharsets.UTF_8))
            w.record(2, dbKey)
            for (name in signal.names()) {
                val v = signal.get(name) ?: continue
                val k = name.toByteArray(StandardCharsets.UTF_8)
                w.record(3, ByteBuffer.allocate(2 + k.size + v.size).putShort(k.size.toShort()).put(k).put(v).array())
            }
            rows.forEachRow { store, key, idx, value ->
                val a = store.toByteArray(StandardCharsets.UTF_8)
                val b = key.toByteArray(StandardCharsets.UTF_8)
                val i = idx?.toByteArray(StandardCharsets.UTF_8)
                val bb = ByteBuffer.allocate(6 + a.size + b.size + (i?.size ?: 0) + value.size)
                bb.putShort(a.size.toShort()).put(a).putShort(b.size.toShort()).put(b)
                    .putShort((i?.size ?: 0xFFFF).toShort())
                if (i != null) bb.put(i)
                w.record(4, bb.put(value).array())
            }
        }
    }

    fun stage(input: InputStream, code: String): Staged {
        val digits = code.filter { it in '0'..'9' }
        if (digits.length != CODE_DIGITS) throw BackupFormat.BackupException(BackupFormat.BAD_CODE)
        val h = BackupFormat.readHeader(input)
        val key = BackupFormat.pbkdf2(digits.toByteArray(StandardCharsets.US_ASCII), h.salt, h.iterations, 32)
        val r = BackupFormat.Reader(input, h, key)
        ctx.deleteDatabase(STAGING_DB)
        val st = Staged(NativeStore(ctx, STAGING_DB))
        try {
            st.rows.writableDatabase.beginTransaction()
            while (true) {
                val rec = r.next() ?: break
                when {
                    rec.type == 1 && st.meta == null -> st.meta = String(rec.data, StandardCharsets.UTF_8)
                    rec.type == 2 && st.dbKey == null && rec.data.size == 32 -> st.dbKey = rec.data
                    rec.type == 3 -> {
                        val b = ByteBuffer.wrap(rec.data)
                        val name = str(b)
                        if (name.isEmpty()) throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
                        st.signal[name] = take(b, b.remaining())
                    }
                    rec.type == 4 -> {
                        val b = ByteBuffer.wrap(rec.data)
                        val store = str(b)
                        val k = str(b)
                        if (b.remaining() < 2) throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
                        val il = b.short.toInt() and 0xffff
                        val idx = if (il == 0xFFFF) null else String(take(b, il), StandardCharsets.UTF_8)
                        st.rows.put(store, k, idx, take(b, b.remaining()))
                    }
                    else -> throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
                }
            }
            if (st.meta == null || st.dbKey == null) throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
            st.rows.writableDatabase.setTransactionSuccessful()
            st.rows.writableDatabase.endTransaction()
            return st
        } catch (e: Exception) {
            discard(st)
            throw e
        }
    }

    fun discard(st: Staged) {
        try {
            st.rows.close()
        } catch (ignored: RuntimeException) {
        }
        ctx.deleteDatabase(STAGING_DB)
    }

    companion object {
        const val ITERATIONS = 600000
        const val STAGING_DB = "restore-staging.db"
        private const val ALIAS = "ripplo_backup_wrap"
        private const val PREFS = "ripplo_backup"
        private const val CODE_DIGITS = 30

        private fun take(b: ByteBuffer, len: Int): ByteArray {
            if (len < 0 || len > b.remaining()) throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
            val o = ByteArray(len)
            b.get(o)
            return o
        }

        private fun str(b: ByteBuffer): String {
            if (b.remaining() < 2) throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
            return String(take(b, b.short.toInt() and 0xffff), StandardCharsets.UTF_8)
        }
    }
}
