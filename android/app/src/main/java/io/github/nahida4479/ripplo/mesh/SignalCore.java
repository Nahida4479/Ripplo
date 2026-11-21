package io.github.nahida4479.ripplo.mesh;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.signal.libsignal.protocol.IdentityKey;
import org.signal.libsignal.protocol.IdentityKeyPair;
import org.signal.libsignal.protocol.InvalidKeyIdException;
import org.signal.libsignal.protocol.NoSessionException;
import org.signal.libsignal.protocol.SessionBuilder;
import org.signal.libsignal.protocol.SessionCipher;
import org.signal.libsignal.protocol.SignalProtocolAddress;
import org.signal.libsignal.protocol.UntrustedIdentityException;
import org.signal.libsignal.protocol.ecc.ECKeyPair;
import org.signal.libsignal.protocol.ecc.ECPrivateKey;
import org.signal.libsignal.protocol.ecc.ECPublicKey;
import org.signal.libsignal.protocol.fingerprint.NumericFingerprintGenerator;
import org.signal.libsignal.protocol.kdf.HKDF;
import org.signal.libsignal.protocol.kem.KEMKeyPair;
import org.signal.libsignal.protocol.kem.KEMKeyType;
import org.signal.libsignal.protocol.kem.KEMPublicKey;
import org.signal.libsignal.protocol.message.CiphertextMessage;
import org.signal.libsignal.protocol.message.PreKeySignalMessage;
import org.signal.libsignal.protocol.message.SignalMessage;
import org.signal.libsignal.protocol.state.IdentityKeyStore;
import org.signal.libsignal.protocol.state.KyberPreKeyRecord;
import org.signal.libsignal.protocol.state.KyberPreKeyStore;
import org.signal.libsignal.protocol.state.PreKeyBundle;
import org.signal.libsignal.protocol.state.PreKeyRecord;
import org.signal.libsignal.protocol.state.PreKeyStore;
import org.signal.libsignal.protocol.state.SessionRecord;
import org.signal.libsignal.protocol.state.SessionStore;
import org.signal.libsignal.protocol.state.SignedPreKeyRecord;
import org.signal.libsignal.protocol.state.SignedPreKeyStore;

public final class SignalCore {
    public interface Storage {
        byte[] get(String key);
        void put(String key, byte[] value);
        void delete(String key);
    }

    public static final class Failed extends IllegalArgumentException {
        public final byte[] tag;

        Failed(String message, byte[] tag) {
            super(message);
            this.tag = tag;
        }
    }

    public static final class Opened {
        public final byte[] tag;
        public final byte[] ik;
        public final byte[] plaintext;

        Opened(byte[] tag, byte[] ik, byte[] plaintext) {
            this.tag = tag;
            this.ik = ik;
            this.plaintext = plaintext;
        }
    }

    public static final String BAD_BUNDLE = "bad_bundle";
    public static final String NO_SESSION = "no_session";
    public static final String BAD_MESSAGE = "bad_message";
    public static final String UNTRUSTED = "untrusted_identity";

    private static final int BUNDLE_LEN = 1776;
    private static final int KYBER_PUB_LEN = 1569;
    private static final byte[] SEALED_INFO = "ripplo-sealed-v2".getBytes(StandardCharsets.UTF_8);
    private static final byte[] PROOF_INFO = "ripplo-proof-v1".getBytes(StandardCharsets.UTF_8);
    private static final SecureRandom RNG = new SecureRandom();

    private final Storage storage;
    private final Store store = new Store();
    private IdentityKeyPair identity;
    private int registrationId;
    private byte[] myTag;
    private SignalProtocolAddress localAddress;

    public SignalCore(Storage storage) {
        this.storage = storage;
    }

