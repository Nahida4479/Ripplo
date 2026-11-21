package io.github.nahida4479.ripplo;

import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowManager;
import com.getcapacitor.BridgeActivity;
import io.github.nahida4479.ripplo.mesh.RipploMeshPlugin;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(RipploMeshPlugin.class);
        showOverLock(getIntent());
        super.onCreate(savedInstanceState);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        showOverLock(intent);
        super.onNewIntent(intent);
    }

    private void showOverLock(Intent intent) {
        if (intent == null || !RipploMeshPlugin.callTokenValid(intent.getStringExtra("ripplo.answer"))) return;
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true);
            setTurnScreenOn(true);
        } else {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        }
    }
}
