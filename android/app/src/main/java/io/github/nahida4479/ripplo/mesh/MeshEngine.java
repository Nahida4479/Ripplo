package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.PowerManager;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public final class MeshEngine implements Router.Host {
    public interface Listener {
        void onPacket(byte[] packet, String from);
        void onNeighbor(String node, boolean up, String medium, long kbps);
    }

    private static MeshEngine instance;

    public static synchronized MeshEngine get(Context ctx) {
        if (instance == null) instance = new MeshEngine(ctx.getApplicationContext());
        return instance;
    }

    static long nominalKbps(String medium) {
        switch (medium) {
            case "lan":
            case "wifi-aware":
            case "wifi-direct":
                return 20000;
            case "l2cap":
                return 300;
            default:
                return 50;
        }
    }

    final Context ctx;
    final ExecutorService rx = Executors.newSingleThreadExecutor(r -> daemon(r, "ripplo-rx"));
    private final ScheduledExecutorService sched = Executors.newScheduledThreadPool(2, r -> daemon(r, "ripplo-sched"));
    private final SharedPreferences prefs;
    private final Inbox inbox;
    private final PowerManager.WakeLock wake;
    private final String nodeTag;
    private final Object lock = new Object();
    private final Map<String, List<Link>> byNode = new HashMap<>();
    private final Set<Link> pending = new HashSet<>();
    private final List<Transport> transports = new ArrayList<>();
    private volatile Router router;
    private volatile boolean running;
    private volatile byte[] selfTag;
    private ScheduledFuture<?> tickTask;
    private volatile Listener listener;
    private volatile boolean jsAttached;

    private static Thread daemon(Runnable r, String name) {
        Thread t = new Thread(r, name);
        t.setDaemon(true);
        return t;
    }

    private MeshEngine(Context ctx) {
        this.ctx = ctx;
        prefs = ctx.getSharedPreferences("ripplo_mesh", Context.MODE_PRIVATE);
        inbox = new Inbox(ctx);
        byte[] t = Packet.newId();
        nodeTag = Packet.hex(t);
        PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ripplo:mesh");
        wake.setReferenceCounted(false);
    }

    public String nodeTag() { return nodeTag; }

    public boolean isRunning() { return running; }

    public boolean background() { return prefs.getBoolean("background", true); }

    public void setListener(Listener l) { listener = l; }

    public void setJsAttached(boolean v) { jsAttached = v; }

    public boolean jsAttached() { return jsAttached; }

    public synchronized void start(byte[] self, boolean background, boolean launchService) {
        prefs.edit().putString("selfTag", Packet.hex(self)).putBoolean("background", background).apply();
        if (running && java.util.Arrays.equals(self, selfTag)) {
            if (launchService) MeshService.launch(ctx);
            return;
        }
        if (running) stop(false);
        selfTag = self;
        router = new Router(this, self);
        running = true;
        if (Build.VERSION.SDK_INT >= 29) transports.add(new WifiAwareTransport(ctx, this));
        transports.add(new BleTransport(ctx, this));
        transports.add(new LanTransport(ctx, this));
        transports.add(new WifiDirectTransport(ctx, this));
        for (Transport t : transports) sched.execute(t::start);
        tickTask = sched.scheduleWithFixedDelay(this::tick, 60, 60, TimeUnit.SECONDS);
        if (launchService) MeshService.launch(ctx);
    }

    public synchronized boolean resumeFromPrefs() {
        String s = prefs.getString("selfTag", null);
        if (s == null || s.length() != 32 || !background()) return false;
        start(Packet.unhex(s), true, false);
        return true;
    }

    public void stop() { stop(true); }

    private synchronized void stop(boolean clear) {
        running = false;
        if (tickTask != null) tickTask.cancel(false);
        for (Transport t : transports) t.stop();
        transports.clear();
        List<Link> all = new ArrayList<>();
        synchronized (lock) {
            for (List<Link> l : byNode.values()) all.addAll(l);
            all.addAll(pending);
        }
        for (Link l : all) l.close();
        router = null;
        if (clear) {
            prefs.edit().remove("selfTag").apply();
            ctx.stopService(new Intent(ctx, MeshService.class));
        }
    }

    private void tick() {
        List<Link> all = new ArrayList<>();
        synchronized (lock) {
            for (List<Link> l : byNode.values()) all.addAll(l);
        }
        for (Link l : all) sendPing(l);
        for (Transport t : new ArrayList<>(transports)) t.tick();
    }

    void touchWake() {
        try { wake.acquire(30000); } catch (RuntimeException ignored) { }
    }

    boolean addLink(Link link) {
        if (!running) { link.close(); return false; }
        synchronized (lock) { pending.add(link); }
        link.start();
        link.send(Packet.make(Packet.LINK_HELLO, new byte[16], Packet.unhex(nodeTag)).encode());
        return true;
    }

    boolean hasLink(String node, String medium) {
        synchronized (lock) {
            List<Link> l = byNode.get(node);
            if (l != null) for (Link k : l) if (k.medium.equals(medium)) return true;
        }
        return false;
    }

    void linkDown(Link link) {
        boolean down = false;
        String node = link.node;
        synchronized (lock) {
            pending.remove(link);
            if (node != null) {
                List<Link> l = byNode.get(node);
                if (l != null && l.remove(link) && l.isEmpty()) {
                    byNode.remove(node);
                    down = true;
                }
            }
        }
        if (down) {
            Router r = router;
            if (r != null) r.linkDown(node);
            emitNeighbor(node, false, link.medium, link.kbps);
        }
    }

    private void emitNeighbor(String node, boolean up, String medium, long kbps) {
        Listener l = listener;
        if (l != null) l.onNeighbor(node, up, medium, kbps);
    }

    private List<Link> sortedLinks(String node) {
        List<Link> out;
        synchronized (lock) {
            List<Link> l = byNode.get(node);
            out = l == null ? new ArrayList<Link>() : new ArrayList<>(l);
        }
        Collections.sort(out, (a, b) -> Long.compare(b.kbps, a.kbps));
        return out;
    }

    void onFrame(Link link, byte[] frame) {
        Router r = router;
        if (r == null || !link.alive.get()) return;
        long now = System.currentTimeMillis();
        if (now - link.windowStart >= 1000) {
            link.windowStart = now;
            link.windowCount = 0;
        }
        if (++link.windowCount > 200) return;
        Packet p;
        try {
            p = Packet.decode(frame);
        } catch (IllegalArgumentException e) {
            link.close();
            return;
        }
        switch (p.type) {
            case Packet.LINK_HELLO:
                if (p.payload.length != 16) { link.close(); return; }
                onHello(link, Packet.hex(p.payload));
                return;
            case Packet.PING:
                if (link.node != null && p.payload.length >= 16) {
                    byte[] echo = new byte[16];
                    System.arraycopy(p.payload, 0, echo, 0, 16);
                    link.send(Packet.make(Packet.PONG, new byte[16], echo).encode());
                }
                return;
            case Packet.PONG:
                onPong(link, p);
                return;
            default:
                if (link.node == null) return;
                if (p.type == Packet.DATA || p.type == Packet.ACK) touchWake();
                r.onPacket(p, link.node);
        }
    }

    private void onHello(Link link, String tag) {
        if (link.node != null) return;
        if (tag.equals(nodeTag)) { link.close(); return; }
        List<Link> toClose = new ArrayList<>();
        boolean loser = false;
        boolean first;
        synchronized (lock) {
            pending.remove(link);
            List<Link> list = byNode.get(tag);
            if (list == null) {
                list = new ArrayList<>();
                byNode.put(tag, list);
            }
            first = list.isEmpty();
            String initNew = link.outbound ? nodeTag : tag;
            for (Link o : list) {
                if (!o.medium.equals(link.medium)) continue;
                String initOld = o.outbound ? nodeTag : tag;
                if (initNew.compareTo(initOld) < 0) toClose.add(o);
                else loser = true;
            }
            if (loser) {
                if (list.isEmpty()) byNode.remove(tag);
            } else {
                link.node = tag;
                list.add(link);
            }
        }
        if (loser) { link.close(); return; }
        for (Link o : toClose) o.close();
        if (first) emitNeighbor(tag, true, link.medium, link.kbps);
        sendPing(link);
    }

    private void sendPing(Link link) {
        if (link.node == null || !link.alive.get()) return;
        int filler = link.medium.equals("ble") ? 2048 : 16384;
        ByteBuffer b = ByteBuffer.allocate(16 + filler);
        long nonce = new java.security.SecureRandom().nextLong();
        b.putLong(nonce).putLong(System.currentTimeMillis());
        Packet p = Packet.make(Packet.PING, new byte[16], b.array());
        link.pingNonce = nonce;
        link.pingBits = (Packet.HEADER + b.capacity() + 4) * 8;
        link.pingStartNanos = System.nanoTime();
        link.send(p.encode());
    }

    private void onPong(Link link, Packet p) {
        if (link.node == null || p.payload.length < 8 || link.pingStartNanos == 0) return;
        if (ByteBuffer.wrap(p.payload).getLong() != link.pingNonce) return;
        long ms = Math.max(1, (System.nanoTime() - link.pingStartNanos) / 1000000L);
        link.pingStartNanos = 0;
        link.rttMs = ms;
        link.kbps = Math.max(1, link.pingBits / ms);
        List<Link> sorted = sortedLinks(link.node);
        if (!sorted.isEmpty()) emitNeighbor(link.node, true, sorted.get(0).medium, sorted.get(0).kbps);
    }

    @Override
    public boolean send(String to, Packet p) {
        byte[] bytes = p.encode();
        if (p.type == Packet.DATA || p.type == Packet.ACK) touchWake();
        for (Link l : sortedLinks(to)) if (l.send(bytes)) return true;
        return false;
    }

    @Override
    public List<String> neighbors() {
        synchronized (lock) { return new ArrayList<>(byNode.keySet()); }
    }

    @Override
    public void deliver(Packet p, String from) {
        Listener l = listener;
        if (l != null && jsAttached) l.onPacket(p.encode(), from);
    }

    @Override
    public boolean persist(Packet p, String from) {
        if (jsAttached && listener != null) return true;
        if (!inbox.add(p.encode(), from)) return false;
        if (p.payload.length > 0 && p.payload[0] == 1) Notifier.newMessage(ctx);
        return true;
    }

    public List<Inbox.Item> drainInbox() { return inbox.drain(); }

    public int sendFromJs(byte[] bytes) {
        Router r = router;
        if (r == null) throw new IllegalStateException("not started");
        Packet p = Packet.decode(bytes);
        if (p.type != Packet.DATA && p.type != Packet.DISCOVER && p.type != Packet.REPLY) throw new IllegalArgumentException("type");
        int n = r.onPacket(p, Router.SELF);
        return p.type == Packet.REPLY ? neighbors().size() : n;
    }

    public boolean sendApp(String node, byte[] payload) {
        Packet p = new Packet(Packet.APP, 1, 0, Packet.newId(), new byte[16], payload);
        if (p.encode().length > Packet.MAX_PACKET) throw new IllegalArgumentException("size");
        return send(node, p);
    }

    public JSONArray neighborsJson() {
        JSONArray out = new JSONArray();
        for (String node : neighbors()) {
            List<Link> links = sortedLinks(node);
            if (links.isEmpty()) continue;
            try {
                JSONObject o = new JSONObject();
                o.put("node", node);
                o.put("medium", links.get(0).medium);
                o.put("kbps", links.get(0).kbps);
                o.put("rttMs", links.get(0).rttMs);
                JSONArray ls = new JSONArray();
                for (Link l : links) ls.put(new JSONObject().put("medium", l.medium).put("kbps", l.kbps));
                o.put("links", ls);
                out.put(o);
            } catch (JSONException ignored) {
            }
        }
        return out;
    }
}
