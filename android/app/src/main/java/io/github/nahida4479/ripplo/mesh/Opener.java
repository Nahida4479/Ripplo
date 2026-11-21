package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;
import io.github.nahida4479.ripplo.R;

final class Opener {
    private static final long STALE_MS = 120000L;
    private static final int MAX_BODY = 200;
    private static String ringingCall;
    private static String ringingPeer;
    private static String ringingName;

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
        return s.length() > MAX_BODY ? s.substring(0, MAX_BODY) : s;
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

    private static String[] announce(Context ctx, byte[] key, SignalCore.Opened o, JSONObject msg) {
        String id = Ids.ripploId(o.tag);
        JSONObject contact = Shared.row(ctx, key, "contacts", id);
        JSONObject settings = Shared.row(ctx, key, "kv", "settings");
        boolean hidden = settings != null && settings.optBoolean("hidden");
        boolean appLock = settings != null && settings.optBoolean("appLock");
        boolean known = contact != null;
        boolean pending = known && "in".equals(contact.optString("request"));
        String name = known ? contact.optString("name") : "";
        if (name.isEmpty()) {
            try {
                name = Ids.cardName(Base64.decode(msg.optString("c"), Base64.NO_WRAP));
            } catch (IllegalArgumentException e) {
                name = null;
            }
            if (name == null) name = "Ripplo " + id.substring(0, 4);
        }
        String type = msg.optString("t");
        String none = null;
        if ("msg".equals(type) || "att".equals(type)) {
            if (pending) return new String[]{none, null};
            String body;
            if ("msg".equals(type)) {
                String text = msg.optString("text", null);
                if (text == null) return new String[]{none, null};
                body = cut(text);
            } else {
                String caption = msg.optString("text", "");
                body = ctx.getString("image".equals(msg.optString("kind")) ? R.string.notif_photo : R.string.notif_attachment)
                        + (caption.isEmpty() ? "" : ": " + cut(caption));
            }
            String chatId = id;
            String title = name;
            String g = msg.optString("g", "");
            if (!g.isEmpty()) {
                JSONObject chat = Shared.row(ctx, key, "chats", g);
                if (chat == null || !"group".equals(chat.optString("type")) || !memberOf(chat, id)) return new String[]{none, null};
                chatId = g;
                title = chat.optString("name") + ": " + name;
            }
            if (appLock) {
                title = ctx.getString(R.string.app_name);
                body = ctx.getString(R.string.new_message);
            }
            Notifier.message(ctx, chatId, title, body);
            return new String[]{"1", null};
        }
        if ("invite".equals(type)) {
            if ((hidden && !known) || (known && !pending)) return new String[]{none, null};
            Notifier.invite(ctx, id, name);
            return new String[]{"1", null};
        }
        if ("call".equals(type)) return call(ctx, id, name, contact, msg);
        return new String[]{none, null};
    }

    private static String[] call(Context ctx, String id, String name, JSONObject contact, JSONObject msg) {
        String k = msg.optString("k");
        String callId = msg.optString("id", "");
        if (decode(callId, 8) == null) return new String[]{null, null};
        if ("offer".equals(k)) {
            boolean consented = contact != null && !"in".equals(contact.optString("request"))
                    && (!"incoming".equals(contact.optString("addedVia")) || contact.optLong("cardSent") > 0);
            long ts = msg.optLong("ts", 0);
            boolean fresh = ts == 0 || System.currentTimeMillis() - ts <= STALE_MS;
            if (!consented || !fresh || decode(msg.optString("key"), 32) == null) return new String[]{null, null};
            synchronized (Opener.class) {
                if (ringingCall != null) return new String[]{null, null};
                ringingCall = callId;
                ringingPeer = id;
                ringingName = name;
            }
            Notifier.incomingCall(ctx, name, callId, id);
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
        return new String[]{null, null};
    }
}
