package io.github.nahida4479.ripplo.mesh;

import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class SignalFileStore implements SignalCore.Storage {
    private static final String INDEX = "names.idx";
    private static final String INDEX_AAD = "\u0000names";
    private static final String[] FIXED = {"identity", "regid", "spk:1", "kyber:1"};

    private final File dir;
    private final SecretKeySpec key;
    private final SecureRandom rng = new SecureRandom();
    private Set<String> names;

    public SignalFileStore(File filesDir, byte[] dbKey) {
        this(new File(filesDir, "signal"), dbKey, true);
    }

    private SignalFileStore(File dir, byte[] dbKey, boolean unused) {
        this.dir = dir;
        dir.mkdirs();
        key = new SecretKeySpec(dbKey, "AES");
    }

    public static SignalFileStore at(File dir, byte[] dbKey) {
        return new SignalFileStore(dir, dbKey, true);
    }

    private File file(String name) {
        try {
            byte[] h = MessageDigest.getInstance("SHA-256").digest(name.getBytes(StandardCharsets.UTF_8));
            return new File(dir, SignalCore.hex(h));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private byte[] read(File f, String aad) throws Exception {
        try (DataInputStream in = new DataInputStream(new FileInputStream(f))) {
            byte[] blob = new byte[(int) f.length()];
            in.readFully(blob);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, blob, 0, 12));
            c.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
            return c.doFinal(blob, 12, blob.length - 12);
        }
    }

    private void write(File f, String aad, byte[] value) throws Exception {
        File tmp = new File(dir, f.getName() + ".tmp");
        try {
            byte[] nonce = new byte[12];
            rng.nextBytes(nonce);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, nonce));
            c.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
            byte[] ct = c.doFinal(value);
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(nonce);
                out.write(ct);
                out.getFD().sync();
            }
            if (!tmp.renameTo(f)) throw new IllegalStateException("storage");
        } catch (Exception e) {
            tmp.delete();
            throw e;
        }
    }

    private Set<String> index() throws Exception {
        if (names == null) {
            names = new LinkedHashSet<>();
            File f = new File(dir, INDEX);
            if (f.exists()) {
                String s = new String(read(f, INDEX_AAD), StandardCharsets.UTF_8);
                for (String n : s.split("\n")) if (!n.isEmpty()) names.add(n);
            }
        }
        return names;
    }

    private void saveIndex() throws Exception {
        write(new File(dir, INDEX), INDEX_AAD, String.join("\n", names).getBytes(StandardCharsets.UTF_8));
    }

    @Override
    public synchronized byte[] get(String name) {
        File f = file(name);
        if (!f.exists()) return null;
        try {
            return read(f, name);
        } catch (Exception e) {
            throw new IllegalStateException("storage");
        }
    }

    @Override
    public synchronized void put(String name, byte[] value) {
        try {
            write(file(name), name, value);
            if (index().add(name)) saveIndex();
        } catch (Exception e) {
            throw new IllegalStateException("storage");
        }
    }

    @Override
    public synchronized void delete(String name) {
        file(name).delete();
        try {
            if (index().remove(name)) saveIndex();
        } catch (Exception e) {
            throw new IllegalStateException("storage");
        }
    }

    public synchronized List<String> names() {
        try {
            Set<String> all = new LinkedHashSet<>(index());
            for (String n : FIXED) all.add(n);
            List<String> out = new ArrayList<>();
            for (String n : all) if (file(n).exists()) out.add(n);
            return out;
        } catch (Exception e) {
            throw new IllegalStateException("storage");
        }
    }
}
