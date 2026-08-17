package com.bloom.widget_bridge

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import android.provider.Settings
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

class BloomWidgetBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.bloom/widget")
        channel.setMethodCallHandler(this)
        // Package replacement preserves SharedPreferences and AlarmManager
        // entries. Convert a previously cached plan to provider-targeted
        // alarms as soon as the new engine attaches, without asking the user
        // to reselect carousel mode or download the photos again.
        try {
            rescheduleStoredCarousel()
        } catch (error: Exception) {
            Log.w(TAG, "Unable to migrate stored carousel alarms", error)
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
            "updateWidgetCache" -> {
                val arguments = call.arguments as? Map<*, *>
                context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
                    .edit()
                    .putString("mobileLocalPortraitPath", arguments?.get("portraitPath") as? String)
                    .putString("mobileLocalSquarePath", arguments?.get("squarePath") as? String)
                    .putString("mobileLocalLargeSquarePath", arguments?.get("largeSquarePath") as? String)
                    .putString("originalPhotoPath", arguments?.get("originalPhotoPath") as? String)
                    .putString("date", arguments?.get("date") as? String)
                    .putInt("recommendationId", (arguments?.get("recommendationId") as? Number)?.toInt() ?: 0)
                    .putString("captionZh", arguments?.get("captionZh") as? String)
                    .putString("captionEn", arguments?.get("captionEn") as? String)
                    .putString("capturedDateText", arguments?.get("capturedDateText") as? String)
                    .putString("locationText", arguments?.get("locationText") as? String)
                    .putString("mode", arguments?.get("mode") as? String)
                    .putLong("updatedAtMillis", System.currentTimeMillis())
                    .apply()
                refreshWidgets()
                result.success(null)
            }
            "refreshWidgets" -> {
                refreshWidgets()
                result.success(null)
            }
            "scheduleCarousel" -> {
                val arguments = call.arguments as? Map<*, *>
                val planId = (arguments?.get("planId") as? Number)?.toInt()
                val entries = arguments?.get("entries") as? List<*>
                if (planId == null || entries == null) {
                    result.error("invalid_carousel_plan", null, null)
                } else {
                    scheduleCarousel(planId, entries)
                    result.success(null)
                }
            }
            "clearCarouselSchedule" -> {
                context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
                    .edit().putInt("scheduledCarouselPlanId", -1).apply()
                result.success(null)
            }
            "readCurrentWidgetState" -> {
                val prefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
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
            else -> result.notImplemented()
        }
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    private fun scheduleCarousel(planId: Int, entries: List<*>) {
        val storedEntries = JSONArray()
        entries.forEach { raw ->
            val entry = raw as? Map<*, *> ?: return@forEach
            storedEntries.put(
                JSONObject()
                    .put("itemId", (entry["itemId"] as? Number)?.toInt())
                    .put("displayAtMillis", (entry["displayAtMillis"] as? Number)?.toLong())
                    .put("date", entry["date"] as? String)
                    .put("portraitPath", entry["portraitPath"] as? String)
                    .put("squarePath", entry["squarePath"] as? String)
                    .put("largeSquarePath", entry["largeSquarePath"] as? String)
                    .put("originalPhotoPath", entry["originalPhotoPath"] as? String)
                    .put("captionZh", entry["captionZh"] as? String)
                    .put("captionEn", entry["captionEn"] as? String)
                    .put("capturedDateText", entry["capturedDateText"] as? String)
                    .put("locationText", entry["locationText"] as? String)
            )
        }
        context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
            .edit()
            .putInt("scheduledCarouselPlanId", planId)
            .putString("scheduledCarouselEntries", storedEntries.toString())
            .apply()
        scheduleWidgetAlarms(planId, storedEntries)
    }

    private fun rescheduleStoredCarousel() {
        val prefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
        val planId = prefs.getInt("scheduledCarouselPlanId", -1)
        val rawEntries = prefs.getString("scheduledCarouselEntries", null)
        if (planId < 1 || rawEntries.isNullOrBlank()) return
        scheduleWidgetAlarms(planId, JSONArray(rawEntries))
    }

    private fun scheduleWidgetAlarms(planId: Int, entries: JSONArray) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val widgetManager = AppWidgetManager.getInstance(context)
        val widgetProviders = listOf(
            "BloomPortraitWidgetProvider",
            "BloomSquareWidgetProvider",
            "BloomLargeSquareWidgetProvider",
        ).mapIndexedNotNull { familyIndex, className ->
            val component = ComponentName(context.packageName, "${context.packageName}.$className")
            val widgetIds = widgetManager.getAppWidgetIds(component)
            if (widgetIds.isEmpty()) null else Triple(familyIndex, component, widgetIds)
        }
        val now = System.currentTimeMillis()
        for (entryIndex in 0 until entries.length()) {
            val entry = entries.optJSONObject(entryIndex) ?: continue
            val itemId = entry.optInt("itemId", 0)
            val displayAt = entry.optLong("displayAtMillis", 0L)
            if (itemId < 1 || displayAt < 1L) continue

            // Remove alarms created by version 9015 and earlier. Those target
            // a custom receiver that MIUI can suppress after SwipeUpClean.
            val legacyIntent = Intent("com.bloom.bloom.CAROUSEL_ALARM")
                .setPackage(context.packageName)
            PendingIntent.getBroadcast(
                context,
                itemId,
                legacyIntent,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
            )?.let { legacyPending ->
                alarmManager.cancel(legacyPending)
                legacyPending.cancel()
            }

            if (displayAt <= now + 5_000L) continue
            widgetProviders.forEach { (familyIndex, component, widgetIds) ->
                // Xiaomi may refuse to start a custom receiver after the user
                // swipes the app away. A standard, explicit APPWIDGET_UPDATE
                // directed at the installed provider remains eligible to run.
                val intent = Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                    .setComponent(component)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
                    .putExtra("bloomCarouselAlarm", true)
                    .putExtra("planId", planId)
                    .putExtra("itemId", itemId)
                val requestCode = itemId * 10 + familyIndex
                val pending = PendingIntent.getBroadcast(
                    context,
                    requestCode,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                // The image is already local, so this alarm performs no network
                // or Flutter work.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()) {
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        displayAt,
                        pending,
                    )
                    Log.i(TAG, "Scheduled exact widget alarm item=$itemId family=$familyIndex at=$displayAt")
                } else {
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        displayAt,
                        pending,
                    )
                    Log.i(TAG, "Scheduled fallback widget alarm item=$itemId family=$familyIndex at=$displayAt")
                }
            }
        }
    }

    private fun refreshWidgets() {
        val manager = AppWidgetManager.getInstance(context)
        listOf("BloomPortraitWidgetProvider", "BloomSquareWidgetProvider", "BloomLargeSquareWidgetProvider").forEach { className ->
            val component = ComponentName(context.packageName, "${context.packageName}.$className")
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) {
                context.sendBroadcast(
                    Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                        .setComponent(component)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                )
            }
        }
    }

    private companion object {
        const val TAG = "BloomCarousel"
    }
}
