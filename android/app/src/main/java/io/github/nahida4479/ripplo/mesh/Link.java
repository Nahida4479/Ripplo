package io.github.nahida4479.ripplo.mesh;

import java.io.IOException;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

abstract class Link {
    static final long QUEUE_CAP = 32L * 1024 * 1024;
    static final long STALE_NANOS = 12L * 1000000000L;

    final MeshEngine engine;
    final String medium;
    final boolean outbound;
    volatile String node;
    volatile String note = "";
    /** Peer tag from the hello, also kept for links the engine closes as duplicates (node stays null for those). */
    volatile String helloTag = null;
    /** Called once with the peer tag when its hello arrives. */
    volatile java.util.function.Consumer<String> helloHook;
    volatile long kbps;
    volatile long rttMs;
    volatile long lastRx = System.nanoTime();
    int strikes;
    volatile long pingNonce;
    volatile long pingStartNanos;
    volatile int pingBits;
    long windowStart;
    int windowCount;
    final AtomicBoolean alive = new AtomicBoolean(true);
    private final LinkedBlockingQueue<byte[]> queue = new LinkedBlockingQueue<>();
    private final AtomicLong queued = new AtomicLong();
    private final byte[] lenBuf = new byte[4];
    private int lenGot;
    private byte[] body;
    private int bodyGot;
    private Thread writer;
    final long born = System.nanoTime();

    Link(MeshEngine engine, String medium, boolean outbound) {
        this.engine = engine;
        this.medium = medium;
        this.outbound = outbound;
        this.kbps = MeshEngine.nominalKbps(medium);
    }

    abstract void writeFrame(byte[] frame) throws IOException;

    abstract void closeImpl();

    final void start() {
        writer = new Thread(() -> {
            try {
                while (alive.get()) {
                    byte[] f = queue.poll(1, TimeUnit.SECONDS);
                    if (f == null) continue;
                    writeFrame(f);
                    queued.addAndGet(-f.length);
                }
            } catch (Exception e) {
                Diag.i("write failed " + medium + " node=" + (node == null ? "none" : node.substring(0, 8)) + " " + e);
                close();
            }
        }, "ripplo-link-w");
        writer.setDaemon(true);
        writer.start();
    }

    final boolean stale(long nowNanos) {
        return nowNanos - lastRx > STALE_NANOS;
    }

    final boolean send(byte[] packet) {
        if (!alive.get()) return false;
        byte[] f = new byte[packet.length + 4];
        f[0] = (byte) (packet.length >>> 24);
        f[1] = (byte) (packet.length >>> 16);
        f[2] = (byte) (packet.length >>> 8);
        f[3] = (byte) packet.length;
        System.arraycopy(packet, 0, f, 4, packet.length);
        if (queued.addAndGet(f.length) > QUEUE_CAP) {
            queued.addAndGet(-f.length);
            return false;
        }
        return queue.offer(f);
    }

    final void onBytes(byte[] d, int off, int len) {
        lastRx = System.nanoTime();
        try {
            while (len > 0) {
                if (body == null) {
                    int n = Math.min(4 - lenGot, len);
                    System.arraycopy(d, off, lenBuf, lenGot, n);
                    lenGot += n; off += n; len -= n;
                    if (lenGot < 4) return;
                    int l = ((lenBuf[0] & 0xFF) << 24) | ((lenBuf[1] & 0xFF) << 16) | ((lenBuf[2] & 0xFF) << 8) | (lenBuf[3] & 0xFF);
                    if (l < Packet.HEADER || l > Packet.MAX_PACKET) throw new IOException("bad frame");
                    body = new byte[l];
                    bodyGot = 0;
                } else {
                    int n = Math.min(body.length - bodyGot, len);
                    System.arraycopy(d, off, body, bodyGot, n);
                    bodyGot += n; off += n; len -= n;
                    if (bodyGot == body.length) {
                        byte[] f = body;
                        body = null;
                        lenGot = 0;
                        engine.onFrame(this, f);
                    }
                }
            }
        } catch (IOException e) {
            Diag.i("rx error " + medium + " " + e);
            close();
        }
    }

    final void close() {
        if (alive.compareAndSet(true, false)) {
            Diag.i("close " + medium + " out=" + outbound + " node=" + (node == null ? "none" : node.substring(0, 8)) + " age=" + (System.nanoTime() - born) / 1000000L + "ms");
            try { closeImpl(); } catch (Exception ignored) { }
            engine.linkDown(this);
        }
    }
}
