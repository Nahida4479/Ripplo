package io.github.nahida4479.ripplo.mesh;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;
import io.github.nahida4479.ripplo.MainActivity;
import io.github.nahida4479.ripplo.R;

final class Notifier {
    static final String CH_RELAY = "mesh_relay";
    static final String CH_MESSAGES = "messages";
    static final String CH_UPDATES = "updates";
    static final int ID_RELAY = 4101;
    static final int ID_MESSAGE = 4102;
    static final int ID_UPDATED = 4103;
    static final int ID_UPDATE_INFO = 4104;
    static final int ID_CALL = 4105;
    static final String CH_CALLS = "calls";
    static final String EXTRA_CHAT = "ripplo.chat";
    static final String EXTRA_ANSWER = "ripplo.answer";
    static final long RING_MS = 45000L;

    private static final int ACCENT = 0xFF4F9CF9;
    private static Bitmap largeIcon;

    private Notifier() { }

    private static synchronized Bitmap large(Context ctx) {
        if (largeIcon == null) largeIcon = BitmapFactory.decodeResource(ctx.getResources(), R.drawable.ic_notification_large);
        return largeIcon;
    }

    static void createChannels(Context ctx) {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        NotificationChannel relay = new NotificationChannel(CH_RELAY, ctx.getString(R.string.channel_relay), NotificationManager.IMPORTANCE_MIN);
        relay.setShowBadge(false);
        nm.createNotificationChannel(relay);
        NotificationChannel msg = new NotificationChannel(CH_MESSAGES, ctx.getString(R.string.channel_messages), NotificationManager.IMPORTANCE_HIGH);
        nm.createNotificationChannel(msg);
        NotificationChannel calls = new NotificationChannel(CH_CALLS, ctx.getString(R.string.channel_calls), NotificationManager.IMPORTANCE_HIGH);
        calls.setSound(null, null);
        calls.enableVibration(false);
        calls.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        nm.createNotificationChannel(calls);
        nm.createNotificationChannel(new NotificationChannel(CH_UPDATES, ctx.getString(R.string.channel_updates), NotificationManager.IMPORTANCE_DEFAULT));
    }

