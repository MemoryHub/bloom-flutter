package com.bloom.bloom

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import com.bloom.widget_bridge.BloomCarouselAlarms
import com.bloom.widget_bridge.BloomCarouselState
import java.io.File

/**
 * 格子到点。只做两件事：查表上屏、刷新 provider。
 *
 * **这里不再有任何选取逻辑。** 旧实现自带一套 `latestDueEntry`：在已烘焙的
 * 条目里挑「最晚的一个已到点条目」，还要处理并列打破（取最大 itemId）与
 * 「不得倒退到已看过的照片」（`lastShownItemId` 地板）。那套启发式与 iOS、
 * Dart 各自的实现互不相同，正是「App 和小组件显示两张不同照片」以及
 * 「刚切换完几分钟又变一张」的来源。
 *
 * 现在唯一的决策者是 Dart 的 tick 引擎；原生侧只回答「`date_ms` 不晚于此刻
 * 的最后一条是谁」，与 iOS 完全同一条规则（共享向量 `current_from_entries`）。
 */
class BloomCarouselAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            intent.action == Intent.ACTION_BOOT_COMPLETED) {
            // 包替换与设备重启都要重建闹钟链，不必等用户打开 App。
            try {
                BloomWidgetRefresh.prepareCarouselRecoveryAfterRestart(context)
                BloomWidgetRefresh.enqueueRecoveryAfterRestart(context)
            } catch (error: Exception) {
                Log.w(TAG, "carousel recovery after restart failed", error)
            }
            try {
                // 闹钟由权威状态的栅格推导，重启后直接重排即可，不需要
                // Dart 重新推送任何东西。
                BloomCarouselAlarms.arm(context)
            } catch (error: Exception) {
                Log.w(TAG, "Unable to rebuild carousel alarms", error)
            }
        }
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

    private companion object {
        const val TAG = "BloomCarousel"
    }
}

/**
 * 把权威状态里「此刻该显示的那一条」搬到 provider 读取的 prefs 上。
 *
 * provider 也在这里被调用（小米可能在用户上划清后台后丢掉自定义 receiver，
 * 但系统识别的 AppWidgetProvider 仍会运行）。
 */
object BloomCarouselSchedule {
    private const val TAG = "BloomCarousel"
    private const val PREFS = "bloom_widget"

    /**
     * @return 是否值得继续刷新 provider。返回 false 表示此刻没有可显示的条目，
     *         保持画面不变即可。
     */
    fun applyLatestDueEntry(context: Context, intent: Intent? = null): Boolean {
        val now = System.currentTimeMillis()
        val entry = BloomCarouselState.currentEntry(context, now)
        if (entry == null) {
            Log.i(
                TAG,
                "no baked entry covers now action=${intent?.action} now=$now; keeping current",
            )
            return false
        }

        val itemId = entry.optInt("item_id", 0)
        val portrait = entry.nullableString("portrait_path")
        val original = entry.nullableString("original_path")

        // 宁可显示上一张，也不显示空图。文件不在就保持当前画面，但仍然返回
        // true，让 provider 跑一次顺带触发补货——缺失的那张会在下一次 tick
        // 补上。
        val candidates = listOfNotNull(portrait, original)
        if (candidates.isEmpty() || candidates.none { File(it).exists() }) {
            Log.i(TAG, "due item=$itemId has no image on disk; keeping current")
            return true
        }

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val editor = prefs.edit()
            .putString("mobileLocalPortraitPath", portrait)
            .putString("mobileLocalSquarePath", entry.nullableString("square_path"))
            .putString(
                "mobileLocalLargeSquarePath",
                entry.nullableString("large_square_path"),
            )
            .putString("originalPhotoPath", original)
            .putString("date", entry.nullableString("date"))
            .putInt("recommendationId", itemId)
            .putString("captionZh", entry.nullableString("caption_zh"))
            .putString("captionEn", entry.nullableString("caption_en"))
            .putString("capturedDateText", entry.nullableString("captured_date_text"))
            .putString("locationText", entry.nullableString("location_text"))
            .putString("mode", "carousel")
            .putLong("updatedAtMillis", now)
        editor.apply()

        Log.i(
            TAG,
            "applied item=$itemId at=${entry.optLong("date_ms", 0L)} now=$now " +
                "action=${intent?.action}",
        )
        return true
    }

    private fun org.json.JSONObject.nullableString(key: String): String? {
        if (isNull(key)) return null
        val value = optString(key, "")
        return value.ifEmpty { null }
    }
}
