package io.github.ccch1mneyyy.dsh_app.speech

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings

/** Microphone FGS while a Realtime voice call is active in the background. */
class RealtimeCallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HANG_UP -> {
                RealtimeKeepPlugin.emit("hangUp")
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: AppStrings.get(this, R.string.realtime_call_notify_title)
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: AppStrings.get(this, R.string.realtime_call_notify_text)
                ensureChannel()
                startAsForeground(buildNotification(title, text))
                running = true
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun startAsForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                AppStrings.get(this, R.string.realtime_call_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = AppStrings.get(this@RealtimeCallService, R.string.realtime_call_channel_desc)
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(title: String, text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val hangUp = PendingIntent.getService(
            this,
            1,
            Intent(this, RealtimeCallService::class.java).setAction(ACTION_HANG_UP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(0, AppStrings.get(this, R.string.realtime_call_hang_up), hangUp)
            .build()
    }

    companion object {
        const val ACTION_START = "io.github.ccch1mneyyy.dsh_app.realtime.CALL_START"
        const val ACTION_STOP = "io.github.ccch1mneyyy.dsh_app.realtime.CALL_STOP"
        const val ACTION_HANG_UP = "io.github.ccch1mneyyy.dsh_app.realtime.CALL_HANG_UP"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "realtime_call"
        private const val NOTIFICATION_ID = 71401

        @Volatile
        var running = false
            private set

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, RealtimeCallService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            if (!running) return
            context.startService(Intent(context, RealtimeCallService::class.java).setAction(ACTION_STOP))
        }
    }
}
