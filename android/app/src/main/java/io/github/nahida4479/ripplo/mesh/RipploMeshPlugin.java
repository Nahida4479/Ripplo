package io.github.nahida4479.ripplo.mesh;

import android.Manifest;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONException;

@CapacitorPlugin(
        name = "RipploMesh",
        permissions = {
                @Permission(alias = "bluetooth", strings = {
                        Manifest.permission.BLUETOOTH_SCAN,
                        Manifest.permission.BLUETOOTH_ADVERTISE,
                        Manifest.permission.BLUETOOTH_CONNECT}),
                @Permission(alias = "bluetoothLegacy", strings = {
                        Manifest.permission.BLUETOOTH,
                        Manifest.permission.BLUETOOTH_ADMIN,
                        Manifest.permission.ACCESS_FINE_LOCATION}),
                @Permission(alias = "wifi", strings = {Manifest.permission.NEARBY_WIFI_DEVICES}),
                @Permission(alias = "wifiLegacy", strings = {Manifest.permission.ACCESS_FINE_LOCATION}),
                @Permission(alias = "notifications", strings = {Manifest.permission.POST_NOTIFICATIONS})
        })
public class RipploMeshPlugin extends Plugin implements MeshEngine.Listener {
    private static final String KEY_ALIAS = "ripplo_db_wrap";
    private static final String ACTION_INSTALL = "io.github.nahida4479.ripplo.INSTALL_RESULT";
    private static volatile PluginCall installCall;

    private MeshEngine engine;
    private boolean drained;

    @Override
    public void load() {
        engine = MeshEngine.get(getContext());
        engine.setListener(this);
    }

    @Override
    protected void handleOnPause() {
        engine.setJsAttached(false);
    }

    @Override
    protected void handleOnResume() {
        if (!drained) return;
        engine.setJsAttached(true);
        for (Inbox.Item it : engine.drainInbox()) onPacket(it.packet, it.from);
    }

    @Override
    protected void handleOnDestroy() {
        engine.setJsAttached(false);
        engine.setListener(null);
        if (!engine.background()) engine.stop();
    }

    @Override
    public void onPacket(byte[] packet, String from) {
        JSObject o = new JSObject();
        o.put("packet", Base64.encodeToString(packet, Base64.NO_WRAP));
        o.put("from", from);
        notifyListeners("packet", o);
    }

    @Override
    public void onNeighbor(String node, boolean up, String medium, long kbps) {
        JSObject o = new JSObject();
        o.put("node", node);
        o.put("up", up);
        o.put("medium", medium);
        o.put("kbps", kbps);
        notifyListeners("neighbor", o);
    }

    private static byte[] b64(String s) {
        return Base64.decode(s, Base64.DEFAULT);
    }

    @PluginMethod
    public void start(PluginCall call) {
        try {
            byte[] self = b64(call.getString("selfTag", ""));
            if (self.length != 16) { call.reject("bad selfTag"); return; }
            engine.start(self, call.getBoolean("background", true), true);
            JSObject r = new JSObject();
            r.put("nodeTag", engine.nodeTag());
            call.resolve(r);
        } catch (RuntimeException e) {
            call.reject("start failed");
        }
    }

    @PluginMethod
    public void stop(PluginCall call) {
        engine.stop();
        call.resolve();
    }

    @PluginMethod
    public void send(PluginCall call) {
        try {
            int n = engine.sendFromJs(b64(call.getString("packet", "")));
            JSObject r = new JSObject();
            r.put("neighbors", n);
            call.resolve(r);
        } catch (RuntimeException e) {
            call.reject("send failed");
        }
    }

    @PluginMethod
    public void sendApp(PluginCall call) {
        try {
            String node = call.getString("node", "");
            if (!engine.sendApp(node, b64(call.getString("payload", "")))) { call.reject("no link"); return; }
            call.resolve();
        } catch (RuntimeException e) {
            call.reject("send failed");
        }
    }

    @PluginMethod
    public void getNeighbors(PluginCall call) {
        try {
            JSObject r = new JSObject();
            r.put("neighbors", new JSArray(engine.neighborsJson().toString()));
            call.resolve(r);
        } catch (JSONException e) {
            call.reject("failed");
        }
    }

    @PluginMethod
    public void drainInbox(PluginCall call) {
        drained = true;
        engine.setJsAttached(true);
        JSArray arr = new JSArray();
        for (Inbox.Item it : engine.drainInbox()) {
            JSObject o = new JSObject();
            o.put("packet", Base64.encodeToString(it.packet, Base64.NO_WRAP));
            o.put("from", it.from);
            arr.put(o);
        }
        JSObject r = new JSObject();
        r.put("packets", arr);
        call.resolve(r);
    }

