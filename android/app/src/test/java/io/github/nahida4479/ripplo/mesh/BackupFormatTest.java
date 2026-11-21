package io.github.nahida4479.ripplo.mesh;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.fail;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Random;
import org.junit.Test;

public class BackupFormatTest {
    private static final byte[] SALT = new byte[16];
    private static final byte[] KEY = BackupFormat.pbkdf2("123456789012345678901234567890".getBytes(), SALT, 3, 32);

    private static byte[] hexb(String s) {
        byte[] o = new byte[s.length() / 2];
        for (int i = 0; i < o.length; i++) o[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        return o;
    }

    private static byte[] write(List<byte[]> recs) throws IOException {
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        try (BackupFormat.Writer w = new BackupFormat.Writer(bo, BackupFormat.header(3, SALT), KEY)) {
            for (int i = 0; i < recs.size(); i++) w.record(i % 5 + 1, recs.get(i));
        }
        return bo.toByteArray();
    }

    private static List<BackupFormat.Record> read(byte[] file, byte[] key) throws IOException {
        ByteArrayInputStream in = new ByteArrayInputStream(file);
        BackupFormat.Reader r = new BackupFormat.Reader(in, BackupFormat.readHeader(in), key);
        List<BackupFormat.Record> out = new ArrayList<>();
        BackupFormat.Record rec;
        while ((rec = r.next()) != null) out.add(rec);
        return out;
    }

    private static String codeOf(byte[] file, byte[] key) {
        try {
            read(file, key);
            return null;
        } catch (BackupFormat.BackupException e) {
            return e.code;
        } catch (IOException e) {
            return "io";
        }
    }

    @Test
    public void pbkdf2Vectors() {
        assertArrayEquals(hexb("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
                BackupFormat.pbkdf2("password".getBytes(), "salt".getBytes(), 1, 32));
        assertArrayEquals(hexb("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
                BackupFormat.pbkdf2("password".getBytes(), "salt".getBytes(), 2, 32));
    }

    @Test
    public void roundtripSpansFrames() throws Exception {
        Random rnd = new Random(1);
        List<byte[]> recs = new ArrayList<>();
        for (int i = 0; i < 48; i++) {
            byte[] b = new byte[64 * 1024 + rnd.nextInt(1000)];
            rnd.nextBytes(b);
            recs.add(b);
        }
        byte[] file = write(recs);
        List<BackupFormat.Record> got = read(file, KEY);
        assertEquals(recs.size(), got.size());
        for (int i = 0; i < recs.size(); i++) {
            assertEquals(i % 5 + 1, got.get(i).type);
            assertArrayEquals(recs.get(i), got.get(i).data);
        }
    }

    @Test
    public void emptyAndHugeRecord() throws Exception {
        byte[] big = new byte[BackupFormat.FRAME + 5];
        new Random(2).nextBytes(big);
        List<BackupFormat.Record> got = read(write(Arrays.asList(new byte[0], big)), KEY);
        assertEquals(2, got.size());
        assertEquals(0, got.get(0).data.length);
        assertArrayEquals(big, got.get(1).data);
    }

    @Test
    public void wrongCodeRejected() throws Exception {
        byte[] file = write(Arrays.asList(new byte[100]));
        byte[] other = BackupFormat.pbkdf2("000000000000000000000000000000".getBytes(), SALT, 3, 32);
        assertEquals(BackupFormat.BAD_CODE, codeOf(file, other));
    }

    @Test
    public void truncatedLastFrameRejected() throws Exception {
        byte[] b = new byte[3 * BackupFormat.FRAME];
        new Random(3).nextBytes(b);
        byte[] file = write(Arrays.asList(b));
        int hdr = 30;
        int off = hdr;
        int frames = 0;
        List<Integer> ends = new ArrayList<>();
        while (off < file.length) {
            off += 4 + ((file[off] & 0xff) << 24 | (file[off + 1] & 0xff) << 16 | (file[off + 2] & 0xff) << 8 | (file[off + 3] & 0xff));
            ends.add(off);
            frames++;
        }
        assertEquals(4, frames);
        assertNull(codeOf(file, KEY));
        assertEquals(BackupFormat.BAD_FILE, codeOf(Arrays.copyOf(file, ends.get(2)), KEY));
        assertEquals(BackupFormat.BAD_FILE, codeOf(Arrays.copyOf(file, ends.get(0)), KEY));
        assertEquals(BackupFormat.BAD_FILE, codeOf(Arrays.copyOf(file, file.length - 1), KEY));
    }

    @Test
    public void tamperAndHeaderBindingRejected() throws Exception {
        byte[] file = write(Arrays.asList(new byte[1000]));
        byte[] flipped = file.clone();
        flipped[flipped.length - 20] ^= 1;
        assertNotNull(codeOf(flipped, KEY));
        byte[] hdr = file.clone();
        hdr[20] ^= 1;
        assertNotNull(codeOf(hdr, KEY));
        byte[] factor = file.clone();
        factor[9] = 1;
        assertEquals(BackupFormat.NEED_FACTOR, codeOf(factor, KEY));
        try {
            read(new byte[10], KEY);
            fail();
        } catch (BackupFormat.BackupException e) {
            assertEquals(BackupFormat.BAD_FILE, e.code);
        }
    }

    @Test
    public void reorderedFramesRejected() throws Exception {
        byte[] b = new byte[2 * BackupFormat.FRAME + 10];
        byte[] file = write(Arrays.asList(b));
        int l0 = 4 + ((file[30] & 0xff) << 24 | (file[31] & 0xff) << 16 | (file[32] & 0xff) << 8 | (file[33] & 0xff));
        int s1 = 30 + l0;
        int l1 = 4 + ((file[s1] & 0xff) << 24 | (file[s1 + 1] & 0xff) << 16 | (file[s1 + 2] & 0xff) << 8 | (file[s1 + 3] & 0xff));
        byte[] sw = new byte[file.length];
        System.arraycopy(file, 0, sw, 0, 30);
        System.arraycopy(file, s1, sw, 30, l1);
        System.arraycopy(file, 30, sw, 30 + l1, l0);
        System.arraycopy(file, s1 + l1, sw, 30 + l1 + l0, file.length - s1 - l1);
        assertNotNull(codeOf(sw, KEY));
    }
}
