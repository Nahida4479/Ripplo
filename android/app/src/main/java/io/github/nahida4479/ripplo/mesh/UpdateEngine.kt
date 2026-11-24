package io.github.nahida4479.ripplo.mesh

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.regex.Pattern
import org.json.JSONObject

internal object UpdateEngine {
    const val ACTION_INSTALL = "io.github.nahida4479.ripplo.INSTALL_RESULT"
    const val PREFS = "ripplo_update"
    val busy = AtomicBoolean()
    private const val LATEST = "https://api.github.com/repos/Nahida4479/Ripplo/releases/latest"
    private const val MAX_FAILS = 3
    private const val MAX_APK = 300L * 1024 * 1024
    private val TAG: Pattern = Pattern.compile("^v(\\d+)\\.(\\d+)\\.(\\d+)")
    private val SHA256 = Regex("[0-9a-f]{64}")
    private val SHA256_ANY_CASE = Regex("[0-9a-fA-F]{64}")
    private val WHITESPACE = Regex("\\s+")

    fun interface Progress {
        fun on(fraction: Double)
    }

    class Release(val tag: String, val apkUrl: String, val sha: String)

    fun autoEnabled(ctx: Context): Boolean =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("auto", true)

    fun canInstall(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 26 || ctx.packageManager.canRequestPackageInstalls()

    fun installedVersion(ctx: Context): String? =
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName

    fun newer(a: String, b: String): Boolean {
        val x = nums(a)
        val y = nums(b)
        for (i in 0 until 3) if (x[i] != y[i]) return x[i] > y[i]
        return false
    }

    private fun nums(v: String): IntArray {
        val m = TAG.matcher(if (v.startsWith("v")) v else "v$v")
        if (!m.find()) return intArrayOf(0, 0, 0)
        return intArrayOf(Integer.parseInt(m.group(1)), Integer.parseInt(m.group(2)), Integer.parseInt(m.group(3)))
    }

    fun latest(): Release? {
        val c = URL(LATEST).openConnection() as HttpURLConnection
        c.connectTimeout = 15000
        c.readTimeout = 30000
        c.setRequestProperty("Accept", "application/vnd.github+json")
        try {
            if (c.responseCode != 200) return null
            val bo = ByteArrayOutputStream()
            c.inputStream.use { input ->
                val buf = ByteArray(8192)
                var n: Int
                while (input.read(buf).also { n = it } > 0) {
                    bo.write(buf, 0, n)
                    if (bo.size() > 4 * 1024 * 1024) return null
                }
            }
            val j = JSONObject(bo.toString("UTF-8"))
            val tag = j.getString("tag_name")
            if (!TAG.matcher(tag).find()) return null
            val name = "Ripplo-$tag.apk"
            val assets = j.getJSONArray("assets")
            var apkUrl: String? = null
            var digest: String? = null
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                if (name == a.optString("name")) {
                    apkUrl = a.optString("browser_download_url", null)
                    digest = a.optString("digest", null)
                }
            }
            val sha = if (digest != null && digest.startsWith("sha256:")) {
                digest.substring(7).lowercase(Locale.getDefault())
            } else {
                fromNotes(j.optString("body", ""), name)
            }
            if (apkUrl == null || !apkUrl.startsWith("https://") || sha == null || !sha.matches(SHA256)) return null
            return Release(tag, apkUrl, sha)
        } finally {
            c.disconnect()
        }
    }

    private fun fromNotes(body: String, name: String): String? {
        for (line in body.split("\n")) {
            val p = line.trim { it <= ' ' }.split(WHITESPACE)
            if (p.size == 2 && p[1] == name && p[0].matches(SHA256_ANY_CASE)) return p[0].lowercase(Locale.getDefault())
        }
        return null
    }

    fun apply(ctx: Context, url: String?, sha: String?, progress: Progress?, call: Call?) {
        val apk = File(ctx.cacheDir, "update.apk")
        try {
            download(url, apk, sha, progress)
            verifyCerts(ctx, apk)
            if (call == null && RipploMeshPlugin.foreground) throw Exception("foreground")
            install(ctx, apk, call)
        } finally {
            apk.delete()
        }
    }

