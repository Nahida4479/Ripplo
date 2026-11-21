package io.github.nahida4479.ripplo.mesh;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import io.github.nahida4479.ripplo.MainActivity;

public class UpdatedReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (!Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction())) return;
        Notifier.updated(ctx);
        try {
            ctx.startActivity(new Intent(ctx, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (RuntimeException ignored) {
        }
    }
}
