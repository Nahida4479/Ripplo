package io.github.nahida4479.ripplo.mesh;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import io.github.nahida4479.ripplo.MainActivity;

public class UpdatedReceiver extends BroadcastReceiver {
    static final String PREFS = "ripplo_update";
    static final String KEY = "relaunchAt";
    private static final long WINDOW = 30 * 60 * 1000L;

    static void arm(Context ctx) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong(KEY, System.currentTimeMillis()).apply();
    }

    static void disarm(Context ctx) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).apply();
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (!Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction())) return;
        SharedPreferences sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long at = sp.getLong(KEY, 0);
        disarm(ctx);
        if (at == 0 || System.currentTimeMillis() - at > WINDOW) return;
        Notifier.updated(ctx);
        try {
            ctx.startActivity(new Intent(ctx, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (RuntimeException ignored) {
        }
    }
}
