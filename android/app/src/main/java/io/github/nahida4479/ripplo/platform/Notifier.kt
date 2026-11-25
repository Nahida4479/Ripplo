package io.github.nahida4479.ripplo.platform

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.github.nahida4479.ripplo.MainActivity
import io.github.nahida4479.ripplo.R
import io.github.nahida4479.ripplo.calls.CallActionReceiver
import io.github.nahida4479.ripplo.calls.CallActivity

internal object Notifier {
    const val CH_RELAY = "mesh_relay"
    const val CH_MESSAGES = "messages"
    const val CH_UPDATES = "updates"
    const val ID_RELAY = 4101
    const val ID_MESSAGE = 4102
    const val ID_UPDATED = 4103
    const val ID_UPDATE_INFO = 4104
    const val ID_CALL = 4105
    const val CH_CALLS = "calls"
    const val EXTRA_CHAT = "ripplo.chat"
    const val EXTRA_ANSWER = "ripplo.answer"
    const val RING_MS = 45000L

    private const val ACCENT = 0xFF4F9CF9.toInt()
    private var largeIcon: Bitmap? = null

    @Synchronized
    private fun large(ctx: Context): Bitmap? {
        if (largeIcon == null) largeIcon = BitmapFactory.decodeResource(ctx.resources, R.drawable.ic_notification_large)
        return largeIcon
    }

    private fun builder(ctx: Context, channel: String): NotificationCompat.Builder =
        NotificationCompat.Builder(ctx, channel)
            .setSmallIcon(R.drawable.ic_stat_ripplo)
            .setLargeIcon(large(ctx))
            .setColor(ACCENT)

    fun createChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java)!!
        nm.createNotificationChannel(
            NotificationChannel(CH_RELAY, ctx.getString(R.string.channel_relay), NotificationManager.IMPORTANCE_MIN).apply {
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(NotificationChannel(CH_MESSAGES, ctx.getString(R.string.channel_messages), NotificationManager.IMPORTANCE_HIGH))
        nm.createNotificationChannel(
            NotificationChannel(CH_CALLS, ctx.getString(R.string.channel_calls), NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        )
        nm.createNotificationChannel(NotificationChannel(CH_UPDATES, ctx.getString(R.string.channel_updates), NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun open(ctx: Context) = openChat(ctx, 0, null, null)

    fun relay(ctx: Context): Notification {
        createChannels(ctx)
        return builder(ctx, CH_RELAY)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(ctx.getString(R.string.relay_text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(open(ctx))
            .build()
    }

    private fun openChat(ctx: Context, req: Int, chat: String?, answer: String?): PendingIntent? {
        val i = Intent(ctx, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (chat != null) i.putExtra(EXTRA_CHAT, chat)
        if (answer != null) i.putExtra(EXTRA_ANSWER, answer)
        return PendingIntent.getActivity(ctx, req, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun allowed(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun message(ctx: Context, chatId: String, title: String?, body: String?) {
        if (!allowed(ctx)) return
        createChannels(ctx)
        val id = 5000 + (chatId.hashCode() and 0x7FF)
        val generic = builder(ctx, CH_MESSAGES)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(ctx.getString(R.string.new_message))
            .build()
        val n = builder(ctx, CH_MESSAGES)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(generic)
            .setContentIntent(openChat(ctx, id, chatId, null))
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(id, n)
        } catch (ignored: SecurityException) {
        }
    }

    fun invite(ctx: Context, id: String, name: String?) {
        message(ctx, id, ctx.getString(R.string.invite_title), ctx.getString(R.string.invite_text, name))
    }

    fun incomingCall(ctx: Context, title: String, callId: String, peerId: String, token: String): Boolean {
        if (!allowed(ctx)) return false
        createChannels(ctx)
        val screen = Intent(ctx, CallActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)
            .putExtra(CallActivity.EXTRA_TITLE, title).putExtra(CallActivity.EXTRA_CALL, callId)
            .putExtra(CallActivity.EXTRA_PEER, peerId).putExtra(CallActivity.EXTRA_TOKEN, token)
        val show = PendingIntent.getActivity(ctx, ID_CALL, screen, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val answer = openChat(ctx, ID_CALL + 1, peerId, token)
        val decline = PendingIntent.getBroadcast(
            ctx, ID_CALL + 2,
            Intent(ctx, CallActionReceiver::class.java).setAction(CallActionReceiver.DECLINE).putExtra("callId", callId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val generic = builder(ctx, CH_CALLS)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(ctx.getString(R.string.incoming_call))
            .build()
        val n = builder(ctx, CH_CALLS)
            .setContentTitle(title)
            .setContentText(ctx.getString(R.string.incoming_call))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(generic)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter(RING_MS)
            .setFullScreenIntent(show, true)
            .setContentIntent(show)
            .addAction(NotificationCompat.Action.Builder(0, ctx.getString(R.string.call_answer), answer).setAuthenticationRequired(false).build())
            .addAction(0, ctx.getString(R.string.call_decline), decline)
            .build()
        return try {
            NotificationManagerCompat.from(ctx).notify(ID_CALL, n)
            true
        } catch (e: SecurityException) {
            false
        }
    }

    fun cancelCall(ctx: Context) {
        NotificationManagerCompat.from(ctx).cancel(ID_CALL)
        CallActivity.dismiss()
    }

    fun missedCall(ctx: Context, name: String?, peerId: String) {
        message(ctx, peerId, name, ctx.getString(R.string.missed_call))
    }

    fun updated(ctx: Context) {
        if (!allowed(ctx)) return
        createChannels(ctx)
        val n = builder(ctx, CH_MESSAGES)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(ctx.getString(R.string.updated_text))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(open(ctx))
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(ID_UPDATED, n)
        } catch (ignored: SecurityException) {
        }
    }

    private fun post(ctx: Context, id: Int, text: String, target: PendingIntent?) {
        if (!allowed(ctx)) return
        createChannels(ctx)
        val n = builder(ctx, CH_UPDATES)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(text)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(target)
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(id, n)
        } catch (ignored: SecurityException) {
        }
    }

    fun updateAvailable(ctx: Context, tag: String) {
        post(ctx, ID_UPDATE_INFO, ctx.getString(R.string.update_available, tag), open(ctx))
    }

    fun updateReady(ctx: Context, confirm: Intent) {
        val pi = PendingIntent.getActivity(ctx, 1, confirm, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        post(ctx, ID_UPDATE_INFO, ctx.getString(R.string.update_ready), pi)
    }

    fun cancelUpdated(ctx: Context) {
        NotificationManagerCompat.from(ctx).cancel(ID_UPDATE_INFO)
        NotificationManagerCompat.from(ctx).cancel(ID_UPDATED)
    }

    fun newMessage(ctx: Context) {
        if (!allowed(ctx)) return
        createChannels(ctx)
        val n = builder(ctx, CH_MESSAGES)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(ctx.getString(R.string.new_message))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setContentIntent(open(ctx))
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(ID_MESSAGE, n)
        } catch (ignored: SecurityException) {
        }
    }
}
