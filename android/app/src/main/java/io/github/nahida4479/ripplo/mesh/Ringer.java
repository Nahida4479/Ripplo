package io.github.nahida4479.ripplo.mesh;

import android.app.NotificationManager;
import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.Ringtone;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationAttributes;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;

final class Ringer {
    private static final long[] PATTERN = {0, 700, 500, 700, 1500};
    private static final Handler HANDLER = new Handler(Looper.getMainLooper());
    private static Ringtone tone;
    private static Vibrator vibrator;
    private static Runnable replay;
    private static Runnable limit;

    private Ringer() { }

    static synchronized void start(Context ctx) {
        stop();
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (am == null) return;
        int mode = am.getRingerMode();
        int filter = Build.VERSION.SDK_INT >= 23 && nm != null ? nm.getCurrentInterruptionFilter() : NotificationManager.INTERRUPTION_FILTER_ALL;
        boolean quiet = filter != NotificationManager.INTERRUPTION_FILTER_ALL && filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN;
        if (mode == AudioManager.RINGER_MODE_SILENT || quiet) return;
        if (mode == AudioManager.RINGER_MODE_NORMAL) playTone(ctx);
        vibrate(ctx);
    }

    private static void playTone(Context ctx) {
        try {
            Uri uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
            final Ringtone r = RingtoneManager.getRingtone(ctx, uri);
            if (r == null) return;
            r.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build());
            if (Build.VERSION.SDK_INT >= 28) {
                r.setLooping(true);
            } else {
                replay = new Runnable() {
                    @Override
                    public void run() {
                        if (tone != r) return;
                        if (!r.isPlaying()) r.play();
                        HANDLER.postDelayed(this, 1000);
                    }
                };
                HANDLER.postDelayed(replay, 1000);
            }
            tone = r;
            r.play();
        } catch (RuntimeException ignored) {
            tone = null;
        }
    }

    @SuppressWarnings("deprecation")
    private static void vibrate(Context ctx) {
        try {
            Vibrator v = Build.VERSION.SDK_INT >= 31
                    ? ((VibratorManager) ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)).getDefaultVibrator()
                    : (Vibrator) ctx.getSystemService(Context.VIBRATOR_SERVICE);
            if (v == null || !v.hasVibrator()) return;
            vibrator = v;
            if (Build.VERSION.SDK_INT >= 33) {
                v.vibrate(VibrationEffect.createWaveform(PATTERN, 0), VibrationAttributes.createForUsage(VibrationAttributes.USAGE_RINGTONE));
            } else if (Build.VERSION.SDK_INT >= 26) {
                v.vibrate(VibrationEffect.createWaveform(PATTERN, 0), new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build());
            } else {
                v.vibrate(PATTERN, 0);
            }
        } catch (RuntimeException ignored) {
            vibrator = null;
        }
    }

    static synchronized void startFor(Context ctx, long ms) {
        start(ctx);
        limit = Ringer::stop;
        HANDLER.postDelayed(limit, ms);
    }

    static synchronized void stop() {
        if (limit != null) HANDLER.removeCallbacks(limit);
        limit = null;
        if (replay != null) HANDLER.removeCallbacks(replay);
        replay = null;
        if (tone != null) {
            try { tone.stop(); } catch (RuntimeException ignored) { }
            tone = null;
        }
        if (vibrator != null) {
            try { vibrator.cancel(); } catch (RuntimeException ignored) { }
            vibrator = null;
        }
    }
}
