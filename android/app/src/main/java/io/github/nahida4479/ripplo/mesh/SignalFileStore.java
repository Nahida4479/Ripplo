package io.github.nahida4479.ripplo.mesh;

import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class SignalFileStore implements SignalCore.Storage {
    private final File dir;
    private final SecretKeySpec key;
    private final SecureRandom rng = new SecureRandom();

    public SignalFileStore(File filesDir, byte[] dbKey) {
        dir = new File(filesDir, "signal");
        dir.mkdirs();
        key = new SecretKeySpec(dbKey, "AES");
    }

    private File file(String name) {
        try {
            byte[] h = MessageDigest.getInstance("SHA-256").digest(name.getBytes(StandardCharsets.UTF_8));
            return new File(dir, SignalCore.hex(h));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    @Override
    public synchronized byte[] get(String name) {
        File f = file(name);
        if (!f.exists()) return null;
        try (DataInputStream in = new DataInputStream(new FileInputStream(f))) {
            byte[] blob = new byte[(int) f.length()];
            in.readFully(blob);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, blob, 0, 12));
            c.updateAAD(name.getBytes(StandardCharsets.UTF_8));
            return c.doFinal(blob, 12, blob.length - 12);
        } catch (Exception e) {
            throw new IllegalStateException("storage");
        }
    }

    @Override
    public synchronized void put(String name, byte[] value) {
        File f = file(name);
        File tmp = new File(dir, f.getName() + ".tmp");
        try {
            byte[] nonce = new byte[12];
            rng.nextBytes(nonce);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, nonce));
            c.updateAAD(name.getBytes(StandardCharsets.UTF_8));
            byte[] ct = c.doFinal(value);
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(nonce);
                out.write(ct);
                out.getFD().sync();
            }
            if (!tmp.renameTo(f)) throw new IllegalStateException("storage");
        } catch (Exception e) {
            tmp.delete();
            throw new IllegalStateException("storage");
        }
    }

    @Override
    public synchronized void delete(String name) {
        file(name).delete();
    }
}
