package io.github.nahida4479.ripplo.mesh;

import android.Manifest;
import android.app.Activity;
import android.app.KeyguardManager;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.ContentResolver;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.DocumentsContract;
import android.provider.Settings;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import android.view.WindowManager;
import androidx.activity.result.ActivityResult;
import androidx.fragment.app.FragmentActivity;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.FilterOutputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.HashSet;
import java.text.SimpleDateFormat;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONException;
import org.json.JSONObject;

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
                @Permission(alias = "notifications", strings = {Manifest.permission.POST_NOTIFICATIONS}),
                @Permission(alias = "microphone", strings = {Manifest.permission.RECORD_AUDIO})
        })
public class RipploMeshPlugin extends Plugin implements MeshEngine.Listener {
    private static final String KEY_ALIAS = "ripplo_db_wrap";
    static volatile PluginCall installCall;
    static volatile boolean foreground;
    private volatile JSObject pendingShare;
    private volatile JSObject pendingOpen;
    private final ExecutorService shareExec = Executors.newSingleThreadExecutor();
    private final ExecutorService drainExec = Executors.newSingleThreadExecutor();
    private static final java.util.regex.Pattern CHAT_ID = java.util.regex.Pattern.compile("^[0-9A-HJKMNP-TV-Z]{16}$|^[A-Za-z0-9_-]{6,32}$");

    private interface SignalOp {
        JSObject run(SignalCore core) throws Exception;
    }

    private final ExecutorService signalExec = Executors.newSingleThreadExecutor();
    private final ExecutorService storeExec = Executors.newSingleThreadExecutor();
    private final ExecutorService backupExec = Executors.newSingleThreadExecutor();
    private BackupEngine backupEngine;
    private MeshEngine engine;
    private boolean drained;

    @Override
    public void load() {
        engine = MeshEngine.get(getContext());
        engine.setListener(this);
        Diag.sink = (medium, node, stage, detail) -> {
            android.app.Activity act = getActivity();
            if (act == null) return;
            JSObject o = new JSObject();
            o.put("medium", medium);
            o.put("node", node);
            o.put("stage", stage);
            o.put("detail", detail);
            o.put("at", System.currentTimeMillis());
            act.runOnUiThread(() -> notifyListeners("devStage", o));
        };
        readShare(getActivity() == null ? null : getActivity().getIntent());
        readOpen(getActivity() == null ? null : getActivity().getIntent());
    }

    @Override
    protected void handleOnNewIntent(Intent intent) {
        super.handleOnNewIntent(intent);
        readShare(intent);
        readOpen(intent);
    }

    private void readOpen(Intent intent) {
        if (intent == null) return;
        String chat = intent.getStringExtra(Notifier.EXTRA_CHAT);
        String token = intent.getStringExtra(Notifier.EXTRA_ANSWER);
        intent.removeExtra(Notifier.EXTRA_CHAT);
        intent.removeExtra(Notifier.EXTRA_ANSWER);
        if (chat == null || !CHAT_ID.matcher(chat).matches()) return;
        JSObject o = new JSObject();
        o.put("chatId", chat);
        String callId = Opener.redeem(token);
        if (callId != null) o.put("answer", callId);
        pendingOpen = o;
        notifyListeners("open", new JSObject());
    }

    @PluginMethod
    public void takeOpen(PluginCall call) {
        JSObject s = pendingOpen;
        pendingOpen = null;
        JSObject r = new JSObject();
        if (s != null) r.put("open", s);
        call.resolve(r);
    }

    private JSObject openedJson(Inbox.Item it, byte[] key) {
        try {
            byte[] plain = Shared.open(key, it.packet, "inbox");
            return new JSObject(new String(plain, java.nio.charset.StandardCharsets.UTF_8));
        } catch (Exception e) {
            return null;
        }
    }

