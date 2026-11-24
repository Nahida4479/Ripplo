package io.github.nahida4479.ripplo.mesh

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.bluetooth.BluetoothManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.Settings
import android.util.Base64
import android.view.WindowManager
import androidx.activity.result.ActivityResult
import androidx.core.app.NotificationManagerCompat
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.ActivityCallback
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FilterOutputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService
import org.json.JSONException
import org.json.JSONObject

@CapacitorPlugin(
    name = "RipploMesh",
    permissions = [
        Permission(
            alias = "bluetooth",
            strings = [
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            ],
        ),
        Permission(
            alias = "bluetoothLegacy",
            strings = [
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
                Manifest.permission.ACCESS_FINE_LOCATION,
            ],
        ),
        Permission(alias = "wifi", strings = [Manifest.permission.NEARBY_WIFI_DEVICES]),
        Permission(alias = "wifiLegacy", strings = [Manifest.permission.ACCESS_FINE_LOCATION]),
        Permission(alias = "notifications", strings = [Manifest.permission.POST_NOTIFICATIONS]),
        Permission(alias = "microphone", strings = [Manifest.permission.RECORD_AUDIO]),
    ],
)
class RipploMeshPlugin : Plugin(), MeshEngine.Listener {
    @Volatile
    private var pendingShare: JSObject? = null

    @Volatile
    private var pendingOpen: JSObject? = null
    private val shareExec = Executors.newSingleThreadExecutor()
    private val drainExec = Executors.newSingleThreadExecutor()

    private fun interface SignalOp {
        fun run(core: SignalCore): JSObject
    }

    private val signalExec = Executors.newSingleThreadExecutor()
    private val storeExec = Executors.newSingleThreadExecutor()
    private val backupExec = Executors.newSingleThreadExecutor()
    private var backupEngine: BackupEngine? = null
    private lateinit var engine: MeshEngine
    private var drained = false

    override fun load() {
        engine = MeshEngine.get(context)
        engine.setListener(this)
        Diag.sink = Diag.StageSink { medium, node, stage, detail ->
            val act = activity ?: return@StageSink
            val o = JSObject()
            o.put("medium", medium)
            o.put("node", node)
            o.put("stage", stage)
            o.put("detail", detail)
            o.put("at", System.currentTimeMillis())
            act.runOnUiThread { notifyListeners("devStage", o) }
        }
        readShare(activity?.intent)
        readOpen(activity?.intent)
    }

    override fun handleOnNewIntent(intent: Intent?) {
        super.handleOnNewIntent(intent)
        readShare(intent)
        readOpen(intent)
    }

    private fun readOpen(intent: Intent?) {
        if (intent == null) return
        val chat = intent.getStringExtra(Notifier.EXTRA_CHAT)
        val token = intent.getStringExtra(Notifier.EXTRA_ANSWER)
        intent.removeExtra(Notifier.EXTRA_CHAT)
        intent.removeExtra(Notifier.EXTRA_ANSWER)
        if (chat == null || !CHAT_ID.matches(chat)) return
        val o = JSObject()
        o.put("chatId", chat)
        val callId = Opener.redeem(token)
        if (callId != null) o.put("answer", callId)
        pendingOpen = o
        notifyListeners("open", JSObject())
    }

    @PluginMethod
    fun takeOpen(call: PluginCall) {
        val s = pendingOpen
        pendingOpen = null
        val r = JSObject()
        if (s != null) r.put("open", s)
        call.resolve(r)
    }

    private fun openedJson(item: Inbox.Item, key: ByteArray): JSObject? =
        try {
            JSObject(String(Shared.open(key, item.packet, "inbox"), Charsets.UTF_8))
        } catch (e: Exception) {
            null
        }

