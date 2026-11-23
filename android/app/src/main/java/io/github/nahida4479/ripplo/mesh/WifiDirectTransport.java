package io.github.nahida4479.ripplo.mesh;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.net.wifi.WpsInfo;
import android.net.wifi.p2p.WifiP2pConfig;
import android.net.wifi.p2p.WifiP2pDevice;
import android.net.wifi.p2p.WifiP2pInfo;
import android.net.wifi.p2p.WifiP2pManager;
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo;
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest;
import android.os.Build;
import android.os.Looper;
import androidx.core.content.ContextCompat;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.HashMap;
import java.util.Map;

final class WifiDirectTransport extends Transport {
    private static final int PORT = 47321;

    private WifiP2pManager manager;
    private WifiP2pManager.Channel channel;
    private ServerSocket server;
    private long lastDiscover;
    private BroadcastReceiver receiver;
    private WifiP2pDnsSdServiceInfo localService;
    private WifiP2pDnsSdServiceRequest request;
    private volatile boolean clientConnecting;
    private final Map<String, Long> attempts = new HashMap<>();

    WifiDirectTransport(Context ctx, MeshEngine engine) { super(ctx, engine); }

    @Override
    String name() { return "wifi-direct"; }

    @Override
    @SuppressWarnings("MissingPermission")
    void startImpl() throws Exception {
        if (!ctx.getPackageManager().hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)) throw new IllegalStateException("no p2p");
        String perm = Build.VERSION.SDK_INT >= 33 ? Manifest.permission.NEARBY_WIFI_DEVICES : Manifest.permission.ACCESS_FINE_LOCATION;
        if (!has(perm)) throw new SecurityException("wifi permission");
        manager = (WifiP2pManager) ctx.getSystemService(Context.WIFI_P2P_SERVICE);
        if (manager == null) throw new IllegalStateException("no p2p");
        channel = manager.initialize(ctx, Looper.getMainLooper(), null);
        if (channel == null) throw new IllegalStateException("no channel");

        receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent i) {
                manager.requestConnectionInfo(channel, info -> onConnectionInfo(info));
            }
        };
        ContextCompat.registerReceiver(ctx, receiver, new IntentFilter(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION), ContextCompat.RECEIVER_NOT_EXPORTED);

        Map<String, String> txt = new HashMap<>();
        txt.put("nt", engine.nodeTag());
        localService = WifiP2pDnsSdServiceInfo.newInstance("ripplo-" + engine.nodeTag().substring(0, 8), "_ripplo._tcp", txt);
        manager.setDnsSdResponseListeners(channel, (name, type, dev) -> { },
                (domain, record, dev) -> {
                    String tag = record == null ? null : record.get("nt");
                    if (tag != null) onPeer(tag, dev);
                });
        request = WifiP2pDnsSdServiceRequest.newInstance();
        // Steps run one after another: the system answers BUSY (reason 2) when a call starts while the previous one is still running.
        manager.clearLocalServices(channel, null);
        manager.clearServiceRequests(channel, null);
        step(() -> { if (manager != null) manager.addLocalService(channel, localService, stepListener("add local service")); });
    }

    private int busyRetries;

    private void step(Runnable r) { new android.os.Handler(Looper.getMainLooper()).postDelayed(r, 400); }

    private WifiP2pManager.ActionListener stepListener(final String what) {
        return new WifiP2pManager.ActionListener() {
            @Override public void onSuccess() {
                Diag.stage("wifi-direct", "", "started", what + " ok");
                if (what.equals("add local service")) step(() -> { if (manager != null) manager.addServiceRequest(channel, request, stepListener("add service request")); });
                else if (what.equals("add service request")) step(() -> discover());
            }
            @Override public void onFailure(int reason) {
                Diag.stage("wifi-direct", "", "failed", what + " reason=" + reason + reasonText(reason));
                // Keep going: the other steps may still work, and the periodic discovery retries.
                if (what.equals("add local service")) step(() -> { if (manager != null) manager.addServiceRequest(channel, request, stepListener("add service request")); });
                else step(() -> discover());
            }
        };
    }

    private static String reasonText(int r) {
        return r == 2 ? " (busy)" : r == 1 ? " (not supported)" : r == 0 ? " (internal error)" : r == 3 ? " (no service requests)" : "";
    }

    @SuppressWarnings("MissingPermission")
    private void discover() {
        final WifiP2pManager m = manager;
        if (m == null || channel == null) return;
        lastDiscover = System.currentTimeMillis();
        m.discoverPeers(channel, new WifiP2pManager.ActionListener() {
            @Override public void onSuccess() {
                busyRetries = 0;
                log("discover ok");
                Diag.stage("wifi-direct", "", "started", "discovery running");
                step(() -> { if (manager != null) manager.discoverServices(channel, new WifiP2pManager.ActionListener() {
                    @Override public void onSuccess() { Diag.stage("wifi-direct", "", "started", "service discovery running"); }
                    @Override public void onFailure(int reason) { Diag.stage("wifi-direct", "", "failed", "service discovery reason=" + reason + reasonText(reason)); }
                }); });
            }
            @Override public void onFailure(int reason) {
                log("discover failed reason=" + reason);
                Diag.stage("wifi-direct", "", "failed", "discovery reason=" + reason + reasonText(reason));
                if (reason == WifiP2pManager.BUSY && ++busyRetries <= 5) {
                    try { m.stopPeerDiscovery(channel, null); } catch (Exception ignored) { }
                    new android.os.Handler(Looper.getMainLooper()).postDelayed(() -> discover(), 3000L * busyRetries);
                }
            }
        });
    }

    @SuppressWarnings("MissingPermission")
    private final java.util.Map<String, WifiP2pDevice> devices = new java.util.concurrent.ConcurrentHashMap<>();

    private void onPeer(String tag, WifiP2pDevice dev) {
        if (!tag.equals(engine.nodeTag())) devices.put(tag, dev);
        if (!tag.equals(engine.nodeTag())) engine.noteSeen(tag, "wifi-direct");
        log("peer " + tag.substring(0, Math.min(8, tag.length())) + " " + dev.deviceName + " initiator=" + (engine.nodeTag().compareTo(tag) < 0));
        if (engine.nodeTag().compareTo(tag) >= 0 || engine.hasLink(tag, "wifi-direct")) return;
        // Long range is the fallback: no Wi-Fi Direct group (it disturbs Wi-Fi and asks the other user to accept) while the
        // phone is reachable over LAN, Wi-Fi Aware or normal-range Bluetooth.
        if (engine.hasFastLink(tag)) return;
        long now = System.currentTimeMillis();
        synchronized (attempts) {
            Long last = attempts.get(tag);
            if (last != null && now - last < 60000) return;
            attempts.put(tag, now);
        }
        requestConnect(tag, dev);
    }

    @Override
    @SuppressWarnings("MissingPermission")
    boolean forceConnect(String node, String option) {
        if (manager == null || channel == null) {
            Diag.stage("wifi-direct", node, "rejected", "Wi-Fi Direct is not running (Wi-Fi off or no permission)");
            return false;
        }
        WifiP2pDevice dev = devices.get(node);
        if (dev == null) {
            Diag.stage("wifi-direct", node, "scanning", "peer not discovered yet, restarting discovery (up to 12 s)");
            discover();
            logPeers();
            long end = System.currentTimeMillis() + 12000;
            while (dev == null && System.currentTimeMillis() < end && running) {
                try { Thread.sleep(500); } catch (InterruptedException e) { break; }
                dev = devices.get(node);
            }
            if (dev == null) {
                Diag.stage("wifi-direct", node, "rejected", "peer not found over Wi-Fi Direct (other phone needs Wi-Fi on and Ripplo running)");
                return false;
            }
        }
        Diag.stage("wifi-direct", node, "attempt", dev.deviceName == null ? "" : dev.deviceName);
        requestConnect(node, dev);
        return true;
    }

    @SuppressWarnings("MissingPermission")
    private void logPeers() {
        try {
            manager.requestPeers(channel, list -> Diag.stage("wifi-direct", "", "started", "p2p peers in range: " + (list == null ? 0 : list.getDeviceList().size())));
        } catch (Exception ignored) { }
    }

    @SuppressWarnings("MissingPermission")
    private void requestConnect(String tag, WifiP2pDevice dev) {
        WifiP2pConfig cfg = new WifiP2pConfig();
        cfg.deviceAddress = dev.deviceAddress;
        cfg.wps.setup = WpsInfo.PBC;
        log("connect " + tag.substring(0, Math.min(8, tag.length())));
        manager.connect(channel, cfg, new WifiP2pManager.ActionListener() {
            @Override public void onSuccess() {
                log("connect requested");
                Diag.stage("wifi-direct", tag, "connecting", "request accepted by system");
            }
            @Override public void onFailure(int reason) {
                log("connect failed reason=" + reason);
                Diag.stage("wifi-direct", tag, "rejected", "system refused, reason=" + reason);
            }
        });
    }

    private void onConnectionInfo(final WifiP2pInfo info) {
        if (info == null || !info.groupFormed || info.groupOwnerAddress == null) return;
        log("group formed owner=" + info.isGroupOwner);
        if (info.isGroupOwner) {
            startServer();
        } else if (!clientConnecting) {
            clientConnecting = true;
            final java.net.InetAddress go = info.groupOwnerAddress;
            Thread t = new Thread(() -> {
                try {
                    for (int i = 0; i < 8 && running; i++) {
                        try {
                            Socket s = new Socket();
                            s.connect(new InetSocketAddress(go, PORT), 4000);
                            open(s, true);
                            break;
                        } catch (Exception e) {
                            Thread.sleep(1500);
                        }
                    }
                } catch (InterruptedException ignored) {
                }
                clientConnecting = false;
            }, "ripplo-p2p-connect");
            t.setDaemon(true);
            t.start();
        }
    }

    private synchronized void startServer() {
        if (server != null && !server.isClosed()) return;
        try {
            final ServerSocket ss = new ServerSocket();
            ss.setReuseAddress(true);
            ss.bind(new InetSocketAddress(PORT));
            server = ss;
            Thread t = new Thread(() -> {
                try {
                    while (!ss.isClosed()) open(ss.accept(), false);
                } catch (Exception ignored) {
                }
            }, "ripplo-p2p-accept");
            t.setDaemon(true);
            t.start();
        } catch (Exception ignored) {
        }
    }

    private void open(Socket s, boolean outbound) throws java.io.IOException {
        s.setTcpNoDelay(true);
        new StreamLink(engine, "wifi-direct", outbound, s.getInputStream(), s.getOutputStream(), s).open();
    }

    @Override
    void tickImpl() {
        long now = System.currentTimeMillis();
        boolean direct = false;
        for (String n : engine.neighbors()) if (engine.hasLink(n, "wifi-direct")) direct = true;
        // Look for far phones every 90 s (also while nearer phones are linked) unless a Wi-Fi Direct link is already up.
        if (manager != null && channel != null && !direct && now - lastDiscover > 90000) {
            lastDiscover = now;
            discover();
        }
    }

    @Override
    @SuppressWarnings("MissingPermission")
    void stopImpl() {
        try { if (receiver != null) ctx.unregisterReceiver(receiver); } catch (Exception ignored) { }
        receiver = null;
        try {
            if (manager != null && channel != null) {
                if (request != null) manager.removeServiceRequest(channel, request, null);
                if (localService != null) manager.removeLocalService(channel, localService, null);
                manager.stopPeerDiscovery(channel, null);
                manager.removeGroup(channel, null);
            }
        } catch (Exception ignored) {
        }
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        server = null;
        try {
            if (channel != null && Build.VERSION.SDK_INT >= 27) channel.close();
        } catch (Exception ignored) {
        }
        channel = null;
        manager = null;
        devices.clear();
    }
}
