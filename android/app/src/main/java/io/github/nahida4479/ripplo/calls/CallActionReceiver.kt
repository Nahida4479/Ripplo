package io.github.nahida4479.ripplo.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.platform.Notifier
import io.github.nahida4479.ripplo.platform.Opener

class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context?, intent: Intent?) {
        Ringer.stop()
        Notifier.cancelCall(ctx!!)
        Opener.forgetRinging()
        if (DECLINE == intent!!.action) {
            val id = intent.getStringExtra("callId")
            if (id != null) MeshEngine.get(ctx).dropCall(id)
        }
    }

    companion object {
        const val DECLINE = "io.github.nahida4479.ripplo.CALL_DECLINE"
    }
}
