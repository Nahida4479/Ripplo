package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import android.util.Base64;
import io.github.nahida4479.ripplo.R;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

final class Opener {
    private static final long STALE_MS = 120000L;
    private static final long INVITE_GAP_MS = 24L * 3600 * 1000;
    private static final int MAX_BODY = 200;
    private static final int MAX_TEXT = 1000;
    private static final Pattern WIRE_ID = Pattern.compile("^[A-Za-z0-9_-]{1,64}$");
    private static final Map<String, Long> INVITED = new HashMap<>();
    private static final SecureRandom RNG = new SecureRandom();
    private static String ringingCall;
    private static String ringingPeer;
    private static String ringingName;
    private static String ringingToken;
    private static long ringingAt;

    static final class Result {
        final byte[] sealed;
        final String callId;

        Result(byte[] sealed, String callId) {
            this.sealed = sealed;
            this.callId = callId;
        }
    }

    private Opener() { }

    static synchronized void forgetRinging() {
        ringingCall = null;
        ringingPeer = null;
        ringingName = null;
        ringingToken = null;
        ringingAt = 0;
    }

    static synchronized boolean peek(String token) {
        return token != null && !token.isEmpty() && token.equals(ringingToken)
                && System.currentTimeMillis() - ringingAt <= Notifier.RING_MS + 5000;
    }

    static synchronized String redeem(String token) {
        if (token == null || token.isEmpty() || !token.equals(ringingToken)) return null;
        if (System.currentTimeMillis() - ringingAt > Notifier.RING_MS + 5000) return null;
        ringingToken = null;
        return ringingCall;
    }

    static Result process(Context ctx, byte[] payload) {
        byte[] key;
        SignalCore.Opened o;
        try {
            key = Shared.dbKey(ctx);
            o = Shared.signal(ctx).open(payload);
        } catch (Exception e) {
            return null;
        }
        boolean notified = false;
        String callId = null;
        try {
            JSONObject msg = new JSONObject(new String(o.plaintext, StandardCharsets.UTF_8));
            String[] r = announce(ctx, key, o, msg);
            notified = r[0] != null;
            callId = r[1];
        } catch (Exception ignored) {
        }
        try {
            JSONObject rec = new JSONObject()
                    .put("tag", SignalCore.hex(o.tag))
                    .put("ik", Base64.encodeToString(o.ik, Base64.NO_WRAP))
                    .put("plaintext", Base64.encodeToString(o.plaintext, Base64.NO_WRAP))
                    .put("notified", notified);
            return new Result(Shared.seal(key, rec.toString().getBytes(StandardCharsets.UTF_8), "inbox"), callId);
        } catch (Exception e) {
            return null;
        }
    }

    private static String cut(String s) {
        String c = Ids.clean(s);
        return c.length() > MAX_BODY ? c.substring(0, MAX_BODY) : c;
    }

