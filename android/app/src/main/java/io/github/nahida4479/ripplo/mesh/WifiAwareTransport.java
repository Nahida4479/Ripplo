package io.github.nahida4479.ripplo.mesh;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.wifi.aware.AttachCallback;
import android.net.wifi.aware.DiscoverySessionCallback;
import android.net.wifi.aware.PeerHandle;
import android.net.wifi.aware.PublishConfig;
import android.net.wifi.aware.PublishDiscoverySession;
import android.net.wifi.aware.SubscribeConfig;
import android.net.wifi.aware.SubscribeDiscoverySession;
import android.net.wifi.aware.WifiAwareManager;
import android.net.wifi.aware.WifiAwareNetworkInfo;
import android.net.wifi.aware.WifiAwareNetworkSpecifier;
import android.net.wifi.aware.WifiAwareSession;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import java.net.Inet6Address;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

final class WifiAwareTransport extends Transport {
    private static final String SERVICE = "ripplo";
    private static final String PSK = "ripplo-mesh-aware-v1";
    private static final int PORT = 47322;

    private WifiAwareManager manager;
    private ConnectivityManager cm;
    private WifiAwareSession session;
    private PublishDiscoverySession pub;
    private SubscribeDiscoverySession sub;
    private HandlerThread thread;
    private Handler handler;
    private ServerSocket server;
    private int messageId;
    private final Map<String, Long> attempts = new HashMap<>();
    private final Map<Integer, ConnectivityManager.NetworkCallback> callbacks = new HashMap<>();

    WifiAwareTransport(Context ctx, MeshEngine engine) { super(ctx, engine); }

    @Override
    String name() { return "wifi-aware"; }

    @Override
    @SuppressWarnings("MissingPermission")
    void startImpl() throws Exception {
        if (Build.VERSION.SDK_INT < 29 || !ctx.getPackageManager().hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) throw new UnsupportedOperationException("no aware");
        String perm = Build.VERSION.SDK_INT >= 33 ? Manifest.permission.NEARBY_WIFI_DEVICES : Manifest.permission.ACCESS_FINE_LOCATION;
        if (!has(perm)) throw new SecurityException("wifi permission");
        manager = (WifiAwareManager) ctx.getSystemService(Context.WIFI_AWARE_SERVICE);
        cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (manager == null || cm == null || !manager.isAvailable()) throw new IllegalStateException("aware unavailable");
        thread = new HandlerThread("ripplo-aware");
        thread.start();
        handler = new Handler(thread.getLooper());

        final ServerSocket ss = new ServerSocket();
        ss.setReuseAddress(true);
        ss.bind(new InetSocketAddress(PORT));
        server = ss;
        Thread t = new Thread(() -> {
            try {
                while (!ss.isClosed()) open(ss.accept(), false);
            } catch (Exception ignored) {
            }
        }, "ripplo-aware-accept");
        t.setDaemon(true);
        t.start();

        manager.attach(new AttachCallback() {
            @Override
            public void onAttached(WifiAwareSession s) {
                log("attached");
                session = s;
                publish();
                subscribe();
            }
        }, handler);
    }

    @SuppressWarnings("MissingPermission")
    private void publish() {
        PublishConfig cfg = new PublishConfig.Builder()
                .setServiceName(SERVICE)
                .setServiceSpecificInfo(engine.nodeTag().getBytes(StandardCharsets.US_ASCII))
                .build();
        session.publish(cfg, new DiscoverySessionCallback() {
            @Override
            public void onPublishStarted(PublishDiscoverySession s) { pub = s; }

            @Override
            public void onMessageReceived(PeerHandle peer, byte[] message) { respond(peer); }
        }, handler);
    }

    @SuppressWarnings("MissingPermission")
    private void subscribe() {
        SubscribeConfig cfg = new SubscribeConfig.Builder().setServiceName(SERVICE).build();
        session.subscribe(cfg, new DiscoverySessionCallback() {
            @Override
            public void onSubscribeStarted(SubscribeDiscoverySession s) { sub = s; }

            @Override
            public void onServiceDiscovered(PeerHandle peer, byte[] info, List<byte[]> filter) {
                if (info == null) return;
                String tag = new String(info, StandardCharsets.US_ASCII);
                log("discovered " + tag.substring(0, Math.min(8, tag.length())));
                if (!tag.equals(engine.nodeTag())) {
                    engine.noteSeen(tag, "wifi-aware");
                    handles.put(tag, peer);
                }
                if (engine.nodeTag().compareTo(tag) >= 0 || engine.hasLink(tag, "wifi-aware")) return;
                long now = System.currentTimeMillis();
                synchronized (attempts) {
                    Long last = attempts.get(tag);
                    if (last != null && now - last < 20000) return;
                    attempts.put(tag, now);
                }
                initiate(peer);
            }

            @Override
            public void onMessageSendSucceeded(int id) {
                PeerHandle peer;
                synchronized (pendingPeers) { peer = pendingPeers.remove(id); }
                if (peer != null) requestInitiator(peer);
            }
        }, handler);
    }

