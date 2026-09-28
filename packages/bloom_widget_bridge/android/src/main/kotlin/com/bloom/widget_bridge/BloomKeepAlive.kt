package com.bloom.widget_bridge

import android.app.AlarmManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/**
 * 后台保活自检：告诉用户「还差哪个开关，小组件才能自己换图」。
 *
 * 背景：闹钟本身没问题（`dumpsys alarm` 里看到的是 `window=0` 的精确闹钟），
 * 真正会让它失效的是两件事，而且**两台机器坏在不同的地方**：
 *
 *   * **Android 12 起**，`SCHEDULE_EXACT_ALARM` 不再自动授予。targetSdk >= 34
 *     时默认就是拒绝的，于是代码里的 `setExactAndAllowWhileIdle` 静默退化成
 *     非精确闹钟，系统可以随意批处理、Doze 下能推迟十几分钟。
 *   * **厂商的省电管家**（小米的「上滑清理」）会**强制停止**应用，而应用一旦
 *     进入 stopped 状态，**它注册的所有 AlarmManager 闹钟都会被系统取消**。
 *     实测日志：`AutoStartManagerService: prepare force stop` /
 *     `Killing ... SwipeUpClean`，之后 16:42、16:45 两个闹钟直接不存在了。
 *
 * 这个列表**全部由数据描述**，界面不认识任何版本号：
 * 每项自己带「在哪些机器上适用」「怎么判断已开启」「跳到哪里去开」。
 * 因此 iOS 上三项的适用条件全为假，列表为空，界面自然什么都不渲染——
 * **不需要写任何 iOS 专属代码**。
 *
 * 判断能力上有一处必须诚实：**小米的自启动状态第三方读不到**
 * （`com.miui.securitycenter.provider` 会抛 SecurityException），
 * 所以那一项 [Item.satisfied] 是 null，界面显示「需手动确认」而不是伪造一个绿勾。
 */
object BloomKeepAlive {