    @PluginMethod
    public void getDbKey(PluginCall call) {
        try {
            SharedPreferences sp = getContext().getSharedPreferences("ripplo_keys", Context.MODE_PRIVATE);
            KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
            ks.load(null);
            if (!ks.containsAlias(KEY_ALIAS)) {
                KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
                kg.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build());
                kg.generateKey();
            }
            SecretKey wrap = (SecretKey) ks.getKey(KEY_ALIAS, null);
            String stored = sp.getString("dbkey", null);
            byte[] key;
            if (stored == null) {
                key = new byte[32];
                new SecureRandom().nextBytes(key);
                Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
                c.init(Cipher.ENCRYPT_MODE, wrap);
                byte[] iv = c.getIV();
                byte[] ct = c.doFinal(key);
                byte[] blob = new byte[iv.length + ct.length];
                System.arraycopy(iv, 0, blob, 0, iv.length);
                System.arraycopy(ct, 0, blob, iv.length, ct.length);
                sp.edit().putString("dbkey", Base64.encodeToString(blob, Base64.NO_WRAP)).apply();
            } else {
                byte[] blob = Base64.decode(stored, Base64.NO_WRAP);
                Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
                c.init(Cipher.DECRYPT_MODE, wrap, new GCMParameterSpec(128, blob, 0, 12));
                key = c.doFinal(blob, 12, blob.length - 12);
            }
            JSObject r = new JSObject();
            r.put("key", Base64.encodeToString(key, Base64.NO_WRAP));
            call.resolve(r);
        } catch (Exception e) {
            call.reject("key unavailable");
        }
    }

    private static String hex(byte[] b) {
        return Packet.hex(b);
    }

    @PluginMethod
    public void selfHash(PluginCall call) {
        try (InputStream in = new FileInputStream(getContext().getApplicationInfo().sourceDir)) {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
            JSObject r = new JSObject();
            r.put("sha256", hex(md.digest()));
            call.resolve(r);
        } catch (Exception e) {
            call.reject("hash failed");
        }
    }

    @PluginMethod
    public void requestBatteryExemption(PluginCall call) {
        Context ctx = getContext();
        PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
        if (pm.isIgnoringBatteryOptimizations(ctx.getPackageName())) { call.resolve(); return; }
        try {
            Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.getPackageName()));
            getActivity().startActivity(i);
        } catch (RuntimeException e) {
            try {
                getActivity().startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (RuntimeException ignored) {
            }
        }
        call.resolve();
    }

    private boolean granted(String perm) {
        return getContext().checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED;
    }

    private String state(boolean ok, String alias) {
        if (ok) return "granted";
        SharedPreferences sp = getContext().getSharedPreferences("ripplo_perm", Context.MODE_PRIVATE);
        return sp.getBoolean(alias, false) ? "denied" : "prompt";
    }

    private JSObject states() {
        boolean bt = Build.VERSION.SDK_INT >= 31
                ? granted(Manifest.permission.BLUETOOTH_SCAN) && granted(Manifest.permission.BLUETOOTH_ADVERTISE) && granted(Manifest.permission.BLUETOOTH_CONNECT)
                : granted(Manifest.permission.ACCESS_FINE_LOCATION);
        boolean wifi = Build.VERSION.SDK_INT >= 33
                ? granted(Manifest.permission.NEARBY_WIFI_DEVICES)
                : granted(Manifest.permission.ACCESS_FINE_LOCATION);
        boolean notif = Build.VERSION.SDK_INT >= 33
                ? granted(Manifest.permission.POST_NOTIFICATIONS)
                : androidx.core.app.NotificationManagerCompat.from(getContext()).areNotificationsEnabled();
        JSObject o = new JSObject();
        o.put("bluetooth", state(bt, "bluetooth"));
        o.put("wifi", state(wifi, "wifi"));
        o.put("notifications", state(notif, "notifications"));
        return o;
    }

    @PluginMethod
    public void checkPermissions(PluginCall call) {
        call.resolve(states());
    }

    @PluginMethod
    public void requestPermissions(PluginCall call) {
        JSObject s = states();
        List<String> need = new ArrayList<>();
        SharedPreferences.Editor ed = getContext().getSharedPreferences("ripplo_perm", Context.MODE_PRIVATE).edit();
        if (!"granted".equals(s.getString("bluetooth"))) { need.add(Build.VERSION.SDK_INT >= 31 ? "bluetooth" : "bluetoothLegacy"); ed.putBoolean("bluetooth", true); }
        if (!"granted".equals(s.getString("wifi"))) { need.add(Build.VERSION.SDK_INT >= 33 ? "wifi" : "wifiLegacy"); ed.putBoolean("wifi", true); }
        if (Build.VERSION.SDK_INT >= 33 && !"granted".equals(s.getString("notifications"))) { need.add("notifications"); ed.putBoolean("notifications", true); }
        ed.apply();
        if (need.isEmpty()) { call.resolve(s); return; }
        requestPermissionForAliases(need.toArray(new String[0]), call, "permissionsDone");
    }

    @PermissionCallback
    private void permissionsDone(PluginCall call) {
        call.resolve(states());
    }

    @PluginMethod
    public void installUpdate(final PluginCall call) {
        final String url = call.getString("url", "");
        final String sha = call.getString("sha256", "").toLowerCase();
        if (!url.startsWith("https://") || !sha.matches("[0-9a-f]{64}")) { call.reject("bad arguments"); return; }
        Thread t = new Thread(() -> {
            File apk = new File(getContext().getCacheDir(), "update.apk");
            try {
                download(url, apk, sha);
                verifyCerts(apk);
                install(apk, call);
            } catch (Exception e) {
                apk.delete();
                call.reject(e.getMessage() == null ? "update failed" : e.getMessage());
            }
        }, "ripplo-update");
        t.setDaemon(true);
        t.start();
    }

    private void download(String url, File out, String sha) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(30000);
        c.setInstanceFollowRedirects(true);
        try {
            if (c.getResponseCode() != 200 || !"https".equals(c.getURL().getProtocol())) throw new Exception("download failed");
            long total = c.getContentLengthLong();
            if (total > 300L * 1024 * 1024) throw new Exception("too large");
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            long got = 0;
            int lastPct = -1;
            try (InputStream in = c.getInputStream(); OutputStream os = new FileOutputStream(out)) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) {
                    md.update(buf, 0, n);
                    os.write(buf, 0, n);
                    got += n;
                    if (got > 300L * 1024 * 1024) throw new Exception("too large");
                    if (total > 0) {
                        int pct = (int) (got * 100 / total);
                        if (pct != lastPct) {
                            lastPct = pct;
                            JSObject o = new JSObject();
                            o.put("progress", pct / 100.0);
                            notifyListeners("updateProgress", o);
                        }
                    }
                }
            }
            if (!hex(md.digest()).equals(sha)) throw new Exception("hash mismatch");
        } finally {
            c.disconnect();
        }
    }

    @SuppressWarnings("deprecation")
    private static Set<String> certs(PackageInfo pi) throws Exception {
        Set<String> out = new HashSet<>();
        Signature[] sigs;
        if (Build.VERSION.SDK_INT >= 28) {
            if (pi.signingInfo == null) throw new Exception("no signature");
            sigs = pi.signingInfo.getApkContentsSigners();
        } else {
            sigs = pi.signatures;
        }
        if (sigs == null || sigs.length == 0) throw new Exception("no signature");
        for (Signature s : sigs) out.add(hex(MessageDigest.getInstance("SHA-256").digest(s.toByteArray())));
        return out;
    }

    @SuppressWarnings("deprecation")
    private void verifyCerts(File apk) throws Exception {
        PackageManager pm = getContext().getPackageManager();
        int flags = Build.VERSION.SDK_INT >= 28 ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES;
        PackageInfo archive = pm.getPackageArchiveInfo(apk.getAbsolutePath(), flags);
        if (archive == null || !getContext().getPackageName().equals(archive.packageName)) throw new Exception("wrong package");
        PackageInfo installed = pm.getPackageInfo(getContext().getPackageName(), flags);
        if (!certs(archive).equals(certs(installed))) throw new Exception("signature mismatch");
    }

    private void install(File apk, PluginCall call) throws Exception {
        Context ctx = getContext();
        PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(ctx.getPackageName());
        if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED);
        int id = pi.createSession(params);
        try (PackageInstaller.Session session = pi.openSession(id)) {
            try (InputStream in = new FileInputStream(apk); OutputStream os = session.openWrite("base.apk", 0, apk.length())) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
                session.fsync(os);
            }
            installCall = call;
            Intent i = new Intent(ctx, InstallReceiver.class).setAction(ACTION_INSTALL);
            int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
            PendingIntent pending = PendingIntent.getBroadcast(ctx, id, i, flags);
            session.commit(pending.getIntentSender());
        } catch (Exception e) {
            pi.abandonSession(id);
            throw e;
        }
    }

    static void installResult(boolean ok, int status) {
        PluginCall c = installCall;
        installCall = null;
        if (c == null) return;
        if (ok) {
            JSObject r = new JSObject();
            r.put("status", "success");
            c.resolve(r);
        } else {
            c.reject("install failed " + status);
        }
    }
}
