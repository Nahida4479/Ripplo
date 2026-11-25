package io.github.nahida4479.ripplo.calls

import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

internal object Ringer {
    private val PATTERN = longArrayOf(0, 700, 500, 700, 1500)
    private val HANDLER = Handler(Looper.getMainLooper())
    private var tone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var replay: Runnable? = null
    private var limit: Runnable? = null

    @JvmStatic
    @Synchronized
    fun start(ctx: Context) {
        stop()
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager?
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager?
        if (am == null) return
        val mode = am.ringerMode
        val filter = if (Build.VERSION.SDK_INT >= 23 && nm != null) nm.currentInterruptionFilter
        else NotificationManager.INTERRUPTION_FILTER_ALL
        val quiet = filter != NotificationManager.INTERRUPTION_FILTER_ALL &&
            filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
        if (mode == AudioManager.RINGER_MODE_SILENT || quiet) return
        if (mode == AudioManager.RINGER_MODE_NORMAL) playTone(ctx)
        vibrate(ctx)
    }

    private fun playTone(ctx: Context) {
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val r = RingtoneManager.getRingtone(ctx, uri) ?: return
            r.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            if (Build.VERSION.SDK_INT >= 28) {
                r.setLooping(true)
            } else {
                val tick = object : Runnable {
                    override fun run() {
                        if (tone != r) return
                        if (!r.isPlaying) r.play()
                        HANDLER.postDelayed(this, 1000)
                    }
                }
                replay = tick
                HANDLER.postDelayed(tick, 1000)
            }
            tone = r
            r.play()
        } catch (ignored: RuntimeException) {
            tone = null
        }
    }

    @Suppress("deprecation")
    private fun vibrate(ctx: Context) {
        try {
            val v: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
                (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator?
            }
            if (v == null || !v.hasVibrator()) return
            vibrator = v
            when {
                Build.VERSION.SDK_INT >= 33 -> v.vibrate(
                    VibrationEffect.createWaveform(PATTERN, 0),
                    VibrationAttributes.createForUsage(VibrationAttributes.USAGE_RINGTONE)
                )
                Build.VERSION.SDK_INT >= 26 -> v.vibrate(
                    VibrationEffect.createWaveform(PATTERN, 0),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build()
                )
                else -> v.vibrate(PATTERN, 0)
            }
        } catch (ignored: RuntimeException) {
            vibrator = null
        }
    }

    @JvmStatic
    @Synchronized
    fun startFor(ctx: Context, ms: Long) {
        start(ctx)
        val stopper = Runnable { stop() }
        limit = stopper
        HANDLER.postDelayed(stopper, ms)
    }

    @JvmStatic
    @Synchronized
    fun stop() {
        limit?.let { HANDLER.removeCallbacks(it) }
        limit = null
        replay?.let { HANDLER.removeCallbacks(it) }
        replay = null
        tone?.let {
            try {
                it.stop()
            } catch (ignored: RuntimeException) {
            }
        }
        tone = null
        vibrator?.let {
            try {
                it.cancel()
            } catch (ignored: RuntimeException) {
            }
        }
        vibrator = null
    }
}