    /**
     * @property satisfied true=已开启，false=未开启，**null=系统不提供查询接口**。
     * @property canOpen   是否有一个确认存在的页面可以跳过去。
     * @property steps     跳不过去时展示的手动步骤。
     */
    data class Item(
        val id: String,
        val title: String,
        val why: String,
        val satisfied: Boolean?,
        val canOpen: Boolean,
        val steps: String?,
        /** 状态读不到、需要用户手动确认一次（界面据此显示「确认已开启」）。 */
        val needsAck: Boolean,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "id" to id,
            "title" to title,
            "why" to why,
            "satisfied" to satisfied,
            "canOpen" to canOpen,
            "steps" to steps,
            "needsAck" to needsAck,
        )
    }

    /** 当前机器上**适用**的保活项，按重要性排序。不适用的项不会出现。 */
    fun items(context: Context): List<Item> =
        listOfNotNull(
            exactAlarm(context),
            batteryWhitelist(context),
            autostart(context),
        )

    /**
     * 「这台机器上有哪几项」——**纯函数**，不碰 Context，因此可以直接被单测覆盖。
     *
     * 这是整个保活功能里最该被测到的一段：它是唯一会因为「手机换成另一台」
     * 而改变行为的地方。界面完全由它的返回值驱动，所以测住它就等于测住了
     * 「小米5 出现哪几项、小米14 出现哪几项、非小米出现哪几项」。
     */
    fun applicableIds(
        sdkInt: Int,
        manufacturer: String,
        brand: String,
    ): List<String> = buildList {
        if (exactAlarmApplies(sdkInt)) add(ID_EXACT_ALARM)
        if (batteryApplies(sdkInt)) add(ID_BATTERY)
        if (isXiaomiFamily(manufacturer, brand)) add(ID_AUTOSTART)
    }

    /** 精确闹钟：Android 12（S）起才有这个权限；更早的系统本来就精确。 */
    fun exactAlarmApplies(sdkInt: Int): Boolean =
        sdkInt >= Build.VERSION_CODES.S

    /** 电池优化白名单：Android 6（M）起才有 Doze。 */
    fun batteryApplies(sdkInt: Int): Boolean =
        sdkInt >= Build.VERSION_CODES.M

    /** 小米系（含 Redmi / POCO）。纯函数，便于单测。 */
    fun isXiaomiFamily(manufacturer: String, brand: String): Boolean {
        val combined = "$manufacturer $brand".lowercase()
        return combined.contains("xiaomi") ||
            combined.contains("redmi") ||
            combined.contains("poco")
    }

    /**
     * 精确闹钟。Android 12（S）才有这个权限，12 以下本来就精确，所以不显示。
     *
     * **这一项是小手机型上最容易漏的**：targetSdk 35 的包在 Android 14 上
     * `canScheduleExactAlarms()` 默认返回 false。
     */
    private fun exactAlarm(context: Context): Item? {
        if (!exactAlarmApplies(Build.VERSION.SDK_INT)) return null
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        return Item(
            id = ID_EXACT_ALARM,
            title = "允许精确闹钟",
            why = "不开的话换图时间由系统凑批处理，可能晚十几分钟",
            satisfied = manager?.canScheduleExactAlarms() ?: false,
            canOpen = true,
            steps = null,
            needsAck = false,
        )
    }

    /**
     * 电池优化白名单。Android 6（M）起才有 Doze。
     *
     * `setExactAndAllowWhileIdle` 即使在 Doze 下也**每个应用最多 9~15 分钟
     * 才放行一次**，而轮播间隔就是 15 分钟——不做白名单等于卡在临界点上。
     */
    private fun batteryWhitelist(context: Context): Item? {
        if (!batteryApplies(Build.VERSION.SDK_INT)) return null
        val manager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return Item(
            id = ID_BATTERY,
            title = "允许后台不受限",
            why = "省电策略会把后台唤醒压到十几分钟一次",
            satisfied = manager?.isIgnoringBatteryOptimizations(context.packageName) ?: false,
            canOpen = true,
            steps = null,
            needsAck = false,
        )
    }

    /**
     * 厂商自启动。目前只有小米系（含 Redmi / POCO）有已知的跳转入口。
     *
     * 这是**唯一能防住「上滑清理＝强制停止」**的开关：小米在应用获得自启动
     * 权限后，上滑清理不再把它打进 stopped 状态，闹钟因此得以保留。
     *
     * 状态读不到，所以 [Item.satisfied] 是 null——界面必须显示「需手动确认」，
     * 不能替用户假装它已经开了。
     */
    private fun autostart(context: Context): Item? {
        if (!isXiaomiFamily(Build.MANUFACTURER, Build.BRAND)) return null
        return Item(
            id = ID_AUTOSTART,
            title = "允许后台自启动",
            why = "「上滑清理」会强制停止应用并取消全部闹钟；开了这个才不会",
            // **小米不提供查询接口**（securitycenter 的 provider 抛
            // SecurityException），所以只有用户自己确认过才算数。确认之前是
            // null（「需确认」），确认之后是 true（不再计入待开启）。
            // 不这么做的话这一项会永远显示「1 项待开启」，永远没有终点。
            satisfied = if (acknowledged(context, ID_AUTOSTART)) true else null,
            canOpen = autostartIntent(context) != null,
            steps = "设置 → 应用管理 → Bloom → 权限管理 → 自启动 → 打开",
            needsAck = !acknowledged(context, ID_AUTOSTART),
        )
    }

    /**
     * 小米自启动页。**必须先 resolve 再 start**：HyperOS 与 MIUI 各版本的
     * 路径并不一致，直接 startActivity 会抛 ActivityNotFoundException。
     */
    private fun autostartIntent(context: Context): Intent? {
        val intent = Intent().setComponent(
            ComponentName(MIUI_SECURITY_CENTER, MIUI_AUTOSTART_ACTIVITY)
        )
        return try {
            if (context.packageManager.resolveActivity(intent, 0) != null) intent else null
        } catch (error: Exception) {
            Log.w(TAG, "resolve autostart page failed", error)
            null
        }
    }

    /**
     * 用户确认「我已经开好了」。
     *
     * 只对 [Item.needsAck] 的项有意义——系统读不到状态的那些。存本地即可：
     * 这是用户的声明，不是我们探测出来的事实，所以不假装成探测结果。
     */
    fun acknowledge(context: Context, id: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(ackKey(id), true).apply()
    }

    private fun acknowledged(context: Context, id: String): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(ackKey(id), false)

    private fun ackKey(id: String) = "keepAliveAck_$id"

    private fun askedKey(id: String) = "keepAliveAsked_$id"

    /**
     * 缺精确闹钟权限时**主动申请一次**。返回 true 表示「现在有权限」。
     *
     * 清单里声明了 `SCHEDULE_EXACT_ALARM`，但**声明不等于授予**——Android 12 起
     * 它不再自动授予，targetSdk >= 34 更是默认关闭。[BloomCarouselAlarms] 因此在
     * 拿不到权限时降级成 `setAndAllowWhileIdle`（不精确），系统会把唤醒推迟到
     * 几分钟之后。
     *
     * 实测小米14（Android 16 / SDK 36）小组件比整点晚约 2 分钟才换图，而 iOS 不用
     * 闹钟、由 WidgetKit 精确重放烘焙好的时间线，所以准时——差异就出在这里。
     *
     * 只在**前台**调用（由 App 的同步路径触发），且只主动弹一次；用户拒绝过就不再
     * 打扰，改为由自检卡片持续展示。
     */
    fun ensureExactAlarm(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return true
        if (manager.canScheduleExactAlarms()) return true

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(askedKey(ID_EXACT_ALARM), false)) return false
        prefs.edit().putBoolean(askedKey(ID_EXACT_ALARM), true).apply()

        // 跳不过去也不要紧：自检卡片里还有「去开启」和文字步骤兜底。
        open(context, ID_EXACT_ALARM)
        return false
    }

    /** 跳到某一项的设置页。返回 false 表示**跳不过去**，界面应改展示 [Item.steps]。 */
    fun open(context: Context, id: String): Boolean {
        val intent = when (id) {
            ID_EXACT_ALARM -> Intent(
                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                Uri.parse("package:${context.packageName}"),
            )
            ID_BATTERY -> Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${context.packageName}"),
            )
            ID_AUTOSTART -> autostartIntent(context)
            else -> null
        } ?: return false
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (error: Exception) {
            // 厂商页面不存在或权限不足都归到这里：**失败要能被界面知道**，
            // 否则用户点了没反应，比没有这个按钮更糟。
            Log.w(TAG, "open keep-alive page failed id=$id", error)
            false
        }
    }

    const val ID_EXACT_ALARM = "exact_alarm"
    const val ID_BATTERY = "battery_whitelist"
    const val ID_AUTOSTART = "autostart"

    private const val MIUI_SECURITY_CENTER = "com.miui.securitycenter"
    private const val MIUI_AUTOSTART_ACTIVITY =
        "com.miui.permcenter.autostart.AutoStartManagementActivity"
    private const val PREFS = "bloom_widget"
    private const val TAG = "BloomKeepAlive"
}
