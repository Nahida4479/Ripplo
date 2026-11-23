package io.github.nahida4479.ripplo.mesh;

import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothServerSocket;
import android.bluetooth.BluetoothSocket;
import android.bluetooth.BluetoothStatusCodes;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.AdvertisingSet;
import android.bluetooth.le.AdvertisingSetCallback;
import android.bluetooth.le.AdvertisingSetParameters;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

final class BleTransport extends Transport {
    static final UUID SERVICE = UUID.fromString("6f2a0001-5c3e-4b7a-9d1e-2b9c6e1a0f01");
    static final UUID RX = UUID.fromString("6f2a0002-5c3e-4b7a-9d1e-2b9c6e1a0f01");
    static final UUID TX = UUID.fromString("6f2a0003-5c3e-4b7a-9d1e-2b9c6e1a0f01");
    static final UUID PSM = UUID.fromString("6f2a0004-5c3e-4b7a-9d1e-2b9c6e1a0f01");
    static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final int MAX_CLIENTS = 5;

    private BluetoothManager mgr;
    private BluetoothAdapter adapter;
    private BluetoothGattServer server;
    private BluetoothGattCharacteristic txChar;
    private BluetoothLeAdvertiser advertiser;
    private BluetoothLeScanner scanner;
    private BluetoothServerSocket l2capServer;
    private volatile byte[] psmBytes = {0, 0};
    private final Map<String, ServerLink> serverLinks = new ConcurrentHashMap<>();
    private final Map<String, Integer> mtus = new ConcurrentHashMap<>();
    private final Map<String, Long> attempts = new HashMap<>();
    // BLE address -> node it belonged to, so a scan hit for a node we already have a link to is not dialled again.
    private final Map<String, String> addrNode = new ConcurrentHashMap<>();
    private final Map<String, Hit> hits = new ConcurrentHashMap<>();
    private AdvertisingSetCallback codedAdvCb;
    private volatile long lastHitAt;
    private volatile long lastScanStart;
    private volatile long lastAdvStart;
    private int tickN;

    private static final class Hit {
        final BluetoothDevice device;
        final int phy;
        final long at;
        Hit(BluetoothDevice device, int phy, long at) { this.device = device; this.phy = phy; this.at = at; }
    }

    private boolean codedOn() {
        return Build.VERSION.SDK_INT >= 26 && adapter != null
                && adapter.isLeCodedPhySupported() && adapter.isLeExtendedAdvertisingSupported();
    }

    private static int mask(boolean coded) {
        return Build.VERSION.SDK_INT >= 26 ? (coded ? BluetoothDevice.PHY_LE_CODED_MASK : BluetoothDevice.PHY_LE_1M_MASK) : 0;
    }
    private final Set<String> active = new HashSet<>();
    private final Set<String> l2capActive = new HashSet<>();
    private final Set<Link> mine = Collections.synchronizedSet(new HashSet<Link>());
    private final Handler main = new Handler(Looper.getMainLooper());

    BleTransport(Context ctx, MeshEngine engine) { super(ctx, engine); }

    @Override
    String name() { return "ble"; }

