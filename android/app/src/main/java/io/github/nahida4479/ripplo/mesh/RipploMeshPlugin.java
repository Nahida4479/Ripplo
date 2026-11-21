package io.github.nahida4479.ripplo.mesh;

import android.Manifest;
import android.app.Activity;
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
                @Permission(alias = "notifications", strings = {Manifest.permission.POST_NOTIFICATIONS})
        })
public class RipploMeshPlugin extends Plugin implements MeshEngine.Listener {
    private static final String KEY_ALIAS = "ripplo_db_wrap";
    private static final String ACTION_INSTALL = "io.github.nahida4479.ripplo.INSTALL_RESULT";
    private static volatile PluginCall installCall;

    private interface SignalOp {
        JSObject run(SignalCore core) throws Exception;
    }

    private final ExecutorService signalExec = Executors.newSingleThreadExecutor();
    private final ExecutorService storeExec = Executors.newSingleThreadExecutor();
    private final ExecutorService backupExec = Executors.newSingleThreadExecutor();
    private SignalCore signalCore;
    private SignalFileStore signalStore;
    private NativeStore nativeStore;
    private BackupEngine backupEngine;
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

    private SecretKey dbWrapKey() throws Exception {
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
        return (SecretKey) ks.getKey(KEY_ALIAS, null);
    }

    private String wrapDbKey(byte[] key) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, dbWrapKey());
        byte[] iv = c.getIV();
        byte[] ct = c.doFinal(key);
        byte[] blob = new byte[iv.length + ct.length];
        System.arraycopy(iv, 0, blob, 0, iv.length);
        System.arraycopy(ct, 0, blob, iv.length, ct.length);
        return Base64.encodeToString(blob, Base64.NO_WRAP);
    }

    private synchronized byte[] loadDbKey() throws Exception {
        SharedPreferences sp = getContext().getSharedPreferences("ripplo_keys", Context.MODE_PRIVATE);
        String stored = sp.getString("dbkey", null);
        if (stored == null) {
            byte[] key = new byte[32];
            new SecureRandom().nextBytes(key);
            sp.edit().putString("dbkey", wrapDbKey(key)).commit();
            return key;
        }
        byte[] blob = Base64.decode(stored, Base64.NO_WRAP);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, dbWrapKey(), new GCMParameterSpec(128, blob, 0, 12));
        return c.doFinal(blob, 12, blob.length - 12);
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
                if (signalCore == null) signalCore = new SignalCore(sigStore());
                call.resolve(op.run(signalCore));
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

    private synchronized SignalFileStore sigStore() throws Exception {
        if (signalStore == null) signalStore = new SignalFileStore(getContext().getFilesDir(), loadDbKey());
        return signalStore;
    }

    private synchronized NativeStore db() {
        if (nativeStore == null) nativeStore = new NativeStore(getContext(), "ripplo.db");
        return nativeStore;
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
        if (!"auto".equals(call.getString("mode", "pick"))) {
            Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, backupName());
            startActivityForResult(call, i, "createPicked");
            return;
        }
        SharedPreferences sp = backup().prefs();
        String folder = sp.getString("folder", null);
        if (folder == null) { call.reject("no_folder", "no_folder"); return; }
        if (System.currentTimeMillis() - sp.getLong("lastAt", 0) < 24L * 3600 * 1000) {
            JSObject r = new JSObject();
            r.put("skipped", true);
            call.resolve(r);
            return;
        }
        run(backupExec, call, () -> {
            ContentResolver cr = getContext().getContentResolver();
            Uri tree = Uri.parse(folder);
            String treeId = DocumentsContract.getTreeDocumentId(tree);
            String name = backupName();
            Uri doc;
            try {
                doc = DocumentsContract.createDocument(cr, DocumentsContract.buildDocumentUriUsingTree(tree, treeId), "application/octet-stream", name);
            } catch (RuntimeException e) {
                throw new IllegalStateException("folder_unavailable");
            }
            if (doc == null) throw new IllegalStateException("folder_unavailable");
            long size;
            try (OutputStream o = cr.openOutputStream(doc, "wt")) {
                size = writeBackup(o, call);
            } catch (Exception e) {
                try {
                    DocumentsContract.deleteDocument(cr, doc);
                } catch (Exception ignored) {
                }
                throw e;
            }
            rotate(cr, tree, treeId);
            return created(name, size);
        });
    }

    private void rotate(ContentResolver cr, Uri tree, String treeId) {
        List<String[]> found = new ArrayList<>();
        try (Cursor c = cr.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, treeId),
                new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            while (c != null && c.moveToNext()) {
                String n = c.getString(1);
                if (n != null && n.startsWith("Ripplo-backup-") && n.contains(".rbk")) found.add(new String[]{c.getString(0), n});
            }
        } catch (RuntimeException e) {
            return;
        }
        Collections.sort(found, (a, b) -> b[1].compareTo(a[1]));
        for (int i = 3; i < found.size(); i++) {
            try {
                DocumentsContract.deleteDocument(cr, DocumentsContract.buildDocumentUriUsingTree(tree, found.get(i)[0]));
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
        synchronized (this) {
            signalStore = null;
        }
        signalCore = null;
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
