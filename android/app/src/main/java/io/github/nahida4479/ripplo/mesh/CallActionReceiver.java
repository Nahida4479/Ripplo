package io.github.nahida4479.ripplo.mesh;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class CallActionReceiver extends BroadcastReceiver {
    static final String DECLINE = "io.github.nahida4479.ripplo.CALL_DECLINE";

    @Override
    public void onReceive(Context ctx, Intent intent) {
        Ringer.stop();
        Notifier.cancelCall(ctx);
        Opener.forgetRinging();
        if (DECLINE.equals(intent.getAction())) {
            String id = intent.getStringExtra("callId");
            if (id != null) MeshEngine.get(ctx).dropCall(id);
        }
    }
}