    private final Map<Integer, PeerHandle> pendingPeers = new HashMap<>();
    private final Map<String, PeerHandle> handles = new java.util.concurrent.ConcurrentHashMap<>();

    @Override
    boolean forceConnect(String node, String option) {
        PeerHandle h = handles.get(node);
        if (h == null || sub == null) {
            log("force: peer not discovered");
            return false;
        }
        initiate(h);
        return true;
    }

    private void initiate(PeerHandle peer) {
        SubscribeDiscoverySession s = sub;
        if (s == null) return;
        int id;
        synchronized (pendingPeers) {
            id = ++messageId;
            pendingPeers.put(id, peer);
        }
        s.sendMessage(peer, id, new byte[]{1});
    }

    private void respond(PeerHandle peer) {
        PublishDiscoverySession s = pub;
        if (s == null || cm == null) return;
        WifiAwareNetworkSpecifier spec = new WifiAwareNetworkSpecifier.Builder(s, peer).setPskPassphrase(PSK).setPort(PORT).build();
        request(spec, false);
    }

    private void requestInitiator(PeerHandle peer) {
        SubscribeDiscoverySession s = sub;
        if (s == null || cm == null) return;
        WifiAwareNetworkSpecifier spec = new WifiAwareNetworkSpecifier.Builder(s, peer).setPskPassphrase(PSK).build();
        request(spec, true);
    }

    private void request(WifiAwareNetworkSpecifier spec, final boolean initiator) {
        NetworkRequest req = new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
                .setNetworkSpecifier(spec)
                .build();
        final int key;
        synchronized (callbacks) { key = callbacks.size() + (int) (System.nanoTime() & 0xFFFFF); }
        ConnectivityManager.NetworkCallback cb = new ConnectivityManager.NetworkCallback() {
            private boolean connected;

            @Override
            public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) {
                if (!initiator || connected) return;
                if (!(caps.getTransportInfo() instanceof WifiAwareNetworkInfo)) return;
                WifiAwareNetworkInfo info = (WifiAwareNetworkInfo) caps.getTransportInfo();
                final Inet6Address addr = info.getPeerIpv6Addr();
                final int port = info.getPort();
                if (addr == null || port <= 0) return;
                connected = true;
                log("network ready port=" + port);
                final Network net = network;
                Thread t = new Thread(() -> {
                    try {
                        Socket s = net.getSocketFactory().createSocket(addr, port);
                        open(s, true);
                    } catch (Exception ignored) {
                    }
                }, "ripplo-aware-connect");
                t.setDaemon(true);
                t.start();
            }

            @Override
            public void onLost(Network network) { release(key); }

            @Override
            public void onUnavailable() { log("network unavailable"); release(key); }
        };
        synchronized (callbacks) { callbacks.put(key, cb); }
        try {
            cm.requestNetwork(req, cb, 30000);
        } catch (RuntimeException e) {
            release(key);
        }
    }

    private void release(int key) {
        ConnectivityManager.NetworkCallback cb;
        synchronized (callbacks) { cb = callbacks.remove(key); }
        if (cb != null && cm != null) {
            try { cm.unregisterNetworkCallback(cb); } catch (RuntimeException ignored) { }
        }
    }

    private void open(Socket s, boolean outbound) throws java.io.IOException {
        s.setTcpNoDelay(true);
        new StreamLink(engine, "wifi-aware", outbound, s.getInputStream(), s.getOutputStream(), s).open();
    }

    @Override
    void stopImpl() {
        Integer[] keys;
        synchronized (callbacks) { keys = callbacks.keySet().toArray(new Integer[0]); }
        for (int k : keys) release(k);
        try { if (pub != null) pub.close(); } catch (Exception ignored) { }
        try { if (sub != null) sub.close(); } catch (Exception ignored) { }
        try { if (session != null) session.close(); } catch (Exception ignored) { }
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        if (thread != null) thread.quitSafely();
        handles.clear();
        pub = null;
        sub = null;
        session = null;
        server = null;
        thread = null;
    }
}
