package com.bloom.bloom

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.fluttercommunity.workmanager.SharedPreferenceHelper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation

/**
 * Runs the already-registered Dart background callback directly from the
 * provider-targeted widget alarm. Xiaomi may reject WorkManager's
 * SystemJobService after the app is swiped away, while it still allows the
 * installed AppWidgetProvider to receive APPWIDGET_UPDATE.
 */
object BloomFlutterSync : MethodChannel.MethodCallHandler {
    private const val TAG = "BloomFlutterSync"
    private const val DART_TASK = "com.bloom.bloom.dailySync"
    private const val PAYLOAD_KEY = "be.tramckrijte.workmanager.INPUT_DATA"
    private const val DART_TASK_KEY = "be.tramckrijte.workmanager.DART_TASK"
    private const val CHANNEL = "be.tramckrijte.workmanager/background_channel_work_manager"
    private const val CHANNEL_INITIALIZED = "backgroundChannelInitialized"

    private val lock = Any()
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var finish: ((Boolean) -> Unit)? = null
    private var starting = false
    private var watchdog: Runnable? = null
    private val flutterLoader = FlutterLoader()

    fun start(context: Context, expectedPlanId: Int, onFinished: (Boolean) -> Unit) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
            if (expectedPlanId > 0 && prefs.getInt("scheduledCarouselPlanId", -1) != expectedPlanId) {
                onFinished(false)
                return
            }
            if (engine != null) {
                // A duplicate provider broadcast may arrive while the first
                // refill is still running. Do not leave its goAsync token
                // open; the first sync already owns the shared engine.
                onFinished(true)
                return
            }
            if (starting) {
                // The Flutter engine is being initialized for another alarm.
                // Keep this attempt retryable instead of claiming success.
                onFinished(false)
                return
            }
            val callbackHandle = SharedPreferenceHelper.getCallbackHandle(context)
            if (callbackHandle < 1L) {
                Log.w(TAG, "Dart background callback is not registered yet")
                onFinished(false)
                return
            }
            finish = onFinished
            starting = true

            // Construct the engine before resolving FlutterCallbackInformation.
            // lookupCallbackInformation() calls FlutterJNI native code, which
            // is unavailable until Flutter's native library has been loaded.
            // The previous order caused an UnsatisfiedLinkError when MIUI
            // delivered a widget alarm while the app process was cold.
            val newEngine = FlutterEngine(context.applicationContext)
            engine = newEngine
            val timeout = Runnable {
                synchronized(lock) {
                    if (engine !== newEngine) return@synchronized
                    Log.w(TAG, "Direct Dart carousel refill timed out; scheduling recovery")
                }
                stop(false)
            }
            watchdog = timeout
            Handler(Looper.getMainLooper()).postDelayed(timeout, 30_000L)
            if (!flutterLoader.initialized()) {
                flutterLoader.startInitialization(context)
            }
            flutterLoader.ensureInitializationCompleteAsync(
                context,
                null,
                Handler(Looper.getMainLooper()),
            ) {
                synchronized(lock) {
                    if (engine !== newEngine) return@ensureInitializationCompleteAsync
                    val callbackInfo = try {
                        FlutterCallbackInformation.lookupCallbackInformation(callbackHandle)
                    } catch (error: Throwable) {
                        Log.e(TAG, "Unable to resolve Dart callback handle", error)
                        null
                    }
                    if (callbackInfo == null) {
                        starting = false
                        stop(false)
                        return@ensureInitializationCompleteAsync
                    }
                    starting = false
                    val newChannel = MethodChannel(newEngine.dartExecutor, CHANNEL)
                    channel = newChannel
                    newChannel.setMethodCallHandler(this)
                    newEngine.dartExecutor.executeDartCallback(
                        DartExecutor.DartCallback(
                            context.applicationContext.assets,
                            flutterLoader.findAppBundlePath(),
                            callbackInfo,
                        ),
                    )
                }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != CHANNEL_INITIALIZED) {
            result.notImplemented()
            return
        }
        channel?.invokeMethod(
            "onResultSend",
            mapOf(DART_TASK_KEY to DART_TASK, PAYLOAD_KEY to null),
            object : MethodChannel.Result {
                override fun success(value: Any?) {
                    stop(value == true)
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    Log.e(TAG, "Dart background sync failed: $errorCode $errorMessage")
                    stop(false)
                }

                override fun notImplemented() {
                    stop(false)
                }
            },
        )
        result.success(null)
    }

    private fun stop(success: Boolean) {
        synchronized(lock) {
            watchdog?.let { Handler(Looper.getMainLooper()).removeCallbacks(it) }
            watchdog = null
            channel?.setMethodCallHandler(null)
            channel = null
            val oldEngine = engine
            engine = null
            val callback = finish
            finish = null
            Handler(Looper.getMainLooper()).post {
                oldEngine?.destroy()
                callback?.invoke(success)
            }
        }
        Log.i(TAG, "Direct Dart carousel refill finished success=$success")
    }
}
