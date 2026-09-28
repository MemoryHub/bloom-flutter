package com.bloom.widget_bridge

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * 从权威状态排闹钟。
 *
 * 旧实现由 Dart 通过 `scheduleCarousel(planId, entries)` 把烘焙好的条目推给
 * 原生，原生再据此排闹钟。那条路径现在整条去掉了：状态文件本身就是唯一真相，
 * 原生直接读它排闹钟即可，Dart 侧只剩一个 `refreshWidgets()` 通知。
 *
 * 闹钟时刻取自状态的 `grid[].slot_at_ms`，而不是「已烘焙条目」的时刻——栅格
 * 是权威的排期，照片是否就绪由到点时的查表决定（没有照片就不切换）。
 */
object BloomCarouselAlarms {
    private const val TAG = "BloomCarousel"

    /**
     * 一次最多排多少个格子闹钟。
     *
     * 更远的格子在触发前一定会被新一次 tick 重排，排多了既无意义，又会撞上
     * AlarmManager 对每应用的闹钟数量限制。
     */
    private const val MAX_SLOT_ALARMS = 8

    private const val SLOT_REQUEST_BASE = 0x1000
    private const val REFILL_REQUEST_CODE = 0xB10

    // 与 App 模块 `com.bloom.bloom.BloomCarouselConstants` 中的取值必须一致。
    // 插件模块是 App 模块的依赖，方向反过来引用不到，因此这里各自持有常量；
    // 取值不同会让 provider 认不出闹钟，是排查起来很痛的故障。
    private const val BLOOM_CAROUSEL_ALARM_EXTRA = "bloomCarouselAlarm"
    private const val BLOOM_CAROUSEL_REFILL_EXTRA = "bloomCarouselRefill"

    /** 提前多少毫秒唤醒 Dart 去烘焙后续格子。 */
    private const val REFILL_LEAD_MS = 3 * 60_000L

    private val PROVIDERS = listOf(
        "BloomPortraitWidgetProvider",
        "BloomSquareWidgetProvider",
        "BloomLargeSquareWidgetProvider",
    )

    /**
     * 重排全部闹钟：先清掉旧的，再按当前状态重排。
     *
     * 每次 tick 提交后都会调用，因此这里必须是幂等的——重复调用不能留下
     * 悬空闹钟，否则一个旧闹钟会在错误的时间把小组件切到过期的一格。
     */
    fun arm(context: Context) {
        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val state = BloomCarouselState.read(context)
        if (state == null) {
            Log.i(TAG, "no carousel state yet; nothing to arm")
            cancelAll(context, alarmManager)
            return
        }

        val now = System.currentTimeMillis()
        val planId = BloomCarouselState.planId(state)
        val times = BloomCarouselState.upcomingGridTimes(state, now, MAX_SLOT_ALARMS)

        cancelAll(context, alarmManager)

        val widgets = widgetTargets(context)
        if (widgets.isEmpty()) {
            Log.i(TAG, "no widget instances; skip arming plan=$planId")
            return
        }

        var armed = 0
        times.forEachIndexed { index, at ->
            widgets.forEach { (familyIndex, component, widgetIds) ->
                val pending = slotPendingIntent(
                    context = context,
                    component = component,
                    widgetIds = widgetIds,
                    requestCode = SLOT_REQUEST_BASE + index * 10 + familyIndex,
                    planId = planId,
                )
                setAlarm(alarmManager, at, pending)
            }
            armed++
        }

        // 唤醒 Dart 去烘焙后续格子。排在下一格之前一点点，好让照片在格子到来
        // 前就已落盘；若下一格近在眼前则退化为尽快唤醒一次。
        val firstUpcoming = times.firstOrNull()
        if (firstUpcoming != null) {
            val refillAt = maxOf(now + 60_000L, firstUpcoming - REFILL_LEAD_MS)
            val (_, component, widgetIds) = widgets.first()
            val refill = PendingIntent.getBroadcast(
                context,
                REFILL_REQUEST_CODE,
                Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                    .setComponent(component)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
                    .putExtra(BLOOM_CAROUSEL_ALARM_EXTRA, true)
                    .putExtra(BLOOM_CAROUSEL_REFILL_EXTRA, true)
                    .putExtra("planId", planId),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            setAlarm(alarmManager, refillAt, refill)
            Log.i(
                TAG,
                "armed plan=$planId slots=${armed} nextSlot=$firstUpcoming refillAt=$refillAt",
            )
        } else {
            Log.i(TAG, "armed plan=$planId slots=0 (grid exhausted)")
        }
    }

    /** 取消本模块排出的全部闹钟。 */
    fun cancelAll(context: Context, alarmManager: AlarmManager? = null) {
        val manager = alarmManager
            ?: (context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)
            ?: return
        val widgets = widgetTargets(context)
        val components = if (widgets.isEmpty()) {
            PROVIDERS.map {
                ComponentName(context.packageName, "${context.packageName}.$it")
            }
        } else {
            widgets.map { it.second }
        }
        components.forEach { component ->
            for (index in 0 until MAX_SLOT_ALARMS) {
                for (familyIndex in 0..2) {
                    cancel(
                        context,
                        manager,
                        component,
                        SLOT_REQUEST_BASE + index * 10 + familyIndex,
                    )
                }
            }
        }
        if (components.isNotEmpty()) {
            cancel(context, manager, components.first(), REFILL_REQUEST_CODE)
        }
    }

    private fun cancel(
        context: Context,
        alarmManager: AlarmManager,
        component: ComponentName,
        requestCode: Int,
    ) {
        PendingIntent.getBroadcast(
            context,
            requestCode,
            Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).setComponent(component),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )?.let { pending ->
            alarmManager.cancel(pending)
            pending.cancel()
        }
    }

    private fun slotPendingIntent(
        context: Context,
        component: ComponentName,
        widgetIds: IntArray,
        requestCode: Int,
        planId: Int,
    ): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode,
        Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
            .setComponent(component)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
            // 标准 AppWidgetProvider 广播在小米上比自定义 receiver 更容易在
            // 用户上划清后台之后仍然收到。
            .putExtra(BLOOM_CAROUSEL_ALARM_EXTRA, true)
            .putExtra("planId", planId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun setAlarm(alarmManager: AlarmManager, at: Long, pending: PendingIntent) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                alarmManager.canScheduleExactAlarms()
            ) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            } else {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            }
        } catch (error: SecurityException) {
            // 没有精确闹钟权限时退化为非精确，绝不让 tick 因为排闹钟失败而中断。
            Log.w(TAG, "exact alarm denied at=$at; falling back", error)
            alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }

    private fun widgetTargets(context: Context): List<Triple<Int, ComponentName, IntArray>> {
        val manager = AppWidgetManager.getInstance(context)
        return PROVIDERS.mapIndexedNotNull { familyIndex, className ->
            val component =
                ComponentName(context.packageName, "${context.packageName}.$className")
            val ids = manager.getAppWidgetIds(component)
            if (ids.isEmpty()) null else Triple(familyIndex, component, ids)
        }
    }
}
