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
     * 重排全部闹钟：清掉旧的，按当前状态重排。
     *
     * 每次 tick 提交后都会调用，因此这里必须是幂等的——重复调用不能留下
     * 悬空闹钟，否则一个旧闹钟会在错误的时间把小组件切到过期的一格。
     *
     * **但"幂等"不等于"可以先拆后不排"。** 只要这个函数排不出任何一个未来的
     * 闹钟，它就必须保留旧链：链一旦归零，在有人重新打开 App 之前，小组件再也
     * 不会动。真机踩过一次——重启瞬间 launcher 还没恢复小组件，
     * `getAppWidgetIds` 返回空，旧实现先 `cancelAll` 再 `return`，于是整条链被
     * 拆掉而且什么都没排；小组件一直停在上上格，直到 12 分钟后补货闹钟顺手把它
     * 救回来。
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
        val widgets = widgetTargets(context)

        // 当天栅格用尽时 `times` 是空的，此时唯一的排程依据是状态里的
        // `next_slot_at_ms`（服务端会把它滚到明天第一格）。旧实现在这种情况下
        // 什么都不排，于是每天窗口一结束闹钟链就被清零，第二天第一格永远不会
        // 自己到来——这条跨天路径本来就是为它准备的，只是从来没被调用过。
        val firstUpcoming = times.firstOrNull()
        val recoveryTarget = firstUpcoming ?: BloomCarouselState.nextSlotAt(state)

        if (recoveryTarget == null) {
            // 既没有未来格子、也没有跨天依据，说明状态本身是坏的。这时**保持现状**
            // 是唯一安全的动作：拆掉旧链只会让小组件更早定格。
            Log.i(
                TAG,
                "nothing to arm plan=$planId (no future slot, no next_slot_at_ms); " +
                    "keeping existing alarms",
            )
            return
        }

        cancelAll(context, alarmManager)

        // 格子闹钟必须携带 `EXTRA_APPWIDGET_IDS`，所以只有在真的看得到实例时才排。
        // 看不到实例**不等于**用户没有小组件：重启中、launcher 重载中都会短暂为空。
        var armed = 0
        if (widgets.isEmpty()) {
            Log.i(TAG, "no widget instances; arming refill only plan=$planId")
        } else {
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
        }

        // 补货/恢复闹钟：**不依赖小组件实例**，固定挂在第一个 provider 上。
        //
        // 广播目标是显式组件，系统照样投递、provider 也照常处理；而它做的事情与
        // 哪一个 family 收到无关——先 `applyLatestDueEntry` 落盘，再唤起 Dart 跑批。
        // 排在下一格之前一点点，好让照片在格子到来前就已落盘；若下一格近在眼前则
        // 退化为尽快唤醒一次。栅格用尽时，它同时充当"跨天恢复"闹钟。
        val refillAt = maxOf(now + 60_000L, recoveryTarget - REFILL_LEAD_MS)
        val refillComponent = refillComponent(context)
        val refillIds = widgets.firstOrNull { it.second == refillComponent }?.third ?: IntArray(0)
        val refill = PendingIntent.getBroadcast(
            context,
            REFILL_REQUEST_CODE,
            Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                .setComponent(refillComponent)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, refillIds)
                .putExtra(BLOOM_CAROUSEL_ALARM_EXTRA, true)
                .putExtra(BLOOM_CAROUSEL_REFILL_EXTRA, true)
                .putExtra("planId", planId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        setAlarm(alarmManager, refillAt, refill)
        Log.i(
            TAG,
            "armed plan=$planId slots=$armed nextSlot=${firstUpcoming ?: -1L} " +
                "recoveryTarget=$recoveryTarget refillAt=$refillAt widgets=${widgets.size}",
        )
    }

    /**
     * 取消本模块排出的全部闹钟。
     *
     * **固定覆盖全部三个 provider，不按"当前看得见的实例"来。** 实例可能刚刚
     * 消失（重启、launcher 重载），若只取消还看得见的那些，另一个 provider 名下
     * 的旧闹钟会留在系统里，在错误的时间把小组件切到过期的一格。补货闹钟同理：
     * 它固定挂在 [refillComponent] 上，取消就必须落在同一个组件上，否则旧的那颗
     * 永远取消不掉。
     */
    fun cancelAll(context: Context, alarmManager: AlarmManager? = null) {
        val manager = alarmManager
            ?: (context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)
            ?: return
        val components = PROVIDERS.map {
            ComponentName(context.packageName, "${context.packageName}.$it")
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
        cancel(context, manager, refillComponent(context), REFILL_REQUEST_CODE)
    }

    /** 补货/恢复闹钟固定挂在这个 provider 上，与实例是否存在无关。 */
    private fun refillComponent(context: Context): ComponentName =
        ComponentName(context.packageName, "${context.packageName}.${PROVIDERS.first()}")

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
