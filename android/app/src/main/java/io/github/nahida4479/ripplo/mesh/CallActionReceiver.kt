package io.github.nahida4479.ripplo.mesh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

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