    public static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(Character.forDigit((x >> 4) & 15, 16)).append(Character.forDigit(x & 15, 16));
        return sb.toString();
    }

    public static byte[] unhex(String s) {
        if (s == null || s.length() % 2 != 0) throw new IllegalArgumentException(BAD_MESSAGE);
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            int hi = Character.digit(s.charAt(i * 2), 16);
            int lo = Character.digit(s.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) throw new IllegalArgumentException(BAD_MESSAGE);
            out[i] = (byte) (hi << 4 | lo);
        }
        return out;
    }

    private static byte[] sha256(byte[] b) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(b);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static byte[] tagOf(byte[] ik33) {
        return Arrays.copyOf(sha256(ik33), 16);
    }

    private static byte[] hmac(byte[] key, byte[]... parts) throws Exception {
        Mac m = Mac.getInstance("HmacSHA256");
        m.init(new SecretKeySpec(key, "HmacSHA256"));
        for (byte[] p : parts) m.update(p);
        return m.doFinal();
    }

    private static byte[] concat(byte[]... parts) {
        int n = 0;
        for (byte[] p : parts) n += p.length;
        byte[] out = new byte[n];
        int o = 0;
        for (byte[] p : parts) {
            System.arraycopy(p, 0, out, o, p.length);
            o += p.length;
        }
        return out;
    }

    private SignalProtocolAddress addr(byte[] tag) {
        if (tag == null || tag.length != 16) throw new IllegalArgumentException(BAD_MESSAGE);
        return new SignalProtocolAddress(hex(tag), 1);
    }

    private SessionCipher cipher(SignalProtocolAddress remote) {
        return new SessionCipher(store, store, store, store, store, localAddress, remote);
    }

    private void ensure() throws Exception {
        if (identity != null) return;
        byte[] raw = storage.get("identity");
        if (raw == null) {
            IdentityKeyPair ikp = IdentityKeyPair.generate();
            ECPrivateKey priv = ikp.getPrivateKey();
            long now = System.currentTimeMillis();
            ECKeyPair spk = ECKeyPair.generate();
            SignedPreKeyRecord spr = new SignedPreKeyRecord(1, now, spk, priv.calculateSignature(spk.getPublicKey().serialize()));
            KEMKeyPair kem = KEMKeyPair.generate(KEMKeyType.KYBER_1024);
            KyberPreKeyRecord kpr = new KyberPreKeyRecord(1, now, kem, priv.calculateSignature(kem.getPublicKey().serialize()));
            storage.put("spk:1", spr.serialize());
            storage.put("kyber:1", kpr.serialize());
            storage.put("regid", ByteBuffer.allocate(4).putInt(1 + RNG.nextInt(16380)).array());
            storage.put("identity", ikp.serialize());
            raw = ikp.serialize();
        }
        identity = new IdentityKeyPair(raw);
        registrationId = ByteBuffer.wrap(storage.get("regid")).getInt();
        myTag = tagOf(identity.getPublicKey().serialize());
        localAddress = new SignalProtocolAddress(hex(myTag), 1);
    }

    public synchronized byte[] init() throws Exception {
        ensure();
        SignedPreKeyRecord spr = new SignedPreKeyRecord(storage.get("spk:1"));
        KyberPreKeyRecord kpr = new KyberPreKeyRecord(storage.get("kyber:1"));
        ByteBuffer b = ByteBuffer.allocate(BUNDLE_LEN);
        b.put((byte) 2).putInt(registrationId).put(identity.getPublicKey().serialize());
        b.putInt(spr.getId()).put(spr.getKeyPair().getPublicKey().serialize()).put(spr.getSignature());
        b.putInt(kpr.getId()).put(kpr.getKeyPair().getPublicKey().serialize()).put(kpr.getSignature());
        if (b.position() != BUNDLE_LEN) throw new IllegalStateException();
        return b.array();
    }

    public synchronized byte[] identityKey() throws Exception {
        ensure();
        return identity.getPublicKey().serialize();
    }

    public synchronized byte[] addContact(byte[] bundle) throws Exception {
        ensure();
        try {
            if (bundle == null || bundle.length != BUNDLE_LEN || bundle[0] != 2) throw new IllegalArgumentException();
            ByteBuffer b = ByteBuffer.wrap(bundle);
            b.get();
            int reg = b.getInt();
            byte[] ikRaw = new byte[33];
            b.get(ikRaw);
            int spkId = b.getInt();
            byte[] spkRaw = new byte[33];
            b.get(spkRaw);
            byte[] spkSig = new byte[64];
            b.get(spkSig);
            int kId = b.getInt();
            byte[] kRaw = new byte[KYBER_PUB_LEN];
            b.get(kRaw);
            byte[] kSig = new byte[64];
            b.get(kSig);
            byte[] tag = tagOf(ikRaw);
            if (Arrays.equals(tag, myTag)) throw new IllegalArgumentException();
            IdentityKey ik = new IdentityKey(ikRaw);
            PreKeyBundle pb = new PreKeyBundle(reg, 1, PreKeyBundle.NULL_PRE_KEY_ID, null, spkId,
                    new ECPublicKey(spkRaw), spkSig, ik, kId, new KEMPublicKey(kRaw), kSig);
            new SessionBuilder(store, store, store, store, addr(tag), localAddress).process(pb);
            return tag;
        } catch (Exception e) {
            throw new IllegalArgumentException(BAD_BUNDLE);
        }
    }

    public synchronized byte[] seal(byte[] tag, byte[] plaintext) throws Exception {
        ensure();
        SignalProtocolAddress remote = addr(tag);
        IdentityKey rik = store.getIdentity(remote);
        if (rik == null) throw new IllegalArgumentException(NO_SESSION);
        CiphertextMessage msg;
        try {
            msg = cipher(remote).encrypt(plaintext);
        } catch (NoSessionException e) {
            throw new IllegalArgumentException(NO_SESSION);
        } catch (UntrustedIdentityException e) {
            throw new IllegalArgumentException(UNTRUSTED);
        }
        byte[] inner = concat(new byte[]{2}, myTag, new byte[]{(byte) msg.getType()}, msg.serialize());
        ECKeyPair eph = ECKeyPair.generate();
        byte[] shared = eph.getPrivateKey().calculateAgreement(rik.getPublicKey());
        byte[] key = HKDF.deriveSecrets(shared, tag, SEALED_INFO, 32);
        byte[] nonce = new byte[12];
        RNG.nextBytes(nonce);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        return concat(new byte[]{1}, eph.getPublicKey().getPublicKeyBytes(), nonce, c.doFinal(inner));
    }

    public synchronized Opened open(byte[] sealed) throws Exception {
        ensure();
        byte[] inner;
        try {
            if (sealed == null || sealed.length < 1 + 32 + 12 + 16 || sealed[0] != 1) throw new IllegalArgumentException();
            ECPublicKey eph = ECPublicKey.fromPublicKeyBytes(Arrays.copyOfRange(sealed, 1, 33));
            byte[] shared = identity.getPrivateKey().calculateAgreement(eph);
            byte[] key = HKDF.deriveSecrets(shared, myTag, SEALED_INFO, 32);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, sealed, 33, 12));
            inner = c.doFinal(sealed, 45, sealed.length - 45);
        } catch (Exception e) {
            throw new IllegalArgumentException(BAD_MESSAGE);
        }
        if (inner.length < 19 || inner[0] != 2) throw new IllegalArgumentException(BAD_MESSAGE);
        byte[] tag = Arrays.copyOfRange(inner, 1, 17);
        int type = inner[17] & 0xff;
        byte[] body = Arrays.copyOfRange(inner, 18, inner.length);
        SignalProtocolAddress remote = addr(tag);
        SessionCipher sc = cipher(remote);
        byte[] plain;
        byte[] ik;
        try {
            if (type == CiphertextMessage.PREKEY_TYPE) {
                PreKeySignalMessage pm = new PreKeySignalMessage(body);
                ik = pm.getIdentityKey().serialize();
                if (!Arrays.equals(tagOf(ik), tag)) throw new IllegalArgumentException(BAD_MESSAGE);
                plain = sc.decrypt(pm);
            } else if (type == CiphertextMessage.WHISPER_TYPE) {
                SignalMessage sm = new SignalMessage(body);
                plain = sc.decrypt(sm);
                IdentityKey known = store.getIdentity(remote);
                if (known == null) throw new IllegalArgumentException(NO_SESSION);
                ik = known.serialize();
            } else {
                throw new IllegalArgumentException(BAD_MESSAGE);
            }
        } catch (IllegalArgumentException e) {
            throw new Failed(e.getMessage(), tag);
        } catch (NoSessionException e) {
            throw new Failed(NO_SESSION, tag);
        } catch (UntrustedIdentityException e) {
            throw new Failed(UNTRUSTED, tag);
        } catch (Exception e) {
            throw new Failed(BAD_MESSAGE, tag);
        }
        return new Opened(tag, ik, plain);
    }

    public synchronized byte[] proof(byte[] otherIk33, byte[] n, byte[] challengerTag, byte[] proverTag) throws Exception {
        ensure();
        try {
            ECPublicKey other = new ECPublicKey(otherIk33);
            byte[] shared = identity.getPrivateKey().calculateAgreement(other);
            byte[] k = HKDF.deriveSecrets(shared, n, PROOF_INFO, 32);
            return hmac(k, PROOF_INFO, n, challengerTag, proverTag);
        } catch (Exception e) {
            throw new IllegalArgumentException(BAD_MESSAGE);
        }
    }

    public synchronized String safetyNumber(byte[] theirIk33) throws Exception {
        ensure();
        try {
            IdentityKey theirs = new IdentityKey(theirIk33);
            return new NumericFingerprintGenerator(5200)
                    .createFor(1, myTag, identity.getPublicKey(), tagOf(theirIk33), theirs)
                    .getDisplayableFingerprint().getDisplayText();
        } catch (Exception e) {
            throw new IllegalArgumentException(BAD_MESSAGE);
        }
    }

    public synchronized void forget(byte[] tag) throws Exception {
        ensure();
        if (tag == null || tag.length != 16) throw new IllegalArgumentException(BAD_MESSAGE);
        String h = hex(tag);
        storage.delete("session:" + h);
        storage.delete("ident:" + h);
    }

    private final class Store implements IdentityKeyStore, SessionStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore {
        public IdentityKeyPair getIdentityKeyPair() {
            return identity;
        }

        public int getLocalRegistrationId() {
            return registrationId;
        }

        private boolean tagMatches(SignalProtocolAddress a, IdentityKey ik) {
            return hex(tagOf(ik.serialize())).equals(a.getName());
        }

        public IdentityChange saveIdentity(SignalProtocolAddress a, IdentityKey ik) {
            if (!tagMatches(a, ik)) return IdentityChange.NEW_OR_UNCHANGED;
            byte[] old = storage.get("ident:" + a.getName());
            byte[] now = ik.serialize();
            if (old != null && Arrays.equals(old, now)) return IdentityChange.NEW_OR_UNCHANGED;
            storage.put("ident:" + a.getName(), now);
            return old == null ? IdentityChange.NEW_OR_UNCHANGED : IdentityChange.REPLACED_EXISTING;
        }

        public boolean isTrustedIdentity(SignalProtocolAddress a, IdentityKey ik, Direction d) {
            return tagMatches(a, ik);
        }

        public IdentityKey getIdentity(SignalProtocolAddress a) {
            byte[] raw = storage.get("ident:" + a.getName());
            if (raw == null) return null;
            try {
                return new IdentityKey(raw);
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }

        public SessionRecord loadSession(SignalProtocolAddress a) {
            byte[] raw = storage.get("session:" + a.getName());
            if (raw == null) return new SessionRecord();
            try {
                return new SessionRecord(raw);
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }

        public List<SessionRecord> loadExistingSessions(List<SignalProtocolAddress> addresses) throws NoSessionException {
            java.util.ArrayList<SessionRecord> out = new java.util.ArrayList<>();
            for (SignalProtocolAddress a : addresses) {
                if (storage.get("session:" + a.getName()) == null) throw new NoSessionException("no session for " + a.getName());
                out.add(loadSession(a));
            }
            return out;
        }

        public List<Integer> getSubDeviceSessions(String name) {
            return Collections.emptyList();
        }

        public void storeSession(SignalProtocolAddress a, SessionRecord r) {
            storage.put("session:" + a.getName(), r.serialize());
        }

        public boolean containsSession(SignalProtocolAddress a) {
            return storage.get("session:" + a.getName()) != null;
        }

        public void deleteSession(SignalProtocolAddress a) {
            storage.delete("session:" + a.getName());
        }

        public void deleteAllSessions(String name) {
            storage.delete("session:" + name);
        }

        public PreKeyRecord loadPreKey(int id) throws InvalidKeyIdException {
            throw new InvalidKeyIdException("no one-time prekeys");
        }

        public void storePreKey(int id, PreKeyRecord r) {
        }

        public boolean containsPreKey(int id) {
            return false;
        }

        public void removePreKey(int id) {
        }

        public SignedPreKeyRecord loadSignedPreKey(int id) throws InvalidKeyIdException {
            byte[] raw = id == 1 ? storage.get("spk:1") : null;
            if (raw == null) throw new InvalidKeyIdException("unknown signed prekey");
            try {
                return new SignedPreKeyRecord(raw);
            } catch (Exception e) {
                throw new InvalidKeyIdException(e);
            }
        }

        public List<SignedPreKeyRecord> loadSignedPreKeys() {
            try {
                return Collections.singletonList(loadSignedPreKey(1));
            } catch (InvalidKeyIdException e) {
                return Collections.emptyList();
            }
        }

        public void storeSignedPreKey(int id, SignedPreKeyRecord r) {
            if (id == 1) storage.put("spk:1", r.serialize());
        }

        public boolean containsSignedPreKey(int id) {
            return id == 1 && storage.get("spk:1") != null;
        }

        public void removeSignedPreKey(int id) {
        }

        public KyberPreKeyRecord loadKyberPreKey(int id) throws InvalidKeyIdException {
            byte[] raw = id == 1 ? storage.get("kyber:1") : null;
            if (raw == null) throw new InvalidKeyIdException("unknown kyber prekey");
            try {
                return new KyberPreKeyRecord(raw);
            } catch (Exception e) {
                throw new InvalidKeyIdException(e);
            }
        }

        public List<KyberPreKeyRecord> loadKyberPreKeys() {
            try {
                return Collections.singletonList(loadKyberPreKey(1));
            } catch (InvalidKeyIdException e) {
                return Collections.emptyList();
            }
        }

        public void storeKyberPreKey(int id, KyberPreKeyRecord r) {
            if (id == 1) storage.put("kyber:1", r.serialize());
        }

        public boolean containsKyberPreKey(int id) {
            return id == 1 && storage.get("kyber:1") != null;
        }

        public void markKyberPreKeyUsed(int kyberId, int signedId, ECPublicKey baseKey) {
        }
    }
}
