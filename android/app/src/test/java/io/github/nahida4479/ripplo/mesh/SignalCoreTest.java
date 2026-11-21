package io.github.nahida4479.ripplo.mesh;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.fail;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.junit.Before;
import org.junit.Test;
import org.signal.libsignal.protocol.ecc.ECPrivateKey;
import org.signal.libsignal.protocol.ecc.ECPublicKey;
import org.signal.libsignal.protocol.kdf.HKDF;

public class SignalCoreTest {
    private static final class Mem implements SignalCore.Storage {
        final Map<String, byte[]> m = new HashMap<>();

        public byte[] get(String k) {
            return m.get(k);
        }

        public void put(String k, byte[] v) {
            m.put(k, v);
        }

        public void delete(String k) {
            m.remove(k);
        }
    }

    private SignalCore alice;
    private SignalCore bob;
    private byte[] aliceBundle;
    private byte[] bobBundle;
    private byte[] aliceIk;
    private byte[] bobIk;
    private byte[] aliceTag;
    private byte[] bobTag;

    private static byte[] tagOf(byte[] ik) throws Exception {
        return Arrays.copyOf(MessageDigest.getInstance("SHA-256").digest(ik), 16);
    }

    private static byte[] utf8(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }

    @Before
    public void setUp() throws Exception {
        alice = new SignalCore(new Mem());
        bob = new SignalCore(new Mem());
        aliceBundle = alice.init();
        bobBundle = bob.init();
        aliceIk = alice.identityKey();
        bobIk = bob.identityKey();
        aliceTag = tagOf(aliceIk);
        bobTag = tagOf(bobIk);
    }

    private interface Call {
        void run() throws Exception;
    }

    private static void expectCode(String code, Call c) throws Exception {
        try {
            c.run();
            fail("expected " + code);
        } catch (IllegalArgumentException e) {
            assertEquals(code, e.getMessage());
        }
    }

    @Test
    public void bundleShape() throws Exception {
        assertEquals(1776, aliceBundle.length);
        assertEquals(2, aliceBundle[0]);
        assertArrayEquals(aliceBundle, alice.init());
        assertArrayEquals(aliceIk, Arrays.copyOfRange(aliceBundle, 5, 38));
    }

    @Test
    public void conversation() throws Exception {
        assertArrayEquals(bobTag, alice.addContact(bobBundle));

        byte[] first = alice.seal(bobTag, utf8("hello bob"));
        assertEquals(1, first[0]);
        SignalCore.Opened o = bob.open(first);
        assertArrayEquals(aliceTag, o.tag);
        assertArrayEquals(aliceIk, o.ik);
        assertArrayEquals(utf8("hello bob"), o.plaintext);

        byte[] reply = bob.seal(aliceTag, utf8("hello alice"));
        SignalCore.Opened r = alice.open(reply);
        assertArrayEquals(bobTag, r.tag);
        assertArrayEquals(bobIk, r.ik);
        assertArrayEquals(utf8("hello alice"), r.plaintext);

        for (int i = 0; i < 5; i++) {
            String a = "a" + i;
            String b = "b" + i;
            assertArrayEquals(utf8(a), bob.open(alice.seal(bobTag, utf8(a))).plaintext);
            assertArrayEquals(utf8(b), alice.open(bob.seal(aliceTag, utf8(b))).plaintext);
        }
    }

    @Test
    public void tamperedSealedRejected() throws Exception {
        alice.addContact(bobBundle);
        byte[] sealed = alice.seal(bobTag, utf8("x"));
        sealed[sealed.length - 1] ^= 1;
        expectCode("bad_message", () -> bob.open(sealed));
    }

    @Test
    public void swappedKyberSignatureRejected() throws Exception {
        SignalCore mallory = new SignalCore(new Mem());
        byte[] mb = mallory.init();
        byte[] forged = bobBundle.clone();
        System.arraycopy(mb, 1776 - 64, forged, 1776 - 64, 64);
        expectCode("bad_bundle", () -> alice.addContact(forged));
        expectCode("bad_bundle", () -> alice.addContact(Arrays.copyOf(bobBundle, 1775)));
    }

    @Test
    public void proofMatchesSpec() throws Exception {
        byte[] n = new byte[32];
        Arrays.fill(n, (byte) 7);
        byte[] fromAlice = alice.proof(bobIk, n, aliceTag, bobTag);
        byte[] fromBob = bob.proof(aliceIk, n, aliceTag, bobTag);
        assertArrayEquals(fromAlice, fromBob);
        assertEquals(32, fromAlice.length);

        assertNotEquals(Arrays.toString(fromAlice), Arrays.toString(alice.proof(bobIk, n, bobTag, aliceTag)));
    }

    @Test
    public void proofIndependentComputation() throws Exception {
        Mem bobMem = new Mem();
        SignalCore b = new SignalCore(bobMem);
        byte[] ik = b.identityKey();
        byte[] n = new byte[32];
        Arrays.fill(n, (byte) 9);
        byte[] expected = referenceProof(bobMem, aliceIk, n, aliceTag, tagOf(ik));
        assertArrayEquals(expected, b.proof(aliceIk, n, aliceTag, tagOf(ik)));
    }

    private static byte[] referenceProof(Mem mem, byte[] otherIk, byte[] n, byte[] ct, byte[] pt) throws Exception {
        org.signal.libsignal.protocol.IdentityKeyPair kp = new org.signal.libsignal.protocol.IdentityKeyPair(mem.get("ik"));
        ECPrivateKey priv = kp.getPrivateKey();
        byte[] shared = priv.calculateAgreement(new ECPublicKey(otherIk));
        byte[] info = utf8("ripplo-proof-v1");
        byte[] k = HKDF.deriveSecrets(shared, n, info, 32);
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(k, "HmacSHA256"));
        mac.update(info);
        mac.update(n);
        mac.update(ct);
        mac.update(pt);
        return mac.doFinal();
    }

    @Test
    public void safetyNumbers() throws Exception {
        String a = alice.safetyNumber(bobIk);
        String b = bob.safetyNumber(aliceIk);
        assertEquals(a, b);
        assertEquals(60, a.length());
        assertEquals(60, a.replaceAll("[^0-9]", "").length());
    }

    @Test
    public void noSessionAndForget() throws Exception {
        expectCode("no_session", () -> alice.seal(bobTag, utf8("x")));
        alice.addContact(bobBundle);
        alice.seal(bobTag, utf8("x"));
        alice.forget(bobTag);
        expectCode("no_session", () -> alice.seal(bobTag, utf8("x")));
    }

    @Test
    public void persistsAcrossInstances() throws Exception {
        Mem mem = new Mem();
        SignalCore a1 = new SignalCore(mem);
        byte[] b1 = a1.init();
        a1.addContact(bobBundle);
        byte[] sealed = a1.seal(bobTag, utf8("p"));
        SignalCore a2 = new SignalCore(mem);
        assertArrayEquals(b1, a2.init());
        assertArrayEquals(utf8("p"), bob.open(sealed).plaintext);
        assertArrayEquals(utf8("q"), bob.open(a2.seal(bobTag, utf8("q"))).plaintext);
    }
}
