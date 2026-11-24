package io.github.nahida4479.ripplo.mesh

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.InvalidKeyIdException
import org.signal.libsignal.protocol.NoSessionException
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.UntrustedIdentityException
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.fingerprint.NumericFingerprintGenerator
import org.signal.libsignal.protocol.kdf.HKDF
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.kem.KEMPublicKey
import org.signal.libsignal.protocol.message.CiphertextMessage
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SignalMessage
import org.signal.libsignal.protocol.state.IdentityKeyStore
import org.signal.libsignal.protocol.state.IdentityKeyStore.Direction
import org.signal.libsignal.protocol.state.IdentityKeyStore.IdentityChange
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.KyberPreKeyStore
import org.signal.libsignal.protocol.state.PreKeyBundle
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyStore
import org.signal.libsignal.protocol.state.SessionRecord
import org.signal.libsignal.protocol.state.SessionStore
import org.signal.libsignal.protocol.state.SignedPreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyStore

class SignalCore(private val storage: Storage) {
    interface Storage {
        fun get(key: String): ByteArray?
        fun put(key: String, value: ByteArray)
        fun delete(key: String)
    }

    class Failed internal constructor(message: String?, val tag: ByteArray) : IllegalArgumentException(message)

    class Opened internal constructor(val tag: ByteArray, val ik: ByteArray, val plaintext: ByteArray)

    private val store = Store()
    private lateinit var identity: IdentityKeyPair
    private var registrationId = 0
    private lateinit var myTag: ByteArray
    private lateinit var localAddress: SignalProtocolAddress

    private fun addr(tag: ByteArray?): SignalProtocolAddress {
        if (tag == null || tag.size != 16) throw IllegalArgumentException(BAD_MESSAGE)
        return SignalProtocolAddress(hex(tag), 1)
    }

    private fun cipher(remote: SignalProtocolAddress) = SessionCipher(store, store, store, store, store, localAddress, remote)

    private fun ensure() {
        if (::identity.isInitialized) return
        var raw = storage.get("identity")
        if (raw == null) {
            val ikp = IdentityKeyPair.generate()
            val priv = ikp.privateKey
            val now = System.currentTimeMillis()
            val spk = ECKeyPair.generate()
            val spr = SignedPreKeyRecord(1, now, spk, priv.calculateSignature(spk.publicKey.serialize()))
            val kem = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
            val kpr = KyberPreKeyRecord(1, now, kem, priv.calculateSignature(kem.publicKey.serialize()))
            storage.put("spk:1", spr.serialize())
            storage.put("kyber:1", kpr.serialize())
            storage.put("regid", ByteBuffer.allocate(4).putInt(1 + RNG.nextInt(16380)).array())
            storage.put("identity", ikp.serialize())
            raw = ikp.serialize()
        }
        identity = IdentityKeyPair(raw)
        registrationId = ByteBuffer.wrap(storage.get("regid")).getInt()
        myTag = tagOf(identity.publicKey.serialize())
        localAddress = SignalProtocolAddress(hex(myTag), 1)
    }

    @Synchronized
    @Throws(Exception::class)
    fun init(): ByteArray {
        ensure()
        val spr = SignedPreKeyRecord(storage.get("spk:1"))
        val kpr = KyberPreKeyRecord(storage.get("kyber:1"))
        val b = ByteBuffer.allocate(BUNDLE_LEN)
        b.put(2.toByte()).putInt(registrationId).put(identity.publicKey.serialize())
        b.putInt(spr.id).put(spr.keyPair.publicKey.serialize()).put(spr.signature)
        b.putInt(kpr.id).put(kpr.keyPair.publicKey.serialize()).put(kpr.signature)
        if (b.position() != BUNDLE_LEN) throw IllegalStateException()
        return b.array()
    }

    @Synchronized
    @Throws(Exception::class)
    fun identityKey(): ByteArray {
        ensure()
        return identity.publicKey.serialize()
    }

