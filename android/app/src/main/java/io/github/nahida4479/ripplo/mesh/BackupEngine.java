package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class BackupEngine {
    static final int ITERATIONS = 600000;
    static final String STAGING_DB = "restore-staging.db";
    private static final String ALIAS = "ripplo_backup_wrap";
    private static final String PREFS = "ripplo_backup";
    private static final int CODE_DIGITS = 30;

    static final class Secrets {
        final String code;
        final byte[] salt;
        final byte[] key;

        Secrets(String code, byte[] salt, byte[] key) {
            this.code = code;
            this.salt = salt;
            this.key = key;
        }
    }

    static final class Staged {
        String meta;
        byte[] dbKey;
        final Map<String, byte[]> signal = new LinkedHashMap<>();
        NativeStore rows;
    }

    private final Context ctx;
    private final SecureRandom rng = new SecureRandom();

    BackupEngine(Context ctx) {
        this.ctx = ctx.getApplicationContext();
    }

    SharedPreferences prefs() {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    boolean enabled() {
        return prefs().getString("wrapped", null) != null;
    }

    private SecretKey wrapKey() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (!ks.containsAlias(ALIAS)) {
            KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            kg.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build());
            kg.generateKey();
        }
        return (SecretKey) ks.getKey(ALIAS, null);
    }

    String enable() throws Exception {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < CODE_DIGITS; i++) sb.append(rng.nextInt(10));
        byte[] salt = new byte[16];
        rng.nextBytes(salt);
        String code = sb.toString();
        byte[] key = BackupFormat.pbkdf2(code.getBytes(StandardCharsets.US_ASCII), salt, ITERATIONS, 32);
        byte[] plain = ByteBuffer.allocate(CODE_DIGITS + 16 + 32).put(code.getBytes(StandardCharsets.US_ASCII)).put(salt).put(key).array();
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, wrapKey());
        byte[] iv = c.getIV();
        byte[] ct = c.doFinal(plain);
        byte[] blob = new byte[iv.length + ct.length];
        System.arraycopy(iv, 0, blob, 0, iv.length);
        System.arraycopy(ct, 0, blob, iv.length, ct.length);
        prefs().edit().putString("wrapped", Base64.encodeToString(blob, Base64.NO_WRAP)).remove("lastAt").commit();
        return code;
    }

    Secrets secrets() throws Exception {
        String s = prefs().getString("wrapped", null);
        if (s == null) return null;
        byte[] blob = Base64.decode(s, Base64.NO_WRAP);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, wrapKey(), new GCMParameterSpec(128, blob, 0, 12));
        byte[] p = c.doFinal(blob, 12, blob.length - 12);
        return new Secrets(new String(p, 0, CODE_DIGITS, StandardCharsets.US_ASCII),
                Arrays.copyOfRange(p, CODE_DIGITS, CODE_DIGITS + 16), Arrays.copyOfRange(p, CODE_DIGITS + 16, p.length));
    }

    void write(OutputStream out, String meta, byte[] dbKey, Secrets s, SignalFileStore signal, NativeStore rows) throws Exception {
        try (BackupFormat.Writer w = new BackupFormat.Writer(out, BackupFormat.header(ITERATIONS, s.salt), s.key)) {
            w.record(1, meta.getBytes(StandardCharsets.UTF_8));
            w.record(2, dbKey);
            for (String name : signal.names()) {
                byte[] v = signal.get(name);
                if (v == null) continue;
                byte[] k = name.getBytes(StandardCharsets.UTF_8);
                w.record(3, ByteBuffer.allocate(2 + k.length + v.length).putShort((short) k.length).put(k).put(v).array());
            }
            rows.forEachRow((store, key, idx, value) -> {
                byte[] a = store.getBytes(StandardCharsets.UTF_8);
                byte[] b = key.getBytes(StandardCharsets.UTF_8);
                byte[] i = idx == null ? null : idx.getBytes(StandardCharsets.UTF_8);
                ByteBuffer bb = ByteBuffer.allocate(6 + a.length + b.length + (i == null ? 0 : i.length) + value.length);
                bb.putShort((short) a.length).put(a).putShort((short) b.length).put(b).putShort((short) (i == null ? 0xFFFF : i.length));
                if (i != null) bb.put(i);
                w.record(4, bb.put(value).array());
            });
        }
    }

    private static byte[] take(ByteBuffer b, int len) throws IOException {
        if (len < 0 || len > b.remaining()) throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
        byte[] o = new byte[len];
        b.get(o);
        return o;
    }

    private static String str(ByteBuffer b) throws IOException {
        if (b.remaining() < 2) throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
        return new String(take(b, b.getShort() & 0xffff), StandardCharsets.UTF_8);
    }

    Staged stage(InputStream in, String code) throws Exception {
        StringBuilder digits = new StringBuilder();
        for (char ch : code.toCharArray()) if (ch >= '0' && ch <= '9') digits.append(ch);
        if (digits.length() != CODE_DIGITS) throw new BackupFormat.BackupException(BackupFormat.BAD_CODE);
        BackupFormat.Header h = BackupFormat.readHeader(in);
        byte[] key = BackupFormat.pbkdf2(digits.toString().getBytes(StandardCharsets.US_ASCII), h.salt, h.iterations, 32);
        BackupFormat.Reader r = new BackupFormat.Reader(in, h, key);
        ctx.deleteDatabase(STAGING_DB);
        Staged st = new Staged();
        st.rows = new NativeStore(ctx, STAGING_DB);
        try {
            st.rows.getWritableDatabase().beginTransaction();
            BackupFormat.Record rec;
            while ((rec = r.next()) != null) {
                if (rec.type == 1 && st.meta == null) {
                    st.meta = new String(rec.data, StandardCharsets.UTF_8);
                } else if (rec.type == 2 && st.dbKey == null && rec.data.length == 32) {
                    st.dbKey = rec.data;
                } else if (rec.type == 3) {
                    ByteBuffer b = ByteBuffer.wrap(rec.data);
                    if (b.remaining() < 2) throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
                    String name = new String(take(b, b.getShort() & 0xffff), StandardCharsets.UTF_8);
                    if (name.isEmpty()) throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
                    st.signal.put(name, take(b, b.remaining()));
                } else if (rec.type == 4) {
                    ByteBuffer b = ByteBuffer.wrap(rec.data);
                    String store = str(b);
                    String k = str(b);
                    if (b.remaining() < 2) throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
                    int il = b.getShort() & 0xffff;
                    String idx = il == 0xFFFF ? null : new String(take(b, il), StandardCharsets.UTF_8);
                    st.rows.put(store, k, idx, take(b, b.remaining()));
                } else {
                    throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
                }
            }
            if (st.meta == null || st.dbKey == null) throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
            st.rows.getWritableDatabase().setTransactionSuccessful();
            st.rows.getWritableDatabase().endTransaction();
            return st;
        } catch (Exception e) {
            discard(st);
            throw e;
        }
    }

    void discard(Staged st) {
        try {
            st.rows.close();
        } catch (RuntimeException ignored) {
        }
        ctx.deleteDatabase(STAGING_DB);
    }
}
