package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

final class LanTransport extends Transport {
    private static final String TYPE = "_ripplo._tcp.";

    private static final class Peer {
        final InetAddress host;
        final int port;
        final String tag;
        long lastTry;
        Peer(InetAddress host, int port, String tag) { this.host = host; this.port = port; this.tag = tag; }
    }

    private NsdManager nsd;
    private ServerSocket server;
    private final Map<String, Peer> peers = new HashMap<>();
    private final Set<String> connecting = new HashSet<>();
    private final Map<String, Integer> resolveTries = new HashMap<>();
    private final ArrayDeque<NsdServiceInfo> toResolve = new ArrayDeque<>();
    private boolean resolving;
    private String serviceName;
    private NsdManager.RegistrationListener regListener;
    private NsdManager.DiscoveryListener discListener;

    LanTransport(Context ctx, MeshEngine engine) { super(ctx, engine); }

    @Override
    String name() { return "lan"; }

    @Override
    void startImpl() throws Exception {
        nsd = (NsdManager) ctx.getSystemService(Context.NSD_SERVICE);
        if (nsd == null) throw new IllegalStateException("no nsd");
        final ServerSocket ss = new ServerSocket(0);
        server = ss;
        Thread t = new Thread(() -> {
            try {
                while (!ss.isClosed()) {
                    Socket s = ss.accept();
                    open(s, false);
                }
            } catch (Exception ignored) {
            }
        }, "ripplo-lan-accept");
        t.setDaemon(true);
        t.start();

        serviceName = "ripplo-" + engine.nodeTag().substring(0, 8);
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName(serviceName);
        info.setServiceType(TYPE);
        info.setPort(ss.getLocalPort());
        info.setAttribute("nt", engine.nodeTag());
        regListener = new NsdManager.RegistrationListener() {
            @Override public void onRegistrationFailed(NsdServiceInfo i, int e) { log("register failed " + e); }
            @Override public void onUnregistrationFailed(NsdServiceInfo i, int e) { }
            @Override public void onServiceRegistered(NsdServiceInfo i) { }
            @Override public void onServiceUnregistered(NsdServiceInfo i) { }
        };
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, regListener);

        discListener = new NsdManager.DiscoveryListener() {
            @Override public void onStartDiscoveryFailed(String s, int e) { log("discovery failed " + e); }
            @Override public void onStopDiscoveryFailed(String s, int e) { }
            @Override public void onDiscoveryStarted(String s) { }
            @Override public void onDiscoveryStopped(String s) { }

            @Override
            public void onServiceFound(NsdServiceInfo i) {
                if (serviceName.equals(i.getServiceName())) return;
                log("found " + i.getServiceName());
                synchronized (LanTransport.this) {
                    toResolve.add(i);
                }
                resolveNext();
            }

            @Override
            public void onServiceLost(NsdServiceInfo i) {
                synchronized (LanTransport.this) { peers.remove(i.getServiceName()); }
            }
        };
        nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, discListener);
    }

    private void resolveNext() {
        NsdServiceInfo next;
        synchronized (this) {
            if (resolving || toResolve.isEmpty() || nsd == null) return;
            next = toResolve.poll();
            resolving = true;
        }
        try {
            nsd.resolveService(next, new NsdManager.ResolveListener() {
                @Override
                public void onResolveFailed(NsdServiceInfo i, int e) {
                    log("resolve failed " + e);
                    retryResolve(i);
                    done();
                }

                @Override
                public void onServiceResolved(NsdServiceInfo i) {
                    try { handleResolved(i); } finally { done(); }
                }
            });
        } catch (Exception e) {
            done();
        }
    }

    private void retryResolve(final NsdServiceInfo i) {
        final String name = i.getServiceName();
        int n;
        synchronized (this) {
            Integer t = resolveTries.get(name);
            n = t == null ? 1 : t + 1;
            resolveTries.put(name, n);
        }
        if (n > 5) return;
        Thread t = new Thread(() -> {
            try { Thread.sleep(1500L * n); } catch (InterruptedException e) { return; }
            synchronized (LanTransport.this) {
                if (nsd == null) return;
                toResolve.add(i);
            }
            resolveNext();
        }, "ripplo-lan-resolve");
        t.setDaemon(true);
        t.start();
    }

    private void done() {
        synchronized (this) { resolving = false; }
        resolveNext();
    }

    private void handleResolved(NsdServiceInfo i) {
        InetAddress host = i.getHost();
        if (host == null) return;
        byte[] nt = i.getAttributes() == null ? null : i.getAttributes().get("nt");
        String tag = nt == null ? "" : new String(nt, StandardCharsets.US_ASCII);
        if (tag.equals(engine.nodeTag())) return;
        Peer p = new Peer(host, i.getPort(), tag);
        synchronized (this) {
            peers.put(i.getServiceName(), p);
            resolveTries.remove(i.getServiceName());
        }
        connect(p);
    }

    private void connect(final Peer p) {
        final String key = p.host.getHostAddress() + ":" + p.port;
        synchronized (this) {
            if (connecting.contains(key)) return;
            if (!p.tag.isEmpty() && engine.hasLink(p.tag, "lan")) return;
            connecting.add(key);
            p.lastTry = System.currentTimeMillis();
        }
        Thread t = new Thread(() -> {
            try {
                Socket s = new Socket();
                s.connect(new InetSocketAddress(p.host, p.port), 5000);
                open(s, true);
            } catch (Exception e) {
                log("connect failed " + p.host.getHostAddress() + " " + e);
            }
            synchronized (LanTransport.this) { connecting.remove(key); }
        }, "ripplo-lan-connect");
        t.setDaemon(true);
        t.start();
    }

    private void open(Socket s, boolean outbound) throws java.io.IOException {
        s.setTcpNoDelay(true);
        new StreamLink(engine, "lan", outbound, s.getInputStream(), s.getOutputStream(), s).open();
    }

    @Override
    void tickImpl() {
        long now = System.currentTimeMillis();
        ArrayList<Peer> list;
        synchronized (this) { list = new ArrayList<>(peers.values()); }
        for (Peer p : list) if (now - p.lastTry > 4000) connect(p);
    }

    @Override
    void stopImpl() {
        try { if (nsd != null && discListener != null) nsd.stopServiceDiscovery(discListener); } catch (Exception ignored) { }
        try { if (nsd != null && regListener != null) nsd.unregisterService(regListener); } catch (Exception ignored) { }
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        discListener = null;
        regListener = null;
        server = null;
        synchronized (this) {
            peers.clear();
            resolveTries.clear();
            toResolve.clear();
            resolving = false;
        }
    }
}
