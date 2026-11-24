package io.github.nahida4479.ripplo.mesh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.nahida4479.ripplo.MainActivity

class UpdatedReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context?, intent: Intent?) {
        if (Intent.ACTION_MY_PACKAGE_REPLACED != intent!!.action) return
        if (UpdateEngine.autoEnabled(ctx!!)) UpdateJobService.schedule(ctx)
        Notifier.updated(ctx)
        try {
            ctx.startActivity(Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (ignored: RuntimeException) {
        }
    }
}
