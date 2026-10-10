package com.bloom.bloom

import com.bloom.widget_bridge.BloomCarouselState
import com.bloom.widget_bridge.BloomCarouselAlarms
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * 安卓原生侧的查表规则，用**与 Dart、iOS 完全相同的那一份**共享测试向量验证。
 *
 * 这是「三端一致」唯一的硬证据：只要有人改坏了安卓侧的取舍（例如并列时改成
 * 取最后一条），这个测试立刻红，而不是等到用户发现 App 和小组件显示两张
 * 不同照片。
 *
 * 与 Dart 侧的分工：安卓不计算「下次更新」，也不决定计划栅格——那两件事由
 * Dart 的 tick 引擎独占。安卓只实现 `current_from_entries` 这一条规则。
 */
class CarouselVectorsTest {

    @Test
    fun `下一格已完整准备则到点后补货 缺图仍提前准备`() {
        val now = 1_000_000L
        val next = now + 15 * 60_000L
        assertEquals(next + 60_000L, BloomCarouselAlarms.refillAt(now, next, true))
        assertEquals(next - 180_000L, BloomCarouselAlarms.refillAt(now, next, false))
        assertEquals(next + 60_000L, BloomCarouselAlarms.refillAt(next - 30_000L, next, true))
        assertEquals(next + 30_000L, BloomCarouselAlarms.refillAt(next - 30_000L, next, false))
        val dir = java.nio.file.Files.createTempDirectory("bloom-refill-test-").toFile()
        try {
            val entry = JSONObject().put("date_ms", next)
            val state = JSONObject().put("timeline_entries", JSONArray().put(entry))
            val file = File(dir, "ready.photo").apply { writeBytes(byteArrayOf(1)) }
            listOf("original_path", "portrait_path", "square_path", "large_square_path").forEach { entry.put(it, file.absolutePath) }
            assertTrue(BloomCarouselAlarms.slotPrepared(state, next))
            assertEquals(false, BloomCarouselAlarms.slotPrepared(state, next + 60_000L))
            file.delete()
            assertEquals(false, BloomCarouselAlarms.slotPrepared(state, next))
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun vectors(): JSONObject {
        // JVM 单测的工作目录是模块目录 android/app。
        val file = File("../../test/vectors/carousel_vectors.json")
        if (!file.exists()) {
            fail("共享测试向量不存在: ${file.absolutePath}")
        }
        return JSONObject(file.readText())
    }

    private fun group(rule: String): JSONArray {
        val groups = vectors().getJSONArray("groups")
        for (index in 0 until groups.length()) {
            val candidate = groups.getJSONObject(index)
            if (candidate.getString("rule") == rule) {
                return candidate.getJSONArray("cases")
            }
        }
        fail("共享向量里没有分组: $rule")
        error("unreachable")
    }

    @Test
    fun `current_from_entries 与共享向量完全一致`() {
        val cases = group("current_from_entries")
        assertTrue("向量分组不能为空", cases.length() > 0)

        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val description = case.getString("description")
            val input = case.getJSONObject("input")
            val expected = case.getJSONObject("expected")

            val state = JSONObject().put(
                "timeline_entries",
                input.optJSONArray("entries") ?: JSONArray(),
            )
            val entry = BloomCarouselState.currentEntry(state, input.getLong("now_ms"))

            if (expected.isNull("item_id")) {
                assertNull("[$description] 应当没有可显示的条目", entry)
            } else {
                assertEquals(
                    "[$description] 选中的条目不符",
                    expected.getInt("item_id"),
                    entry?.optInt("item_id", 0),
                )
            }
        }
    }

    @Test
    fun `并列时刻取先出现的那条`() {
        val entries = JSONArray()
            .put(JSONObject().put("date_ms", 1000L).put("item_id", 41))
            .put(JSONObject().put("date_ms", 1000L).put("item_id", 42))
        val state = JSONObject().put("timeline_entries", entries)

        assertEquals(41, BloomCarouselState.currentEntry(state, 1500L)?.optInt("item_id"))
    }

    @Test
    fun `只在未来排闹钟，且按时间升序并受数量上限约束`() {
        val grid = JSONArray()
        .put(JSONObject().put("slot_at_ms", 5000L))
        .put(JSONObject().put("slot_at_ms", 1000L))
        .put(JSONObject().put("slot_at_ms", 3000L))
        .put(JSONObject().put("slot_at_ms", 9000L))
        val state = JSONObject().put("grid", grid)

        val times = BloomCarouselState.upcomingGridTimes(state, 2000L, 8)
        assertEquals(listOf(3000L, 5000L, 9000L), times)

        val limited = BloomCarouselState.upcomingGridTimes(state, 0L, 2)
        assertEquals(listOf(1000L, 3000L), limited)
    }

    @Test
    fun `状态文件缺失或损坏时不抛异常`() {
        assertNull(BloomCarouselState.currentEntry(null as JSONObject?, 1000L))
        assertNull(BloomCarouselState.nextSlotAt(null))
        assertTrue(BloomCarouselState.upcomingGridTimes(null, 0L, 4).isEmpty())
        assertEquals(0, BloomCarouselState.planId(null))
    }

    @Test
    fun `下次更新读取的是状态里的绝对时间`() {
        val state = JSONObject().put("next_slot_at_ms", 1790567100000L)
        assertEquals(1790567100000L, BloomCarouselState.nextSlotAt(state))

        val cleared = JSONObject().put("next_slot_at_ms", JSONObject.NULL)
        assertNull(BloomCarouselState.nextSlotAt(cleared))
    }
}
