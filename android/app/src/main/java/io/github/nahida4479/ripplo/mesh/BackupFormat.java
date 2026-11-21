package io.github.nahida4479.ripplo.mesh;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PushbackInputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class BackupFormat {
    public static final int FRAME = 1 << 20;
    public static final int MAX_RECORD = 256 << 20;
    public static final int VERSION = 1;
    public static final int FLAG_FACTOR = 1;
    public static final String BAD_CODE = "bad_code";
    public static final String BAD_FILE = "bad_file";
    public static final String NEED_FACTOR = "need_factor";
    private static final byte[] MAGIC = "RIPPLOBK".getBytes(StandardCharsets.US_ASCII);
    private static final SecureRandom RNG = new SecureRandom();

    private BackupFormat() {
    }

    public static final class BackupException extends IOException {
        public final String code;

        public BackupException(String code) {
            super(code);
            this.code = code;
        }
    }

    public static final class Header {
        public final int flags;
        public final int iterations;
        public final byte[] salt;
        final byte[] raw;

        Header(int flags, int iterations, byte[] salt, byte[] raw) {
            this.flags = flags;
            this.iterations = iterations;
            this.salt = salt;
            this.raw = raw;
        }
    }

    public static final class Record {
        public final int type;
        public final byte[] data;

        Record(int type, byte[] data) {
            this.type = type;
            this.data = data;
        }
    }

    public static Header header(int iterations, byte[] salt) {
        if (salt.length != 16) throw new IllegalArgumentException("salt");
        ByteBuffer b = ByteBuffer.allocate(8 + 1 + 1 + 4 + 16);
        b.put(MAGIC).put((byte) VERSION).put((byte) 0).putInt(iterations).put(salt);
        return new Header(0, iterations, salt.clone(), b.array());
    }

    public static Header readHeader(InputStream in) throws IOException {
        byte[] raw = readFully(in, 30);
        if (!Arrays.equals(Arrays.copyOf(raw, 8), MAGIC) || raw[8] != VERSION) throw new BackupException(BAD_FILE);
        int flags = raw[9] & 0xff;
        if ((flags & ~FLAG_FACTOR) != 0) throw new BackupException(BAD_FILE);
        if ((flags & FLAG_FACTOR) != 0) throw new BackupException(NEED_FACTOR);
        int iterations = ByteBuffer.wrap(raw, 10, 4).getInt();
        if (iterations < 1 || iterations > 10_000_000) throw new BackupException(BAD_FILE);
        return new Header(flags, iterations, Arrays.copyOfRange(raw, 14, 30), raw);
    }

    static byte[] readFully(InputStream in, int n) throws IOException {
        byte[] b = new byte[n];
        int o = 0;
        while (o < n) {
            int r = in.read(b, o, n - o);
            if (r < 0) throw new BackupException(BAD_FILE);
            o += r;
        }
        return b;
    }

    public static byte[] pbkdf2(byte[] password, byte[] salt, int iterations, int length) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(password, "HmacSHA256"));
            byte[] out = new byte[length];
            int blocks = (length + 31) / 32;
            for (int i = 1; i <= blocks; i++) {
                mac.update(salt);
                byte[] u = mac.doFinal(ByteBuffer.allocate(4).putInt(i).array());
                byte[] t = u.clone();
                for (int j = 1; j < iterations; j++) {
                    u = mac.doFinal(u);
                    for (int k = 0; k < t.length; k++) t[k] ^= u[k];
                }
                System.arraycopy(t, 0, out, (i - 1) * 32, Math.min(32, length - (i - 1) * 32));
            }
            return out;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    private static byte[] aad(byte[] headerHash, long index, boolean last) {
        return ByteBuffer.allocate(41).put(headerHash).putLong(index).put((byte) (last ? 1 : 0)).array();
    }

    private static byte[] sha256(byte[] b) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(b);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    public static final class Writer implements Closeable {
        private final OutputStream out;
        private final byte[] key;
        private final byte[] headerHash;
        private final byte[] buf = new byte[FRAME];
        private int n;
        private long index;
        private boolean closed;

        public Writer(OutputStream out, Header h, byte[] key) throws IOException {
            this.out = out;
            this.key = key;
            this.headerHash = sha256(h.raw);
            out.write(h.raw);
        }

        public void record(int type, byte[] data) throws IOException {
            write(ByteBuffer.allocate(5).put((byte) type).putInt(data.length).array());
            write(data);
        }

        private void write(byte[] b) throws IOException {
            int o = 0;
            while (o < b.length) {
                if (n == FRAME) frame(false);
                int c = Math.min(FRAME - n, b.length - o);
                System.arraycopy(b, o, buf, n, c);
                n += c;
                o += c;
            }
        }

        private void frame(boolean last) throws IOException {
            try {
                byte[] nonce = new byte[12];
                RNG.nextBytes(nonce);
                Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
                c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
                c.updateAAD(aad(headerHash, index, last));
                byte[] ct = c.doFinal(buf, 0, n);
                out.write(ByteBuffer.allocate(4).putInt(12 + ct.length).array());
                out.write(nonce);
                out.write(ct);
            } catch (GeneralSecurityException e) {
                throw new IOException("encrypt");
            }
            index++;
            n = 0;
        }

        @Override
        public void close() throws IOException {
            if (closed) return;
            closed = true;
            try {
                frame(true);
                out.flush();
            } finally {
                out.close();
            }
        }
    }

    public static final class Reader {
        private final PushbackInputStream in;
        private final byte[] key;
        private final byte[] headerHash;
        private byte[] cur = new byte[0];
        private int pos;
        private long index;
        private boolean ended;

        public Reader(InputStream in, Header h, byte[] key) {
            this.in = new PushbackInputStream(in, 1);
            this.key = key;
            this.headerHash = sha256(h.raw);
        }

        private byte[] open(byte[] frame, boolean last) throws GeneralSecurityException {
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, frame, 0, 12));
            c.updateAAD(aad(headerHash, index, last));
            return c.doFinal(frame, 12, frame.length - 12);
        }

        private void nextFrame() throws IOException {
            int b0 = in.read();
            if (b0 < 0) throw new BackupException(BAD_FILE);
            in.unread(b0);
            int len = ByteBuffer.wrap(readFully(in, 4)).getInt();
            if (len < 28 || len > 12 + FRAME + 16) throw new BackupException(BAD_FILE);
            byte[] frame = readFully(in, len);
            int peek = in.read();
            boolean last = peek < 0;
            if (!last) in.unread(peek);
            byte[] pt;
            try {
                pt = open(frame, last);
            } catch (GeneralSecurityException e) {
                boolean other = false;
                try {
                    open(frame, !last);
                    other = true;
                } catch (GeneralSecurityException ignored) {
                }
                throw new BackupException(index == 0 && !other ? BAD_CODE : BAD_FILE);
            }
            cur = pt;
            pos = 0;
            ended = last;
            index++;
        }

        private boolean ensure(int need) throws IOException {
            while (cur.length - pos < need) {
                if (ended) return false;
                byte[] rest = Arrays.copyOfRange(cur, pos, cur.length);
                nextFrame();
                if (rest.length > 0) {
                    byte[] m = new byte[rest.length + cur.length];
                    System.arraycopy(rest, 0, m, 0, rest.length);
                    System.arraycopy(cur, 0, m, rest.length, cur.length);
                    cur = m;
                }
            }
            return true;
        }

        public Record next() throws IOException {
            if (!ensure(1)) return null;
            if (!ensure(5)) throw new BackupException(BAD_FILE);
            int type = cur[pos] & 0xff;
            int len = ByteBuffer.wrap(cur, pos + 1, 4).getInt();
            if (len < 0 || len > MAX_RECORD) throw new BackupException(BAD_FILE);
            pos += 5;
            ByteArrayOutputStream bo = new ByteArrayOutputStream(Math.min(len, 1 << 16));
            int left = len;
            while (left > 0) {
                if (pos == cur.length && !ensure(1)) throw new BackupException(BAD_FILE);
                int c = Math.min(left, cur.length - pos);
                bo.write(cur, pos, c);
                pos += c;
                left -= c;
            }
            return new Record(type, bo.toByteArray());
        }
    }
}
