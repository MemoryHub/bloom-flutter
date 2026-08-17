package com.bloom.bloom

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import org.json.JSONArray

class BloomCarouselAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!BloomCarouselSchedule.applyLatestDueEntry(context, intent)) return

        val manager = AppWidgetManager.getInstance(context)
        listOf(
            BloomPortraitWidgetProvider::class.java,
            BloomSquareWidgetProvider::class.java,
            BloomLargeSquareWidgetProvider::class.java,
        ).forEach { provider ->
            val component = ComponentName(context, provider)
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) {
                when (provider) {
                    BloomPortraitWidgetProvider::class.java ->
                        BloomPortraitWidgetProvider().onUpdate(context, manager, ids)
                    BloomSquareWidgetProvider::class.java ->
                        BloomSquareWidgetProvider().onUpdate(context, manager, ids)
                    BloomLargeSquareWidgetProvider::class.java ->
                        BloomLargeSquareWidgetProvider().onUpdate(context, manager, ids)
                }
            }
        }
    }
}

/**
 * Applies the newest locally-prefetched carousel entry without starting
 * Flutter or touching the network. Widget providers also call this helper
 * before handling alarm-backed APPWIDGET_UPDATE broadcasts. This matters on
 * MIUI, which may drop a custom receiver after the user swipes the app away
 * while still allowing the system-recognized AppWidgetProvider to run.
 */
object BloomCarouselSchedule {
    fun applyLatestDueEntry(context: Context, intent: Intent): Boolean {
        val prefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
        val planId = intent.getIntExtra(
            "planId",
            prefs.getInt("scheduledCarouselPlanId", -1),
        )
        if (planId < 1 || prefs.getInt("scheduledCarouselPlanId", -1) != planId) {
            Log.i(TAG, "Ignoring stale carousel alarm: action=${intent.action} plan=$planId")
            return false
        }

        // MIUI and Doze may deliver an alarm after one or more later slots are
        // already due. Always resolve against the cached plan instead of using
        // the item embedded in this particular alarm; an old alarm must never
        // overwrite a newer image.
        val resolved = latestDueEntry(
            prefs.getString("scheduledCarouselEntries", null),
        ) ?: run {
            Log.w(TAG, "No due cached carousel entry for action=${intent.action}")
            return false
        }

        prefs.edit()
            .putString("mobileLocalPortraitPath", resolved["portraitPath"] as? String)
            .putString("mobileLocalSquarePath", resolved["squarePath"] as? String)
            .putString("mobileLocalLargeSquarePath", resolved["largeSquarePath"] as? String)
            .putString("originalPhotoPath", resolved["originalPhotoPath"] as? String)
            .putString("date", resolved["date"] as? String)
            .putInt("recommendationId", resolved["itemId"] as? Int ?: 0)
            .putString("captionZh", resolved["captionZh"] as? String)
            .putString("captionEn", resolved["captionEn"] as? String)
            .putString("capturedDateText", resolved["capturedDateText"] as? String)
            .putString("locationText", resolved["locationText"] as? String)
            .putString("mode", "carousel")
            .putLong("updatedAtMillis", System.currentTimeMillis())
            .apply()

        Log.i(
            TAG,
            "Applied cached carousel item=${resolved["itemId"]} action=${intent.action}",
        )
        return true
    }

    private const val TAG = "BloomCarousel"

    private fun latestDueEntry(raw: String?): Map<String, Any?>? {
        if (raw.isNullOrBlank()) return null
        val entries = try { JSONArray(raw) } catch (_: Exception) { return null }
        val now = System.currentTimeMillis()
        var selected: Map<String, Any?>? = null
        var selectedAt = Long.MIN_VALUE
        for (index in 0 until entries.length()) {
            val entry = entries.optJSONObject(index) ?: continue
            val displayAt = entry.optLong("displayAtMillis", Long.MAX_VALUE)
            if (displayAt > now || displayAt < selectedAt) continue
            selectedAt = displayAt
            selected = mapOf(
                "itemId" to entry.optInt("itemId", 0),
                "date" to entry.optString("date", null),
                "portraitPath" to entry.optString("portraitPath", null),
                "squarePath" to entry.optString("squarePath", null),
                "largeSquarePath" to entry.optString("largeSquarePath", null),
                "originalPhotoPath" to entry.optString("originalPhotoPath", null),
                "captionZh" to entry.optString("captionZh", null),
                "captionEn" to entry.optString("captionEn", null),
                "capturedDateText" to entry.optString("capturedDateText", null),
                "locationText" to entry.optString("locationText", null),
            )
        }
        return selected
    }
}