    private static PendingIntent open(Context ctx) {
        Intent i = new Intent(ctx, MainActivity.class).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(ctx, 0, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    static Notification relay(Context ctx) {
        createChannels(ctx);
        return new NotificationCompat.Builder(ctx, CH_RELAY)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
                .setLargeIcon(large(ctx))
                .setColor(ACCENT)
                .setContentTitle(ctx.getString(R.string.app_name))
                .setContentText(ctx.getString(R.string.relay_text))
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setContentIntent(open(ctx))
                .build();
    }

    private static PendingIntent openChat(Context ctx, int req, String chat, String answer) {
        Intent i = new Intent(ctx, MainActivity.class).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        if (chat != null) i.putExtra(EXTRA_CHAT, chat);
        if (answer != null) i.putExtra(EXTRA_ANSWER, answer);
        return PendingIntent.getActivity(ctx, req, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private static boolean allowed(Context ctx) {
        return Build.VERSION.SDK_INT < 33
                || ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
    }

    static void message(Context ctx, String chatId, String title, String body) {
        if (!allowed(ctx)) return;
        createChannels(ctx);
        int id = 5000 + (chatId.hashCode() & 0x7FF);
        Notification generic = new NotificationCompat.Builder(ctx, CH_MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
                .setLargeIcon(large(ctx))
                .setColor(ACCENT)
                .setContentTitle(ctx.getString(R.string.app_name))
                .setContentText(ctx.getString(R.string.new_message))
                .build();
        Notification n = new NotificationCompat.Builder(ctx, CH_MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
                .setLargeIcon(large(ctx))
                .setColor(ACCENT)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(generic)
                .setContentIntent(openChat(ctx, id, chatId, null))
                .build();
        try {
            NotificationManagerCompat.from(ctx).notify(id, n);
        } catch (SecurityException ignored) {
        }
    }

    static void invite(Context ctx, String id, String name) {
        message(ctx, id, ctx.getString(R.string.invite_title), ctx.getString(R.string.invite_text, name));
    }

    static boolean incomingCall(Context ctx, String title, String callId, String peerId, String token) {
        if (!allowed(ctx)) return false;
        createChannels(ctx);
        Intent screen = new Intent(ctx, CallActivity.class).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_USER_ACTION)
                .putExtra(CallActivity.EXTRA_TITLE, title).putExtra(CallActivity.EXTRA_CALL, callId)
                .putExtra(CallActivity.EXTRA_PEER, peerId).putExtra(CallActivity.EXTRA_TOKEN, token);
        PendingIntent show = PendingIntent.getActivity(ctx, ID_CALL, screen, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent answer = openChat(ctx, ID_CALL + 1, peerId, token);
        PendingIntent decline = PendingIntent.getBroadcast(ctx, ID_CALL + 2,
                new Intent(ctx, CallActionReceiver.class).setAction(CallActionReceiver.DECLINE).putExtra("callId", callId),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification generic = new NotificationCompat.Builder(ctx, CH_CALLS)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
                .setLargeIcon(large(ctx))
                .setColor(ACCENT)
                .setContentTitle(ctx.getString(R.string.app_name))
                .setContentText(ctx.getString(R.string.incoming_call))
                .build();
        Notification n = new NotificationCompat.Builder(ctx, CH_CALLS)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
                .setLargeIcon(large(ctx))
                .setColor(ACCENT)
                .setContentTitle(title)
                .setContentText(ctx.getString(R.string.incoming_call))
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(generic)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setTimeoutAfter(RING_MS)
                .setFullScreenIntent(show, true)
                .setContentIntent(show)
                .addAction(0, ctx.getString(R.string.call_answer), answer)
                .addAction(0, ctx.getString(R.string.call_decline), decline)
                .build();
        try {
            NotificationManagerCompat.from(ctx).notify(ID_CALL, n);
            return true;
        } catch (SecurityException e) {
            return false;
        }
    }

    static void cancelCall(Context ctx) {
        NotificationManagerCompat.from(ctx).cancel(ID_CALL);
        CallActivity.dismiss();
    }

    static void missedCall(Context ctx, String name, String peerId) {
        message(ctx, peerId, name, ctx.getString(R.string.missed_call));
    }

    static void updated(Context ctx) {
        if (Build.VERSION.SDK_INT >= 33
                && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        createChannels(ctx);
        Notification n = new NotificationCompat.Builder(ctx, CH_MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
                .setLargeIcon(large(ctx))
                .setColor(ACCENT)
                .setContentTitle(ctx.getString(R.string.app_name))
                .setContentText(ctx.getString(R.string.updated_text))
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setContentIntent(open(ctx))
                .build();
        try {
            NotificationManagerCompat.from(ctx).notify(ID_UPDATED, n);
        } catch (SecurityException ignored) {
        }
    }

    private static void post(Context ctx, int id, String text, PendingIntent target) {
        if (Build.VERSION.SDK_INT >= 33
                && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        createChannels(ctx);
        Notification n = new NotificationCompat.Builder(ctx, CH_UPDATES)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
                .setLargeIcon(large(ctx))
                .setColor(ACCENT)
                .setContentTitle(ctx.getString(R.string.app_name))
                .setContentText(text)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setContentIntent(target)
                .build();
        try {
            NotificationManagerCompat.from(ctx).notify(id, n);
        } catch (SecurityException ignored) {
        }
    }

    static void updateAvailable(Context ctx, String tag) {
        post(ctx, ID_UPDATE_INFO, ctx.getString(R.string.update_available, tag), open(ctx));
    }

    static void updateReady(Context ctx, Intent confirm) {
        PendingIntent pi = PendingIntent.getActivity(ctx, 1, confirm, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        post(ctx, ID_UPDATE_INFO, ctx.getString(R.string.update_ready), pi);
    }

    static void cancelUpdated(Context ctx) {
        NotificationManagerCompat.from(ctx).cancel(ID_UPDATE_INFO);
        NotificationManagerCompat.from(ctx).cancel(ID_UPDATED);
    }

    static void newMessage(Context ctx) {
        if (Build.VERSION.SDK_INT >= 33
                && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        createChannels(ctx);
        Notification n = new NotificationCompat.Builder(ctx, CH_MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
                .setLargeIcon(large(ctx))
                .setColor(ACCENT)
                .setContentTitle(ctx.getString(R.string.app_name))
                .setContentText(ctx.getString(R.string.new_message))
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setContentIntent(open(ctx))
                .build();
        try {
            NotificationManagerCompat.from(ctx).notify(ID_MESSAGE, n);
        } catch (SecurityException ignored) {
        }
    }
}