    private fun download(url: String?, out: File, sha: String?, progress: Progress?) {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 15000
        c.readTimeout = 30000
        c.instanceFollowRedirects = true
        try {
            if (c.responseCode != 200 || c.url.protocol != "https") throw Exception("download failed")
            val total = c.contentLengthLong
            if (total > MAX_APK) throw Exception("too large")
            val md = MessageDigest.getInstance("SHA-256")
            var got = 0L
            var lastPct = -1
            c.inputStream.use { input ->
                FileOutputStream(out).use { os ->
                    val buf = ByteArray(65536)
                    var n: Int
                    while (input.read(buf).also { n = it } > 0) {
                        md.update(buf, 0, n)
                        os.write(buf, 0, n)
                        got += n
                        if (got > MAX_APK) throw Exception("too large")
                        if (total > 0 && progress != null) {
                            val pct = (got * 100 / total).toInt()
                            if (pct != lastPct) {
                                lastPct = pct
                                progress.on(pct / 100.0)
                            }
                        }
                    }
                }
            }
            if (SignalCore.hex(md.digest()) != sha) throw Exception("hash mismatch")
        } finally {
            c.disconnect()
        }
    }

    @Suppress("DEPRECATION")
    private fun certs(pi: PackageInfo): Set<String> {
        val sigs: Array<Signature>? = if (Build.VERSION.SDK_INT >= 28) {
            (pi.signingInfo ?: throw Exception("no signature")).apkContentsSigners
        } else {
            pi.signatures
        }
        if (sigs == null || sigs.isEmpty()) throw Exception("no signature")
        return sigs.mapTo(HashSet()) { SignalCore.hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }
    }

    @Suppress("DEPRECATION")
    private fun verifyCerts(ctx: Context, apk: File) {
        val pm = ctx.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val archive = pm.getPackageArchiveInfo(apk.absolutePath, flags)
        if (archive == null || ctx.packageName != archive.packageName) throw Exception("wrong package")
        val installed = pm.getPackageInfo(ctx.packageName, flags)
        if (certs(archive) != certs(installed)) throw Exception("signature mismatch")
    }

    private fun install(ctx: Context, apk: File, call: Call?) {
        val pi = ctx.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(ctx.packageName)
        if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        val id = pi.createSession(params)
        try {
            pi.openSession(id).use { session ->
                FileInputStream(apk).use { input ->
                    session.openWrite("base.apk", 0, apk.length()).use { os ->
                        val buf = ByteArray(65536)
                        var n: Int
                        while (input.read(buf).also { n = it } > 0) os.write(buf, 0, n)
                        session.fsync(os)
                    }
                }
                if (call != null) RipploMeshPlugin.installCall = call
                val i = Intent(ctx, InstallReceiver::class.java).setAction(ACTION_INSTALL)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val pending = PendingIntent.getBroadcast(ctx, id, i, flags)
                session.commit(pending.intentSender)
            }
        } catch (e: Exception) {
            if (call != null) RipploMeshPlugin.installCall = null
            pi.abandonSession(id)
            throw e
        }
    }

    fun background(ctx: Context) {
        if (!autoEnabled(ctx) || RipploMeshPlugin.foreground || RipploMeshPlugin.installCall != null || !busy.compareAndSet(false, true)) return
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        var tag: String? = null
        try {
            val r = latest()
            if (r == null || !newer(r.tag, installedVersion(ctx)!!) || r.tag == sp.getString("attempted", "")) return
            tag = r.tag
            if (tag == sp.getString("failTag", "") && sp.getInt("fails", 0) >= MAX_FAILS) return
            if (!canInstall(ctx)) {
                if (r.tag != sp.getString("notified", "")) {
                    sp.edit().putString("notified", r.tag).apply()
                    Notifier.updateAvailable(ctx, r.tag)
                }
                return
            }
            apply(ctx, r.apkUrl, r.sha, null, null)
            sp.edit().putString("attempted", tag).apply()
        } catch (e: Exception) {
            if (tag != null && e.message != "foreground") {
                val fails = if (tag == sp.getString("failTag", "")) sp.getInt("fails", 0) + 1 else 1
                sp.edit().putString("failTag", tag).putInt("fails", fails).apply()
            }
        } finally {
            busy.set(false)
        }
    }
}
