package io.github.nahida4479.ripplo.mesh

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.kdf.HKDF

class SignalCoreTest {
    private class Mem : SignalCore.Storage {
        val m = HashMap<String, ByteArray>()

        override fun get(key: String): ByteArray? = m[key]

        override fun put(key: String, value: ByteArray) {
            m[key] = value
        }

        override fun delete(key: String) {
            m.remove(key)
        }
    }

    private lateinit var alice: SignalCore
    private lateinit var bob: SignalCore
    private lateinit var aliceBundle: ByteArray
    private lateinit var bobBundle: ByteArray
    private lateinit var aliceIk: ByteArray
    private lateinit var bobIk: ByteArray
    private lateinit var aliceTag: ByteArray
    private lateinit var bobTag: ByteArray

    @Before
    fun setUp() {
        alice = SignalCore(Mem())
        bob = SignalCore(Mem())
        aliceBundle = alice.init()
        bobBundle = bob.init()
        aliceIk = alice.identityKey()
        bobIk = bob.identityKey()
        aliceTag = tagOf(aliceIk)
        bobTag = tagOf(bobIk)
    }

    @Test
    fun bundleShape() {
        assertEquals(1776, aliceBundle.size)
        assertEquals(2, aliceBundle[0].toInt())
        assertArrayEquals(aliceBundle, alice.init())
        assertArrayEquals(aliceIk, aliceBundle.copyOfRange(5, 38))
    }

    @Test
    fun conversation() {
        assertArrayEquals(bobTag, alice.addContact(bobBundle))

        val first = alice.seal(bobTag, utf8("hello bob"))
        assertEquals(1, first[0].toInt())
        val o = bob.open(first)
        assertArrayEquals(aliceTag, o.tag)
        assertArrayEquals(aliceIk, o.ik)
        assertArrayEquals(utf8("hello bob"), o.plaintext)

        val reply = bob.seal(aliceTag, utf8("hello alice"))
        val r = alice.open(reply)
        assertArrayEquals(bobTag, r.tag)
        assertArrayEquals(bobIk, r.ik)
        assertArrayEquals(utf8("hello alice"), r.plaintext)

        for (i in 0 until 5) {
            val a = "a$i"
            val b = "b$i"
            assertArrayEquals(utf8(a), bob.open(alice.seal(bobTag, utf8(a))).plaintext)
            assertArrayEquals(utf8(b), alice.open(bob.seal(aliceTag, utf8(b))).plaintext)
        }
    }

    @Test
    fun tamperedSealedRejected() {
        alice.addContact(bobBundle)
        val sealed = alice.seal(bobTag, utf8("x"))
        sealed[sealed.size - 1] = (sealed[sealed.size - 1].toInt() xor 1).toByte()
        expectCode("bad_message") { bob.open(sealed) }
    }

    @Test
    fun swappedKyberSignatureRejected() {
        val mallory = SignalCore(Mem())
        val mb = mallory.init()
        val forged = bobBundle.clone()
        System.arraycopy(mb, 1776 - 64, forged, 1776 - 64, 64)
        expectCode("bad_bundle") { alice.addContact(forged) }
        expectCode("bad_bundle") { alice.addContact(bobBundle.copyOf(1775)) }
    }

    @Test
    fun proofMatchesSpec() {
        val n = ByteArray(32) { 7 }
        val fromAlice = alice.proof(bobIk, n, aliceTag, bobTag)
        val fromBob = bob.proof(aliceIk, n, aliceTag, bobTag)
        assertArrayEquals(fromAlice, fromBob)
        assertEquals(32, fromAlice.size)

        assertNotEquals(fromAlice.contentToString(), alice.proof(bobIk, n, bobTag, aliceTag).contentToString())
    }

    @Test
    fun proofIndependentComputation() {
        val bobMem = Mem()
        val b = SignalCore(bobMem)
        val ik = b.identityKey()
        val n = ByteArray(32) { 9 }
        val expected = referenceProof(bobMem, aliceIk, n, aliceTag, tagOf(ik))
        assertArrayEquals(expected, b.proof(aliceIk, n, aliceTag, tagOf(ik)))
    }

    @Test
    fun safetyNumbers() {
        val a = alice.safetyNumber(bobIk)
        val b = bob.safetyNumber(aliceIk)
        assertEquals(a, b)
        assertEquals(60, a.length)
        assertEquals(60, a.replace(Regex("[^0-9]"), "").length)
    }

    @Test
    fun noSessionAndForget() {
        expectCode("no_session") { alice.seal(bobTag, utf8("x")) }
        alice.addContact(bobBundle)
        alice.seal(bobTag, utf8("x"))
        alice.forget(bobTag)
        expectCode("no_session") { alice.seal(bobTag, utf8("x")) }
    }

    @Test
    fun persistsAcrossInstances() {
        val mem = Mem()
        val a1 = SignalCore(mem)
        val b1 = a1.init()
        a1.addContact(bobBundle)
        val sealed = a1.seal(bobTag, utf8("p"))
        val a2 = SignalCore(mem)
        assertArrayEquals(b1, a2.init())
        assertArrayEquals(utf8("p"), bob.open(sealed).plaintext)
        assertArrayEquals(utf8("q"), bob.open(a2.seal(bobTag, utf8("q"))).plaintext)
    }

    private companion object {
        fun tagOf(ik: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(ik).copyOf(16)

        fun utf8(s: String) = s.toByteArray(Charsets.UTF_8)

        fun expectCode(code: String, c: () -> Unit) {
            try {
                c()
                fail("expected $code")
            } catch (e: IllegalArgumentException) {
                assertEquals(code, e.message)
            }
        }

        fun referenceProof(mem: Mem, otherIk: ByteArray, n: ByteArray, ct: ByteArray, pt: ByteArray): ByteArray {
            val kp = IdentityKeyPair(mem.get("identity"))
            val shared = kp.privateKey.calculateAgreement(ECPublicKey(otherIk))
            val info = utf8("ripplo-proof-v1")
            val k = HKDF.deriveSecrets(shared, n, info, 32)
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(k, "HmacSHA256"))
            mac.update(info)
            mac.update(n)
            mac.update(ct)
            mac.update(pt)
            return mac.doFinal()
        }
    }
}
