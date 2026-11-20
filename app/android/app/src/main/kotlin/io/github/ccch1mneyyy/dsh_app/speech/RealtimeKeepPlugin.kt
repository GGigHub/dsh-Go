package io.github.ccch1mneyyy.dsh_app.speech

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.ccch1mneyyy.dsh_app.MainActivity
import java.util.concurrent.atomic.AtomicReference

/**
 * Keeps a Qwen Realtime call (or wake listener) alive with a microphone FGS.
 * Channel `dsh/realtime_keep`. Events to Dart: `wake`, `hangUp`, `wakeError`.
 *
 * Wake is sticky: [signalWake] always stashes a pending payload so Dart can
 * [consumePendingWake] after the activity is back in front (小艺-style open).
 */
class RealtimeKeepPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {
    private lateinit var methods: MethodChannel
    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        bridge = this
        // Engine may attach after a wake while the process was still alive.
        pendingWake.get()?.let { emitNow("wake", it) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        if (bridge === this) bridge = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        takeOpenCall(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean = takeOpenCall(intent)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startCallKeep" -> {
                val title = call.argument<String>("title") ?: "Voice call"
                val text = call.argument<String>("text") ?: "Realtime call in progress"
                RealtimeCallService.start(app, title, text)
                result.success(null)
            }
            "stopCallKeep" -> {
                RealtimeCallService.stop(app)
                result.success(null)
            }
            "startWake" -> {
                val phrase = call.argument<String>("phrase")?.trim().orEmpty()
                if (phrase.isEmpty()) {
                    result.error("phrase", "wake phrase required", null)
                    return
                }
                RealtimeWakeService.start(app, phrase)
                result.success(null)
            }
            "stopWake" -> {
                RealtimeWakeService.stop(app)
                result.success(null)
            }
            "supported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            "wakeRunning" -> result.success(RealtimeWakeService.running)
            "consumePendingWake" -> {
                val held = pendingWake.getAndSet(null)
                result.success(held)
            }
            else -> result.notImplemented()
        }
    }

    /** Notification / cold-start intent: stash + emit (app is already coming forward). */
    private fun takeOpenCall(intent: Intent?): Boolean {
        if (intent == null) return false
        if (!intent.getBooleanExtra(RealtimeWakeService.EXTRA_OPEN_CALL, false)) return false
        if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return false
        intent.removeExtra(RealtimeWakeService.EXTRA_OPEN_CALL)
        val phrase = intent.getStringExtra(RealtimeWakeService.EXTRA_PHRASE).orEmpty().ifEmpty { "wake" }
        val heard = intent.getStringExtra(RealtimeWakeService.EXTRA_HEARD).orEmpty().ifEmpty { "notification" }
        stashAndEmit(phrase = phrase, heard = heard)
        return true
    }

    private fun emitNow(type: String, args: Map<String, Any?>) {
        main.post {
            runCatching { methods.invokeMethod("event", mapOf("type" to type) + args) }
                .onFailure { Log.w(TAG, "emit $type failed: ${it.message}") }
        }
    }

    companion object {
        const val CHANNEL = "dsh/realtime_keep"
        private const val TAG = "dsh.realtime"

        @Volatile
        private var bridge: RealtimeKeepPlugin? = null

        private val pendingWake = AtomicReference<Map<String, Any?>?>(null)

        fun emit(type: String, args: Map<String, Any?> = emptyMap()) {
            bridge?.emitNow(type, args) ?: Log.w(TAG, "emit dropped (no bridge): $type $args")
        }

        /** Stash + emit + bring the app forward so Flutter can open the call page. */
        fun signalWake(phrase: String, heard: String) {
            stashAndEmit(phrase = phrase, heard = heard)
            bringAppToFront()
        }

        private fun stashAndEmit(phrase: String, heard: String) {
            val payload = mapOf(
                "phrase" to phrase,
                "heard" to heard,
            )
            pendingWake.set(payload)
            Log.i(TAG, "wake signal phraseLen=${phrase.length} heardLen=${heard.length}")
            bridge?.emitNow("wake", payload)
        }

        private fun bringAppToFront() {
            val app = bridge?.app ?: return
            val intent = Intent(app, MainActivity::class.java)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                )
            runCatching { app.startActivity(intent) }
                .onFailure { Log.w(TAG, "bringToFront failed: ${it.message}") }
        }
    }
}
