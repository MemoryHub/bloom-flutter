import Foundation

// 用与 Dart、安卓完全相同的那一份共享向量验证 Swift 侧的规则。
// 用法：swiftc BloomSharedState.swift main.swift -o runner && ./runner <向量文件>
//
// 这个 runner 只依赖 Foundation，因此不需要模拟器：BloomSharedState.swift 里
// 放的正是「三端必须一致」的那部分逻辑。

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "test/vectors/carousel_vectors.json"
guard let data = FileManager.default.contents(atPath: path),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let groups = root["groups"] as? [[String: Any]]
else {
    print("无法读取共享向量: \(path)")
    exit(2)
}

var checked = 0
var failures: [String] = []

func check(_ condition: Bool, _ message: String) {
    checked += 1
    if !condition { failures.append(message) }
}

// ---- current_from_entries：三端共用的查表规则 ----
for group in groups {
    guard let rule = group["rule"] as? String, rule == "current_from_entries",
          let cases = group["cases"] as? [[String: Any]] else { continue }
    for testCase in cases {
        let description = testCase["description"] as? String ?? "(无描述)"
        guard let input = testCase["input"] as? [String: Any],
              let expected = testCase["expected"] as? [String: Any] else { continue }
        let entries = input["entries"] as? [[String: Any]] ?? []
        let now = (input["now_ms"] as? NSNumber)?.doubleValue ?? 0
        let entry = BloomCarouselRule.currentEntry(entries, nowMillis: now)
        let expectedId = (expected["item_id"] as? NSNumber)?.intValue
        let actualId = (entry?["item_id"] as? NSNumber)?.intValue
        check(
            expectedId == actualId,
            "[\(description)] 期望 \(expectedId.map(String.init) ?? "nil")，实际 \(actualId.map(String.init) ?? "nil")"
        )
    }
}

// ---- 栅格与闹钟辅助（安卓侧同样实现）----
let grid: [[String: Any]] = [
    ["slot_at_ms": 5000], ["slot_at_ms": 1000], ["slot_at_ms": 3000], ["slot_at_ms": 9000],
]
check(
    BloomCarouselRule.upcomingGridTimes(grid, nowMillis: 2000, limit: 8) == [3000, 5000, 9000],
    "[栅格未来时刻] 排序或过滤不符"
)
check(
    BloomCarouselRule.upcomingGridTimes(grid, nowMillis: 0, limit: 2) == [1000, 3000],
    "[栅格未来时刻上限] 未按上限截断"
)

// ---- 共享状态键名映射 ----
//
// Dart 写入 `carousel-state.json`，Swift 读它。键名一旦漂移，iOS 不会报错，
// 只会**静默读不到计划**（小组件不更新），因此必须在测试里钉死。
let fixture: [String: Any] = [
    "plan": ["plan_id": 152, "settings_hash": "h", "day": "2026-09-28"],
    "next_slot_at_ms": 1790567100000,
    "timeline_entries": [
        [
            "date_ms": 1790566800000,
            "item_id": 4481,
            "portrait_path": "/tmp/mobile-local-portrait-4481.png",
            "square_path": "/tmp/mobile-local-square-4481.png",
            "large_square_path": "/tmp/mobile-local-largeSquare-4481.png",
            "original_path": "/tmp/carousel-original-4481.photo",
            "date": "2026-09-28",
            "caption_zh": "中文文案",
            "caption_en": "caption",
            "captured_date_text": "2020-01-01",
            "location_text": "某地",
        ],
    ],
]

check(BloomSharedState.planId(fixture) == 152, "[状态] plan_id 读取不符")
check(BloomSharedState.nextSlotAt(fixture) == 1790567100000, "[状态] next_slot_at_ms 读取不符")
check(BloomSharedState.timelineEntries(fixture).count == 1, "[状态] timeline_entries 读取不符")

let items = BloomSharedState.planItems(from: fixture)
check(items.count == 1, "[映射] 条目数不符")
if let item = items.first {
    check((item["itemId"] as? NSNumber)?.intValue == 4481, "[映射] item_id → itemId 不符")
    check(
        (item["displayAtMillis"] as? NSNumber)?.doubleValue == 1790566800000,
        "[映射] date_ms → displayAtMillis 不符"
    )
    check(
        item["squarePath"] as? String == "/tmp/mobile-local-square-4481.png",
        "[映射] square_path → squarePath 不符"
    )
    check(
        item["largeSquarePath"] as? String == "/tmp/mobile-local-largeSquare-4481.png",
        "[映射] large_square_path → largeSquarePath 不符"
    )
    // 最容易写错的一条：`photoPath` 的语义是「需要套信纸排版的**原图**」，
    // 必须取 original_path，绝不能取 portrait_path（那张已经把文案画进像素）。
    check(
        item["photoPath"] as? String == "/tmp/carousel-original-4481.photo",
        "[映射] original_path → photoPath 不符"
    )
    check(
        item["photoPath"] as? String != "/tmp/mobile-local-portrait-4481.png",
        "[映射] 不得把已渲染的 portrait_path 当成原始照片"
    )
    check(item["captionZh"] as? String == "中文文案", "[映射] caption_zh → captionZh 不符")
    check(item["locationText"] as? String == "某地", "[映射] location_text → locationText 不符")
}

