package io.github.nahida4479.ripplo.mesh;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
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

    private Notifier() { }

    static void createChannels(Context ctx) {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        NotificationChannel relay = new NotificationChannel(CH_RELAY, ctx.getString(R.string.channel_relay), NotificationManager.IMPORTANCE_MIN);
        relay.setShowBadge(false);
        nm.createNotificationChannel(relay);
        NotificationChannel msg = new NotificationChannel(CH_MESSAGES, ctx.getString(R.string.channel_messages), NotificationManager.IMPORTANCE_HIGH);
        nm.createNotificationChannel(msg);
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
                .setContentTitle(ctx.getString(R.string.app_name))
                .setContentText(ctx.getString(R.string.relay_text))
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setContentIntent(open(ctx))
                .build();
    }

    static void updated(Context ctx) {
        if (Build.VERSION.SDK_INT >= 33
                && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        createChannels(ctx);
        Notification n = new NotificationCompat.Builder(ctx, CH_MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_ripplo)
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
