package io.github.nahida4479.ripplo.bridge

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
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.JSONMethodCodec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.nahida4479.ripplo.calls.CallAudio
import io.github.nahida4479.ripplo.calls.Ringer
import io.github.nahida4479.ripplo.crypto.SignalCore
import io.github.nahida4479.ripplo.crypto.SignalFileStore
import io.github.nahida4479.ripplo.data.BackupEngine
import io.github.nahida4479.ripplo.data.BackupFormat
import io.github.nahida4479.ripplo.data.Inbox
import io.github.nahida4479.ripplo.data.NativeStore
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.mesh.Packet
import io.github.nahida4479.ripplo.mesh.Shared
import io.github.nahida4479.ripplo.platform.AppLock
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.platform.Notifier
import io.github.nahida4479.ripplo.platform.Opener
import io.github.nahida4479.ripplo.update.UpdateEngine
import io.github.nahida4479.ripplo.update.UpdateJobService
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

class RipploMeshPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.NewIntentListener,
    MeshEngine.Listener {
    @Volatile
    private var pendingShare: JSONObject? = null

    @Volatile
    private var pendingOpen: JSONObject? = null

    private fun interface SignalOp {
        fun run(core: SignalCore): JSONObject
    }

    private var backupEngine: BackupEngine? = null
    private lateinit var engine: MeshEngine
    private lateinit var context: Context

    @Volatile
    private var drained = false

    @Volatile
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var callAudio: CallAudio? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null
    private val pending = ConcurrentHashMap<Int, Call>()

    private val handlers: Map<String, (Call) -> Unit> = mapOf(
        "start" to ::start,
        "stop" to ::stop,
        "send" to ::send,
        "sendApp" to ::sendApp,
        "getNeighbors" to ::getNeighbors,
        "drainInbox" to ::drainInbox,
        "getDbKey" to ::getDbKey,
        "selfHash" to ::selfHash,
        "installUpdate" to ::installUpdate,
        "setAutoUpdate" to ::setAutoUpdate,
        "requestBatteryExemption" to ::requestBatteryExemption,
        "keepAwake" to ::keepAwake,
        "endLockedCall" to ::endLockedCall,
        "requestFullScreen" to ::requestFullScreen,
        "startRing" to ::startRing,
        "stopRing" to ::stopRing,
        "takeOpen" to ::takeOpen,
        "takeShare" to ::takeShare,
        "isLocked" to ::isLocked,
        "fromPlay" to ::fromPlay,
        "getDeviceInfo" to ::getDeviceInfo,
        "getBleCaps" to ::getBleCaps,
        "getDiag" to ::getDiag,
        "clearDiag" to ::clearDiag,
        "setHello" to ::setHello,
        "usbLog" to ::usbLog,
        "getTransports" to ::getTransports,
        "devConnect" to ::devConnect,
        "devDisconnect" to ::devDisconnect,
        "checkPermissions" to ::checkPermissions,
        "requestPermissions" to ::requestPermissions,
        "dbPut" to ::dbPut,
        "dbPutMany" to ::dbPutMany,
        "dbGet" to ::dbGet,
        "dbDel" to ::dbDel,
        "dbKeys" to ::dbKeys,
        "dbAll" to ::dbAll,
        "dbByIdx" to ::dbByIdx,
        "dbCount" to ::dbCount,
        "authAvailable" to ::authAvailable,
        "authenticate" to ::authenticate,
        "setSecure" to ::setSecure,
        "backupStatus" to ::backupStatus,
        "backupEnable" to ::backupEnable,
        "backupShowCode" to ::backupShowCode,
        "backupDisable" to ::backupDisable,
        "backupChooseFolder" to ::backupChooseFolder,
        "backupCreate" to ::backupCreate,
        "backupRestore" to ::backupRestore,
        "signalInit" to ::signalInit,
        "signalAddContact" to ::signalAddContact,
        "signalSeal" to ::signalSeal,
        "signalOpen" to ::signalOpen,
        "signalProof" to ::signalProof,
        "signalSafetyNumber" to ::signalSafetyNumber,
        "signalForget" to ::signalForget,
        "notify" to ::notifyUser,
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        live = this
        engine = MeshEngine.get(context)
        engine.setListener(this)
        Diag.sink = Diag.StageSink { medium, node, stage, detail ->
            if (activity == null) return@StageSink
            val o = JSONObject()
            o.put("medium", medium)
            o.put("node", node)
            o.put("stage", stage)
            o.put("detail", detail)
            o.put("at", System.currentTimeMillis())
            emit("devStage", o)
        }
        val m = MethodChannel(binding.binaryMessenger, "ripplo/mesh", JSONMethodCodec.INSTANCE)
        m.setMethodCallHandler(this)
        methods = m
        val e = EventChannel(binding.binaryMessenger, "ripplo/mesh/events", JSONMethodCodec.INSTANCE)
        e.setStreamHandler(this)
        events = e
        val ca = CallAudio(context, binding.binaryMessenger)
        ca.attach()
        callAudio = ca
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        methods = null
        events?.setStreamHandler(null)
        events = null
        sink = null
        callAudio?.detach()
        callAudio = null
        if (live !== this) return
        live = null
        Diag.sink = null
        Ringer.stop()
        engine.setJsAttached(false)
        engine.setListener(null)
        if (!engine.background()) engine.stop()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        bind(binding)
        readShare(binding.activity.intent)
        readOpen(binding.activity.intent)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        bind(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        unbind()
    }

    override fun onDetachedFromActivity() {
        unbind()
    }

    private fun bind(b: ActivityPluginBinding) {
        binding = b
        activity = b.activity
        b.addActivityResultListener(this)
        b.addRequestPermissionsResultListener(this)
        b.addOnNewIntentListener(this)
    }

    private fun unbind() {
        val b = binding
        if (b != null) {
            b.removeActivityResultListener(this)
            b.removeRequestPermissionsResultListener(this)
            b.removeOnNewIntentListener(this)
        }
        binding = null
        activity = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (pendingOpen != null) emit("open", JSONObject())
        if (pendingShare != null) emit("share", JSONObject())
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: String, data: JSONObject) {
        Call.post {
            val s = sink
            if (s != null) s.success(JSONObject().put("event", event).put("data", data))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val h = handlers[call.method]
        if (h == null) {
            result.notImplemented()
            return
        }
        val args = when (val a = call.arguments) {
            is JSONObject -> a
            is Map<*, *> -> JSONObject(a)
            else -> JSONObject()
        }
        val c = Call(args, result)
        callExec.execute {
            try {
                h(c)
            } catch (e: Exception) {
                c.reject(e.message ?: "failed")
            }
        }
    }

    override fun onNewIntent(intent: Intent): Boolean {
        readShare(intent)
        readOpen(intent)
        return false
    }

    private fun readOpen(intent: Intent?) {
        if (intent == null) return
        val chat = intent.getStringExtra(Notifier.EXTRA_CHAT)
        val token = intent.getStringExtra(Notifier.EXTRA_ANSWER)
        intent.removeExtra(Notifier.EXTRA_CHAT)
        intent.removeExtra(Notifier.EXTRA_ANSWER)
        if (chat == null || !CHAT_ID.matches(chat)) return
        val o = JSONObject()
        o.put("chatId", chat)
        val callId = Opener.redeem(token)
        if (callId != null) o.put("answer", callId)
        pendingOpen = o
        emit("open", JSONObject())
    }

    private fun takeOpen(call: Call) {
        val s = pendingOpen
        pendingOpen = null
        val r = JSONObject()
        if (s != null) r.put("open", s)
        call.resolve(r)
    }

    private fun openedJson(item: Inbox.Item, key: ByteArray): JSONObject? =
        try {
            JSONObject(String(Shared.open(key, item.packet, "inbox"), Charsets.UTF_8))
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
                val o = JSONObject()
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
                emit("share", JSONObject())
            } catch (ignored: Exception) {
            }
        }
    }

    private fun takeShare(call: Call) {
        val s = pendingShare
        pendingShare = null
        val r = JSONObject()
        if (s != null) r.put("share", s)
        call.resolve(r)
    }

    fun onHostPause() {
        foreground = false
        if (::engine.isInitialized) engine.setJsAttached(false)
    }

    fun onHostResume() {
        foreground = true
        if (!::engine.isInitialized) return
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
                else -> openedJson(item, key)?.let { emit("opened", it) }
            }
        }
    }

    private fun isLocked(call: Call) {
        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager?
        val r = JSONObject()
        r.put("locked", km != null && km.isKeyguardLocked)
        call.resolve(r)
    }

    private fun keepAwake(call: Call) {
        val on = call.getBoolean("on", false)
        val a = activity
        a?.runOnUiThread {
            if (on) a.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else a.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        call.resolve()
    }

    private fun endLockedCall(call: Call) {
        val a = activity
        a?.runOnUiThread {
            if (Build.VERSION.SDK_INT >= 27) a.setShowWhenLocked(false)
            a.finishAndRemoveTask()
        }
        call.resolve()
    }

    private fun requestFullScreen(call: Call) {
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                activity?.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:" + context.packageName)))
            } catch (ignored: RuntimeException) {
            }
        }
        call.resolve()
    }

    private fun startRing(call: Call) {
        Ringer.start(context)
        call.resolve()
    }

    private fun stopRing(call: Call) {
        Ringer.stop()
        call.resolve()
    }

    override fun onPacket(packet: ByteArray, from: String) {
        val o = JSONObject()
        o.put("packet", enc(packet))
        o.put("from", from)
        emit("packet", o)
    }

    override fun onNeighbor(node: String, up: Boolean, medium: String, kbps: Long) {
        val o = JSONObject()
        o.put("node", node)
        o.put("up", up)
        o.put("medium", medium)
        o.put("kbps", kbps)
        emit("neighbor", o)
    }

    private fun start(call: Call) {
        try {
            val self = b64(call.getString("selfTag", ""))
            if (self.size != 16) {
                call.reject("bad selfTag")
                return
            }
            engine.start(self, call.getBoolean("background", true), true)
            val r = JSONObject()
            r.put("nodeTag", engine.nodeTag())
            call.resolve(r)
        } catch (e: RuntimeException) {
            call.reject("start failed")
        }
    }

    private fun stop(call: Call) {
        engine.stop()
        call.resolve()
    }

    private fun send(call: Call) {
        try {
            val n = engine.sendFromJs(b64(call.getString("packet", "")))
            val r = JSONObject()
            r.put("neighbors", n)
            call.resolve(r)
        } catch (e: RuntimeException) {
            call.reject("send failed")
        }
    }

    private fun sendApp(call: Call) {
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

    private fun devConnect(call: Call) {
        val node = call.getString("node", "")
        val spec = call.getString("spec", "")
        val r = JSONObject()
        val err = if (node.isNotEmpty() && spec.isNotEmpty()) engine.forceConnect(node, spec) else "Forced connection needs a node and a medium"
        r.put("started", err == null)
        r.put("error", err ?: "")
        call.resolve(r)
    }

    private fun devDisconnect(call: Call) {
        val node = call.getString("node", "")
        val medium = call.getString("medium", "")
        if (node.isNotEmpty() && medium.isNotEmpty()) engine.closeLinks(node, medium)
        if (node.isNotEmpty()) engine.forceEnd(node)
        call.resolve()
    }

    private fun getDeviceInfo(call: Call) {
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
        val r = JSONObject()
        r.put("text", text)
        call.resolve(r)
    }

    private fun getBleCaps(call: Call) {
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
        val r = JSONObject()
        r.put("coded", coded)
        r.put("extended", ext)
        call.resolve(r)
    }

    private fun getDiag(call: Call) {
        val r = JSONObject()
        r.put("log", Diag.dump())
        call.resolve(r)
    }

    private fun usbAttached(): Boolean {
        val b = context.registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val usb = b != null && (b.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) and android.os.BatteryManager.BATTERY_PLUGGED_USB) != 0
        return usb && Settings.Global.getInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0) == 1
    }

    private fun usbLog(call: Call) {
        val r = JSONObject()
        val ok = usbAttached()
        if (ok) {
            val text = call.getString("text") ?: ""
            for (chunk in text.chunked(3000)) android.util.Log.i("ripplo", chunk)
        }
        r.put("usb", ok)
        call.resolve(r)
    }

    private fun setHello(call: Call) {
        engine.setHello(call.getString("card", ""), call.getBoolean("hidden", false))
        call.resolve()
    }

    private fun clearDiag(call: Call) {
        Diag.clear()
        call.resolve()
    }

    private fun getTransports(call: Call) {
        try {
            val r = JSONObject()
            r.put("transports", JSONArray(engine.transportsJson().toString()))
            call.resolve(r)
        } catch (e: JSONException) {
            call.reject("failed")
        }
    }

    private fun getNeighbors(call: Call) {
        try {
            val r = JSONObject()
            r.put("neighbors", JSONArray(engine.neighborsJson().toString()))
            call.resolve(r)
        } catch (e: JSONException) {
            call.reject("failed")
        }
    }

    private fun drainInbox(call: Call) {
        drained = true
        engine.setJsAttached(true)
        val arr = JSONArray()
        val key = keyOrNull()
        for (item in engine.drainInbox()) {
            val o = JSONObject()
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
        val r = JSONObject()
        r.put("packets", arr)
        call.resolve(r)
        lateDrain()
    }

    private fun getDbKey(call: Call) {
        try {
            val r = JSONObject()
            r.put("key", enc(Shared.dbKey(context)))
            call.resolve(r)
        } catch (e: Exception) {
            call.reject("key unavailable")
        }
    }

    private fun fromPlay(call: Call) {
        val pm = context.packageManager
        val installer = try {
            if (Build.VERSION.SDK_INT >= 30) pm.getInstallSourceInfo(context.packageName).installingPackageName
            else @Suppress("DEPRECATION") pm.getInstallerPackageName(context.packageName)
        } catch (e: Exception) {
            null
        }
        val r = JSONObject()
        r.put("play", installer == "com.android.vending")
        call.resolve(r)
    }

    private fun selfHash(call: Call) {
        try {
            FileInputStream(context.applicationInfo.sourceDir).use { input ->
                val md = MessageDigest.getInstance("SHA-256")
                val buf = ByteArray(65536)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    md.update(buf, 0, n)
                }
                val r = JSONObject()
                r.put("sha256", Packet.hex(md.digest()))
                call.resolve(r)
            }
        } catch (e: Exception) {
            call.reject("hash failed")
        }
    }

    private fun signal(call: Call, op: SignalOp) {
        signalExec.execute {
            try {
                call.resolve(op.run(Shared.signal(context)))
            } catch (e: Exception) {
                val code = when (val m = e.message) {
                    SignalCore.BAD_BUNDLE, SignalCore.NO_SESSION, SignalCore.UNTRUSTED -> m
                    else -> SignalCore.BAD_MESSAGE
                }
                if (e is SignalCore.Failed) {
                    val d = JSONObject()
                    d.put("tag", SignalCore.hex(e.tag))
                    call.reject(code, code, d)
                } else {
                    call.reject(code, code)
                }
            }
        }
    }

    private fun signalInit(call: Call) {
        signal(call) { c ->
            val r = JSONObject()
            r.put("bundle", enc(c.init()))
            r.put("ik", enc(c.identityKey()))
            r
        }
    }

    private fun signalAddContact(call: Call) {
        signal(call) { c ->
            val r = JSONObject()
            r.put("tag", SignalCore.hex(c.addContact(arg(call, "bundle"))))
            r
        }
    }

    private fun signalSeal(call: Call) {
        signal(call) { c ->
            val r = JSONObject()
            r.put("payload", enc(c.seal(SignalCore.unhex(call.getString("tag")), arg(call, "plaintext"))))
            r
        }
    }

    private fun signalOpen(call: Call) {
        signal(call) { c ->
            val o = c.open(arg(call, "payload"))
            val r = JSONObject()
            r.put("tag", SignalCore.hex(o.tag))
            r.put("ik", enc(o.ik))
            r.put("plaintext", enc(o.plaintext))
            r
        }
    }

    private fun signalProof(call: Call) {
        signal(call) { c ->
            val r = JSONObject()
            r.put("mac", enc(c.proof(arg(call, "ik"), arg(call, "n"), arg(call, "challengerTag"), arg(call, "proverTag"))))
            r
        }
    }

    private fun signalSafetyNumber(call: Call) {
        signal(call) { c ->
            val r = JSONObject()
            r.put("digits", c.safetyNumber(arg(call, "ik")))
            r
        }
    }

    private fun signalForget(call: Call) {
        signal(call) { c ->
            c.forget(SignalCore.unhex(call.getString("tag")))
            JSONObject()
        }
    }

    private fun db(): NativeStore = Shared.db(context)

    @Synchronized
    private fun backup(): BackupEngine = backupEngine ?: BackupEngine(context).also { backupEngine = it }

    private fun run(ex: ExecutorService, call: Call, op: () -> JSONObject?) {
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

    private fun dbPut(call: Call) {
        run(storeExec, call) {
            db().put(need(call, "store"), need(call, "key"), call.getString("idx"), Base64.decode(need(call, "value"), Base64.NO_WRAP))
            null
        }
    }

    private fun dbPutMany(call: Call) {
        run(storeExec, call) {
            val arr = call.getArray("rows") ?: throw IllegalArgumentException("bad_args")
            val rows = ArrayList<Array<String?>>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                rows.add(arrayOf(o.getString("store"), o.getString("key"), if (o.isNull("idx")) null else o.getString("idx"), o.getString("value")))
            }
            val r = JSONObject()
            r.put("count", db().putMany(rows))
            r
        }
    }

    private fun dbGet(call: Call) {
        run(storeExec, call) {
            val v = db().get(need(call, "store"), need(call, "key"))
            val r = JSONObject()
            r.put("value", v ?: JSONObject.NULL)
            r
        }
    }

    private fun dbDel(call: Call) {
        run(storeExec, call) {
            db().del(need(call, "store"), need(call, "key"))
            null
        }
    }

    private fun dbKeys(call: Call) {
        run(storeExec, call) {
            val keys = JSONArray()
            for (k in db().keys(need(call, "store"), call.getString("prefix"))) keys.put(k)
            val r = JSONObject()
            r.put("keys", keys)
            r
        }
    }

    private fun dbAll(call: Call) {
        run(storeExec, call) { rowsResult(db().all(need(call, "store"))) }
    }

    private fun dbByIdx(call: Call) {
        run(storeExec, call) { rowsResult(db().byIdx(need(call, "store"), need(call, "idx"))) }
    }

    private fun dbCount(call: Call) {
        run(storeExec, call) {
            val r = JSONObject()
            r.put("count", db().count())
            r
        }
    }

    private fun authAvailable(call: Call) {
        val r = JSONObject()
        r.put("biometric", AppLock.biometric(context))
        r.put("deviceCredential", AppLock.deviceCredential(context))
        call.resolve(r)
    }

    private fun authenticateThen(reason: String, next: AppLock.Result) {
        val a = activity as? FragmentActivity
        if (a == null) {
            next.done(false)
            return
        }
        a.runOnUiThread { AppLock.authenticate(a, reason, next) }
    }

    private fun authenticate(call: Call) {
        authenticateThen(call.getString("reason", "Ripplo")) { ok ->
            val r = JSONObject()
            r.put("ok", ok)
            call.resolve(r)
        }
    }

    private fun setSecure(call: Call) {
        val on = call.getBoolean("on", false)
        val a = activity
        if (a == null) {
            call.reject("failed")
            return
        }
        a.runOnUiThread {
            if (on) a.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            else a.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            call.resolve()
        }
    }

    private fun backupStatus(call: Call) {
        val sp = backup().prefs()
        val r = JSONObject()
        r.put("enabled", backup().enabled())
        r.put("lastAt", sp.getLong("lastAt", 0L))
        val f = sp.getString("folderName", null)
        r.put("folder", if (sp.getString("folder", null) == null || f == null) JSONObject.NULL else f)
        call.resolve(r)
    }

    private fun backupEnable(call: Call) {
        run(backupExec, call) {
            val r = JSONObject()
            r.put("code", backup().enable())
            r
        }
    }

    private fun backupShowCode(call: Call) {
        authenticateThen("Ripplo") { ok ->
            if (!ok) {
                call.reject("auth_failed", "auth_failed")
                return@authenticateThen
            }
            run(backupExec, call) {
                val s = backup().secrets() ?: throw IllegalStateException("not_enabled")
                val r = JSONObject()
                r.put("code", s.code)
                r
            }
        }
    }

    private fun backupDisable(call: Call) {
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

    @Suppress("DEPRECATION")
    private fun launch(call: Call, intent: Intent, code: Int) {
        val a = activity
        if (a == null) {
            call.reject("failed", "failed")
            return
        }
        pending.put(code, call)?.reject("cancelled", "cancelled")
        Call.post {
            try {
                a.startActivityForResult(intent, code)
            } catch (e: RuntimeException) {
                pending.remove(code)?.reject("failed", "failed")
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_FOLDER && requestCode != REQ_CREATE && requestCode != REQ_RESTORE) return false
        val call = pending.remove(requestCode) ?: return false
        when (requestCode) {
            REQ_FOLDER -> folderPicked(call, resultCode, data)
            REQ_CREATE -> createPicked(call, resultCode, data)
            else -> restorePicked(call, resultCode, data)
        }
        return true
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQ_PERMS) return false
        val call = pending.remove(REQ_PERMS) ?: return false
        call.resolve(states())
        return true
    }

    private fun backupChooseFolder(call: Call) {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        launch(call, i, REQ_FOLDER)
    }

    private fun folderPicked(call: Call, resultCode: Int, data: Intent?) {
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
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
            val r = JSONObject()
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

    private fun writeBackup(raw: OutputStream, call: Call): Long {
        val s = backup().secrets() ?: throw IllegalStateException("not_enabled")
        val out = Counting(BufferedOutputStream(raw, 65536))
        backup().write(out, call.getObject("meta", JSONObject()).toString(), Shared.dbKey(context), s, Shared.signalStore(context), db())
        backup().prefs().edit().putLong("lastAt", System.currentTimeMillis()).commit()
        return out.n
    }

    private fun created(name: String, size: Long): JSONObject {
        val r = JSONObject()
        r.put("ok", true)
        r.put("name", name)
        r.put("size", size)
        return r
    }

    private fun backupCreate(call: Call) {
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
            launch(call, i, REQ_CREATE)
            return
        }
        if (folder == null) {
            call.reject("no_folder", "no_folder")
            return
        }
        if (mode == "auto" && System.currentTimeMillis() - sp.getLong("lastAt", 0L) < 24L * 3600 * 1000) {
            val r = JSONObject()
            r.put("skipped", true)
            call.resolve(r)
            return
        }
        run(backupExec, call) { writeToFolder(folder, call) }
    }

    private fun writeToFolder(folder: String, call: Call): JSONObject {
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

    private fun createPicked(call: Call, resultCode: Int, data: Intent?) {
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
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

    private fun backupRestore(call: Call) {
        if (call.getString("code") == null) {
            call.reject("bad_code", "bad_code")
            return
        }
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        launch(call, i, REQ_RESTORE)
    }

    private fun restorePicked(call: Call, resultCode: Int, data: Intent?) {
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
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
                    JSONObject(st.meta)
                } catch (e: JSONException) {
                    throw BackupFormat.BackupException(BackupFormat.BAD_FILE)
                }
                applyRestore(st)
                val r = JSONObject()
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

    private fun requestBatteryExemption(call: Call) {
        val ctx = context
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(ctx.packageName)) {
            call.resolve()
            return
        }
        try {
            activity?.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName)))
        } catch (e: RuntimeException) {
            try {
                activity?.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
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

    private fun states(): JSONObject {
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
        val o = JSONObject()
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

    private fun checkPermissions(call: Call) {
        call.resolve(states())
    }

    private fun permissionStrings(alias: String): Array<String> = when (alias) {
        "bluetooth" -> arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT,
        )
        "bluetoothLegacy" -> arrayOf(
            Manifest.permission.BLUETOOTH,
            Manifest.permission.BLUETOOTH_ADMIN,
            Manifest.permission.ACCESS_FINE_LOCATION,
        )
        "wifi" -> arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        "wifiLegacy" -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        "notifications" -> arrayOf(Manifest.permission.POST_NOTIFICATIONS)
        "microphone" -> arrayOf(Manifest.permission.RECORD_AUDIO)
        else -> emptyArray()
    }

    private fun requestPermissions(call: Call) {
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
        val a = activity
        if (a == null) {
            call.resolve(s)
            return
        }
        val perms = LinkedHashSet<String>()
        for (alias in aliases) perms.addAll(permissionStrings(alias))
        pending.put(REQ_PERMS, call)?.resolve(s)
        Call.post { ActivityCompat.requestPermissions(a, perms.toTypedArray(), REQ_PERMS) }
    }

    private fun setAutoUpdate(call: Call) {
        val on = call.getBoolean("enabled", true)
        context.getSharedPreferences(UpdateEngine.PREFS, Context.MODE_PRIVATE).edit().putBoolean("auto", on).apply()
        if (on) UpdateJobService.schedule(context) else UpdateJobService.cancel(context)
        call.resolve()
    }

    private fun installUpdate(call: Call) {
        val url = call.getString("url", "")
        val sha = call.getString("sha256", "").lowercase(Locale.getDefault())
        if (!url.startsWith("https://") || !sha.matches(Regex("[0-9a-f]{64}"))) {
            call.reject("bad arguments")
            return
        }
        if (!UpdateEngine.canInstall(context)) {
            if (call.getBoolean("prompt", false)) {
                try {
                    activity?.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + context.packageName)))
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
                    val o = JSONObject()
                    o.put("progress", p)
                    emit("updateProgress", o)
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

    private fun notifyUser(call: Call) {
        Notifier.message(context, call.getString("chatId", ""), call.getString("title"), call.getString("body"))
        call.resolve()
    }

    companion object {
        @Volatile
        internal var installCall: Call? = null

        @Volatile
        internal var foreground = false

        @Volatile
        private var live: RipploMeshPlugin? = null
        private val shareExec = Executors.newSingleThreadExecutor()
        private val drainExec = Executors.newSingleThreadExecutor()
        private val callExec = Executors.newSingleThreadExecutor()
        private val signalExec = Executors.newSingleThreadExecutor()
        private val storeExec = Executors.newSingleThreadExecutor()
        private val backupExec = Executors.newSingleThreadExecutor()
        private const val REQ_FOLDER = 7101
        private const val REQ_CREATE = 7102
        private const val REQ_RESTORE = 7103
        private const val REQ_PERMS = 7104
        private val CHAT_ID = Regex("^[0-9A-HJKMNP-TV-Z]{16}$|^[A-Za-z0-9_-]{6,32}$")
        private const val BACKUP_FILE = "Ripplo-backup.rbk"

        @JvmStatic
        fun callTokenValid(token: String?): Boolean = Opener.peek(token)

        private fun b64(s: String): ByteArray = Base64.decode(s, Base64.DEFAULT)

        private fun enc(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)

        private fun arg(call: Call, name: String): ByteArray {
            val v = call.getString(name) ?: throw IllegalArgumentException("bad_message")
            return b64(v)
        }

        private fun need(call: Call, name: String): String =
            call.getString(name) ?: throw IllegalArgumentException("bad_args")

        private fun rowsResult(rows: List<NativeStore.Row>): JSONObject {
            val arr = JSONArray()
            for (row in rows) {
                val o = JSONObject()
                o.put("key", row.key)
                o.put("value", row.value)
                arr.put(o)
            }
            val r = JSONObject()
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
                val r = JSONObject()
                r.put("status", "success")
                c.resolve(r)
            } else {
                c.reject("install failed " + status + (if (message == null) "" else ": $message"))
            }
        }
    }
}
