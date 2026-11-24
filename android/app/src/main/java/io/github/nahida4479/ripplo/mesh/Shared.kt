package io.github.nahida4479.ripplo.mesh

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

internal object Shared {
    private const val KEY_ALIAS = "ripplo_db_wrap"
    private var signalStoreInstance: SignalFileStore? = null
    private var signalCoreInstance: SignalCore? = null
    private var nativeStoreInstance: NativeStore? = null
    private var cachedKey: ByteArray? = null

    private fun wrapKey(): SecretKey? {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        if (!ks.containsAlias(KEY_ALIAS)) {
            val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            kg.init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
            kg.generateKey()
        }
        return ks.getKey(KEY_ALIAS, null) as SecretKey?
    }

    @JvmStatic
    @Throws(Exception::class)
    fun wrapDbKey(key: ByteArray): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, wrapKey())
        val iv = c.iv
        val ct = c.doFinal(key)
        return Base64.encodeToString(iv + ct, Base64.NO_WRAP)
    }

    @JvmStatic
    @Synchronized
    @Throws(Exception::class)
    fun dbKey(ctx: Context): ByteArray {
        val cached = cachedKey
        if (cached != null) return cached.copyOf()
        val key = loadKey(ctx)
        cachedKey = key
        return key.copyOf()
    }

    @Throws(Exception::class)
    private fun loadKey(ctx: Context): ByteArray {
        val sp = ctx.getSharedPreferences("ripplo_keys", Context.MODE_PRIVATE)
        val stored = sp.getString("dbkey", null)
        if (stored == null) {
            val key = ByteArray(32)
            SecureRandom().nextBytes(key)
            sp.edit().putString("dbkey", wrapDbKey(key)).commit()
            return key
        }
        val blob = Base64.decode(stored, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, blob, 0, 12))
        return c.doFinal(blob, 12, blob.size - 12)
    }

    @JvmStatic
    @Synchronized
    @Throws(Exception::class)
    fun signalStore(ctx: Context): SignalFileStore {
        val existing = signalStoreInstance
        if (existing != null) return existing
        val store = SignalFileStore(ctx.filesDir, dbKey(ctx))
        signalStoreInstance = store
        return store
    }

    @JvmStatic
    @Synchronized
    @Throws(Exception::class)
    fun signal(ctx: Context): SignalCore {
        val existing = signalCoreInstance
        if (existing != null) return existing
        val core = SignalCore(signalStore(ctx))
        signalCoreInstance = core
        return core
    }

    @JvmStatic
    @Synchronized
    fun db(ctx: Context): NativeStore {
        val existing = nativeStoreInstance
        if (existing != null) return existing
        val store = NativeStore(ctx.applicationContext, "ripplo.db")
        nativeStoreInstance = store
        return store
    }

    @JvmStatic
    @Synchronized
    fun reset() {
        cachedKey = null
        signalStoreInstance = null
        signalCoreInstance = null
    }

    @JvmStatic
    @Throws(Exception::class)
    fun seal(key: ByteArray, plain: ByteArray, aad: String): ByteArray {
        val nonce = ByteArray(12)
        SecureRandom().nextBytes(nonce)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return nonce + c.doFinal(plain)
    }

    @JvmStatic
    @Throws(Exception::class)
    fun open(key: ByteArray, sealedBytes: ByteArray, aad: String): ByteArray {
        if (sealedBytes.size < 12 + 16) throw IllegalArgumentException("short")
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, sealedBytes, 0, 12))
        c.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return c.doFinal(sealedBytes, 12, sealedBytes.size - 12)
    }

    @JvmStatic
    fun row(ctx: Context, key: ByteArray, store: String, rowKey: String): JSONObject? {
        return try {
            val b64 = db(ctx).get(store, rowKey) ?: return null
            val plain = open(key, Base64.decode(b64, Base64.NO_WRAP), "$store/$rowKey")
            JSONObject(String(plain, Charsets.UTF_8))
        } catch (e: Exception) {
            null
        }
    }
}
