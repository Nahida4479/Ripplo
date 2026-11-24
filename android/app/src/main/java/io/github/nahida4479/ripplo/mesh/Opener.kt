package io.github.nahida4479.ripplo.mesh

import android.content.Context
import android.util.Base64
import io.github.nahida4479.ripplo.R
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.regex.Pattern
import org.json.JSONObject

internal object Opener {
    private const val STALE_MS = 120000L
    private const val INVITE_GAP_MS = 24L * 3600 * 1000
    private const val MAX_BODY = 200
    private const val MAX_TEXT = 1000
    private val WIRE_ID: Pattern = Pattern.compile("^[A-Za-z0-9_-]{1,64}$")
    private val INVITED = HashMap<String, Long>()
    private val RNG = SecureRandom()
    private val NONE = arrayOf<String?>(null, null)
    private var ringingCall: String? = null
    private var ringingPeer: String? = null
    private var ringingName: String? = null
    private var ringingToken: String? = null
    private var ringingAt = 0L

    class Result(val sealed: ByteArray, val callId: String?)

    @Synchronized
    fun forgetRinging() {
        ringingCall = null
        ringingPeer = null
        ringingName = null
        ringingToken = null
        ringingAt = 0
    }

    @Synchronized
    fun peek(token: String?): Boolean =
        !token.isNullOrEmpty() && token == ringingToken &&
            System.currentTimeMillis() - ringingAt <= Notifier.RING_MS + 5000

    @Synchronized
    fun redeem(token: String?): String? {
        if (token.isNullOrEmpty() || token != ringingToken) return null
        if (System.currentTimeMillis() - ringingAt > Notifier.RING_MS + 5000) return null
        ringingToken = null
        return ringingCall
    }

    fun process(ctx: Context, payload: ByteArray): Result? {
        val (key, o) = try {
            Shared.dbKey(ctx) to Shared.signal(ctx).open(payload)
        } catch (e: Exception) {
            return null
        }
        var notified = false
        var callId: String? = null
        try {
            val msg = JSONObject(String(o.plaintext, StandardCharsets.UTF_8))
            val r = announce(ctx, key, o, msg)
            notified = r[0] != null
            callId = r[1]
        } catch (ignored: Exception) {
        }
        return try {
            val rec = JSONObject()
                .put("tag", SignalCore.hex(o.tag))
                .put("ik", Base64.encodeToString(o.ik, Base64.NO_WRAP))
                .put("plaintext", Base64.encodeToString(o.plaintext, Base64.NO_WRAP))
                .put("notified", notified)
            Result(Shared.seal(key, rec.toString().toByteArray(StandardCharsets.UTF_8), "inbox"), callId)
        } catch (e: Exception) {
            null
        }
    }

    private fun cut(s: String): String = Ids.clean(s).take(MAX_BODY)

    private fun decode(s: String, len: Int): ByteArray? =
        try {
            Base64.decode(s, Base64.NO_WRAP).takeIf { it.size == len }
        } catch (e: IllegalArgumentException) {
            null
        }

    private fun memberOf(chat: JSONObject, id: String): Boolean {
        val members = chat.optJSONArray("members") ?: return false
        return (0 until members.length()).any { id == members.optString(it) }
    }

