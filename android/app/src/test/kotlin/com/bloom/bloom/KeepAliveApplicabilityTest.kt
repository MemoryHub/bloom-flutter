package com.bloom.bloom

import com.bloom.widget_bridge.BloomKeepAlive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「这台手机上会出现哪几项保活开关」。
 *
 * 这是整个保活功能里**唯一会因为换手机而改变行为**的地方，也是用户直接看到的
 * 内容——界面完全由它的返回值驱动。所以这里用真机档案钉住：
 * 小米5、小米14、非小米、以及一台老到没有 Doze 的机器。
 *
 * 之所以刻意做成不碰 Context 的纯函数，就是为了让这条测试能在 JVM 上跑，
 * 不需要 Robolectric、也不需要插着手机。
 */
class KeepAliveApplicabilityTest {

    private val exact = BloomKeepAlive.ID_EXACT_ALARM
    private val battery = BloomKeepAlive.ID_BATTERY
    private val autostart = BloomKeepAlive.ID_AUTOSTART

    @Test
    fun `小米5 Android 8 没有精确闹钟项 因为那个权限 Android 12 才有`() {
        // 真机档案：MI 5 / MIUI V10 / SDK 26。
        // 这一项不出现是对的——Android 12 以下本来就不存在这个权限，
        // 代码走 `SDK_INT < S` 分支，闹钟天然精确。列出来只会让用户困惑。
        val ids = BloomKeepAlive.applicableIds(
            sdkInt = 26,
            manufacturer = "Xiaomi",
            brand = "Xiaomi",
        )
        assertEquals(listOf(battery, autostart), ids)
        assertFalse("Android 8 不该出现精确闹钟项", ids.contains(exact))
    }

    @Test
    fun `小米14 Android 14 三项都要 精确闹钟是最容易漏的一项`() {
        // targetSdk 35 的包在 Android 14 上 canScheduleExactAlarms() 默认 false，
        // 闹钟会静默退化成非精确。这一项必须出现。
        val ids = BloomKeepAlive.applicableIds(
            sdkInt = 34,
            manufacturer = "Xiaomi",
            brand = "xiaomi",
        )
        assertEquals(listOf(exact, battery, autostart), ids)
    }

    @Test
    fun `非小米机型自动去掉自启动项`() {
        val ids = BloomKeepAlive.applicableIds(
            sdkInt = 34,
            manufacturer = "samsung",
            brand = "samsung",
        )
        // 换牌子不该出现小米的设置页——那会是一个点了没反应的按钮。
        assertEquals(listOf(exact, battery), ids)
        assertFalse(ids.contains(autostart))
    }

    @Test
    fun `Android 5 太老 没有任何一项`() {
        // 没有 Doze（M 才有），也没有精确闹钟权限（S 才有），更不是小米。
        // iOS 走的也是这条路径之外的另一条：原生侧根本不会返回项。
        assertEquals(
            emptyList<String>(),
            BloomKeepAlive.applicableIds(
                sdkInt = 21,
                manufacturer = "LGE",
                brand = "lge",
            ),
        )
    }

    @Test
    fun `Redmi 与 POCO 都算小米系 大小写不敏感`() {
        assertTrue(BloomKeepAlive.isXiaomiFamily("Xiaomi", "Redmi"))
        assertTrue(BloomKeepAlive.isXiaomiFamily("Xiaomi", "POCO"))
        assertTrue(BloomKeepAlive.isXiaomiFamily("xiaomi", "redmi"))
        assertTrue(BloomKeepAlive.isXiaomiFamily("XIAOMI", "XIAOMI"))
        assertFalse(BloomKeepAlive.isXiaomiFamily("HUAWEI", "HUAWEI"))
        assertFalse(BloomKeepAlive.isXiaomiFamily("OPPO", "realme"))
    }

    @Test
    fun `两个系统版本的边界精确落在 S 与 M 上`() {
        // 边界写成 >= 而不是 >：差一版就会让整项在该出现时不出现。
        assertFalse(BloomKeepAlive.exactAlarmApplies(30)) // Android 11
        assertTrue(BloomKeepAlive.exactAlarmApplies(31))  // Android 12
        assertFalse(BloomKeepAlive.batteryApplies(22))    // Android 5.1
        assertTrue(BloomKeepAlive.batteryApplies(23))     // Android 6
    }

    @Test
    fun `每一项的 id 都稳定 界面靠它派发跳转`() {
        // 这三个字符串同时是 MethodChannel 的 openKeepAlive 参数值，
        // 改了就会让界面上的按钮跳错页面。
        assertEquals("exact_alarm", exact)
        assertEquals("battery_whitelist", battery)
        assertEquals("autostart", autostart)
    }
}
