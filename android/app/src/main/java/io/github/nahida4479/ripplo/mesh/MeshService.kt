package io.github.nahida4479.ripplo.mesh

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.platform.Notifier

class MeshService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            ServiceCompat.startForeground(this, Notifier.ID_RELAY, Notifier.relay(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } catch (e: RuntimeException) {
            Diag.w("service foreground start refused: $e")
            stopSelf()
            return START_NOT_STICKY
        }
        active = true
        val engine = MeshEngine.get(this)
        Diag.i("service started engineRunning=${engine.isRunning()}")
        if (!engine.isRunning() && !engine.resumeFromPrefs()) {
            Diag.w("service stopped: engine could not resume (no saved identity or background off)")
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val engine = MeshEngine.get(this)
        if (!engine.background()) {
            engine.stop()
            stopSelf()
        }
    }

    override fun onDestroy() {
        Diag.w("service destroyed")
        active = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        @Volatile
        private var active = false

        fun launch(ctx: Context) {
            if (active) return
            try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, MeshService::class.java))
            } catch (ignored: RuntimeException) {
            }
        }
    }
}
