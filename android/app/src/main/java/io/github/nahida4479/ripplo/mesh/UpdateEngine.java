package io.github.nahida4479.ripplo.mesh;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Build;
import com.getcapacitor.PluginCall;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

final class UpdateEngine {
    static final String ACTION_INSTALL = "io.github.nahida4479.ripplo.INSTALL_RESULT";
    static final String PREFS = "ripplo_update";
    static final AtomicBoolean busy = new AtomicBoolean();
    private static final String LATEST = "https://api.github.com/repos/Nahida4479/Ripplo/releases/latest";
    private static final int MAX_FAILS = 3;
    private static final long MAX_APK = 300L * 1024 * 1024;
    private static final Pattern TAG = Pattern.compile("^v(\\d+)\\.(\\d+)\\.(\\d+)");

    interface Progress {
        void on(double fraction);
    }

    static final class Release {
        String tag;
        String apkUrl;
        String sha;
    }

    private UpdateEngine() { }

    static boolean autoEnabled(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("auto", true);
    }

    static boolean canInstall(Context ctx) {
        return Build.VERSION.SDK_INT < 26 || ctx.getPackageManager().canRequestPackageInstalls();
    }

    static String installedVersion(Context ctx) throws Exception {
        return ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0).versionName;
    }

    static boolean newer(String a, String b) {
        int[] x = nums(a), y = nums(b);
        for (int i = 0; i < 3; i++) if (x[i] != y[i]) return x[i] > y[i];
        return false;
    }

    private static int[] nums(String v) {
        Matcher m = TAG.matcher(v.startsWith("v") ? v : "v" + v);
        if (!m.find()) return new int[] {0, 0, 0};
        return new int[] {Integer.parseInt(m.group(1)), Integer.parseInt(m.group(2)), Integer.parseInt(m.group(3))};
    }

    static Release latest() throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(LATEST).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(30000);
        c.setRequestProperty("Accept", "application/vnd.github+json");
        try {
            if (c.getResponseCode() != 200) return null;
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            try (InputStream in = c.getInputStream()) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) {
                    bo.write(buf, 0, n);
                    if (bo.size() > 4 * 1024 * 1024) return null;
                }
            }
            JSONObject j = new JSONObject(bo.toString("UTF-8"));
            Release r = new Release();
            r.tag = j.getString("tag_name");
            if (!TAG.matcher(r.tag).find()) return null;
            String name = "Ripplo-" + r.tag + ".apk";
            JSONArray assets = j.getJSONArray("assets");
            String digest = null;
            for (int i = 0; i < assets.length(); i++) {
                JSONObject a = assets.getJSONObject(i);
                if (name.equals(a.optString("name"))) {
                    r.apkUrl = a.optString("browser_download_url", null);
                    digest = a.optString("digest", null);
                }
            }
            if (digest != null && digest.startsWith("sha256:")) r.sha = digest.substring(7).toLowerCase();
            else r.sha = fromNotes(j.optString("body", ""), name);
            if (r.apkUrl == null || !r.apkUrl.startsWith("https://") || r.sha == null || !r.sha.matches("[0-9a-f]{64}")) return null;
            return r;
        } finally {
            c.disconnect();
        }
    }

    private static String fromNotes(String body, String name) {
        for (String line : body.split("\n")) {
            String[] p = line.trim().split("\\s+");
            if (p.length == 2 && p[1].equals(name) && p[0].matches("[0-9a-fA-F]{64}")) return p[0].toLowerCase();
        }
        return null;
    }

    static void apply(Context ctx, String url, String sha, Progress progress, PluginCall call) throws Exception {
        File apk = new File(ctx.getCacheDir(), "update.apk");
        try {
            download(url, apk, sha, progress);
            verifyCerts(ctx, apk);
            if (call == null && RipploMeshPlugin.foreground) throw new Exception("foreground");
            install(ctx, apk, call);
        } finally {
            apk.delete();
        }
    }

    private static void download(String url, File out, String sha, Progress progress) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(30000);
        c.setInstanceFollowRedirects(true);
        try {
            if (c.getResponseCode() != 200 || !"https".equals(c.getURL().getProtocol())) throw new Exception("download failed");
            long total = c.getContentLengthLong();
            if (total > MAX_APK) throw new Exception("too large");
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
                    if (got > MAX_APK) throw new Exception("too large");
                    if (total > 0 && progress != null) {
                        int pct = (int) (got * 100 / total);
                        if (pct != lastPct) {
                            lastPct = pct;
                            progress.on(pct / 100.0);
                        }
                    }
                }
            }
            if (!SignalCore.hex(md.digest()).equals(sha)) throw new Exception("hash mismatch");
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
        for (Signature s : sigs) out.add(SignalCore.hex(MessageDigest.getInstance("SHA-256").digest(s.toByteArray())));
        return out;
    }

    @SuppressWarnings("deprecation")
    private static void verifyCerts(Context ctx, File apk) throws Exception {
        PackageManager pm = ctx.getPackageManager();
        int flags = Build.VERSION.SDK_INT >= 28 ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES;
        PackageInfo archive = pm.getPackageArchiveInfo(apk.getAbsolutePath(), flags);
        if (archive == null || !ctx.getPackageName().equals(archive.packageName)) throw new Exception("wrong package");
        PackageInfo installed = pm.getPackageInfo(ctx.getPackageName(), flags);
        if (!certs(archive).equals(certs(installed))) throw new Exception("signature mismatch");
    }

    private static void install(Context ctx, File apk, PluginCall call) throws Exception {
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
            if (call != null) RipploMeshPlugin.installCall = call;
            Intent i = new Intent(ctx, InstallReceiver.class).setAction(ACTION_INSTALL);
            int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
            PendingIntent pending = PendingIntent.getBroadcast(ctx, id, i, flags);
            session.commit(pending.getIntentSender());
        } catch (Exception e) {
            if (call != null) RipploMeshPlugin.installCall = null;
            pi.abandonSession(id);
            throw e;
        }
    }

    static void background(Context ctx) {
        if (!autoEnabled(ctx) || RipploMeshPlugin.foreground || RipploMeshPlugin.installCall != null || !busy.compareAndSet(false, true)) return;
        SharedPreferences sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String tag = null;
        try {
            Release r = latest();
            if (r == null || !newer(r.tag, installedVersion(ctx)) || r.tag.equals(sp.getString("attempted", ""))) return;
            tag = r.tag;
            if (tag.equals(sp.getString("failTag", "")) && sp.getInt("fails", 0) >= MAX_FAILS) return;
            if (!canInstall(ctx)) {
                if (!r.tag.equals(sp.getString("notified", ""))) {
                    sp.edit().putString("notified", r.tag).apply();
                    Notifier.updateAvailable(ctx, r.tag);
                }
                return;
            }
            apply(ctx, r.apkUrl, r.sha, null, null);
            sp.edit().putString("attempted", tag).apply();
        } catch (Exception e) {
            if (tag != null && !"foreground".equals(e.getMessage())) {
                int fails = tag.equals(sp.getString("failTag", "")) ? sp.getInt("fails", 0) + 1 : 1;
                sp.edit().putString("failTag", tag).putInt("fails", fails).apply();
            }
        } finally {
            busy.set(false);
        }
    }
}
