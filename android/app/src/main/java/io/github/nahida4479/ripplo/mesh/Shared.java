package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

final class Shared {
    private static final String KEY_ALIAS = "ripplo_db_wrap";
    private static SignalFileStore signalStore;
    private static SignalCore signalCore;
    private static NativeStore nativeStore;

    private Shared() { }

    private static SecretKey wrapKey() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (!ks.containsAlias(KEY_ALIAS)) {
            KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            kg.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build());
            kg.generateKey();
        }
        return (SecretKey) ks.getKey(KEY_ALIAS, null);
    }

    static String wrapDbKey(byte[] key) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, wrapKey());
        byte[] iv = c.getIV();
        byte[] ct = c.doFinal(key);
        byte[] blob = new byte[iv.length + ct.length];
        System.arraycopy(iv, 0, blob, 0, iv.length);
        System.arraycopy(ct, 0, blob, iv.length, ct.length);
        return Base64.encodeToString(blob, Base64.NO_WRAP);
    }

    static synchronized byte[] dbKey(Context ctx) throws Exception {
        SharedPreferences sp = ctx.getSharedPreferences("ripplo_keys", Context.MODE_PRIVATE);
        String stored = sp.getString("dbkey", null);
        if (stored == null) {
            byte[] key = new byte[32];
            new SecureRandom().nextBytes(key);
            sp.edit().putString("dbkey", wrapDbKey(key)).commit();
            return key;
        }
        byte[] blob = Base64.decode(stored, Base64.NO_WRAP);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, wrapKey(), new GCMParameterSpec(128, blob, 0, 12));
        return c.doFinal(blob, 12, blob.length - 12);
    }

    static synchronized SignalFileStore signalStore(Context ctx) throws Exception {
        if (signalStore == null) signalStore = new SignalFileStore(ctx.getFilesDir(), dbKey(ctx));
        return signalStore;
    }

    static synchronized SignalCore signal(Context ctx) throws Exception {
        if (signalCore == null) signalCore = new SignalCore(signalStore(ctx));
        return signalCore;
    }

    static synchronized NativeStore db(Context ctx) {
        if (nativeStore == null) nativeStore = new NativeStore(ctx.getApplicationContext(), "ripplo.db");
        return nativeStore;
    }

    static synchronized void reset() {
        signalStore = null;
        signalCore = null;
    }

    static byte[] seal(byte[] key, byte[] plain, String aad) throws Exception {
        byte[] nonce = new byte[12];
        new SecureRandom().nextBytes(nonce);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, new javax.crypto.spec.SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        c.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
        byte[] ct = c.doFinal(plain);
        byte[] out = new byte[12 + ct.length];
        System.arraycopy(nonce, 0, out, 0, 12);
        System.arraycopy(ct, 0, out, 12, ct.length);
        return out;
    }

    static byte[] open(byte[] key, byte[] sealed, String aad) throws Exception {
        if (sealed.length < 12 + 16) throw new IllegalArgumentException("short");
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, new javax.crypto.spec.SecretKeySpec(key, "AES"), new GCMParameterSpec(128, sealed, 0, 12));
        c.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
        return c.doFinal(sealed, 12, sealed.length - 12);
    }

    static JSONObject row(Context ctx, byte[] key, String store, String rowKey) {
        try {
            String b64 = db(ctx).get(store, rowKey);
            if (b64 == null) return null;
            byte[] plain = open(key, Base64.decode(b64, Base64.NO_WRAP), store + "/" + rowKey);
            return new JSONObject(new String(plain, StandardCharsets.UTF_8));
        } catch (Exception e) {
            return null;
        }
    }
}