    private static byte[] decode(String s, int len) {
        try {
            byte[] b = Base64.decode(s, Base64.NO_WRAP);
            return b.length == len ? b : null;
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    private static boolean memberOf(JSONObject chat, String id) {
        JSONArray members = chat.optJSONArray("members");
        if (members == null) return false;
        for (int i = 0; i < members.length(); i++) if (id.equals(members.optString(i))) return true;
        return false;
    }

    private static final String[] NONE = {null, null};

    private static String[] announce(Context ctx, byte[] key, SignalCore.Opened o, JSONObject msg) {
        String id = Ids.ripploId(o.tag);
        JSONObject contact = Shared.row(ctx, key, "contacts", id);
        JSONObject settings = Shared.row(ctx, key, "kv", "settings");
        boolean hidden = settings != null && settings.optBoolean("hidden");
        boolean appLock = settings != null && settings.optBoolean("appLock");
        boolean known = contact != null;
        boolean pending = known && "in".equals(contact.optString("request"));
        String name = known ? Ids.clean(contact.optString("name")) : "";
        if (name.isEmpty()) {
            try {
                name = Ids.cardName(Base64.decode(msg.optString("c"), Base64.NO_WRAP), o.tag);
            } catch (IllegalArgumentException e) {
                name = null;
            }
            if (name == null) name = "Ripplo " + id.substring(0, 4);
        }
        String app = ctx.getString(R.string.app_name);
        String type = msg.optString("t");
        if ("msg".equals(type) || "att".equals(type)) {
            if (pending || !WIRE_ID.matcher(msg.optString("id")).matches()) return NONE;
            boolean stranger = known && "incoming".equals(contact.optString("addedVia")) && contact.optLong("cardSent") == 0;
            String body;
            if ("msg".equals(type)) {
                String text = msg.optString("text", null);
                if (text == null || text.length() > MAX_TEXT) return NONE;
                body = cut(text);
            } else {
                if (!known || stranger) return NONE;
                String caption = msg.optString("text", "");
                if (caption.length() > MAX_TEXT) caption = "";
                body = ctx.getString("image".equals(msg.optString("kind")) ? R.string.notif_photo : R.string.notif_attachment)
                        + (caption.isEmpty() ? "" : ": " + cut(caption));
            }
            String chatId = id;
            String title = name;
            String g = msg.optString("g", "");
            if (!g.isEmpty()) {
                JSONObject chat = Shared.row(ctx, key, "chats", g);
                if (chat == null || !"group".equals(chat.optString("type")) || !memberOf(chat, id)) return NONE;
                chatId = g;
                title = Ids.clean(chat.optString("name")) + ": " + name;
            }
            if (appLock) {
                title = app;
                body = ctx.getString(R.string.new_message);
            }
            Notifier.message(ctx, chatId, title, body);
            return new String[]{"1", null};
        }
        if ("invite".equals(type)) {
            if ((hidden && !known) || (known && !pending) || (known && contact.optBoolean("notified"))) return NONE;
            long now = System.currentTimeMillis();
            synchronized (INVITED) {
                Long last = INVITED.get(id);
                if (last != null && now - last < INVITE_GAP_MS) return NONE;
                INVITED.put(id, now);
            }
            if (appLock) Notifier.message(ctx, id, app, ctx.getString(R.string.new_message));
            else Notifier.invite(ctx, id, name);
            return new String[]{"1", null};
        }
        if ("call".equals(type)) return call(ctx, id, appLock ? app : name, contact, msg);
        return NONE;
    }

    private static String[] call(Context ctx, String id, String shown, JSONObject contact, JSONObject msg) {
        String k = msg.optString("k");
        String callId = msg.optString("id", "");
        if (decode(callId, 8) == null) return NONE;
        if ("offer".equals(k)) {
            boolean consented = contact != null && !"in".equals(contact.optString("request"))
                    && (!"incoming".equals(contact.optString("addedVia")) || contact.optLong("cardSent") > 0);
            long ts = msg.optLong("ts", 0);
            boolean fresh = ts == 0 || System.currentTimeMillis() - ts <= STALE_MS;
            if (!consented || !fresh || decode(msg.optString("key"), 32) == null) return NONE;
            byte[] raw = new byte[16];
            RNG.nextBytes(raw);
            String token = SignalCore.hex(raw);
            synchronized (Opener.class) {
                long now = System.currentTimeMillis();
                if (ringingCall != null && now - ringingAt <= Notifier.RING_MS) return NONE;
                ringingCall = callId;
                ringingPeer = id;
                ringingName = shown;
                ringingToken = token;
                ringingAt = now;
            }
            if (!Notifier.incomingCall(ctx, shown, callId, id, token)) {
                forgetRinging();
                return NONE;
            }
            Ringer.startFor(ctx, Notifier.RING_MS);
            return new String[]{"1", callId};
        }
        if ("end".equals(k)) {
            String peerName = null;
            synchronized (Opener.class) {
                if (callId.equals(ringingCall) && id.equals(ringingPeer)) {
                    peerName = ringingName;
                    forgetRinging();
                }
            }
            if (peerName != null) {
                Ringer.stop();
                Notifier.cancelCall(ctx);
                Notifier.missedCall(ctx, peerName, id);
                return new String[]{"1", callId};
            }
        }
        return NONE;
    }
}
