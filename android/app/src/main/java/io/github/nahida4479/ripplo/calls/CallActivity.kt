package io.github.nahida4479.ripplo.calls

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import io.github.nahida4479.ripplo.MainActivity
import io.github.nahida4479.ripplo.R
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.platform.Notifier
import io.github.nahida4479.ripplo.platform.Opener
import java.lang.ref.WeakReference

class CallActivity : Activity() {
    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_CALL = "callId"
        const val EXTRA_PEER = "peer"
        const val EXTRA_TOKEN = "token"
        private var current: WeakReference<CallActivity>? = null

        @JvmStatic
        fun dismiss() {
            current?.get()?.finish()
        }
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        current = WeakReference(this)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        val incoming = intent
        val callId = incoming.getStringExtra(EXTRA_CALL)
        val peer = incoming.getStringExtra(EXTRA_PEER)
        val token = incoming.getStringExtra(EXTRA_TOKEN)
        val title = incoming.getStringExtra(EXTRA_TITLE)
        if (callId == null || peer == null || token == null) {
            finish()
            return
        }
        val density = resources.displayMetrics.density
        val root = LinearLayout(this)
        root.setOrientation(LinearLayout.VERTICAL)
        root.setGravity(Gravity.CENTER_HORIZONTAL)
        root.setBackgroundColor(Color.parseColor("#101418"))
        val pad = (24 * density).toInt()
        root.setPadding(pad, pad * 3, pad, pad * 2)
        val name = TextView(this)
        name.setText(title ?: getString(R.string.app_name))
        name.setTextColor(Color.WHITE)
        name.setTextSize(30f)
        name.setGravity(Gravity.CENTER)
        val sub = TextView(this)
        sub.setText(R.string.incoming_call)
        sub.setTextColor(Color.parseColor("#9AA4AE"))
        sub.setTextSize(16f)
        sub.setGravity(Gravity.CENTER)
        sub.setPadding(0, pad / 2, 0, 0)
        val gap = View(this)
        val grow = LinearLayout.LayoutParams(0, 0, 1f)
        val buttons = LinearLayout(this)
        buttons.setOrientation(LinearLayout.HORIZONTAL)
        buttons.setGravity(Gravity.CENTER)
        val decline = button(R.string.call_decline, "#D93F3F")
        val answer = button(R.string.call_answer, "#2E9E5B")
        val bp = LinearLayout.LayoutParams(0, (56 * density).toInt(), 1f)
        bp.setMargins(pad / 2, 0, pad / 2, 0)
        buttons.addView(decline, bp)
        buttons.addView(answer, bp)
        root.addView(name)
        root.addView(sub)
        root.addView(gap, grow)
        root.addView(buttons, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        setContentView(root)
        decline.setOnClickListener { declineCall(callId) }
        answer.setOnClickListener { answerCall(peer, token) }
    }

    private fun button(text: Int, color: String): Button {
        val b = Button(this)
        b.setText(text)
        b.setTextColor(Color.WHITE)
        b.setAllCaps(false)
        val bg = GradientDrawable()
        bg.setColor(Color.parseColor(color))
        bg.setCornerRadius(999f)
        b.setBackground(bg)
        return b
    }

    private fun declineCall(callId: String) {
        Ringer.stop()
        Notifier.cancelCall(this)
        Opener.forgetRinging()
        MeshEngine.get(this).dropCall(callId)
        finish()
    }

    private fun answerCall(peer: String, token: String) {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(Notifier.EXTRA_CHAT, peer)
                .putExtra(Notifier.EXTRA_ANSWER, token)
        )
        finish()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (current?.get() === this) current = null
    }
}
