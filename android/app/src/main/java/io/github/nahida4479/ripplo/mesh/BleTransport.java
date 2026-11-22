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

    private void openSocket(BluetoothSocket s, boolean outbound) throws IOException {
        StreamLink l = new StreamLink(engine, "l2cap", outbound, s.getInputStream(), s.getOutputStream(), s);
        int mtu = Build.VERSION.SDK_INT >= 23 ? s.getMaxTransmitPacketSize() : 0;
        l.chunk = mtu > 0 ? mtu : 672;
        l.open();
    }

    private void connectL2cap(final BluetoothDevice dev, final int psm) {
        final String addr = dev.getAddress();
        synchronized (active) { if (!l2capActive.add(addr)) return; }
        Thread t = new Thread(() -> {
            try {
                BluetoothSocket s = dev.createInsecureL2capChannel(psm);
                s.connect();
                openSocket(s, true);
            } catch (Exception ignored) {
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
    }

    private void startScan() {
        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) return;
        ScanFilter f = new ScanFilter.Builder().setServiceUuid(new ParcelUuid(SERVICE)).build();
        ScanSettings s = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build();
        scanner.startScan(Collections.singletonList(f), s, scanCb);
    }

    private final AdvertiseCallback advCb = new AdvertiseCallback() { };

    private final ScanCallback scanCb = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            BluetoothDevice d = result.getDevice();
            String a = d.getAddress();
            android.util.Log.i("ripplo", "ble scan hit " + a);
            long now = System.currentTimeMillis();
            synchronized (active) {
                if (active.contains(a) || active.size() >= MAX_CLIENTS) return;
                Long last = attempts.get(a);
                if (last != null && now - last < 15000) return;
                attempts.put(a, now);
                if (attempts.size() > 200) attempts.clear();
                active.add(a);
            }
            new ClientLink(d).connect();
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
            }
        }

        @Override
        public void onMtuChanged(BluetoothDevice device, int mtu) {
            mtus.put(device.getAddress(), mtu);
        }

        @Override
        public void onDescriptorWriteRequest(BluetoothDevice device, int requestId, BluetoothGattDescriptor descriptor,
                                             boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            if (responseNeeded && server != null) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value);
            if (!CCCD.equals(descriptor.getUuid()) || value == null || value.length < 1) return;
            String a = device.getAddress();
            if (value[0] != 0) {
                android.util.Log.i("ripplo", "ble server link up " + a);
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
        BluetoothGattCharacteristic rxChar;
        BluetoothGattCharacteristic psmChar;

        ClientLink(BluetoothDevice device) {
            super(BleTransport.this.engine, "ble", true);
            this.device = device;
            mine.add(this);
        }

        void connect() {
            try {
                gatt = device.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE);
            } catch (Exception e) {
                gatt = null;
            }
            if (gatt == null) { close(); return; }
            main.postDelayed(() -> { if (!registered) close(); }, 30000);
        }

        private void finish(int psm) {
            if (!alive.get()) return;
            registered = true;
            android.util.Log.i("ripplo", "ble client link up " + device.getAddress() + " psm=" + psm);
            if (!engine.addLink(this)) return;
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
                android.util.Log.i("ripplo", "ble client state " + device.getAddress() + " status=" + status + " new=" + newState);
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    if (!g.requestMtu(517)) g.discoverServices();
                } else {
                    close();
                }
            }

            @Override
            public void onMtuChanged(BluetoothGatt g, int m, int status) {
                if (status == BluetoothGatt.GATT_SUCCESS) mtu = m;
                g.discoverServices();
            }

            @Override
            public void onServicesDiscovered(BluetoothGatt g, int status) {
                BluetoothGattService svc = status == BluetoothGatt.GATT_SUCCESS ? g.getService(SERVICE) : null;
                if (svc == null) { android.util.Log.i("ripplo", "ble no service " + device.getAddress() + " status=" + status); close(); return; }
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
            synchronized (active) { active.remove(device.getAddress()); }
            BluetoothGatt g = gatt;
            if (g != null) {
                try { g.disconnect(); } catch (Exception ignored) { }
                try { g.close(); } catch (Exception ignored) { }
            }
        }
    }
}