// 空状态必须安全降级，而不是崩掉。
check(BloomSharedState.planItems(from: nil).isEmpty, "[映射] 空状态应返回空数组")
check(
    BloomCarouselRule.currentEntry(
        BloomSharedState.timelineEntries(nil),
        nowMillis: 1
    ) == nil,
    "[查表] 空状态应返回 nil"
)

// ---- WidgetKit notification boundary: metadata/heartbeats are not new pictures ----
func reloadContent(_ state: [String: Any], mode: String = "carousel", renderer: String = "v1") -> Data? {
    BloomSharedState.reloadContent(state, mode: mode, rendererVersion: renderer)
}
let initialContent = reloadContent(fixture)
check(initialContent != nil, "[刷新内容] 完整时间线必须能生成稳定签名")
var heartbeat = fixture
heartbeat["revision"] = 9876
heartbeat["writer"] = "ios-widget-refill"
heartbeat["updated_at_ms"] = 123456
heartbeat["current_item_id"] = 4481
heartbeat["photos"] = [["item_id": 4481, "fetched_at_ms": 999999]]
heartbeat["grid"] = [["item_id": 4482, "slot_at_ms": 1790567700000]]
check(reloadContent(heartbeat) == initialContent, "[刷新去重] 心跳、仅元数据的栅格与修订号不应耗刷新额度")
var readyFuture = fixture
let futureEntry: [String: Any] = ["item_id": 4482, "asset_id": "asset-4482", "date_ms": 1790567700000,
    "square_path": "/tmp/mobile-local-square-4482.png", "caption_zh": "未来图"]
readyFuture["timeline_entries"] = BloomSharedState.timelineEntries(fixture) + [futureEntry]
let futureContent = reloadContent(readyFuture)
check(futureContent != initialContent, "[渐进发布] 一张未来图就绪应独立通知，不等后续慢图")
check(reloadContent(readyFuture) == futureContent, "[重复补货] 相同已就绪时间线不能重复消耗刷新额度")
check((BloomCarouselRule.currentEntry(BloomSharedState.timelineEntries(readyFuture), nowMillis: 1790567400000)?["item_id"] as? Int) == 4481,
    "[保持栅格] 通知未来图就绪不应把它提前显示")
var edited = fixture
var editedEntry = BloomSharedState.timelineEntries(fixture)[0]
editedEntry["caption_zh"] = "更新过的旁白"
edited["timeline_entries"] = [editedEntry]
check(reloadContent(edited) != initialContent, "[同图重绘] 旁白更改也须通知刷新")
var newPlan = fixture
newPlan["plan"] = ["plan_id": 153, "settings_hash": "h2", "day": "2026-09-28"]
check(reloadContent(newPlan) != initialContent, "[换代] 新计划不受旧刷新签名限制")
check(reloadContent(fixture, mode: "recommend") != initialContent, "[切模式] 推荐轮播变更须刷新")
check(reloadContent(fixture, renderer: "v2") != initialContent, "[排版升级] 渲染版本变更须刷新")

// Exercise the actual native progressive merge: a later download can remain
// absent while the first future entry is already available to the notifier.
let refillGrid: [[String: Any]] = [
    ["item_id": 4481, "slot_at_ms": 1790566800000],
    ["item_id": 4482, "asset_id": "asset-4482", "slot_at_ms": 1790567700000],
    ["item_id": 4483, "slot_at_ms": 1790568600000],
]
let mergedReady = BloomSharedState.merging(fixture, plan: fixture["plan"] as! [String: Any],
    grid: refillGrid, ready: [futureEntry], nowMillis: 1790567400000, serverNext: nil)
check(BloomSharedState.timelineEntries(mergedReady).count == 2,
    "[慢后续图] 第三项未下载不应挡住第二项进入共享时间线")
check(reloadContent(mergedReady) != initialContent,
    "[慢后续图] 首张就绪未来项无需等下一下载完成即可触发通知")
let repeatedReady = BloomSharedState.merging(mergedReady, plan: fixture["plan"] as! [String: Any],
    grid: refillGrid, ready: [], nowMillis: 1790567400000, serverNext: nil)
check(reloadContent(repeatedReady) == reloadContent(mergedReady),
    "[无变化补货] 实际合并修订增长不应导致重复reload")
let advancedReady = BloomSharedState.merging(mergedReady, plan: fixture["plan"] as! [String: Any],
    grid: refillGrid, ready: [], nowMillis: 1790567800000, serverNext: nil)
check((advancedReady["current_item_id"] as? Int) == 4482 && reloadContent(advancedReady) == reloadContent(mergedReady),
    "[到点播放] 已交付未来项按原时刻推进，不必重复请求同一时间线")

print("Swift 侧共享检查：\(checked) 项")
if failures.isEmpty {
    print("全部通过")
    exit(0)
}
for failure in failures { print("✗ \(failure)") }
exit(1)