    @Synchronized
    @Throws(Exception::class)
    fun addContact(bundle: ByteArray?): ByteArray {
        ensure()
        try {
            if (bundle == null || bundle.size != BUNDLE_LEN || bundle[0] != 2.toByte()) throw IllegalArgumentException()
            val b = ByteBuffer.wrap(bundle)
            b.get()
            val reg = b.getInt()
            val ikRaw = ByteArray(33)
            b.get(ikRaw)
            val spkId = b.getInt()
            val spkRaw = ByteArray(33)
            b.get(spkRaw)
            val spkSig = ByteArray(64)
            b.get(spkSig)
            val kId = b.getInt()
            val kRaw = ByteArray(KYBER_PUB_LEN)
            b.get(kRaw)
            val kSig = ByteArray(64)
            b.get(kSig)
            val tag = tagOf(ikRaw)
            if (tag.contentEquals(myTag)) throw IllegalArgumentException()
            val pb = PreKeyBundle(
                reg, 1, PreKeyBundle.NULL_PRE_KEY_ID, null, spkId,
                ECPublicKey(spkRaw), spkSig, IdentityKey(ikRaw), kId, KEMPublicKey(kRaw), kSig
            )
            SessionBuilder(store, store, store, store, addr(tag), localAddress).process(pb)
            return tag
        } catch (e: Exception) {
            throw IllegalArgumentException(BAD_BUNDLE)
        }
    }

    @Synchronized
    @Throws(Exception::class)
    fun seal(tag: ByteArray?, plaintext: ByteArray?): ByteArray {
        ensure()
        val remote = addr(tag)
        val rik = store.getIdentity(remote) ?: throw IllegalArgumentException(NO_SESSION)
        val msg = try {
            cipher(remote).encrypt(plaintext)
        } catch (e: NoSessionException) {
            throw IllegalArgumentException(NO_SESSION)
        } catch (e: UntrustedIdentityException) {
            throw IllegalArgumentException(UNTRUSTED)
        }
        val inner = concat(byteArrayOf(2), myTag, byteArrayOf(msg.type.toByte()), msg.serialize())
        val eph = ECKeyPair.generate()
        val shared = eph.privateKey.calculateAgreement(rik.publicKey)
        val key = HKDF.deriveSecrets(shared, tag!!, SEALED_INFO, 32)
        val nonce = ByteArray(12)
        RNG.nextBytes(nonce)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return concat(byteArrayOf(1), eph.publicKey.publicKeyBytes, nonce, c.doFinal(inner))
    }

