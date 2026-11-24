package io.github.nahida4479.ripplo

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import com.getcapacitor.BridgeActivity
import io.github.nahida4479.ripplo.mesh.RipploMeshPlugin

class MainActivity : BridgeActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        registerPlugin(RipploMeshPlugin::class.java)
        showOverLock(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent?) {
        showOverLock(intent)
        super.onNewIntent(intent)
    }

    private fun showOverLock(intent: Intent?) {
        if (intent == null || !RipploMeshPlugin.callTokenValid(intent.getStringExtra("ripplo.answer"))) return
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
    }
}
