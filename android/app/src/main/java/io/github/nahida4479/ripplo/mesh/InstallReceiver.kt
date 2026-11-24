package io.github.nahida4479.ripplo.mesh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

class InstallReceiver : BroadcastReceiver() {
    @Suppress("deprecation")
    override fun onReceive(ctx: Context?, intent: Intent?) {
        val status = intent!!.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirm: Intent? = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            }
            if (confirm != null) {
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (RipploMeshPlugin.installCall == null || !RipploMeshPlugin.foreground) {
                    Notifier.updateReady(ctx!!, confirm)
                } else {
                    try {
                        ctx!!.startActivity(confirm)
                    } catch (e: RuntimeException) {
                        RipploMeshPlugin.installResult(false, -1, "cannot open installer")
                    }
                }
            }
            return
        }
        RipploMeshPlugin.installResult(status == PackageInstaller.STATUS_SUCCESS, status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE))
    }
}
