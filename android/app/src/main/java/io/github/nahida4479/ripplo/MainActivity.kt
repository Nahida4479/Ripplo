package io.github.nahida4479.ripplo

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.github.nahida4479.ripplo.mesh.RipploMeshPlugin

class MainActivity : FlutterFragmentActivity() {
    private val mesh = RipploMeshPlugin()

    override fun onCreate(savedInstanceState: Bundle?) {
        showOverLock(intent)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(mesh)
    }

    override fun onPause() {
        super.onPause()
        mesh.onHostPause()
    }

    override fun onResume() {
        super.onResume()
        mesh.onHostResume()
    }

    override fun onNewIntent(intent: Intent) {
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
