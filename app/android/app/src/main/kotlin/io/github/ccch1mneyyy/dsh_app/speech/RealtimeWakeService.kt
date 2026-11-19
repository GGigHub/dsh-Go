package io.github.ccch1mneyyy.dsh_app.speech

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings

/**
 * Background wake-word listener for Realtime calls. Uses the system
 * [SpeechRecognizer] inside a microphone FGS; matches a substring phrase.
 */
class RealtimeWakeService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var phrase = ""
    private var listening = false
    private var cooldownUntil = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                tearDown()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                phrase = intent?.getStringExtra(EXTRA_PHRASE)?.trim().orEmpty()
                if (phrase.isEmpty() ||
                    checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
                ) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                ensureChannel()
                startAsForeground(buildNotification())
                running = true
                startListening()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        tearDown()
        running = false
        super.onDestroy()
    }

    private fun tearDown() {
        listening = false
        recognizer?.setRecognitionListener(null)
        runCatching { recognizer?.destroy() }
        recognizer = null
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
                AppStrings.get(this, R.string.realtime_wake_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = AppStrings.get(this@RealtimeWakeService, R.string.realtime_wake_channel_desc)
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            2,
            Intent(this, RealtimeWakeService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(AppStrings.get(this, R.string.realtime_wake_notify_title))
            .setContentText(AppStrings.get(this, R.string.realtime_wake_notify_text, phrase))
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(0, AppStrings.get(this, R.string.realtime_wake_stop), stop)
            .build()
    }

    private fun startListening() {
        if (!running || phrase.isEmpty()) return
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            RealtimeKeepPlugin.emit("wakeError", mapOf("message" to "speech recognizer unavailable"))
            stopSelf()
            return
        }
        if (recognizer == null) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(this).also {
                it.setRecognitionListener(listener)
            }
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
        }
        listening = true
        runCatching { recognizer?.startListening(intent) }
            .onFailure {
                listening = false
                main.postDelayed({ startListening() }, 1500)
            }
    }

    private fun maybeWake(text: String) {
        val now = System.currentTimeMillis()
        if (now < cooldownUntil) return
        val hay = text.lowercase().replace(" ", "")
        val needle = phrase.lowercase().replace(" ", "")
        if (needle.isEmpty() || !hay.contains(needle)) return
        cooldownUntil = now + 4000
        RealtimeKeepPlugin.emit("wake", mapOf("phrase" to phrase, "heard" to text))
        // Bring the app forward so Flutter can open the call page.
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_OPEN_CALL, true),
        )
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onError(error: Int) {
            listening = false
            // Restart after short errors; don't spin on permission/client issues.
            val delay = if (error == SpeechRecognizer.ERROR_CLIENT || error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
                5000L
            } else {
                800L
            }
            main.postDelayed({ if (running) startListening() }, delay)
        }

        override fun onResults(results: Bundle?) {
            listening = false
            val texts = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
            for (t in texts) maybeWake(t)
            main.postDelayed({ if (running) startListening() }, 400)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val texts = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
            for (t in texts) maybeWake(t)
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    companion object {
        const val ACTION_START = "io.github.ccch1mneyyy.dsh_app.realtime.WAKE_START"
        const val ACTION_STOP = "io.github.ccch1mneyyy.dsh_app.realtime.WAKE_STOP"
        const val EXTRA_PHRASE = "phrase"
        const val EXTRA_OPEN_CALL = "realtime_open_call"
        private const val CHANNEL_ID = "realtime_wake"
        private const val NOTIFICATION_ID = 71402

        @Volatile
        var running = false
            private set

        fun start(context: Context, phrase: String) {
            // Call keep takes the mic; don't fight it.
            if (RealtimeCallService.running) return
            val intent = Intent(context, RealtimeWakeService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_PHRASE, phrase)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            if (!running) return
            context.startService(Intent(context, RealtimeWakeService::class.java).setAction(ACTION_STOP))
        }
    }
}