    @Override
    void startImpl() throws Exception {
        if (!ctx.getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) throw new UnsupportedOperationException("no ble");
        if (Build.VERSION.SDK_INT >= 31) {
            if (!has(Manifest.permission.BLUETOOTH_SCAN) || !has(Manifest.permission.BLUETOOTH_ADVERTISE)
                    || !has(Manifest.permission.BLUETOOTH_CONNECT)) throw new SecurityException("ble permissions");
        } else if (!has(Manifest.permission.ACCESS_FINE_LOCATION)) {
            throw new SecurityException("location");
        }
        mgr = (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = mgr == null ? null : mgr.getAdapter();
        if (adapter == null || !adapter.isEnabled()) throw new IllegalStateException("bluetooth off");
        if (Build.VERSION.SDK_INT >= 29) {
            try { startL2capServer(); } catch (Exception ignored) { }
        }
        openServer();
        startScan();
    }

    @Override
    void stopImpl() {
        try { if (scanner != null) scanner.stopScan(scanCb); } catch (Exception ignored) { }
        try { if (advertiser != null) advertiser.stopAdvertising(advCb); } catch (Exception ignored) { }
        try { if (advertiser != null && codedAdvCb != null) advertiser.stopAdvertisingSet(codedAdvCb); } catch (Exception ignored) { }
        codedAdvCb = null;
        hits.clear();
        scanner = null;
        advertiser = null;
        Link[] all;
        synchronized (mine) { all = mine.toArray(new Link[0]); }
        for (Link l : all) l.close();
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        server = null;
        try { if (l2capServer != null) l2capServer.close(); } catch (Exception ignored) { }
        l2capServer = null;
        synchronized (active) {
            active.clear();
            l2capActive.clear();
        }
        psmBytes = new byte[]{0, 0};
    }

    @Override
    boolean forceConnect(String node, String option) {
        boolean coded = "coded".equals(option);
        if (adapter == null || !running) {
            Diag.stage("ble", node, "rejected", "BLE transport not running");
            return false;
        }
        Diag.stage("ble", node, "attempt", coded ? "coded" : "1m");
        // An explicit request replaces whatever BLE/L2CAP link this node already has, so the chosen PHY is really used.
        engine.closeLinks(node, "ble");
        forceNode = node;
        int started = connectHits(coded);
        if (started == 0) {
            // Android may have silently stopped delivering scan results: restart the scan and wait a little for a fresh hit.
            Diag.stage("ble", node, "scanning", "restarting scan, waiting for a " + (coded ? "coded" : "1m") + " hit");
            restartScan();
            long end = System.currentTimeMillis() + 10000;
            while (started == 0 && System.currentTimeMillis() < end && running) {
                try { Thread.sleep(500); } catch (InterruptedException e) { break; }
                started = connectHits(coded);
            }
        }
        Diag.i("ble force " + (coded ? "coded" : "1m") + " started=" + started);
        if (started == 0) Diag.stage("ble", node, "rejected", "no " + (coded ? "coded" : "1m") + " hit in the last 60 s");
        return started > 0;
    }

    private volatile String forceNode;

    private int connectHits(boolean coded) {
        long now = System.currentTimeMillis();
        int started = 0;
        String want = forceNode;
        boolean mapped = false;
        for (Hit h : hits.values()) if (want != null && want.equals(addrNode.get(h.device.getAddress()))) mapped = true;
        for (Hit h : new ArrayList<>(hits.values())) {
            boolean isCoded = Build.VERSION.SDK_INT >= 26 && h.phy == BluetoothDevice.PHY_LE_CODED;
            if (now - h.at > 60000 || isCoded != coded) continue;
            String a = h.device.getAddress();
            // Prefer addresses known to belong to the requested node; otherwise try every fresh hit of that PHY.
            if (mapped && !want.equals(addrNode.get(a))) continue;
            synchronized (active) {
                if (active.contains(a)) continue;
                active.add(a);
            }
            new ClientLink(h.device, mask(coded)).connect();
            started++;
        }
        return started;
    }

    @Override
    void tickImpl() {
        if (adapter == null || !adapter.isEnabled()) return;
        tickN++;
        long now = System.currentTimeMillis();
        // Android stops connectable advertising once a central connects and does not resume it, and it can
        // silently stop scan delivery. Without this the phone stops being seen until Bluetooth is toggled.
        // A restart gives this phone a new random address, which makes peers dial it again, so only do it when nobody is linked.
        if (server != null && serverLinks.isEmpty() && engine.neighbors().isEmpty() && now - lastAdvStart > 120000) restartAdvertising();
        if (now - lastScanStart > 300000 || (now - lastHit() > 90000 && now - lastScanStart > 30000)) restartScan();
    }

    private long lastHit() { return lastHitAt == 0 ? lastScanStart : lastHitAt; }

    private void restartAdvertising() {
        if (!running || server == null) return;
        try { if (advertiser != null) advertiser.stopAdvertising(advCb); } catch (Exception ignored) { }
        try { if (advertiser != null && codedAdvCb != null) advertiser.stopAdvertisingSet(codedAdvCb); } catch (Exception ignored) { }
        codedAdvCb = null;
        try { startAdvertise(); } catch (Exception e) { Diag.w("ble re-advertise failed " + e); }
    }

    private void restartScan() {
        if (!running || adapter == null) return;
        try { if (scanner != null) scanner.stopScan(scanCb); } catch (Exception ignored) { }
        try { startScan(); } catch (Exception e) { Diag.w("ble re-scan failed " + e); }
    }

    private void startL2capServer() throws IOException {
        final BluetoothServerSocket ss = adapter.listenUsingInsecureL2capChannel();
        l2capServer = ss;
        int psm = ss.getPsm();
        psmBytes = new byte[]{(byte) (psm >> 8), (byte) psm};
        Thread t = new Thread(() -> {
            try {
                while (running || l2capServer == ss) {
                    BluetoothSocket s = ss.accept();
                    openSocket(s, false);
                }
            } catch (IOException ignored) {
            }
        }, "ripplo-l2cap-accept");
        t.setDaemon(true);
        t.start();
    }

    private StreamLink openSocket(BluetoothSocket s, boolean outbound) throws IOException {
        StreamLink l = new StreamLink(engine, "l2cap", outbound, s.getInputStream(), s.getOutputStream(), s);
        int mtu = Build.VERSION.SDK_INT >= 23 ? s.getMaxTransmitPacketSize() : 0;
        l.chunk = mtu > 0 ? mtu : 672;
        if (outbound) {
            final String addr = s.getRemoteDevice().getAddress();
            // Remember which node this BLE address belongs to, so later scan hits for it are not dialled again.
            l.helloHook = tag -> addrNode.put(addr, tag);
        }
        l.open();
        return l;
    }

    private void connectL2cap(final BluetoothDevice dev, final int psm) {
        final String addr = dev.getAddress();
        synchronized (active) { if (!l2capActive.add(addr)) return; }
        Thread t = new Thread(() -> {
            try {
                BluetoothSocket s = dev.createInsecureL2capChannel(psm);
                s.connect();
                openSocket(s, true);
            } catch (Exception e) {
                Diag.i("l2cap connect failed " + addr + " " + e);
            }
            synchronized (active) { l2capActive.remove(addr); }
        }, "ripplo-l2cap-connect");
        t.setDaemon(true);
        t.start();
    }

    private void openServer() {
        server = mgr.openGattServer(ctx, serverCb);
        if (server == null) throw new IllegalStateException("no gatt server");
        BluetoothGattService svc = new BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY);
        BluetoothGattCharacteristic rx = new BluetoothGattCharacteristic(RX, BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE);
        txChar = new BluetoothGattCharacteristic(TX, BluetoothGattCharacteristic.PROPERTY_NOTIFY, 0);
        txChar.addDescriptor(new BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE));
        BluetoothGattCharacteristic psm = new BluetoothGattCharacteristic(PSM, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ);
        svc.addCharacteristic(rx);
        svc.addCharacteristic(txChar);
        svc.addCharacteristic(psm);
        server.addService(svc);
    }

    private void startAdvertise() {
        lastAdvStart = System.currentTimeMillis();
        advertiser = adapter.getBluetoothLeAdvertiser();
        if (advertiser == null) return;
        AdvertiseSettings s = new AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .setTimeout(0)
                .build();
        AdvertiseData d = new AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(new ParcelUuid(SERVICE))
                .build();
        advertiser.startAdvertising(s, d, advCb);
        if (codedOn()) startCodedAdvertise(d);
    }

    private void startCodedAdvertise(AdvertiseData d) {
        try {
            AdvertisingSetParameters p = new AdvertisingSetParameters.Builder()
                    .setLegacyMode(false)
                    .setConnectable(true)
                    .setScannable(false)
                    .setPrimaryPhy(BluetoothDevice.PHY_LE_CODED)
                    .setSecondaryPhy(BluetoothDevice.PHY_LE_CODED)
                    .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
                    .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
                    .build();
            codedAdvCb = new AdvertisingSetCallback() {
                @Override
                public void onAdvertisingSetStarted(AdvertisingSet set, int txPower, int status) {
                    Diag.i("ble coded advertising status=" + status);
                    if (status == AdvertisingSetCallback.ADVERTISE_SUCCESS) Diag.stage("ble", "", "started", "advertising coded");
                    else Diag.stage("ble", "", "failed", "coded advertise status=" + status);
                }
            };
            advertiser.startAdvertisingSet(p, d, null, null, null, codedAdvCb);
        } catch (Exception e) {
            Diag.w("ble coded advertise failed " + e);
            Diag.stage("ble", "", "failed", "coded advertise: " + e.getClass().getSimpleName());
        }
    }

    private void startScan() {
        lastScanStart = System.currentTimeMillis();
        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) return;
        ScanFilter f = new ScanFilter.Builder().setServiceUuid(new ParcelUuid(SERVICE)).build();
        ScanSettings.Builder sb = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED);
        if (codedOn()) sb.setLegacy(false).setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED);
        ScanSettings s = sb.build();
        scanner.startScan(Collections.singletonList(f), s, scanCb);
        Diag.stage("ble", "", "started", codedOn() ? "scanning 1M + coded" : "scanning 1M");
    }

    private final AdvertiseCallback advCb = new AdvertiseCallback() {
        @Override
        public void onStartSuccess(AdvertiseSettings settingsInEffect) {
            Diag.i("ble advertising");
            Diag.stage("ble", "", "started", "advertising 1M");
        }

        @Override
        public void onStartFailure(int errorCode) {
            Diag.w("ble advertise failed " + errorCode);
            Diag.stage("ble", "", "failed", "advertise errorCode=" + errorCode);
        }
    };

    private final ScanCallback scanCb = new ScanCallback() {
        @Override
        public void onScanFailed(int errorCode) {
            Diag.w("ble scan failed " + errorCode);
            Diag.stage("ble", "", "failed", "scan errorCode=" + errorCode);
        }

        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            BluetoothDevice d = result.getDevice();
            String a = d.getAddress();
            int phy = Build.VERSION.SDK_INT >= 26 ? result.getPrimaryPhy() : BluetoothDevice.PHY_LE_1M;
            boolean coded = Build.VERSION.SDK_INT >= 26 && phy == BluetoothDevice.PHY_LE_CODED;
            Diag.i("ble scan hit " + a + (coded ? " coded" : ""));
            long now = System.currentTimeMillis();
            lastHitAt = now;
            hits.put(a + (coded ? "/c" : "/1"), new Hit(d, phy, now));
            if (coded) {
                Hit oneM = hits.get(a + "/1");
                if (oneM != null && now - oneM.at < 20000) return;
            }
            String known = addrNode.get(a);
            if (known != null && (engine.hasLink(known, "ble") || engine.hasLink(known, "l2cap"))) return;
            synchronized (active) {
                if (active.contains(a) || active.size() >= MAX_CLIENTS) return;
                Long last = attempts.get(a);
                if (last != null && now - last < 15000) return;
                attempts.put(a, now);
                if (attempts.size() > 200) attempts.clear();
                active.add(a);
            }
            new ClientLink(d, mask(coded)).connect();
        }
    };

    private final BluetoothGattServerCallback serverCb = new BluetoothGattServerCallback() {
        @Override
        public void onServiceAdded(int status, BluetoothGattService service) {
            if (status == BluetoothGatt.GATT_SUCCESS) startAdvertise();
        }

        @Override
        public void onConnectionStateChange(BluetoothDevice device, int status, int newState) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                String a = device.getAddress();
                mtus.remove(a);
                ServerLink l = serverLinks.remove(a);
                if (l != null) l.close();
                // Android may stop connectable advertising while connected. Resume it once no BLE link is left (throttled).
                main.postDelayed(() -> {
                    if (mine.isEmpty() && System.currentTimeMillis() - lastAdvStart > 20000) restartAdvertising();
                }, 1500);
            }
        }

        @Override
        public void onMtuChanged(BluetoothDevice device, int mtu) {
            Diag.i("ble server mtu " + mtu);
            mtus.put(device.getAddress(), mtu);
        }

        @Override
        public void onDescriptorWriteRequest(BluetoothDevice device, int requestId, BluetoothGattDescriptor descriptor,
                                             boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            if (responseNeeded && server != null) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value);
            if (!CCCD.equals(descriptor.getUuid()) || value == null || value.length < 1) return;
            String a = device.getAddress();
            if (value[0] != 0) {
                Diag.i("ble server link up " + a);
                if (serverLinks.containsKey(a)) return;
                ServerLink l = new ServerLink(device);
                serverLinks.put(a, l);
                mine.add(l);
                engine.addLink(l);
            } else {
                ServerLink l = serverLinks.remove(a);
                if (l != null) l.close();
            }
        }

        @Override
        public void onCharacteristicWriteRequest(BluetoothDevice device, int requestId, BluetoothGattCharacteristic characteristic,
                                                 boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            if (responseNeeded && server != null) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null);
            final ServerLink l = serverLinks.get(device.getAddress());
            if (l == null || value == null || !RX.equals(characteristic.getUuid())) return;
            final byte[] v = value.clone();
            engine.rx.execute(() -> l.onBytes(v, 0, v.length));
        }

        @Override
        public void onCharacteristicReadRequest(BluetoothDevice device, int requestId, int offset, BluetoothGattCharacteristic characteristic) {
            if (server == null) return;
            if (!PSM.equals(characteristic.getUuid())) {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null);
                return;
            }
            byte[] v = psmBytes;
            if (offset > v.length) {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null);
                return;
            }
            byte[] out = new byte[v.length - offset];
            System.arraycopy(v, offset, out, 0, out.length);
            server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, out);
        }

        @Override
        public void onNotificationSent(BluetoothDevice device, int status) {
            ServerLink l = serverLinks.get(device.getAddress());
            if (l != null) l.notifyDone.signal(status == BluetoothGatt.GATT_SUCCESS);
        }
    };

    private final class ServerLink extends Link {
        final BluetoothDevice device;
        final Awaiter notifyDone = new Awaiter();

        ServerLink(BluetoothDevice device) {
            super(BleTransport.this.engine, "ble", false);
            this.device = device;
        }

        @Override
        void writeFrame(byte[] frame) throws IOException {
            Integer m = mtus.get(device.getAddress());
            int chunk = Math.max(20, Math.min((m == null ? 23 : m) - 3, 512));
            for (int o = 0; o < frame.length; o += chunk) {
                byte[] slice = new byte[Math.min(chunk, frame.length - o)];
                System.arraycopy(frame, o, slice, 0, slice.length);
                notifyDone.reset();
                if (!notify(slice)) throw new IOException("notify failed");
                if (!notifyDone.await(8000)) throw new IOException("notify timeout");
            }
        }

        @SuppressWarnings("deprecation")
        private boolean notify(byte[] slice) {
            BluetoothGattServer s = server;
            if (s == null) return false;
            synchronized (txChar) {
                if (Build.VERSION.SDK_INT >= 33) {
                    return s.notifyCharacteristicChanged(device, txChar, false, slice) == BluetoothStatusCodes.SUCCESS;
                }
                txChar.setValue(slice);
                return s.notifyCharacteristicChanged(device, txChar, false);
            }
        }

        @Override
        void closeImpl() {
            mine.remove(this);
            serverLinks.remove(device.getAddress(), this);
            try { if (server != null) server.cancelConnection(device); } catch (Exception ignored) { }
        }
    }

    private final class ClientLink extends Link {
        final BluetoothDevice device;
        final Awaiter writeDone = new Awaiter();
        volatile BluetoothGatt gatt;
        volatile int mtu = 23;
        volatile boolean registered;
        final int phyMask;
        BluetoothGattCharacteristic rxChar;
        BluetoothGattCharacteristic psmChar;

        ClientLink(BluetoothDevice device, int phyMask) {
            super(BleTransport.this.engine, "ble", true);
            this.phyMask = phyMask;
            this.device = device;
            mine.add(this);
        }

        void connect() {
            try {
                gatt = Build.VERSION.SDK_INT >= 26
                        ? device.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE, phyMask)
                        : device.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE);
            } catch (Exception e) {
                gatt = null;
            }
            if (gatt == null) { Diag.stage("ble", device.getAddress(), "failed", "connectGatt error"); close(); return; }
            Diag.stage("ble", device.getAddress(), "connecting", "");
            main.postDelayed(() -> {
                if (registered) return;
                Diag.stage("ble", device.getAddress(), "timeout", "no link after 30 s");
                close();
            }, 30000);
        }

        private void finish(int psm) {
            if (!alive.get()) return;
            registered = true;
            Diag.i("ble client link up " + device.getAddress() + " psm=" + psm);
            if (!engine.addLink(this)) {
                Diag.stage("ble", device.getAddress(), "rejected", "engine did not accept the link");
                close();
                return;
            }
            Diag.stage("ble", device.getAddress(), "linked", "psm=" + psm);
            if (psm > 0 && Build.VERSION.SDK_INT >= 29) connectL2cap(device, psm);
        }

        private void psmRead(byte[] v, int status) {
            int psm = 0;
            if (status == BluetoothGatt.GATT_SUCCESS && v != null && v.length >= 2) psm = ((v[0] & 0xFF) << 8) | (v[1] & 0xFF);
            finish(psm);
        }

        private final BluetoothGattCallback cb = new BluetoothGattCallback() {
            @Override
            public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
                Diag.i("ble client state " + device.getAddress() + " status=" + status + " new=" + newState);
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    Diag.stage("ble", device.getAddress(), "connected", "GATT up, discovering services");
                    if (Build.VERSION.SDK_INT >= 26) g.readPhy();
                    if (!g.requestMtu(517)) g.discoverServices();
                } else {
                    if (!registered) Diag.stage("ble", device.getAddress(), "failed", "GATT status=" + status + " new=" + newState);
                    else Diag.stage("ble", device.getAddress(), "closed", "status=" + status);
                    close();
                }
            }

            @Override
            public void onPhyRead(BluetoothGatt g, int txPhy, int rxPhy, int status) {
                note = "phy " + (rxPhy == BluetoothDevice.PHY_LE_CODED ? "coded" : rxPhy == BluetoothDevice.PHY_LE_2M ? "2M" : "1M");
                Diag.i("ble client " + note + " " + device.getAddress());
            }

            @Override
            public void onMtuChanged(BluetoothGatt g, int m, int status) {
                Diag.i("ble client mtu " + m + " status=" + status);
                if (status == BluetoothGatt.GATT_SUCCESS) mtu = m;
                g.discoverServices();
            }

            @Override
            public void onServicesDiscovered(BluetoothGatt g, int status) {
                BluetoothGattService svc = status == BluetoothGatt.GATT_SUCCESS ? g.getService(SERVICE) : null;
                if (svc == null) { Diag.i("ble no service " + device.getAddress() + " status=" + status); close(); return; }
                rxChar = svc.getCharacteristic(RX);
                BluetoothGattCharacteristic tx = svc.getCharacteristic(TX);
                psmChar = svc.getCharacteristic(PSM);
                BluetoothGattDescriptor d = tx == null ? null : tx.getDescriptor(CCCD);
                if (rxChar == null || d == null) { close(); return; }
                g.setCharacteristicNotification(tx, true);
                if (!writeDescriptor(g, d)) close();
            }

            @Override
            public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
                if (status != BluetoothGatt.GATT_SUCCESS) { close(); return; }
                if (psmChar != null && Build.VERSION.SDK_INT >= 29) {
                    if (!g.readCharacteristic(psmChar)) finish(0);
                } else {
                    finish(0);
                }
            }

            @Override
            public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value, int status) {
                psmRead(value, status);
            }

            @Override
            @SuppressWarnings("deprecation")
            public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
                if (Build.VERSION.SDK_INT < 33) psmRead(c.getValue(), status);
            }

            @Override
            public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
                writeDone.signal(status == BluetoothGatt.GATT_SUCCESS);
            }

            @Override
            public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value) {
                feed(value);
            }

            @Override
            @SuppressWarnings("deprecation")
            public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
                if (Build.VERSION.SDK_INT < 33) feed(c.getValue());
            }
        };

        private void feed(byte[] value) {
            if (value == null || !registered) return;
            final byte[] v = value.clone();
            engine.rx.execute(() -> onBytes(v, 0, v.length));
        }

        @SuppressWarnings("deprecation")
        private boolean writeDescriptor(BluetoothGatt g, BluetoothGattDescriptor d) {
            if (Build.VERSION.SDK_INT >= 33) {
                return g.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS;
            }
            d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
            return g.writeDescriptor(d);
        }

        @SuppressWarnings("deprecation")
        private boolean writeChar(byte[] v) {
            BluetoothGatt g = gatt;
            if (g == null) return false;
            if (Build.VERSION.SDK_INT >= 33) {
                return g.writeCharacteristic(rxChar, v, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS;
            }
            rxChar.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            rxChar.setValue(v);
            return g.writeCharacteristic(rxChar);
        }

        @Override
        void writeFrame(byte[] frame) throws IOException {
            int chunk = Math.max(20, Math.min(mtu - 3, 512));
            for (int o = 0; o < frame.length; o += chunk) {
                byte[] slice = new byte[Math.min(chunk, frame.length - o)];
                System.arraycopy(frame, o, slice, 0, slice.length);
                writeDone.reset();
                if (!writeChar(slice)) throw new IOException("write failed");
                if (!writeDone.await(8000)) throw new IOException("write timeout");
            }
        }

        @Override
        void closeImpl() {
            mine.remove(this);
            String peer = node != null ? node : helloTag;
            if (peer != null) addrNode.put(device.getAddress(), peer);
            synchronized (active) { active.remove(device.getAddress()); }
            BluetoothGatt g = gatt;
            if (g != null) {
                try { g.disconnect(); } catch (Exception ignored) { }
                try { g.close(); } catch (Exception ignored) { }
            }
        }
    }
}
