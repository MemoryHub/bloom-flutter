package com.bloom.widget_bridge

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * 读取 Dart 单写者写下的权威状态 `carousel-state.json`。
 *
 * **这个类只查表，不做决策。** 历史上安卓原生自己维护了一套选取逻辑
 * （`latestDueEntry` 的并列打破 + `lastShownItemId` 地板 + 防倒退判断），
 * iOS 扩展另有一套，Dart 还有一套——三处各拉各的、各决定各的，正是
 * 「App 和小组件显示两张不同照片」的根源。
 *
 * 现在唯一的决策者是 Dart 的 tick 引擎：它把「某一格到点后应当显示什么」
 * 烘焙成 `timeline_entries`，原生侧到点后只回答一个问题——
 * 「`date_ms` 不晚于此刻的最后一条是谁」。这条规则与 Dart 的
 * `currentEntryFromTimeline` 和 iOS 侧的实现完全一致，由共享测试向量
 * （`current_from_entries`）钉住。
 *
 * 文件位置与 Dart 的 `WidgetBridge.cacheDirectory()` 返回值一致：
 * 应用私有目录下的 `widget-cache/`。provider 与应用同进程，可直接读。
 */
object BloomCarouselState {
    private const val TAG = "BloomCarousel"
    private const val CACHE_DIR = "widget-cache"
    const val FILE_NAME = "carousel-state.json"

    fun stateFile(context: Context): File =
        File(File(context.filesDir, CACHE_DIR), FILE_NAME)

    /** 读取状态；文件缺失或损坏时返回 null，绝不抛异常。 */
    fun read(context: Context): JSONObject? {
        val file = stateFile(context)
        if (!file.exists()) return null
        return try {
            val raw = file.readText()
            if (raw.isBlank()) null else JSONObject(raw)
        } catch (error: Exception) {
            Log.w(TAG, "Unable to read carousel state", error)
            null
        }
    }

    /**
     * 此刻应当显示的条目：`timeline_entries` 中 `date_ms` 不晚于 [nowMs] 的最后一条。
     *
     * 并列时取先出现的那条——Dart 侧按 `date_ms` 升序写入，且栅格时刻互不相同，
     * 因此并列在实践中不会发生；这里保持与 Dart、iOS 完全相同的取舍，避免
     * 三端在边界上分叉。
     *
     * 返回 null 表示列表尚未覆盖此刻（例如刚换代、照片还在下载），调用方应当
     * **保持当前画面不变**，而不是清空或猜测。
     */
    fun currentEntry(context: Context, nowMs: Long): JSONObject? =
        currentEntry(read(context), nowMs)

    fun currentEntry(state: JSONObject?, nowMs: Long): JSONObject? {
        val entries = state?.optJSONArray("timeline_entries") ?: return null
        var best: JSONObject? = null
        var bestAt = Long.MIN_VALUE
        for (index in 0 until entries.length()) {
            val entry = entries.optJSONObject(index) ?: continue
            val at = entry.optLong("date_ms", Long.MIN_VALUE)
            if (at > nowMs) continue
            if (best == null || at > bestAt) {
                best = entry
                bestAt = at
            }
        }
        return best
    }

    /**
     * 栅格中仍在未来的格子时刻（升序），用于排闹钟。
     *
     * 只排前 [limit] 个：更远的格子在触发前一定会被新一次 tick 重排，排多了
     * 只是给系统添乱，而且 AlarmManager 对每应用有闹钟数量上限。
     */
    fun upcomingGridTimes(state: JSONObject?, nowMs: Long, limit: Int): List<Long> {
        val grid = state?.optJSONArray("grid") ?: return emptyList()
        val times = ArrayList<Long>()
        for (index in 0 until grid.length()) {
            val at = grid.optJSONObject(index)?.optLong("slot_at_ms", 0L) ?: 0L
            if (at > nowMs) times.add(at)
        }
        times.sort()
        return if (times.size <= limit) times else times.subList(0, limit)
    }

    /** 状态里的「下次更新」；缺失时为 null。 */
    fun nextSlotAt(state: JSONObject?): Long? {
        if (state == null || state.isNull("next_slot_at_ms")) return null
        val at = state.optLong("next_slot_at_ms", 0L)
        return if (at > 0L) at else null
    }

    /** 状态里的计划代次；用于日志与闹钟的陈旧判定。 */
    fun planId(state: JSONObject?): Int =
        state?.optJSONObject("plan")?.optInt("plan_id", 0) ?: 0
}
