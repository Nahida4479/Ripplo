package io.github.nahida4479.ripplo.mesh;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class Router {
    static final String SELF = "self";
    private static final long EXPIRY_MS = 10 * 60 * 1000L;
    private static final int SEEN_CAP = 20000;

    interface Host {
                boolean send(String to, Packet p);
        List<String> neighbors();
        void deliver(Packet p, String from);
                boolean persist(Packet p, String from);
    }

    private static final class Rev {
        String prev; String dest; int pending; boolean done; long t;
    }

    private static final class Route {
        String n; long t;
        Route(String n, long t) { this.n = n; this.t = t; }
    }

    private final Host host;
    private final byte[] selfTag;
    private final String selfHex;
    private final LinkedHashMap<String, Long> seen = new LinkedHashMap<>();
    private final LinkedHashMap<String, Rev> reverse = new LinkedHashMap<>();
    private final Map<String, Route> routes = new HashMap<>();

    Router(Host host, byte[] selfTag) {
        this.host = host; this.selfTag = selfTag; this.selfHex = Packet.hex(selfTag);
    }

    synchronized void linkDown(String n) {
        for (Iterator<Route> it = routes.values().iterator(); it.hasNext(); ) if (it.next().n.equals(n)) it.remove();
    }

        synchronized int onPacket(Packet p, String from) {
        expire();
        String id = Packet.hex(p.id), dest = Packet.hex(p.dest);
        boolean fromSelf = SELF.equals(from);
        switch (p.type) {
            case Packet.APP:
                host.deliver(p, from);
                return 0;
            case Packet.DATA:
            case Packet.DISCOVER: {
                if (isSeen(p, id)) {
                    if (!fromSelf) sendDeadEnd(from, id);
                    return 0;
                }
                markSeen(p, id);
                Rev r = new Rev();
                r.prev = from; r.dest = dest; r.t = System.currentTimeMillis();
                reverse.put(id, r);
                if (p.type == Packet.DATA && Arrays.equals(p.dest, selfTag)) {
                    if (!host.persist(p, from)) { deadEnd(id); return 0; }
                    if (!fromSelf) send(from, Packet.ACK, p.id);
                    host.deliver(p, from);
                    return 0;
                }
                if (p.type == Packet.DISCOVER && !fromSelf) host.deliver(p, from);
                if (!fromSelf && p.ttl <= 1) { sendDeadEnd(from, id); return 0; }
                Packet q = p.copy();
                if (!fromSelf) {
                    q.ttl = Math.min(p.ttl, Packet.TTL_DEFAULT) - 1;
                    q.hops = Math.min(p.hops + 1, 255);
                }
                Route route = p.type == Packet.DATA ? routes.get(dest) : null;
                List<String> nb = host.neighbors();
                List<String> targets = new ArrayList<>();
                if (route != null && nb.contains(route.n) && !route.n.equals(from)) targets.add(route.n);
                else for (String n : nb) if (!n.equals(from)) targets.add(n);
                int sent = 0;
                for (String n : targets) if (host.send(n, q)) sent++;
                if (sent == 0) { deadEnd(id); return 0; }
                r.pending = sent;
                return sent;
            }
            case Packet.ACK:
            case Packet.REPLY: {
                if (isSeen(p, id)) return 0;
                markSeen(p, id);
                Rev r = reverse.get(dest);
                if (r == null) return 0;
                if (p.type == Packet.ACK) {
                    if (!fromSelf) routes.put(r.dest, new Route(from, System.currentTimeMillis()));
                    r.done = true;
                }
                Packet q = p.copy();
                q.hops = Math.min(p.hops + 1, 255);
                if (SELF.equals(r.prev)) host.deliver(q, SELF);
                else host.send(r.prev, q);
                return 0;
            }
            case Packet.DEAD_END: {
                if (isSeen(p, id)) return 0;
                markSeen(p, id);
                Rev r = reverse.get(dest);
                if (r == null || r.done) return 0;
                if (--r.pending <= 0) deadEnd(dest);
                return 0;
            }
            default:
                return 0;
        }
    }

    private void deadEnd(String id) {
        Rev r = reverse.get(id);
        if (r == null) return;
        r.done = true;
        if (SELF.equals(r.prev)) host.deliver(Packet.make(Packet.DEAD_END, Packet.unhex(id), new byte[0]), SELF);
        else sendDeadEnd(r.prev, id);
    }

    private void sendDeadEnd(String to, String id) { send(to, Packet.DEAD_END, Packet.unhex(id)); }

    private void send(String to, int type, byte[] dest) { host.send(to, Packet.make(type, dest, new byte[0])); }

    private boolean isSeen(Packet p, String id) { return seen.containsKey(p.type + ":" + id); }

    private void markSeen(Packet p, String id) {
        seen.put(p.type + ":" + id, System.currentTimeMillis());
        if (seen.size() > SEEN_CAP) { Iterator<String> it = seen.keySet().iterator(); it.next(); it.remove(); }
    }

    private void expire() {
        long cutoff = System.currentTimeMillis() - EXPIRY_MS;
        for (Iterator<Long> it = seen.values().iterator(); it.hasNext(); ) { if (it.next() > cutoff) break; it.remove(); }
        for (Iterator<Rev> it = reverse.values().iterator(); it.hasNext(); ) { if (it.next().t > cutoff) break; it.remove(); }
        for (Iterator<Route> it = routes.values().iterator(); it.hasNext(); ) if (it.next().t <= cutoff) it.remove();
    }
}
