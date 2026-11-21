package io.github.nahida4479.ripplo.mesh;

import java.security.SecureRandom;

final class Packet {
    static final int LINK_HELLO = 1, PING = 2, PONG = 3, DATA = 10, ACK = 11, DEAD_END = 12,
            DISCOVER = 13, REPLY = 14, APP = 20;
    static final int HEADER = 36, MAX_PACKET = 65536, TTL_DEFAULT = 8;
    private static final SecureRandom RNG = new SecureRandom();

    int type, ttl, hops;
    byte[] id, dest, payload;

    Packet(int type, int ttl, int hops, byte[] id, byte[] dest, byte[] payload) {
        this.type = type; this.ttl = ttl; this.hops = hops;
        this.id = id; this.dest = dest; this.payload = payload;
    }

    static byte[] newId() { byte[] b = new byte[16]; RNG.nextBytes(b); return b; }

    static Packet make(int type, byte[] dest, byte[] payload) {
        return new Packet(type, TTL_DEFAULT, 0, newId(), dest, payload);
    }

        static Packet decode(byte[] b) {
        if (b.length < HEADER || b.length > MAX_PACKET || b[0] != 1) throw new IllegalArgumentException("bad packet");
        byte[] id = new byte[16], dest = new byte[16], payload = new byte[b.length - HEADER];
        System.arraycopy(b, 4, id, 0, 16);
        System.arraycopy(b, 20, dest, 0, 16);
        System.arraycopy(b, HEADER, payload, 0, payload.length);
        return new Packet(b[1] & 0xFF, b[2] & 0xFF, b[3] & 0xFF, id, dest, payload);
    }

    byte[] encode() {
        byte[] b = new byte[HEADER + payload.length];
        b[0] = 1; b[1] = (byte) type; b[2] = (byte) ttl; b[3] = (byte) hops;
        System.arraycopy(id, 0, b, 4, 16);
        System.arraycopy(dest, 0, b, 20, 16);
        System.arraycopy(payload, 0, b, HEADER, payload.length);
        return b;
    }

    Packet copy() { return new Packet(type, ttl, hops, id, dest, payload); }

    static String hex(byte[] b) {
        char[] c = new char[b.length * 2];
        for (int i = 0; i < b.length; i++) {
            c[2 * i] = "0123456789abcdef".charAt((b[i] >> 4) & 15);
            c[2 * i + 1] = "0123456789abcdef".charAt(b[i] & 15);
        }
        return new String(c);
    }

    static byte[] unhex(String s) {
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return b;
    }
}
