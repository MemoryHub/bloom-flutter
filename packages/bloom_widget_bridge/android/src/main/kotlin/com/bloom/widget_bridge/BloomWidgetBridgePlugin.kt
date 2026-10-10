package com.bloom.widget_bridge

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Dart 与原生小组件之间的桥。
 *
 * 轮播部分已经收敛到「Dart 是唯一决策者」：条目不再由 Dart 推送
 * （旧的 `scheduleCarousel(planId, entries)` 整条路径删除），闹钟由原生直接
 * 读权威状态 `carousel-state.json` 推导（见 [BloomCarouselAlarms]）。因此这里
 * 只剩一个通知口：[refreshWidgets] —— 刷新 provider，并重排闹钟。
 */
class BloomWidgetBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.bloom/widget")
        channel.setMethodCallHandler(this)
        // 包替换会清掉 AlarmManager 里的闹钟但保留状态文件。引擎重新挂上时
        // 直接按状态重排一次，用户不必重新选模式、也不必重新下载照片。
        try {
            BloomCarouselAlarms.arm(context)
        } catch (error: Exception) {
            Log.w(TAG, "Unable to rebuild carousel alarms", error)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cacheDirectory" -> {
                val directory = File(context.filesDir, "widget-cache")
                directory.mkdirs()
                result.success(directory.absolutePath)
            }
            "resetAccountContent" -> {
                BloomCarouselAlarms.cancelAll(context)
                context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE).edit().clear().putBoolean("accountSignedOut", true).commit()
                val manager = AppWidgetManager.getInstance(context)
                listOf("BloomPortraitWidgetProvider" to "widget_portrait", "BloomSquareWidgetProvider" to "widget_square", "BloomLargeSquareWidgetProvider" to "widget_large_square").forEach { (provider, layout) ->
                    val component = ComponentName(context.packageName, "${context.packageName}.$provider")
                    val ids = manager.getAppWidgetIds(component)
                    if (ids.isNotEmpty()) {
                        val layoutId = context.resources.getIdentifier(layout, "layout", context.packageName)
                        val views = android.widget.RemoteViews(context.packageName, layoutId)
                        views.setTextViewText(context.resources.getIdentifier("widget_placeholder", "id", context.packageName), "请登录 Bloom")
                        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                        if (launch != null) {
                            val click = android.app.PendingIntent.getActivity(context, 1001, launch, android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE)
                            views.setOnClickPendingIntent(context.resources.getIdentifier("widget_root", "id", context.packageName), click)
                        }
                        manager.updateAppWidget(ids, views)
                        context.sendBroadcast(Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).setComponent(component)
                            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids).putExtra("bloomAccountReset", true))
                    }
                }
                result.success(null)
            }
            "updateWidgetCache" -> {
                val arguments = call.arguments as? Map<*, *>
                val prefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
                val recommendationId = (arguments?.get("recommendationId") as? Number)?.toInt() ?: 0
                val mode = arguments?.get("mode") as? String
                val editor = prefs.edit()
                    .putString("mobileLocalPortraitPath", arguments?.get("portraitPath") as? String)
                    .putString("mobileLocalSquarePath", arguments?.get("squarePath") as? String)
                    .putString("mobileLocalLargeSquarePath", arguments?.get("largeSquarePath") as? String)
                    .putString("originalPhotoPath", arguments?.get("originalPhotoPath") as? String)
                    .putString("date", arguments?.get("date") as? String)
                    .putInt("recommendationId", recommendationId)
                    .putString("captionZh", arguments?.get("captionZh") as? String)
                    .putString("captionEn", arguments?.get("captionEn") as? String)
                    .putString("capturedDateText", arguments?.get("capturedDateText") as? String)
                    .putString("locationText", arguments?.get("locationText") as? String)
                    .putString("mode", mode)
                    .putLong("updatedAtMillis", System.currentTimeMillis())
                editor.apply()
                refreshWidgets()
                result.success(null)
            }
            "refreshWidgets" -> {
                refreshWidgets()
                result.success(null)
            }
            // 保留方法名以免旧客户端调用报错；条目参数已不再使用，状态文件
            // 才是唯一真相。收到调用时按状态重排一次闹钟即可。
            "scheduleCarousel" -> {
                try {
                    BloomCarouselAlarms.arm(context)
                } catch (error: Exception) {
                    Log.w(TAG, "scheduleCarousel is deprecated; rearm failed", error)
                }
                result.success(null)
            }
            "clearCarouselSchedule" -> {
                BloomCarouselAlarms.cancelAll(context)
                context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
                    .edit().putInt("scheduledCarouselPlanId", -1).apply()
                result.success(null)
            }
            "readCurrentWidgetState" -> {
                val prefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
                // Read the same due timeline entry as the provider. AlarmManager
                // may be late; its preference projection is not a second clock.
                val due = if (prefs.getString("mode", null) != "recommend") {
                    BloomCarouselState.currentEntry(context, System.currentTimeMillis())?.takeIf {
                        File(it.optString("original_path", "")).isFile &&
                            File(it.optString("portrait_path", "")).isFile
                    }
                } else null
                if (due != null) {
                    fun text(key: String): String? = if (due.isNull(key)) null else due.optString(key, null)
                    result.success(mapOf(
                        "recommendationId" to due.optInt("item_id", 0),
                        "mode" to "carousel", "date" to text("date"),
                        "originalPhotoPath" to text("original_path"),
                        "portraitPath" to text("portrait_path"),
                        "squarePath" to text("square_path"),
                        "largeSquarePath" to text("large_square_path"),
                        "captionZh" to text("caption_zh"), "captionEn" to text("caption_en"),
                        "capturedDateText" to text("captured_date_text"),
                        "locationText" to text("location_text"),
                        "updatedAtMillis" to due.optLong("date_ms", 0L),
                    ))
                    return
                }
                val id = prefs.getInt("recommendationId", 0)
                if (id < 1) {
                    result.success(null)
                } else {
                    result.success(mapOf(
                        "recommendationId" to id,
                        "mode" to prefs.getString("mode", null),
                        "date" to prefs.getString("date", null),
                        "originalPhotoPath" to prefs.getString("originalPhotoPath", null),
                        "portraitPath" to prefs.getString("mobileLocalPortraitPath", null),
                        "squarePath" to prefs.getString("mobileLocalSquarePath", null),
                        "largeSquarePath" to prefs.getString("mobileLocalLargeSquarePath", null),
                        "captionZh" to prefs.getString("captionZh", null),
                        "captionEn" to prefs.getString("captionEn", null),
                        "capturedDateText" to prefs.getString("capturedDateText", null),
                        "locationText" to prefs.getString("locationText", null),
                        "updatedAtMillis" to prefs.getLong("updatedAtMillis", 0L),
                    ))
                }
            }
            "stableDeviceCredentials" -> {
                val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
                val identity = sha256("bloom-device-id-v2:$androidId")
                val token = sha256("bloom-device-token-v2:$androidId")
                result.success(mapOf(
                    "deviceId" to "bloom-mobile-${identity.take(32)}",
                    "deviceToken" to token,
                ))
            }
            // 设备身份镜像到"小组件读得到"的地方。
            //
            // Android 上是**空操作**：小组件换图跑在同一个进程的 Flutter 后台
            // isolate 里（workmanager 的 Dart 回调），它直接读 SharedPreferences，
            // 不存在第二个进程需要被通知的问题。
            //
            // iOS 上则必须做 —— 那边的 WidgetKit 扩展是独立进程、自己去拉
            // `/carousel/plan`，只认 App Group 里的令牌。这里保留同名方法是为了
            // 让 Dart 侧不必按平台分支。
            "writeDeviceCredentials" -> {
                val token = call.argument<String>("deviceToken")
                context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE).edit()
                    .putBoolean("accountSignedOut", token.isNullOrEmpty()).commit()
                result.success(null)
            }
            // 后台保活自检：哪些开关还没开，以及怎么去开。列表本身由原生按机型
            // 与系统版本推导，Dart 侧只负责渲染，不认识任何版本号。
            "keepAliveStatus" -> {
                result.success(BloomKeepAlive.items(context).map { it.toMap() })
            }
            "acknowledgeKeepAlive" -> {
                val id = call.argument<String>("id")
                if (id != null) BloomKeepAlive.acknowledge(context, id)
                result.success(null)
            }
            "openKeepAlive" -> {
                val id = call.argument<String>("id")
                result.success(id != null && BloomKeepAlive.open(context, id))
            }
            else -> result.notImplemented()
        }
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    /**
     * 刷新所有 provider，并按权威状态重排闹钟。
     *
     * 每次 tick 提交后 Dart 都会调用它，因此这里是幂等的：provider 刷新只是
     * 让画面跟上 prefs，闹钟重排只是让排期跟上栅格。
     */
    private fun refreshWidgets() {
        try {
            // 没有精确闹钟权限时，[BloomCarouselAlarms] 会降级成 `setAndAllowWhileIdle`，
            // 系统把唤醒推迟几分钟——实测小米14（Android 16）小组件比整点晚约 2 分钟，
            // 而 iOS 不用闹钟、精确重放烘焙时间线，所以准时。
            //
            // 这里是每次 tick 之后的**前台**路径，顺手补一次权限申请最自然。
            // 只主动弹一次；用户拒绝过就不再打扰，改由自检卡片持续展示。
            BloomKeepAlive.ensureExactAlarm(context)
            BloomCarouselAlarms.arm(context)
        } catch (error: Exception) {
            Log.w(TAG, "Unable to rearm carousel alarms", error)
        }
        // The provider deduplicates actual image bytes and size per widget.
        // A current-pointer stamp misses recommendation changes and cannot
        // suppress the independent refill-alarm/provider refresh paths.
        val manager = AppWidgetManager.getInstance(context)
        listOf("BloomPortraitWidgetProvider", "BloomSquareWidgetProvider", "BloomLargeSquareWidgetProvider").forEach { className ->
            val component = ComponentName(context.packageName, "${context.packageName}.$className")
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) {
                context.sendBroadcast(
                    Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                        .setComponent(component)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                        .putExtra("bloomContentOnly", true)
                )
            }
        }
    }

    private companion object {
        const val TAG = "BloomCarousel"
    }
}