    private void readShare(Intent intent) {
        if (intent == null || !Intent.ACTION_SEND.equals(intent.getAction())) return;
        final String type = intent.getType();
        final String text = intent.getStringExtra(Intent.EXTRA_TEXT);
        final Uri stream = Build.VERSION.SDK_INT >= 33
                ? intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class)
                : (Uri) intent.getParcelableExtra(Intent.EXTRA_STREAM);
        intent.setAction(Intent.ACTION_MAIN);
        shareExec.execute(() -> {
            try {
                JSObject o = new JSObject();
                if (stream != null) {
                    if (!"content".equals(stream.getScheme()) || stream.getAuthority() == null
                            || stream.getAuthority().startsWith(getContext().getPackageName())) return;
                    String mime = getContext().getContentResolver().getType(stream);
                    if (mime == null) mime = type;
                    if (mime == null || !(mime.startsWith("image/") || mime.startsWith("video/") || mime.startsWith("audio/"))) return;
                    File dir = new File(getContext().getCacheDir(), "share");
                    File[] old = dir.listFiles();
                    if (old != null) for (File f : old) f.delete();
                    dir.mkdirs();
                    File out = new File(dir, "s" + System.nanoTime());
                    long total = 0;
                    try (InputStream in = getContext().getContentResolver().openInputStream(stream); OutputStream os = new FileOutputStream(out)) {
                        if (in == null) return;
                        byte[] buf = new byte[65536];
                        int n;
                        while ((n = in.read(buf)) > 0) {
                            total += n;
                            if (total > 20L * 1024 * 1024) { out.delete(); return; }
                            os.write(buf, 0, n);
                        }
                    }
                    o.put("kind", mime.startsWith("image/") ? "image" : mime.startsWith("video/") ? "video" : "voice");
                    o.put("mime", mime);
                    o.put("path", out.getAbsolutePath());
                } else if (text != null && !text.trim().isEmpty()) {
                    o.put("kind", "text");
                    o.put("text", text);
                } else {
                    return;
                }
                pendingShare = o;
                notifyListeners("share", new JSObject());
            } catch (Exception ignored) {
            }
        });
    }

    @PluginMethod
    public void takeShare(PluginCall call) {
        JSObject s = pendingShare;
        pendingShare = null;
        JSObject r = new JSObject();
        if (s != null) r.put("share", s);
        call.resolve(r);
    }

    @Override
    protected void handleOnPause() {
        foreground = false;
        engine.setJsAttached(false);
    }

    @Override
    protected void handleOnResume() {
        foreground = true;
        Notifier.cancelUpdated(getContext());
        Ringer.stop();
        Notifier.cancelCall(getContext());
        Opener.forgetRinging();
        if (!drained) return;
        engine.setJsAttached(true);
        drainExec.execute(this::deliverInbox);
        lateDrain();
    }

    private void lateDrain() {
        new Handler(Looper.getMainLooper()).postDelayed(() -> drainExec.execute(this::deliverInbox), 1500);
    }

    private byte[] keyOrNull() {
        try {
            return Shared.dbKey(getContext());
        } catch (Exception e) {
            return null;
        }
    }

    private void deliverInbox() {
        List<Inbox.Item> items = engine.drainInbox();
        if (items.isEmpty()) return;
        byte[] key = keyOrNull();
        for (Inbox.Item it : items) {
            if (!it.opened()) { onPacket(it.packet, it.from); continue; }
            if (key == null) { engine.requeue(it); continue; }
            JSObject o = openedJson(it, key);
            if (o != null) notifyListeners("opened", o);
        }
    }

    public static boolean callTokenValid(String token) {
        return Opener.peek(token);
    }

    @PluginMethod
    public void isLocked(PluginCall call) {
        KeyguardManager km = (KeyguardManager) getContext().getSystemService(Context.KEYGUARD_SERVICE);
        JSObject r = new JSObject();
        r.put("locked", km != null && km.isKeyguardLocked());
        call.resolve(r);
    }

    @PluginMethod
    public void keepAwake(PluginCall call) {
        final boolean on = call.getBoolean("on", false);
        Activity a = getActivity();
        if (a != null) {
            a.runOnUiThread(() -> {
                if (on) a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                else a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            });
        }
        call.resolve();
    }

    @PluginMethod
    public void endLockedCall(PluginCall call) {
        Activity a = getActivity();
        if (a != null) {
            a.runOnUiThread(() -> {
                if (Build.VERSION.SDK_INT >= 27) a.setShowWhenLocked(false);
                a.finishAndRemoveTask();
            });
        }
        call.resolve();
    }

    @PluginMethod
    public void requestFullScreen(PluginCall call) {
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                getActivity().startActivity(new Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:" + getContext().getPackageName())));
            } catch (RuntimeException ignored) {
            }
        }
        call.resolve();
    }

    @PluginMethod
    public void startRing(PluginCall call) {
        Ringer.start(getContext());
        call.resolve();
    }

    @PluginMethod
    public void stopRing(PluginCall call) {
        Ringer.stop();
        call.resolve();
    }

    @Override
    protected void handleOnDestroy() {
        Ringer.stop();
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
    public void devConnect(PluginCall call) {
        String node = call.getString("node", "");
        String spec = call.getString("spec", "");
        JSObject r = new JSObject();
        r.put("started", !node.isEmpty() && !spec.isEmpty() && engine.forceConnect(node, spec));
        call.resolve(r);
    }

    @PluginMethod
    public void devDisconnect(PluginCall call) {
        String node = call.getString("node", "");
        String medium = call.getString("medium", "");
        if (!node.isEmpty() && !medium.isEmpty()) engine.closeLinks(node, medium);
        call.resolve();
    }

    @PluginMethod
    public void getDeviceInfo(PluginCall call) {
        Context c = getContext();
        StringBuilder b = new StringBuilder();
        b.append("device ").append(Build.MANUFACTURER).append(' ').append(Build.BRAND).append(' ').append(Build.MODEL).append(" (").append(Build.DEVICE).append(")\n");
        b.append("android ").append(Build.VERSION.RELEASE).append(" sdk ").append(Build.VERSION.SDK_INT);
        if (Build.VERSION.SDK_INT >= 23) b.append(" patch ").append(Build.VERSION.SECURITY_PATCH);
        b.append('\n');
        android.content.pm.PackageManager pm = c.getPackageManager();
        try {
            android.bluetooth.BluetoothManager bm = (android.bluetooth.BluetoothManager) c.getSystemService(Context.BLUETOOTH_SERVICE);
            android.bluetooth.BluetoothAdapter a = bm == null ? null : bm.getAdapter();
            b.append("ble ").append(pm.hasSystemFeature(android.content.pm.PackageManager.FEATURE_BLUETOOTH_LE))
                    .append(" bt-on ").append(a != null && a.isEnabled());
            if (a != null && Build.VERSION.SDK_INT >= 26) {
                b.append(" coded ").append(a.isLeCodedPhySupported()).append(" ext-adv ").append(a.isLeExtendedAdvertisingSupported())
                        .append(" 2m ").append(a.isLe2MPhySupported()).append(" periodic ").append(a.isLePeriodicAdvertisingSupported());
            }
            b.append(" l2cap ").append(Build.VERSION.SDK_INT >= 29).append('\n');
        } catch (RuntimeException e) { b.append("ble info error ").append(e).append('\n'); }
        b.append("wifi-aware ").append(pm.hasSystemFeature("android.hardware.wifi.aware"))
                .append(" wifi-direct ").append(pm.hasSystemFeature("android.hardware.wifi.direct"))
                .append(" wifi ").append(pm.hasSystemFeature("android.hardware.wifi")).append('\n');
        try {
            android.os.PowerManager pw = (android.os.PowerManager) c.getSystemService(Context.POWER_SERVICE);
            b.append("battery-optimization-ignored ").append(Build.VERSION.SDK_INT >= 23 && pw.isIgnoringBatteryOptimizations(c.getPackageName()))
                    .append(" power-save ").append(pw.isPowerSaveMode())
                    .append(" idle ").append(Build.VERSION.SDK_INT >= 23 && pw.isDeviceIdleMode());
            if (Build.VERSION.SDK_INT >= 28) {
                android.app.ActivityManager am = (android.app.ActivityManager) c.getSystemService(Context.ACTIVITY_SERVICE);
                b.append(" bg-restricted ").append(am.isBackgroundRestricted());
                android.app.usage.UsageStatsManager us = (android.app.usage.UsageStatsManager) c.getSystemService(Context.USAGE_STATS_SERVICE);
                if (us != null) b.append(" standby-bucket ").append(us.getAppStandbyBucket());
            }
            b.append('\n');
        } catch (RuntimeException e) { b.append("power info error ").append(e).append('\n'); }
        JSObject r = new JSObject();
        r.put("text", b.toString());
        call.resolve(r);
    }

    @PluginMethod
    public void getBleCaps(PluginCall call) {
        boolean coded = false;
        boolean ext = false;
        try {
            android.bluetooth.BluetoothManager bm = (android.bluetooth.BluetoothManager) getContext().getSystemService(Context.BLUETOOTH_SERVICE);
            android.bluetooth.BluetoothAdapter a = bm == null ? null : bm.getAdapter();
            if (a != null && Build.VERSION.SDK_INT >= 26) {
                coded = a.isLeCodedPhySupported();
                ext = a.isLeExtendedAdvertisingSupported();
            }
        } catch (RuntimeException ignored) {
        }
        JSObject r = new JSObject();
        r.put("coded", coded);
        r.put("extended", ext);
        call.resolve(r);
    }

    @PluginMethod
    public void getDiag(PluginCall call) {
        JSObject r = new JSObject();
        r.put("log", Diag.dump());
        call.resolve(r);
    }

    @PluginMethod
    public void clearDiag(PluginCall call) {
        Diag.clear();
        call.resolve();
    }

    @PluginMethod
    public void getTransports(PluginCall call) {
        try {
            JSObject r = new JSObject();
            r.put("transports", new JSArray(engine.transportsJson().toString()));
            call.resolve(r);
        } catch (JSONException e) {
            call.reject("failed");
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
        byte[] key = keyOrNull();
        for (Inbox.Item it : engine.drainInbox()) {
            JSObject o = new JSObject();
            if (it.opened()) {
                if (key == null) { engine.requeue(it); continue; }
                JSObject rec = openedJson(it, key);
                if (rec == null) continue;
                o.put("opened", rec);
            } else {
                o.put("packet", Base64.encodeToString(it.packet, Base64.NO_WRAP));
                o.put("from", it.from);
            }
            arr.put(o);
        }
        JSObject r = new JSObject();
        r.put("packets", arr);
        call.resolve(r);
        lateDrain();
    }

    private String wrapDbKey(byte[] key) throws Exception {
        return Shared.wrapDbKey(key);
    }

    private byte[] loadDbKey() throws Exception {
        return Shared.dbKey(getContext());
    }

    @PluginMethod
    public void getDbKey(PluginCall call) {
        try {
            JSObject r = new JSObject();
            r.put("key", Base64.encodeToString(loadDbKey(), Base64.NO_WRAP));
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

    private static String enc(byte[] b) {
        return Base64.encodeToString(b, Base64.NO_WRAP);
    }

    private static byte[] arg(PluginCall call, String name) {
        String v = call.getString(name);
        if (v == null) throw new IllegalArgumentException("bad_message");
        return b64(v);
    }

    private void signal(PluginCall call, SignalOp op) {
        signalExec.execute(() -> {
            try {
                call.resolve(op.run(Shared.signal(getContext())));
            } catch (Exception e) {
                String m = e.getMessage();
                boolean known = SignalCore.BAD_BUNDLE.equals(m) || SignalCore.NO_SESSION.equals(m)
                        || SignalCore.UNTRUSTED.equals(m);
                String code = known ? m : SignalCore.BAD_MESSAGE;
                if (e instanceof SignalCore.Failed) {
                    JSObject d = new JSObject();
                    d.put("tag", SignalCore.hex(((SignalCore.Failed) e).tag));
                    call.reject(code, code, null, d);
                } else {
                    call.reject(code, code);
                }
            }
        });
    }

    @PluginMethod
    public void signalInit(PluginCall call) {
        signal(call, c -> {
            JSObject r = new JSObject();
            r.put("bundle", enc(c.init()));
            r.put("ik", enc(c.identityKey()));
            return r;
        });
    }

    @PluginMethod
    public void signalAddContact(PluginCall call) {
        signal(call, c -> {
            JSObject r = new JSObject();
            r.put("tag", SignalCore.hex(c.addContact(arg(call, "bundle"))));
            return r;
        });
    }

    @PluginMethod
    public void signalSeal(PluginCall call) {
        signal(call, c -> {
            JSObject r = new JSObject();
            r.put("payload", enc(c.seal(SignalCore.unhex(call.getString("tag")), arg(call, "plaintext"))));
            return r;
        });
    }

    @PluginMethod
    public void signalOpen(PluginCall call) {
        signal(call, c -> {
            SignalCore.Opened o = c.open(arg(call, "payload"));
            JSObject r = new JSObject();
            r.put("tag", SignalCore.hex(o.tag));
            r.put("ik", enc(o.ik));
            r.put("plaintext", enc(o.plaintext));
            return r;
        });
    }

    @PluginMethod
    public void signalProof(PluginCall call) {
        signal(call, c -> {
            JSObject r = new JSObject();
            r.put("mac", enc(c.proof(arg(call, "ik"), arg(call, "n"), arg(call, "challengerTag"), arg(call, "proverTag"))));
            return r;
        });
    }

    @PluginMethod
    public void signalSafetyNumber(PluginCall call) {
        signal(call, c -> {
            JSObject r = new JSObject();
            r.put("digits", c.safetyNumber(arg(call, "ik")));
            return r;
        });
    }

    @PluginMethod
    public void signalForget(PluginCall call) {
        signal(call, c -> {
            c.forget(SignalCore.unhex(call.getString("tag")));
            return new JSObject();
        });
    }

    private SignalFileStore sigStore() throws Exception {
        return Shared.signalStore(getContext());
    }

    private NativeStore db() {
        return Shared.db(getContext());
    }

    private synchronized BackupEngine backup() {
        if (backupEngine == null) backupEngine = new BackupEngine(getContext());
        return backupEngine;
    }

    private void run(ExecutorService ex, PluginCall call, Callable<JSObject> op) {
        ex.execute(() -> {
            try {
                JSObject r = op.call();
                if (r == null) call.resolve(); else call.resolve(r);
            } catch (Exception e) {
                String code = e instanceof BackupFormat.BackupException ? ((BackupFormat.BackupException) e).code : "failed";
                call.reject(code, code);
            }
        });
    }

    private static String need(PluginCall call, String name) {
        String v = call.getString(name);
        if (v == null) throw new IllegalArgumentException("bad_args");
        return v;
    }

    @PluginMethod
    public void dbPut(PluginCall call) {
        run(storeExec, call, () -> {
            db().put(need(call, "store"), need(call, "key"), call.getString("idx"), Base64.decode(need(call, "value"), Base64.NO_WRAP));
            return null;
        });
    }

    @PluginMethod
    public void dbPutMany(PluginCall call) {
        run(storeExec, call, () -> {
            JSArray arr = call.getArray("rows");
            if (arr == null) throw new IllegalArgumentException("bad_args");
            List<String[]> rows = new ArrayList<>();
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                rows.add(new String[]{o.getString("store"), o.getString("key"), o.isNull("idx") ? null : o.getString("idx"), o.getString("value")});
            }
            JSObject r = new JSObject();
            r.put("count", db().putMany(rows));
            return r;
        });
    }

    @PluginMethod
    public void dbGet(PluginCall call) {
        run(storeExec, call, () -> {
            String v = db().get(need(call, "store"), need(call, "key"));
            JSObject r = new JSObject();
            r.put("value", v == null ? JSONObject.NULL : v);
            return r;
        });
    }

    @PluginMethod
    public void dbDel(PluginCall call) {
        run(storeExec, call, () -> {
            db().del(need(call, "store"), need(call, "key"));
            return null;
        });
    }

    @PluginMethod
    public void dbKeys(PluginCall call) {
        run(storeExec, call, () -> {
            JSArray keys = new JSArray();
            for (String k : db().keys(need(call, "store"), call.getString("prefix"))) keys.put(k);
            JSObject r = new JSObject();
            r.put("keys", keys);
            return r;
        });
    }

    private static JSObject rowsResult(List<NativeStore.Row> rows) throws JSONException {
        JSArray arr = new JSArray();
        for (NativeStore.Row row : rows) {
            JSObject o = new JSObject();
            o.put("key", row.key);
            o.put("value", row.value);
            arr.put(o);
        }
        JSObject r = new JSObject();
        r.put("rows", arr);
        return r;
    }

    @PluginMethod
    public void dbAll(PluginCall call) {
        run(storeExec, call, () -> rowsResult(db().all(need(call, "store"))));
    }

    @PluginMethod
    public void dbByIdx(PluginCall call) {
        run(storeExec, call, () -> rowsResult(db().byIdx(need(call, "store"), need(call, "idx"))));
    }

    @PluginMethod
    public void dbCount(PluginCall call) {
        run(storeExec, call, () -> {
            JSObject r = new JSObject();
            r.put("count", db().count());
            return r;
        });
    }

    @PluginMethod
    public void authAvailable(PluginCall call) {
        JSObject r = new JSObject();
        r.put("biometric", AppLock.biometric(getContext()));
        r.put("deviceCredential", AppLock.deviceCredential(getContext()));
        call.resolve(r);
    }

    private void authenticateThen(PluginCall call, String reason, AppLock.Result next) {
        FragmentActivity a = getActivity();
        a.runOnUiThread(() -> AppLock.authenticate(a, reason, next));
    }

    @PluginMethod
    public void authenticate(PluginCall call) {
        authenticateThen(call, call.getString("reason", "Ripplo"), ok -> {
            JSObject r = new JSObject();
            r.put("ok", ok);
            call.resolve(r);
        });
    }

    @PluginMethod
    public void setSecure(PluginCall call) {
        boolean on = Boolean.TRUE.equals(call.getBoolean("on", false));
        getActivity().runOnUiThread(() -> {
            if (on) getActivity().getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
            else getActivity().getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
            call.resolve();
        });
    }

    @PluginMethod
    public void backupStatus(PluginCall call) {
        SharedPreferences sp = backup().prefs();
        JSObject r = new JSObject();
        r.put("enabled", backup().enabled());
        r.put("lastAt", sp.getLong("lastAt", 0));
        String f = sp.getString("folderName", null);
        r.put("folder", sp.getString("folder", null) == null || f == null ? JSONObject.NULL : f);
        call.resolve(r);
    }

    @PluginMethod
    public void backupEnable(PluginCall call) {
        run(backupExec, call, () -> {
            JSObject r = new JSObject();
            r.put("code", backup().enable());
            return r;
        });
    }

    @PluginMethod
    public void backupShowCode(PluginCall call) {
        authenticateThen(call, "Ripplo", ok -> {
            if (!ok) { call.reject("auth_failed", "auth_failed"); return; }
            run(backupExec, call, () -> {
                BackupEngine.Secrets s = backup().secrets();
                if (s == null) throw new IllegalStateException("not_enabled");
                JSObject r = new JSObject();
                r.put("code", s.code);
                return r;
            });
        });
    }

    @PluginMethod
    public void backupDisable(PluginCall call) {
        authenticateThen(call, "Ripplo", ok -> {
            if (!ok) { call.reject("auth_failed", "auth_failed"); return; }
            run(backupExec, call, () -> {
                SharedPreferences sp = backup().prefs();
                releaseFolder(sp.getString("folder", null));
                sp.edit().clear().commit();
                return null;
            });
        });
    }

    private void releaseFolder(String uri) {
        if (uri == null) return;
        try {
            getContext().getContentResolver().releasePersistableUriPermission(Uri.parse(uri),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        } catch (RuntimeException ignored) {
        }
    }

    private String displayName(Uri doc) {
        try (Cursor c = getContext().getContentResolver().query(doc, new String[]{DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) return c.getString(0);
        } catch (RuntimeException ignored) {
        }
        return null;
    }

    @PluginMethod
    public void backupChooseFolder(PluginCall call) {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        startActivityForResult(call, i, "folderPicked");
    }

    @ActivityCallback
    private void folderPicked(PluginCall call, ActivityResult result) {
        if (call == null) return;
        Intent data = result.getData();
        if (result.getResultCode() != Activity.RESULT_OK || data == null || data.getData() == null) {
            call.reject("cancelled", "cancelled");
            return;
        }
        try {
            Uri tree = data.getData();
            getContext().getContentResolver().takePersistableUriPermission(tree,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            SharedPreferences sp = backup().prefs();
            String old = sp.getString("folder", null);
            if (old != null && !old.equals(tree.toString())) releaseFolder(old);
            String name = displayName(DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree)));
            if (name == null) name = tree.getLastPathSegment();
            sp.edit().putString("folder", tree.toString()).putString("folderName", name).commit();
            JSObject r = new JSObject();
            r.put("folder", name);
            call.resolve(r);
        } catch (RuntimeException e) {
            call.reject("failed", "failed");
        }
    }

    private static final class Counting extends FilterOutputStream {
        long n;

        Counting(OutputStream o) {
            super(o);
        }

        @Override
        public void write(int b) throws java.io.IOException {
            out.write(b);
            n++;
        }

        @Override
        public void write(byte[] b, int off, int len) throws java.io.IOException {
            out.write(b, off, len);
            n += len;
        }
    }

    private long writeBackup(OutputStream raw, PluginCall call) throws Exception {
        BackupEngine.Secrets s = backup().secrets();
        if (s == null) throw new IllegalStateException("not_enabled");
        Counting out = new Counting(new java.io.BufferedOutputStream(raw, 65536));
        backup().write(out, call.getObject("meta", new JSObject()).toString(), loadDbKey(), s, sigStore(), db());
        backup().prefs().edit().putLong("lastAt", System.currentTimeMillis()).commit();
        return out.n;
    }

    private static final String BACKUP_FILE = "Ripplo-backup.rbk";

    private static String backupName() {
        return "Ripplo-backup-" + new SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(new Date()) + ".rbk";
    }

    private JSObject created(String name, long size) {
        JSObject r = new JSObject();
        r.put("ok", true);
        r.put("name", name);
        r.put("size", size);
        return r;
    }

    @PluginMethod
    public void backupCreate(PluginCall call) {
        if (!backup().enabled()) { call.reject("not_enabled", "not_enabled"); return; }
        String mode = call.getString("mode", "pick");
        SharedPreferences sp = backup().prefs();
        final String folder = sp.getString("folder", null);
        if ("pick".equals(mode) || ("now".equals(mode) && folder == null)) {
            Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, backupName());
            startActivityForResult(call, i, "createPicked");
            return;
        }
        if (folder == null) { call.reject("no_folder", "no_folder"); return; }
        if ("auto".equals(mode) && System.currentTimeMillis() - sp.getLong("lastAt", 0) < 24L * 3600 * 1000) {
            JSObject r = new JSObject();
            r.put("skipped", true);
            call.resolve(r);
            return;
        }
        run(backupExec, call, () -> writeToFolder(folder, call));
    }

    private JSObject writeToFolder(String folder, PluginCall call) throws Exception {
        ContentResolver cr = getContext().getContentResolver();
        Uri tree = Uri.parse(folder);
        String treeId = DocumentsContract.getTreeDocumentId(tree);
        Uri parent = DocumentsContract.buildDocumentUriUsingTree(tree, treeId);
        String tmpName = BACKUP_FILE + ".tmp";
        deleteNamed(cr, tree, treeId, tmpName);
        Uri tmp;
        try {
            tmp = DocumentsContract.createDocument(cr, parent, "application/octet-stream", tmpName);
        } catch (RuntimeException e) {
            throw new IllegalStateException("folder_unavailable");
        }
        if (tmp == null) throw new IllegalStateException("folder_unavailable");
        long size;
        try (OutputStream o = cr.openOutputStream(tmp, "wt")) {
            if (o == null) throw new IllegalStateException("folder_unavailable");
            size = writeBackup(o, call);
        } catch (Exception e) {
            try {
                DocumentsContract.deleteDocument(cr, tmp);
            } catch (Exception ignored) {
            }
            throw e;
        }
        deleteNamed(cr, tree, treeId, BACKUP_FILE);
        Uri done;
        try {
            done = DocumentsContract.renameDocument(cr, tmp, BACKUP_FILE);
        } catch (RuntimeException e) {
            done = null;
        }
        if (done == null) throw new IllegalStateException("folder_unavailable");
        return created(BACKUP_FILE, size);
    }

    private void deleteNamed(ContentResolver cr, Uri tree, String treeId, String name) {
        List<String> ids = new ArrayList<>();
        try (Cursor c = cr.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, treeId),
                new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            while (c != null && c.moveToNext()) if (name.equals(c.getString(1))) ids.add(c.getString(0));
        } catch (RuntimeException e) {
            return;
        }
        for (String id : ids) {
            try {
                DocumentsContract.deleteDocument(cr, DocumentsContract.buildDocumentUriUsingTree(tree, id));
            } catch (Exception ignored) {
            }
        }
    }

    @ActivityCallback
    private void createPicked(PluginCall call, ActivityResult result) {
        if (call == null) return;
        Intent data = result.getData();
        if (result.getResultCode() != Activity.RESULT_OK || data == null || data.getData() == null) {
            call.reject("cancelled", "cancelled");
            return;
        }
        Uri uri = data.getData();
        run(backupExec, call, () -> {
            ContentResolver cr = getContext().getContentResolver();
            long size;
            try (OutputStream o = cr.openOutputStream(uri, "wt")) {
                if (o == null) throw new IllegalStateException("failed");
                size = writeBackup(o, call);
            } catch (Exception e) {
                try {
                    DocumentsContract.deleteDocument(cr, uri);
                } catch (Exception ignored) {
                }
                throw e;
            }
            String name = displayName(uri);
            return created(name == null ? backupName() : name, size);
        });
    }

    @PluginMethod
    public void backupRestore(PluginCall call) {
        if (call.getString("code") == null) { call.reject("bad_code", "bad_code"); return; }
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
        startActivityForResult(call, i, "restorePicked");
    }

    @ActivityCallback
    private void restorePicked(PluginCall call, ActivityResult result) {
        if (call == null) return;
        Intent data = result.getData();
        if (result.getResultCode() != Activity.RESULT_OK || data == null || data.getData() == null) {
            call.reject("cancelled", "cancelled");
            return;
        }
        Uri uri = data.getData();
        run(signalExec, call, () -> {
            BackupEngine be = backup();
            BackupEngine.Staged st;
            try (InputStream raw = getContext().getContentResolver().openInputStream(uri)) {
                if (raw == null) throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
                st = be.stage(new java.io.BufferedInputStream(raw, 65536), call.getString("code", ""));
            }
            try {
                JSObject meta;
                try {
                    meta = new JSObject(st.meta);
                } catch (JSONException e) {
                    throw new BackupFormat.BackupException(BackupFormat.BAD_FILE);
                }
                applyRestore(st);
                JSObject r = new JSObject();
                r.put("meta", meta);
                return r;
            } finally {
                be.discard(st);
            }
        });
    }

    private static void deleteTree(File f) {
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) deleteTree(k);
        f.delete();
    }

    private void applyRestore(BackupEngine.Staged st) throws Exception {
        File fd = getContext().getFilesDir();
        File cur = new File(fd, "signal");
        File neu = new File(fd, "signal.restore");
        File old = new File(fd, "signal.old");
        deleteTree(neu);
        deleteTree(old);
        SignalFileStore ns = SignalFileStore.at(neu, st.dbKey);
        for (java.util.Map.Entry<String, byte[]> e : st.signal.entrySet()) ns.put(e.getKey(), e.getValue());
        SharedPreferences sp = getContext().getSharedPreferences("ripplo_keys", Context.MODE_PRIVATE);
        String oldBlob = sp.getString("dbkey", null);
        boolean swapped = false;
        try {
            if (!sp.edit().putString("dbkey", wrapDbKey(st.dbKey)).commit()) throw new IllegalStateException("failed");
            if (cur.exists() && !cur.renameTo(old)) throw new IllegalStateException("failed");
            if (!neu.renameTo(cur)) throw new IllegalStateException("failed");
            swapped = true;
            db().replaceAllFrom(st.rows);
        } catch (Exception e) {
            if (old.exists()) {
                if (swapped) deleteTree(cur);
                old.renameTo(cur);
            } else if (swapped) {
                deleteTree(cur);
            }
            deleteTree(neu);
            SharedPreferences.Editor ed = sp.edit();
            if (oldBlob == null) ed.remove("dbkey"); else ed.putString("dbkey", oldBlob);
            ed.commit();
            throw e;
        }
        deleteTree(old);
        Shared.reset();
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
        o.put("microphone", state(granted(Manifest.permission.RECORD_AUDIO), "microphone"));
        if (Build.VERSION.SDK_INT >= 34) {
            NotificationManager nm = getContext().getSystemService(NotificationManager.class);
            o.put("fullscreen", nm != null && nm.canUseFullScreenIntent() ? "granted" : "prompt");
        }
        PowerManager pm = (PowerManager) getContext().getSystemService(Context.POWER_SERVICE);
        o.put("battery", pm.isIgnoringBatteryOptimizations(getContext().getPackageName()) ? "granted" : "prompt");
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
        if (!"granted".equals(s.getString("microphone"))) { need.add("microphone"); ed.putBoolean("microphone", true); }
        ed.apply();
        if (need.isEmpty()) { call.resolve(s); return; }
        requestPermissionForAliases(need.toArray(new String[0]), call, "permissionsDone");
    }

    @PermissionCallback
    private void permissionsDone(PluginCall call) {
        call.resolve(states());
    }

    @PluginMethod
    public void setAutoUpdate(PluginCall call) {
        boolean on = call.getBoolean("enabled", true);
        getContext().getSharedPreferences(UpdateEngine.PREFS, Context.MODE_PRIVATE).edit().putBoolean("auto", on).apply();
        if (on) UpdateJobService.schedule(getContext());
        else UpdateJobService.cancel(getContext());
        call.resolve();
    }

    @PluginMethod
    public void installUpdate(final PluginCall call) {
        final String url = call.getString("url", "");
        final String sha = call.getString("sha256", "").toLowerCase();
        if (!url.startsWith("https://") || !sha.matches("[0-9a-f]{64}")) { call.reject("bad arguments"); return; }
        if (!UpdateEngine.canInstall(getContext())) {
            if (call.getBoolean("prompt", false)) {
                try {
                    getActivity().startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + getContext().getPackageName())));
                } catch (RuntimeException ignored) {
                }
            }
            call.reject("install_permission");
            return;
        }
        if (!UpdateEngine.busy.compareAndSet(false, true)) { call.reject("busy"); return; }
        Thread t = new Thread(() -> {
            try {
                UpdateEngine.apply(getContext(), url, sha, p -> {
                    JSObject o = new JSObject();
                    o.put("progress", p);
                    notifyListeners("updateProgress", o);
                }, call);
            } catch (Exception e) {
                call.reject(e.getMessage() == null ? "update failed" : e.getMessage());
            } finally {
                UpdateEngine.busy.set(false);
            }
        }, "ripplo-update");
        t.setDaemon(true);
        t.start();
    }

    static void installResult(boolean ok, int status, String message) {
        PluginCall c = installCall;
        installCall = null;
        if (c == null) return;
        if (ok) {
            JSObject r = new JSObject();
            r.put("status", "success");
            c.resolve(r);
        } else {
            c.reject("install failed " + status + (message == null ? "" : ": " + message));
        }
    }
}
