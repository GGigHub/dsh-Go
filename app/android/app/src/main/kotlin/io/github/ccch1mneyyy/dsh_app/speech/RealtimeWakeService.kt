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
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.nativemedia.MicArbiter
import java.util.Locale

/**
 * Background wake-word listener for Realtime calls. Uses the system
 * [SpeechRecognizer] inside a microphone FGS; matches a normalized substring.
 * On match, [RealtimeKeepPlugin.signalWake] brings the app forward so Flutter
 * can open the voice-call page (小艺-style).
 */
class RealtimeWakeService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var phrase = ""
    private var listening = false
    private var cooldownUntil = 0L
    private var restartToken = 0
    private var micToken = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                tearDown()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_OPEN_CALL -> {
                // Manual fallback from the notification — same path as a spoken wake.
                RealtimeKeepPlugin.signalWake(phrase = phrase.ifEmpty { "wake" }, heard = "notification")
                return START_STICKY
            }
            else -> {
                phrase = intent?.getStringExtra(EXTRA_PHRASE)?.trim().orEmpty()
                if (phrase.isEmpty()) {
                    Log.w(TAG, "wake start rejected: empty phrase")
                    RealtimeKeepPlugin.emit("wakeError", mapOf("message" to "empty wake phrase"))
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    Log.w(TAG, "wake start rejected: no RECORD_AUDIO")
                    RealtimeKeepPlugin.emit("wakeError", mapOf("message" to "microphone permission required"))
                    stopSelf()
                    return START_NOT_STICKY
                }
                ensureChannel()
                startAsForeground(buildNotification())
                running = true
                Log.i(TAG, "wake listening phraseLen=${phrase.length}")
                startListening()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        tearDown()
        running = false
        Log.i(TAG, "wake stopped")
        super.onDestroy()
    }

    private fun tearDown() {
        restartToken++
        listening = false
        recognizer?.setRecognitionListener(null)
        runCatching { recognizer?.cancel() }
        runCatching { recognizer?.destroy() }
        recognizer = null
        MicArbiter.endDictation(micToken)
        micToken = 0L
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
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_OPEN_CALL, true)
                .putExtra(EXTRA_PHRASE, phrase),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val startCall = PendingIntent.getService(
            this,
            3,
            Intent(this, RealtimeWakeService::class.java).setAction(ACTION_OPEN_CALL),
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
            .addAction(0, AppStrings.get(this, R.string.realtime_wake_open_call), startCall)
            .addAction(0, AppStrings.get(this, R.string.realtime_wake_stop), stop)
            .build()
    }

    private fun createRecognizer(): SpeechRecognizer? {
        val activity = MainActivity.current?.get()
        val ctx: Context = activity ?: this
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
            ) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
            } else {
                SpeechRecognizer.createSpeechRecognizer(ctx)
            }
        }.onFailure {
            Log.w(TAG, "createSpeechRecognizer failed: ${it.message}")
        }.getOrNull()
    }

    private fun startListening() {
        if (!running || phrase.isEmpty()) return
        if (!SpeechRecognizer.isRecognitionAvailable(this) &&
            !(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(this))
        ) {
            Log.w(TAG, "speech recognizer unavailable")
            RealtimeKeepPlugin.emit("wakeError", mapOf("message" to "speech recognizer unavailable"))
            stopSelf()
            return
        }
        if (recognizer == null) {
            recognizer = createRecognizer()?.also {
                it.setRecognitionListener(listener)
            }
            if (recognizer == null) {
                RealtimeKeepPlugin.emit("wakeError", mapOf("message" to "could not create speech recognizer"))
                main.postDelayed({ if (running) startListening() }, 2500)
                return
            }
        }
        if (micToken == 0L) micToken = MicArbiter.beginDictation()
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
            // Chinese wake phrases; without this many ROMs default to en-US.
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "zh-CN")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
        }
        listening = true
        val token = ++restartToken
        runCatching {
            recognizer?.cancel()
            recognizer?.startListening(intent)
        }.onFailure {
            listening = false
            Log.w(TAG, "startListening failed: ${it.message}")
            recreateRecognizer()
            main.postDelayed({ if (running && token == restartToken) startListening() }, 1500)
        }
    }

    private fun recreateRecognizer() {
        recognizer?.setRecognitionListener(null)
        runCatching { recognizer?.destroy() }
        recognizer = null
    }

    private fun maybeWake(text: String) {
        val now = System.currentTimeMillis()
        if (now < cooldownUntil) return
        if (!matchesWake(text, phrase)) return
        cooldownUntil = now + 5000
        Log.i(TAG, "wake matched heardLen=${text.length}")
        // Pause ASR while the call page opens and takes the mic.
        runCatching { recognizer?.cancel() }
        listening = false
        RealtimeKeepPlugin.signalWake(phrase = phrase, heard = text)
    }

    private fun scheduleRestart(delayMs: Long) {
        val token = ++restartToken
        main.postDelayed({
            if (running && token == restartToken) startListening()
        }, delayMs)
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            Log.d(TAG, "wake readyForSpeech")
        }

        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}

        override fun onError(error: Int) {
            listening = false
            Log.d(TAG, "wake recognizer error=$error")
            // Busy / client: destroy and rebuild — OEM recognizers often stick after ERROR_CLIENT.
            if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY ||
                error == SpeechRecognizer.ERROR_CLIENT
            ) {
                recreateRecognizer()
            }
            val delay = when (error) {
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                    RealtimeKeepPlugin.emit("wakeError", mapOf("message" to "microphone permission required"))
                    8000L
                }
                SpeechRecognizer.ERROR_CLIENT, SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> 2000L
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT, SpeechRecognizer.ERROR_NO_MATCH -> 400L
                else -> 900L
            }
            scheduleRestart(delay)
        }

        override fun onResults(results: Bundle?) {
            listening = false
            val texts = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
            for (t in texts) {
                Log.d(TAG, "wake result len=${t.length}")
                maybeWake(t)
            }
            scheduleRestart(500)
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
        const val ACTION_OPEN_CALL = "io.github.ccch1mneyyy.dsh_app.realtime.WAKE_OPEN_CALL"
        const val EXTRA_PHRASE = "phrase"
        const val EXTRA_HEARD = "heard"
        const val EXTRA_OPEN_CALL = "realtime_open_call"
        private const val CHANNEL_ID = "realtime_wake"
        private const val NOTIFICATION_ID = 71402
        private const val TAG = "dsh.realtime"

        @Volatile
        var running = false
            private set

        /** Strip spaces / punctuation so 「小助手！」 still matches 「小助手」. */
        fun matchesWake(heard: String, phrase: String): Boolean {
            val hay = normalize(heard)
            val needle = normalize(phrase)
            return needle.isNotEmpty() && hay.contains(needle)
        }

        private fun normalize(raw: String): String {
            val lower = raw.lowercase(Locale.ROOT)
            val out = StringBuilder(lower.length)
            for (ch in lower) {
                if (ch.isLetterOrDigit() || ch in '\u4e00'..'\u9fff') out.append(ch)
            }
            return out.toString()
        }

        fun start(context: Context, phrase: String) {
            // Call keep takes the mic; don't fight it.
            if (RealtimeCallService.running) {
                Log.i(TAG, "wake start skipped: call keep running")
                return
            }
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
