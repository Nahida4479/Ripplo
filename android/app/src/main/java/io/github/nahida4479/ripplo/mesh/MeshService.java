package io.github.nahida4479.ripplo.mesh;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.IBinder;
import androidx.core.app.ServiceCompat;
import androidx.core.content.ContextCompat;

public class MeshService extends Service {
    private static volatile boolean active;

    static void launch(Context ctx) {
        if (active) return;
        try {
            ContextCompat.startForegroundService(ctx, new Intent(ctx, MeshService.class));
        } catch (RuntimeException ignored) {
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        try {
            ServiceCompat.startForeground(this, Notifier.ID_RELAY, Notifier.relay(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        } catch (RuntimeException e) {
            Diag.w("service foreground start refused: " + e);
            stopSelf();
            return START_NOT_STICKY;
        }
        active = true;
        Diag.i("service started engineRunning=" + MeshEngine.get(this).isRunning());
        MeshEngine engine = MeshEngine.get(this);
        if (!engine.isRunning() && !engine.resumeFromPrefs()) {
            Diag.w("service stopped: engine could not resume (no saved identity or background off)");
            stopSelf();
            return START_NOT_STICKY;
        }
        return START_STICKY;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        MeshEngine engine = MeshEngine.get(this);
        if (!engine.background()) {
            engine.stop();
            stopSelf();
        }
    }

    @Override
    public void onDestroy() {
        Diag.w("service destroyed");
        active = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