    @Synchronized
    @Throws(Exception::class)
    fun open(sealed: ByteArray?): Opened {
        ensure()
        val inner = try {
            if (sealed == null || sealed.size < 1 + 32 + 12 + 16 || sealed[0] != 1.toByte()) throw IllegalArgumentException()
            val eph = ECPublicKey.fromPublicKeyBytes(sealed.copyOfRange(1, 33))
            val shared = identity.privateKey.calculateAgreement(eph)
            val key = HKDF.deriveSecrets(shared, myTag, SEALED_INFO, 32)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, sealed, 33, 12))
            c.doFinal(sealed, 45, sealed.size - 45)
        } catch (e: Exception) {
            throw IllegalArgumentException(BAD_MESSAGE)
        }
        if (inner.size < 19 || inner[0] != 2.toByte()) throw IllegalArgumentException(BAD_MESSAGE)
        val tag = inner.copyOfRange(1, 17)
        val type = inner[17].toInt() and 0xff
        val body = inner.copyOfRange(18, inner.size)
        val remote = addr(tag)
        val sc = cipher(remote)
        val (ik, plain) = try {
            when (type) {
                CiphertextMessage.PREKEY_TYPE -> {
                    val pm = PreKeySignalMessage(body)
                    val senderIk = pm.identityKey.serialize()
                    if (!tagOf(senderIk).contentEquals(tag)) throw IllegalArgumentException(BAD_MESSAGE)
                    senderIk to sc.decrypt(pm)
                }
                CiphertextMessage.WHISPER_TYPE -> {
                    val decrypted = sc.decrypt(SignalMessage(body))
                    val known = store.getIdentity(remote) ?: throw IllegalArgumentException(NO_SESSION)
                    known.serialize() to decrypted
                }
                else -> throw IllegalArgumentException(BAD_MESSAGE)
            }
        } catch (e: IllegalArgumentException) {
            throw Failed(e.message, tag)
        } catch (e: NoSessionException) {
            throw Failed(NO_SESSION, tag)
        } catch (e: UntrustedIdentityException) {
            throw Failed(UNTRUSTED, tag)
        } catch (e: Exception) {
            throw Failed(BAD_MESSAGE, tag)
        }
        return Opened(tag, ik, plain)
    }

    @Synchronized
    @Throws(Exception::class)
    fun proof(otherIk33: ByteArray?, n: ByteArray?, challengerTag: ByteArray?, proverTag: ByteArray?): ByteArray {
        ensure()
        try {
            val shared = identity.privateKey.calculateAgreement(ECPublicKey(otherIk33!!))
            val k = HKDF.deriveSecrets(shared, n!!, PROOF_INFO, 32)
            val m = Mac.getInstance("HmacSHA256")
            m.init(SecretKeySpec(k, "HmacSHA256"))
            for (p in arrayOf(PROOF_INFO, n, challengerTag, proverTag)) m.update(p)
            return m.doFinal()
        } catch (e: Exception) {
            throw IllegalArgumentException(BAD_MESSAGE)
        }
    }

    @Synchronized
    @Throws(Exception::class)
    fun safetyNumber(theirIk33: ByteArray?): String {
        ensure()
        try {
            val theirs = IdentityKey(theirIk33)
            return NumericFingerprintGenerator(5200)
                .createFor(1, myTag, identity.publicKey, tagOf(theirIk33!!), theirs)
                .displayableFingerprint.displayText
        } catch (e: Exception) {
            throw IllegalArgumentException(BAD_MESSAGE)
        }
    }

    @Synchronized
    @Throws(Exception::class)
    fun forget(tag: ByteArray?) {
        ensure()
        if (tag == null || tag.size != 16) throw IllegalArgumentException(BAD_MESSAGE)
        val h = hex(tag)
        storage.delete("session:$h")
        storage.delete("ident:$h")
    }

    private inner class Store : IdentityKeyStore, SessionStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore {
        override fun getIdentityKeyPair(): IdentityKeyPair = identity

        override fun getLocalRegistrationId(): Int = registrationId

        private fun tagMatches(a: SignalProtocolAddress, ik: IdentityKey) = hex(tagOf(ik.serialize())) == a.name

        override fun saveIdentity(a: SignalProtocolAddress, ik: IdentityKey): IdentityChange {
            if (!tagMatches(a, ik)) return IdentityChange.NEW_OR_UNCHANGED
            val old = storage.get("ident:" + a.name)
            val now = ik.serialize()
            if (old != null && old.contentEquals(now)) return IdentityChange.NEW_OR_UNCHANGED
            storage.put("ident:" + a.name, now)
            return if (old == null) IdentityChange.NEW_OR_UNCHANGED else IdentityChange.REPLACED_EXISTING
        }

        override fun isTrustedIdentity(a: SignalProtocolAddress, ik: IdentityKey, d: Direction) = tagMatches(a, ik)

        override fun getIdentity(a: SignalProtocolAddress): IdentityKey? {
            val raw = storage.get("ident:" + a.name) ?: return null
            try {
                return IdentityKey(raw)
            } catch (e: Exception) {
                throw IllegalStateException(e)
            }
        }

        override fun loadSession(a: SignalProtocolAddress): SessionRecord {
            val raw = storage.get("session:" + a.name) ?: return SessionRecord()
            try {
                return SessionRecord(raw)
            } catch (e: Exception) {
                throw IllegalStateException(e)
            }
        }

        override fun loadExistingSessions(addresses: List<SignalProtocolAddress>): List<SessionRecord> =
            addresses.map { a ->
                if (storage.get("session:" + a.name) == null) throw NoSessionException("no session for " + a.name)
                loadSession(a)
            }

        override fun getSubDeviceSessions(name: String): List<Int> = emptyList()

        override fun storeSession(a: SignalProtocolAddress, r: SessionRecord) {
            storage.put("session:" + a.name, r.serialize())
        }

        override fun containsSession(a: SignalProtocolAddress) = storage.get("session:" + a.name) != null

        override fun deleteSession(a: SignalProtocolAddress) {
            storage.delete("session:" + a.name)
        }

        override fun deleteAllSessions(name: String) {
            storage.delete("session:$name")
        }

        override fun loadPreKey(id: Int): PreKeyRecord = throw InvalidKeyIdException("no one-time prekeys")

        override fun storePreKey(id: Int, r: PreKeyRecord) {}

        override fun containsPreKey(id: Int) = false

        override fun removePreKey(id: Int) {}

        override fun loadSignedPreKey(id: Int): SignedPreKeyRecord {
            val raw = (if (id == 1) storage.get("spk:1") else null) ?: throw InvalidKeyIdException("unknown signed prekey")
            try {
                return SignedPreKeyRecord(raw)
            } catch (e: Exception) {
                throw InvalidKeyIdException(e)
            }
        }

        override fun loadSignedPreKeys(): List<SignedPreKeyRecord> =
            try {
                listOf(loadSignedPreKey(1))
            } catch (e: InvalidKeyIdException) {
                emptyList()
            }

        override fun storeSignedPreKey(id: Int, r: SignedPreKeyRecord) {
            if (id == 1) storage.put("spk:1", r.serialize())
        }

        override fun containsSignedPreKey(id: Int) = id == 1 && storage.get("spk:1") != null

        override fun removeSignedPreKey(id: Int) {}

        override fun loadKyberPreKey(id: Int): KyberPreKeyRecord {
            val raw = (if (id == 1) storage.get("kyber:1") else null) ?: throw InvalidKeyIdException("unknown kyber prekey")
            try {
                return KyberPreKeyRecord(raw)
            } catch (e: Exception) {
                throw InvalidKeyIdException(e)
            }
        }

        override fun loadKyberPreKeys(): List<KyberPreKeyRecord> =
            try {
                listOf(loadKyberPreKey(1))
            } catch (e: InvalidKeyIdException) {
                emptyList()
            }

        override fun storeKyberPreKey(id: Int, r: KyberPreKeyRecord) {
            if (id == 1) storage.put("kyber:1", r.serialize())
        }

        override fun containsKyberPreKey(id: Int) = id == 1 && storage.get("kyber:1") != null

        override fun markKyberPreKeyUsed(kyberId: Int, signedId: Int, baseKey: ECPublicKey) {}
    }

    companion object {
        const val BAD_BUNDLE = "bad_bundle"
        const val NO_SESSION = "no_session"
        const val BAD_MESSAGE = "bad_message"
        const val UNTRUSTED = "untrusted_identity"

        private const val BUNDLE_LEN = 1776
        private const val KYBER_PUB_LEN = 1569
        private val SEALED_INFO = "ripplo-sealed-v2".toByteArray(Charsets.UTF_8)
        private val PROOF_INFO = "ripplo-proof-v1".toByteArray(Charsets.UTF_8)
        private val RNG = SecureRandom()

        fun hex(b: ByteArray): String {
            val sb = StringBuilder(b.size * 2)
            for (x in b) sb.append(Character.forDigit((x.toInt() shr 4) and 15, 16)).append(Character.forDigit(x.toInt() and 15, 16))
            return sb.toString()
        }

        fun unhex(s: String?): ByteArray {
            if (s == null || s.length % 2 != 0) throw IllegalArgumentException(BAD_MESSAGE)
            return ByteArray(s.length / 2) { i ->
                val hi = Character.digit(s[i * 2], 16)
                val lo = Character.digit(s[i * 2 + 1], 16)
                if (hi < 0 || lo < 0) throw IllegalArgumentException(BAD_MESSAGE)
                (hi shl 4 or lo).toByte()
            }
        }

        private fun sha256(b: ByteArray): ByteArray =
            try {
                MessageDigest.getInstance("SHA-256").digest(b)
            } catch (e: Exception) {
                throw IllegalStateException(e)
            }

        private fun tagOf(ik33: ByteArray) = sha256(ik33).copyOf(16)

        private fun concat(vararg parts: ByteArray): ByteArray {
            val out = ByteArray(parts.sumOf { it.size })
            var o = 0
            for (p in parts) {
                System.arraycopy(p, 0, out, o, p.size)
                o += p.size
            }
            return out
        }
    }
}
