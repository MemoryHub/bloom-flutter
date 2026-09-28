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

print("Swift 侧共享检查：\(checked) 项")
if failures.isEmpty {
    print("全部通过")
    exit(0)
}
for failure in failures { print("✗ \(failure)") }
exit(1)