    private fun readShare(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_SEND) return
        val type = intent.type
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        @Suppress("DEPRECATION")
        val stream: Uri? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
        intent.action = Intent.ACTION_MAIN
        shareExec.execute {
            try {
                val o = JSObject()
                if (stream != null) {
                    val authority = stream.authority
                    if (stream.scheme != "content" || authority == null || authority.startsWith(context.packageName)) return@execute
                    val mime = context.contentResolver.getType(stream) ?: type
                    if (mime == null || !(mime.startsWith("image/") || mime.startsWith("video/") || mime.startsWith("audio/"))) return@execute
                    val dir = File(context.cacheDir, "share")
                    dir.listFiles()?.forEach { it.delete() }
                    dir.mkdirs()
                    val out = File(dir, "s" + System.nanoTime())
                    var total = 0L
                    context.contentResolver.openInputStream(stream).use { input ->
                        FileOutputStream(out).use { os ->
                            if (input == null) return@execute
                            val buf = ByteArray(65536)
                            while (true) {
                                val n = input.read(buf)
                                if (n <= 0) break
                                total += n
                                if (total > 20L * 1024 * 1024) {
                                    out.delete()
                                    return@execute
                                }
                                os.write(buf, 0, n)
                            }
                        }
                    }
                    o.put("kind", if (mime.startsWith("image/")) "image" else if (mime.startsWith("video/")) "video" else "voice")
                    o.put("mime", mime)
                    o.put("path", out.absolutePath)
                } else if (text != null && text.trim { it <= ' ' }.isNotEmpty()) {
                    o.put("kind", "text")
                    o.put("text", text)
                } else {
                    return@execute
                }
                pendingShare = o
                notifyListeners("share", JSObject())
            } catch (ignored: Exception) {
            }
        }
    }

    @PluginMethod
    fun takeShare(call: PluginCall) {
        val s = pendingShare
        pendingShare = null
        val r = JSObject()
        if (s != null) r.put("share", s)
        call.resolve(r)
    }

    override fun handleOnPause() {
        foreground = false
        engine.setJsAttached(false)
    }

    override fun handleOnResume() {
        foreground = true
        Notifier.cancelUpdated(context)
        Ringer.stop()
        Notifier.cancelCall(context)
        Opener.forgetRinging()
        if (!drained) return
        engine.setJsAttached(true)
        drainExec.execute { deliverInbox() }
        lateDrain()
    }

    private fun lateDrain() {
        Handler(Looper.getMainLooper()).postDelayed({ drainExec.execute { deliverInbox() } }, 1500)
    }

    private fun keyOrNull(): ByteArray? =
        try {
            Shared.dbKey(context)
        } catch (e: Exception) {
            null
        }

    private fun deliverInbox() {
        val items = engine.drainInbox()
        if (items.isEmpty()) return
        val key = keyOrNull()
        for (item in items) {
            when {
                !item.opened() -> onPacket(item.packet, item.from)
                key == null -> engine.requeue(item)
                else -> openedJson(item, key)?.let { notifyListeners("opened", it) }
            }
        }
    }

    @PluginMethod
    fun isLocked(call: PluginCall) {
        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager?
        val r = JSObject()
        r.put("locked", km != null && km.isKeyguardLocked)
        call.resolve(r)
    }

    @PluginMethod
    fun keepAwake(call: PluginCall) {
        val on = call.getBoolean("on", false)
        val a = activity
        a?.runOnUiThread {
            if (on) a.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else a.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        call.resolve()
    }

    @PluginMethod
    fun endLockedCall(call: PluginCall) {
        val a = activity
        a?.runOnUiThread {
            if (Build.VERSION.SDK_INT >= 27) a.setShowWhenLocked(false)
            a.finishAndRemoveTask()
        }
        call.resolve()
    }

    @PluginMethod
    fun requestFullScreen(call: PluginCall) {
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:" + context.packageName)))
            } catch (ignored: RuntimeException) {
            }
        }
        call.resolve()
    }

    @PluginMethod
    fun startRing(call: PluginCall) {
        Ringer.start(context)
        call.resolve()
    }

    @PluginMethod
    fun stopRing(call: PluginCall) {
        Ringer.stop()
        call.resolve()
    }

    override fun handleOnDestroy() {
        Ringer.stop()
        engine.setJsAttached(false)
        engine.setListener(null)
        if (!engine.background()) engine.stop()
    }

    override fun onPacket(packet: ByteArray, from: String) {
        val o = JSObject()
        o.put("packet", enc(packet))
        o.put("from", from)
        notifyListeners("packet", o)
    }

    override fun onNeighbor(node: String, up: Boolean, medium: String, kbps: Long) {
        val o = JSObject()
        o.put("node", node)
        o.put("up", up)
        o.put("medium", medium)
        o.put("kbps", kbps)
        notifyListeners("neighbor", o)
    }

    @PluginMethod
    fun start(call: PluginCall) {
        try {
            val self = b64(call.getString("selfTag", ""))
            if (self.size != 16) {
                call.reject("bad selfTag")
                return
            }
            engine.start(self, call.getBoolean("background", true), true)
            val r = JSObject()
            r.put("nodeTag", engine.nodeTag())
            call.resolve(r)
        } catch (e: RuntimeException) {
            call.reject("start failed")
        }
    }

    @PluginMethod
    fun stop(call: PluginCall) {
        engine.stop()
        call.resolve()
    }

    @PluginMethod
    fun send(call: PluginCall) {
        try {
            val n = engine.sendFromJs(b64(call.getString("packet", "")))
            val r = JSObject()
            r.put("neighbors", n)
            call.resolve(r)
        } catch (e: RuntimeException) {
            call.reject("send failed")
        }
    }

    @PluginMethod
    fun sendApp(call: PluginCall) {
        try {
            val node = call.getString("node", "")
            if (!engine.sendApp(node, b64(call.getString("payload", "")))) {
                call.reject("no link")
                return
            }
            call.resolve()
        } catch (e: RuntimeException) {
            call.reject("send failed")
        }
    }

    @PluginMethod
    fun devConnect(call: PluginCall) {
        val node = call.getString("node", "")
        val spec = call.getString("spec", "")
        val r = JSObject()
        r.put("started", node.isNotEmpty() && spec.isNotEmpty() && engine.forceConnect(node, spec))
        call.resolve(r)
    }

    @PluginMethod
    fun devDisconnect(call: PluginCall) {
        val node = call.getString("node", "")
        val medium = call.getString("medium", "")
        if (node.isNotEmpty() && medium.isNotEmpty()) engine.closeLinks(node, medium)
        call.resolve()
    }

    @PluginMethod
    fun getDeviceInfo(call: PluginCall) {
        val c = context
        val pm = c.packageManager
        val text = buildString {
            append("device ").append(Build.MANUFACTURER).append(' ').append(Build.BRAND).append(' ').append(Build.MODEL)
                .append(" (").append(Build.DEVICE).append(")\n")
            append("android ").append(Build.VERSION.RELEASE).append(" sdk ").append(Build.VERSION.SDK_INT)
            append(" patch ").append(Build.VERSION.SECURITY_PATCH)
            append('\n')
            try {
                val bm = c.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
                val a = bm?.adapter
                append("ble ").append(pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE))
                    .append(" bt-on ").append(a != null && a.isEnabled)
                if (a != null && Build.VERSION.SDK_INT >= 26) {
                    append(" coded ").append(a.isLeCodedPhySupported).append(" ext-adv ").append(a.isLeExtendedAdvertisingSupported)
                        .append(" 2m ").append(a.isLe2MPhySupported).append(" periodic ").append(a.isLePeriodicAdvertisingSupported)
                }
                append(" l2cap ").append(Build.VERSION.SDK_INT >= 29).append('\n')
            } catch (e: RuntimeException) {
                append("ble info error ").append(e).append('\n')
            }
            append("wifi-aware ").append(pm.hasSystemFeature("android.hardware.wifi.aware"))
                .append(" wifi-direct ").append(pm.hasSystemFeature("android.hardware.wifi.direct"))
                .append(" wifi ").append(pm.hasSystemFeature("android.hardware.wifi")).append('\n')
            try {
                val pw = c.getSystemService(Context.POWER_SERVICE) as PowerManager
                append("battery-optimization-ignored ").append(pw.isIgnoringBatteryOptimizations(c.packageName))
                    .append(" power-save ").append(pw.isPowerSaveMode)
                    .append(" idle ").append(pw.isDeviceIdleMode)
                if (Build.VERSION.SDK_INT >= 28) {
                    val am = c.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    append(" bg-restricted ").append(am.isBackgroundRestricted)
                    val us = c.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager?
                    if (us != null) append(" standby-bucket ").append(us.appStandbyBucket)
                }
                append('\n')
            } catch (e: RuntimeException) {
                append("power info error ").append(e).append('\n')
            }
        }
        val r = JSObject()
        r.put("text", text)
        call.resolve(r)
    }

    @PluginMethod
    fun getBleCaps(call: PluginCall) {
        var coded = false
        var ext = false
        try {
            val bm = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
            val a = bm?.adapter
            if (a != null && Build.VERSION.SDK_INT >= 26) {
                coded = a.isLeCodedPhySupported
                ext = a.isLeExtendedAdvertisingSupported
            }
        } catch (ignored: RuntimeException) {
        }
        val r = JSObject()
        r.put("coded", coded)
        r.put("extended", ext)
        call.resolve(r)
    }

    @PluginMethod
    fun getDiag(call: PluginCall) {
        val r = JSObject()
        r.put("log", Diag.dump())
        call.resolve(r)
    }

    @PluginMethod
    fun clearDiag(call: PluginCall) {
        Diag.clear()
        call.resolve()
    }

    @PluginMethod
    fun getTransports(call: PluginCall) {
        try {
            val r = JSObject()
            r.put("transports", JSArray(engine.transportsJson().toString()))
            call.resolve(r)
        } catch (e: JSONException) {
            call.reject("failed")
        }
    }

    @PluginMethod
    fun getNeighbors(call: PluginCall) {
        try {
            val r = JSObject()
            r.put("neighbors", JSArray(engine.neighborsJson().toString()))
            call.resolve(r)
        } catch (e: JSONException) {
            call.reject("failed")
        }
    }

    @PluginMethod
    fun drainInbox(call: PluginCall) {
        drained = true
        engine.setJsAttached(true)
        val arr = JSArray()
        val key = keyOrNull()
        for (item in engine.drainInbox()) {
            val o = JSObject()
            if (item.opened()) {
                if (key == null) {
                    engine.requeue(item)
                    continue
                }
                val rec = openedJson(item, key) ?: continue
                o.put("opened", rec)
            } else {
                o.put("packet", enc(item.packet))
                o.put("from", item.from)
            }
            arr.put(o)
        }
        val r = JSObject()
        r.put("packets", arr)
        call.resolve(r)
        lateDrain()
    }

    @PluginMethod
    fun getDbKey(call: PluginCall) {
        try {
            val r = JSObject()
            r.put("key", enc(Shared.dbKey(context)))
            call.resolve(r)
        } catch (e: Exception) {
            call.reject("key unavailable")
        }
    }

    @PluginMethod
    fun selfHash(call: PluginCall) {
        try {
            FileInputStream(context.applicationInfo.sourceDir).use { input ->
                val md = MessageDigest.getInstance("SHA-256")
                val buf = ByteArray(65536)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    md.update(buf, 0, n)
                }
                val r = JSObject()
                r.put("sha256", Packet.hex(md.digest()))
                call.resolve(r)
            }
        } catch (e: Exception) {
            call.reject("hash failed")
        }
    }

    private fun signal(call: PluginCall, op: SignalOp) {
        signalExec.execute {
            try {
                call.resolve(op.run(Shared.signal(context)))
            } catch (e: Exception) {
                val code = when (val m = e.message) {
                    SignalCore.BAD_BUNDLE, SignalCore.NO_SESSION, SignalCore.UNTRUSTED -> m
                    else -> SignalCore.BAD_MESSAGE
                }
                if (e is SignalCore.Failed) {
                    val d = JSObject()
                    d.put("tag", SignalCore.hex(e.tag))
                    call.reject(code, code, null, d)
                } else {
                    call.reject(code, code)
                }
            }
        }
    }

    @PluginMethod
    fun signalInit(call: PluginCall) {
        signal(call) { c ->
            val r = JSObject()
            r.put("bundle", enc(c.init()))
            r.put("ik", enc(c.identityKey()))
            r
        }
    }

    @PluginMethod
    fun signalAddContact(call: PluginCall) {
        signal(call) { c ->
            val r = JSObject()
            r.put("tag", SignalCore.hex(c.addContact(arg(call, "bundle"))))
            r
        }
    }

    @PluginMethod
    fun signalSeal(call: PluginCall) {
        signal(call) { c ->
            val r = JSObject()
            r.put("payload", enc(c.seal(SignalCore.unhex(call.getString("tag")), arg(call, "plaintext"))))
            r
        }
    }

    @PluginMethod
    fun signalOpen(call: PluginCall) {
        signal(call) { c ->
            val o = c.open(arg(call, "payload"))
            val r = JSObject()
            r.put("tag", SignalCore.hex(o.tag))
            r.put("ik", enc(o.ik))
            r.put("plaintext", enc(o.plaintext))
            r
        }
    }

    @PluginMethod
    fun signalProof(call: PluginCall) {
        signal(call) { c ->
            val r = JSObject()
            r.put("mac", enc(c.proof(arg(call, "ik"), arg(call, "n"), arg(call, "challengerTag"), arg(call, "proverTag"))))
            r
        }
    }

    @PluginMethod
    fun signalSafetyNumber(call: PluginCall) {
        signal(call) { c ->
            val r = JSObject()
            r.put("digits", c.safetyNumber(arg(call, "ik")))
            r
        }
    }

    @PluginMethod
    fun signalForget(call: PluginCall) {
        signal(call) { c ->
            c.forget(SignalCore.unhex(call.getString("tag")))
            JSObject()
        }
    }

    private fun db(): NativeStore = Shared.db(context)

    @Synchronized
    private fun backup(): BackupEngine = backupEngine ?: BackupEngine(context).also { backupEngine = it }

    private fun run(ex: ExecutorService, call: PluginCall, op: () -> JSObject?) {
        ex.execute {
            try {
                val r = op()
                if (r == null) call.resolve() else call.resolve(r)
            } catch (e: Exception) {
                val code = if (e is BackupFormat.BackupException) e.code else "failed"
                call.reject(code, code)
            }
        }
    }

    @PluginMethod
    fun dbPut(call: PluginCall) {
        run(storeExec, call) {
            db().put(need(call, "store"), need(call, "key"), call.getString("idx"), Base64.decode(need(call, "value"), Base64.NO_WRAP))
            null
        }
    }

    @PluginMethod
    fun dbPutMany(call: PluginCall) {
        run(storeExec, call) {
            val arr = call.getArray("rows") ?: throw IllegalArgumentException("bad_args")
            val rows = ArrayList<Array<String?>>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                rows.add(arrayOf(o.getString("store"), o.getString("key"), if (o.isNull("idx")) null else o.getString("idx"), o.getString("value")))
            }
            val r = JSObject()
            r.put("count", db().putMany(rows))
            r
        }
    }

    @PluginMethod
    fun dbGet(call: PluginCall) {
        run(storeExec, call) {
            val v = db().get(need(call, "store"), need(call, "key"))
            val r = JSObject()
            r.put("value", v ?: JSONObject.NULL)
            r
        }
    }

    @PluginMethod
    fun dbDel(call: PluginCall) {
        run(storeExec, call) {
            db().del(need(call, "store"), need(call, "key"))
            null
        }
    }

    @PluginMethod
    fun dbKeys(call: PluginCall) {
        run(storeExec, call) {
            val keys = JSArray()
            for (k in db().keys(need(call, "store"), call.getString("prefix"))) keys.put(k)
            val r = JSObject()
            r.put("keys", keys)
            r
        }
    }

    @PluginMethod
    fun dbAll(call: PluginCall) {
        run(storeExec, call) { rowsResult(db().all(need(call, "store"))) }
    }

    @PluginMethod
    fun dbByIdx(call: PluginCall) {
        run(storeExec, call) { rowsResult(db().byIdx(need(call, "store"), need(call, "idx"))) }
    }

    @PluginMethod
    fun dbCount(call: PluginCall) {
        run(storeExec, call) {
            val r = JSObject()
            r.put("count", db().count())
            r
        }
    }

    @PluginMethod
    fun authAvailable(call: PluginCall) {
        val r = JSObject()
        r.put("biometric", AppLock.biometric(context))
        r.put("deviceCredential", AppLock.deviceCredential(context))
        call.resolve(r)
    }

    private fun authenticateThen(reason: String, next: AppLock.Result) {
        val a = activity
        a.runOnUiThread { AppLock.authenticate(a, reason, next) }
    }

    @PluginMethod
    fun authenticate(call: PluginCall) {
        authenticateThen(call.getString("reason", "Ripplo")) { ok ->
            val r = JSObject()
            r.put("ok", ok)
            call.resolve(r)
        }
    }

    @PluginMethod
    fun setSecure(call: PluginCall) {
        val on = call.getBoolean("on", false) == true
        activity.runOnUiThread {
            if (on) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            call.resolve()
        }
    }

    @PluginMethod
    fun backupStatus(call: PluginCall) {
        val sp = backup().prefs()
        val r = JSObject()
        r.put("enabled", backup().enabled())
        r.put("lastAt", sp.getLong("lastAt", 0L))
        val f = sp.getString("folderName", null)
        r.put("folder", if (sp.getString("folder", null) == null || f == null) JSONObject.NULL else f)
        call.resolve(r)
    }

    @PluginMethod
    fun backupEnable(call: PluginCall) {
        run(backupExec, call) {
            val r = JSObject()
            r.put("code", backup().enable())
            r
        }
    }

    @PluginMethod
    fun backupShowCode(call: PluginCall) {
        authenticateThen("Ripplo") { ok ->
            if (!ok) {
                call.reject("auth_failed", "auth_failed")
                return@authenticateThen
            }
            run(backupExec, call) {
                val s = backup().secrets() ?: throw IllegalStateException("not_enabled")
                val r = JSObject()
                r.put("code", s.code)
                r
            }
        }
    }

    @PluginMethod
    fun backupDisable(call: PluginCall) {
        authenticateThen("Ripplo") { ok ->
            if (!ok) {
                call.reject("auth_failed", "auth_failed")
                return@authenticateThen
            }
            run(backupExec, call) {
                val sp = backup().prefs()
                releaseFolder(sp.getString("folder", null))
                sp.edit().clear().commit()
                null
            }
        }
    }

    private fun releaseFolder(uri: String?) {
        if (uri == null) return
        try {
            context.contentResolver.releasePersistableUriPermission(
                Uri.parse(uri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (ignored: RuntimeException) {
        }
    }

    private fun displayName(doc: Uri): String? {
        try {
            context.contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null).use { c ->
                if (c != null && c.moveToFirst()) return c.getString(0)
            }
        } catch (ignored: RuntimeException) {
        }
        return null
    }

    @PluginMethod
    fun backupChooseFolder(call: PluginCall) {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        startActivityForResult(call, i, "folderPicked")
    }

    @ActivityCallback
    private fun folderPicked(call: PluginCall?, result: ActivityResult) {
        if (call == null) return
        val tree = result.data?.data
        if (result.resultCode != Activity.RESULT_OK || tree == null) {
            call.reject("cancelled", "cancelled")
            return
        }
        try {
            context.contentResolver.takePersistableUriPermission(
                tree,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            val sp = backup().prefs()
            val old = sp.getString("folder", null)
            if (old != null && old != tree.toString()) releaseFolder(old)
            val name = displayName(DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree)))
                ?: tree.lastPathSegment
            sp.edit().putString("folder", tree.toString()).putString("folderName", name).commit()
            val r = JSObject()
            r.put("folder", name)
            call.resolve(r)
        } catch (e: RuntimeException) {
            call.reject("failed", "failed")
        }
    }

    private class Counting(o: OutputStream) : FilterOutputStream(o) {
        var n = 0L

        override fun write(b: Int) {
            out.write(b)
            n++
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            out.write(b, off, len)
            n += len
        }
    }

    private fun writeBackup(raw: OutputStream, call: PluginCall): Long {
        val s = backup().secrets() ?: throw IllegalStateException("not_enabled")
        val out = Counting(BufferedOutputStream(raw, 65536))
        backup().write(out, call.getObject("meta", JSObject()).toString(), Shared.dbKey(context), s, Shared.signalStore(context), db())
        backup().prefs().edit().putLong("lastAt", System.currentTimeMillis()).commit()
        return out.n
    }

    private fun created(name: String, size: Long): JSObject {
        val r = JSObject()
        r.put("ok", true)
        r.put("name", name)
        r.put("size", size)
        return r
    }

    @PluginMethod
    fun backupCreate(call: PluginCall) {
        if (!backup().enabled()) {
            call.reject("not_enabled", "not_enabled")
            return
        }
        val mode = call.getString("mode", "pick")
        val sp = backup().prefs()
        val folder = sp.getString("folder", null)
        if (mode == "pick" || (mode == "now" && folder == null)) {
            val i = Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, backupName())
            startActivityForResult(call, i, "createPicked")
            return
        }
        if (folder == null) {
            call.reject("no_folder", "no_folder")
            return
        }
        if (mode == "auto" && System.currentTimeMillis() - sp.getLong("lastAt", 0L) < 24L * 3600 * 1000) {
            val r = JSObject()
            r.put("skipped", true)
            call.resolve(r)
            return
        }
        run(backupExec, call) { writeToFolder(folder, call) }
    }

    private fun writeToFolder(folder: String, call: PluginCall): JSObject {
        val cr = context.contentResolver
        val tree = Uri.parse(folder)
        val treeId = DocumentsContract.getTreeDocumentId(tree)
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, treeId)
        val tmpName = "$BACKUP_FILE.tmp"
        deleteNamed(cr, tree, treeId, tmpName)
        val tmp = try {
            DocumentsContract.createDocument(cr, parent, "application/octet-stream", tmpName)
        } catch (e: RuntimeException) {
            throw IllegalStateException("folder_unavailable")
        }
        if (tmp == null) throw IllegalStateException("folder_unavailable")
        val size = try {
            cr.openOutputStream(tmp, "wt").use { o ->
                if (o == null) throw IllegalStateException("folder_unavailable")
                writeBackup(o, call)
            }
        } catch (e: Exception) {
            try {
                DocumentsContract.deleteDocument(cr, tmp)
            } catch (ignored: Exception) {
            }
            throw e
        }
        deleteNamed(cr, tree, treeId, BACKUP_FILE)
        val done = try {
            DocumentsContract.renameDocument(cr, tmp, BACKUP_FILE)
        } catch (e: RuntimeException) {
            null
        }
        if (done == null) throw IllegalStateException("folder_unavailable")
        return created(BACKUP_FILE, size)
    }

    private fun deleteNamed(cr: ContentResolver, tree: Uri, treeId: String, name: String) {
        val ids = ArrayList<String>()
        try {
            cr.query(
                DocumentsContract.buildChildDocumentsUriUsingTree(tree, treeId),
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            ).use { c ->
                while (c != null && c.moveToNext()) if (name == c.getString(1)) ids.add(c.getString(0))
            }
        } catch (e: RuntimeException) {
            return
        }
        for (id in ids) {
            try {
                DocumentsContract.deleteDocument(cr, DocumentsContract.buildDocumentUriUsingTree(tree, id))
            } catch (ignored: Exception) {
            }
        }
    }

    @ActivityCallback
    private fun createPicked(call: PluginCall?, result: ActivityResult) {
        if (call == null) return
        val uri = result.data?.data
        if (result.resultCode != Activity.RESULT_OK || uri == null) {
            call.reject("cancelled", "cancelled")
            return
        }
        run(backupExec, call) {
            val cr = context.contentResolver
            val size = try {
                cr.openOutputStream(uri, "wt").use { o ->
                    if (o == null) throw IllegalStateException("failed")
                    writeBackup(o, call)
                }
            } catch (e: Exception) {
                try {
                    DocumentsContract.deleteDocument(cr, uri)
                } catch (ignored: Exception) {
                }
                throw e
            }
            created(displayName(uri) ?: backupName(), size)
        }
    }

    @PluginMethod
    fun backupRestore(call: PluginCall) {
        if (call.getString("code") == null) {
            call.reject("bad_code", "bad_code")
            return
        }
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        startActivityForResult(call, i, "restorePicked")
    }

    @ActivityCallback
    private fun restorePicked(call: PluginCall?, result: ActivityResult) {
        if (call == null) return
        val uri = result.data?.data
        if (result.resultCode != Activity.RESULT_OK || uri == null) {
            call.reject("cancelled", "cancelled")
            return
        }
        run(signalExec, call) {
            val be = backup()
            val st = context.contentResolver.openInputStream(uri).use { raw ->
                if (raw == null) throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
                be.stage(BufferedInputStream(raw, 65536), call.getString("code", ""))
            }
            try {
                val meta = try {
                    JSObject(st.meta)
                } catch (e: JSONException) {
                    throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
                }
                applyRestore(st)
                val r = JSObject()
                r.put("meta", meta)
                r
            } finally {
                be.discard(st)
            }
        }
    }

    private fun applyRestore(st: BackupEngine.Staged) {
        val fd = context.filesDir
        val cur = File(fd, "signal")
        val neu = File(fd, "signal.restore")
        val old = File(fd, "signal.old")
        deleteTree(neu)
        deleteTree(old)
        val dbKey = st.dbKey!!
        val ns = SignalFileStore.at(neu, dbKey)
        for ((k, v) in st.signal) ns.put(k, v)
        val sp = context.getSharedPreferences("ripplo_keys", Context.MODE_PRIVATE)
        val oldBlob = sp.getString("dbkey", null)
        var swapped = false
        try {
            if (!sp.edit().putString("dbkey", Shared.wrapDbKey(dbKey)).commit()) throw IllegalStateException("failed")
            if (cur.exists() && !cur.renameTo(old)) throw IllegalStateException("failed")
            if (!neu.renameTo(cur)) throw IllegalStateException("failed")
            swapped = true
            db().replaceAllFrom(st.rows)
        } catch (e: Exception) {
            if (old.exists()) {
                if (swapped) deleteTree(cur)
                old.renameTo(cur)
            } else if (swapped) {
                deleteTree(cur)
            }
            deleteTree(neu)
            val ed = sp.edit()
            if (oldBlob == null) ed.remove("dbkey") else ed.putString("dbkey", oldBlob)
            ed.commit()
            throw e
        }
        deleteTree(old)
        Shared.reset()
    }

    @PluginMethod
    fun requestBatteryExemption(call: PluginCall) {
        val ctx = context
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(ctx.packageName)) {
            call.resolve()
            return
        }
        try {
            activity.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName)))
        } catch (e: RuntimeException) {
            try {
                activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (ignored: RuntimeException) {
            }
        }
        call.resolve()
    }

    private fun granted(perm: String): Boolean = context.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

    private fun state(ok: Boolean, alias: String): String {
        if (ok) return "granted"
        val sp = context.getSharedPreferences("ripplo_perm", Context.MODE_PRIVATE)
        return if (sp.getBoolean(alias, false)) "denied" else "prompt"
    }

    private fun states(): JSObject {
        val bt = if (Build.VERSION.SDK_INT >= 31) {
            granted(Manifest.permission.BLUETOOTH_SCAN) && granted(Manifest.permission.BLUETOOTH_ADVERTISE) &&
                granted(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            granted(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val wifi = if (Build.VERSION.SDK_INT >= 33) {
            granted(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            granted(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val notif = if (Build.VERSION.SDK_INT >= 33) {
            granted(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            NotificationManagerCompat.from(context).areNotificationsEnabled()
        }
        val o = JSObject()
        o.put("bluetooth", state(bt, "bluetooth"))
        o.put("wifi", state(wifi, "wifi"))
        o.put("notifications", state(notif, "notifications"))
        o.put("microphone", state(granted(Manifest.permission.RECORD_AUDIO), "microphone"))
        if (Build.VERSION.SDK_INT >= 34) {
            val nm = context.getSystemService(NotificationManager::class.java)
            o.put("fullscreen", if (nm != null && nm.canUseFullScreenIntent()) "granted" else "prompt")
        }
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        o.put("battery", if (pm.isIgnoringBatteryOptimizations(context.packageName)) "granted" else "prompt")
        return o
    }

    @PluginMethod
    override fun checkPermissions(call: PluginCall) {
        call.resolve(states())
    }

    @PluginMethod
    override fun requestPermissions(call: PluginCall) {
        val s = states()
        val aliases = ArrayList<String>()
        val ed = context.getSharedPreferences("ripplo_perm", Context.MODE_PRIVATE).edit()
        if (s.getString("bluetooth") != "granted") {
            aliases.add(if (Build.VERSION.SDK_INT >= 31) "bluetooth" else "bluetoothLegacy")
            ed.putBoolean("bluetooth", true)
        }
        if (s.getString("wifi") != "granted") {
            aliases.add(if (Build.VERSION.SDK_INT >= 33) "wifi" else "wifiLegacy")
            ed.putBoolean("wifi", true)
        }
        if (Build.VERSION.SDK_INT >= 33 && s.getString("notifications") != "granted") {
            aliases.add("notifications")
            ed.putBoolean("notifications", true)
        }
        if (s.getString("microphone") != "granted") {
            aliases.add("microphone")
            ed.putBoolean("microphone", true)
        }
        ed.apply()
        if (aliases.isEmpty()) {
            call.resolve(s)
            return
        }
        requestPermissionForAliases(aliases.toTypedArray(), call, "permissionsDone")
    }

    @PermissionCallback
    private fun permissionsDone(call: PluginCall) {
        call.resolve(states())
    }

    @PluginMethod
    fun setAutoUpdate(call: PluginCall) {
        val on = call.getBoolean("enabled", true)
        context.getSharedPreferences(UpdateEngine.PREFS, Context.MODE_PRIVATE).edit().putBoolean("auto", on).apply()
        if (on) UpdateJobService.schedule(context) else UpdateJobService.cancel(context)
        call.resolve()
    }

    @PluginMethod
    fun installUpdate(call: PluginCall) {
        val url = call.getString("url", "")
        val sha = call.getString("sha256", "").lowercase(Locale.getDefault())
        if (!url.startsWith("https://") || !sha.matches(Regex("[0-9a-f]{64}"))) {
            call.reject("bad arguments")
            return
        }
        if (!UpdateEngine.canInstall(context)) {
            if (call.getBoolean("prompt", false)) {
                try {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + context.packageName)))
                } catch (ignored: RuntimeException) {
                }
            }
            call.reject("install_permission")
            return
        }
        if (!UpdateEngine.busy.compareAndSet(false, true)) {
            call.reject("busy")
            return
        }
        val t = Thread({
            try {
                UpdateEngine.apply(context, url, sha, { p ->
                    val o = JSObject()
                    o.put("progress", p)
                    notifyListeners("updateProgress", o)
                }, call)
            } catch (e: Exception) {
                call.reject(e.message ?: "update failed")
            } finally {
                UpdateEngine.busy.set(false)
            }
        }, "ripplo-update")
        t.isDaemon = true
        t.start()
    }

    companion object {
        @Volatile
        internal var installCall: PluginCall? = null

        @Volatile
        internal var foreground = false
        private val CHAT_ID = Regex("^[0-9A-HJKMNP-TV-Z]{16}$|^[A-Za-z0-9_-]{6,32}$")
        private const val BACKUP_FILE = "Ripplo-backup.rbk"

        @JvmStatic
        fun callTokenValid(token: String?): Boolean = Opener.peek(token)

        private fun b64(s: String): ByteArray = Base64.decode(s, Base64.DEFAULT)

        private fun enc(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)

        private fun arg(call: PluginCall, name: String): ByteArray {
            val v = call.getString(name) ?: throw IllegalArgumentException("bad_message")
            return b64(v)
        }

        private fun need(call: PluginCall, name: String): String =
            call.getString(name) ?: throw IllegalArgumentException("bad_args")

        private fun rowsResult(rows: List<NativeStore.Row>): JSObject {
            val arr = JSArray()
            for (row in rows) {
                val o = JSObject()
                o.put("key", row.key)
                o.put("value", row.value)
                arr.put(o)
            }
            val r = JSObject()
            r.put("rows", arr)
            return r
        }

        private fun backupName(): String =
            "Ripplo-backup-" + SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(Date()) + ".rbk"

        private fun deleteTree(f: File) {
            f.listFiles()?.forEach { deleteTree(it) }
            f.delete()
        }

        @JvmStatic
        internal fun installResult(ok: Boolean, status: Int, message: String?) {
            val c = installCall
            installCall = null
            if (c == null) return
            if (ok) {
                val r = JSObject()
                r.put("status", "success")
                c.resolve(r)
            } else {
                c.reject("install failed " + status + (if (message == null) "" else ": $message"))
            }
        }
    }
}
