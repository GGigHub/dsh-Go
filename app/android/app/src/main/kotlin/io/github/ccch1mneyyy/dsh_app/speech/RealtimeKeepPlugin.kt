package io.github.ccch1mneyyy.dsh_app.speech

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps a Qwen Realtime call alive with a microphone FGS.
 * Channel `dsh/realtime_keep`. Events to Dart: `hangUp`.
 */
class RealtimeKeepPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        bridge = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        if (bridge === this) bridge = null
    }

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
            "supported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            else -> result.notImplemented()
        }
    }

    private fun emitNow(type: String, args: Map<String, Any?> = emptyMap()) {
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

        fun emit(type: String, args: Map<String, Any?> = emptyMap()) {
            bridge?.emitNow(type, args) ?: Log.w(TAG, "emit dropped (no bridge): $type $args")
        }
    }
}