    private fun announce(ctx: Context, key: ByteArray, o: SignalCore.Opened, msg: JSONObject): Array<String?> {
        val id = Ids.ripploId(o.tag)
        val contact = Shared.row(ctx, key, "contacts", id)
        val settings = Shared.row(ctx, key, "kv", "settings")
        val hidden = settings != null && settings.optBoolean("hidden")
        val appLock = settings != null && settings.optBoolean("appLock")
        val pending = contact != null && contact.optString("request") == "in"
        var name = if (contact != null) Ids.clean(contact.optString("name")) else ""
        if (name.isEmpty()) {
            val card = try {
                Ids.cardName(Base64.decode(msg.optString("c"), Base64.NO_WRAP), o.tag)
            } catch (e: IllegalArgumentException) {
                null
            }
            name = card ?: "Ripplo ${id.substring(0, 4)}"
        }
        val app = ctx.getString(R.string.app_name)
        val type = msg.optString("t")
        if (type == "msg" || type == "att") {
            if (pending || !WIRE_ID.matcher(msg.optString("id")).matches()) return NONE
            val stranger = contact != null && contact.optString("addedVia") == "incoming" && contact.optLong("cardSent") == 0L
            var body = if (type == "msg") {
                val text: String? = msg.optString("text", null)
                if (text == null || text.length > MAX_TEXT) return NONE
                cut(text)
            } else {
                if (contact == null || stranger) return NONE
                var caption = msg.optString("text", "")
                if (caption.length > MAX_TEXT) caption = ""
                ctx.getString(if (msg.optString("kind") == "image") R.string.notif_photo else R.string.notif_attachment) +
                    (if (caption.isEmpty()) "" else ": " + cut(caption))
            }
            var chatId = id
            var title = name
            val g = msg.optString("g", "")
            if (g.isNotEmpty()) {
                val chat = Shared.row(ctx, key, "chats", g)
                if (chat == null || chat.optString("type") != "group" || !memberOf(chat, id)) return NONE
                chatId = g
                title = Ids.clean(chat.optString("name")) + ": " + name
            }
            if (appLock) {
                title = app
                body = ctx.getString(R.string.new_message)
            }
            Notifier.message(ctx, chatId, title, body)
            return arrayOf("1", null)
        }
        if (type == "invite") {
            if ((hidden && contact == null) || (contact != null && !pending) || (contact != null && contact.optBoolean("notified"))) return NONE
            val now = System.currentTimeMillis()
            synchronized(INVITED) {
                val last = INVITED[id]
                if (last != null && now - last < INVITE_GAP_MS) return NONE
                INVITED[id] = now
            }
            if (appLock) Notifier.message(ctx, id, app, ctx.getString(R.string.new_message))
            else Notifier.invite(ctx, id, name)
            return arrayOf("1", null)
        }
        if (type == "call") return call(ctx, id, if (appLock) app else name, contact, msg)
        return NONE
    }

    private fun call(ctx: Context, id: String, shown: String, contact: JSONObject?, msg: JSONObject): Array<String?> {
        val k = msg.optString("k")
        val callId = msg.optString("id", "")
        if (decode(callId, 8) == null) return NONE
        if (k == "offer") {
            val consented = contact != null && contact.optString("request") != "in" &&
                (contact.optString("addedVia") != "incoming" || contact.optLong("cardSent") > 0)
            val ts = msg.optLong("ts", 0)
            val fresh = ts == 0L || System.currentTimeMillis() - ts <= STALE_MS
            if (!consented || !fresh || decode(msg.optString("key"), 32) == null) return NONE
            val raw = ByteArray(16)
            RNG.nextBytes(raw)
            val token = SignalCore.hex(raw)
            synchronized(this) {
                val now = System.currentTimeMillis()
                if (ringingCall != null && now - ringingAt <= Notifier.RING_MS) return NONE
                ringingCall = callId
                ringingPeer = id
                ringingName = shown
                ringingToken = token
                ringingAt = now
            }
            if (!Notifier.incomingCall(ctx, shown, callId, id, token)) {
                forgetRinging()
                return NONE
            }
            Ringer.startFor(ctx, Notifier.RING_MS)
            return arrayOf("1", callId)
        }
        if (k == "end") {
            val peerName = synchronized(this) {
                if (callId == ringingCall && id == ringingPeer) ringingName.also { forgetRinging() } else null
            }
            if (peerName != null) {
                Ringer.stop()
                Notifier.cancelCall(ctx)
                Notifier.missedCall(ctx, peerName, id)
                return arrayOf("1", callId)
            }
        }
        return NONE
    }
}
