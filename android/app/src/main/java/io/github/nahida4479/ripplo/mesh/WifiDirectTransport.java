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
        manager.addLocalService(channel, localService, null);

        manager.setDnsSdResponseListeners(channel, (name, type, dev) -> { },
                (domain, record, dev) -> {
                    String tag = record == null ? null : record.get("nt");
                    if (tag != null) onPeer(tag, dev);
                });
        request = WifiP2pDnsSdServiceRequest.newInstance();
        manager.addServiceRequest(channel, request, null);
        discover();
    }

    @SuppressWarnings("MissingPermission")
    private void discover() {
        manager.discoverPeers(channel, new WifiP2pManager.ActionListener() {
            @Override public void onSuccess() { }
            @Override public void onFailure(int reason) { }
        });
        manager.discoverServices(channel, null);
    }

    @SuppressWarnings("MissingPermission")
    private void onPeer(String tag, WifiP2pDevice dev) {
        if (engine.nodeTag().compareTo(tag) >= 0 || engine.hasLink(tag, "wifi-direct")) return;
        long now = System.currentTimeMillis();
        synchronized (attempts) {
            Long last = attempts.get(tag);
            if (last != null && now - last < 60000) return;
            attempts.put(tag, now);
        }
        WifiP2pConfig cfg = new WifiP2pConfig();
        cfg.deviceAddress = dev.deviceAddress;
        cfg.wps.setup = WpsInfo.PBC;
        manager.connect(channel, cfg, null);
    }

    private void onConnectionInfo(final WifiP2pInfo info) {
        if (info == null || !info.groupFormed || info.groupOwnerAddress == null) return;
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
        if (manager != null && channel != null && engine.neighbors().isEmpty() && now - lastDiscover > 60000) {
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
    }
}
