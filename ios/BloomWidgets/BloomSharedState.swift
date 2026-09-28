import Foundation

/// 与 Dart、安卓共用的查表规则。
///
/// **这个文件刻意只依赖 Foundation，不 import WidgetKit / SwiftUI。**
/// 这样它可以脱离模拟器，用 `swiftc` 直接在 macOS 上编译并跑共享测试向量，
/// 规则本身的正确性不必等到「装到手机上看看」才发现。
///
/// 三端（Dart / Kotlin / Swift）都必须对同一份
/// `test/vectors/carousel_vectors.json` 给出相同结果。任何一侧偏离，就表现为
/// 「App 和小组件显示两张不同照片」。
enum BloomCarouselRule {

    /// 此刻应当显示的条目：`timeline_entries` 中 `date_ms` 不晚于 [nowMillis] 的最后一条。
    ///
    /// 并列时取先出现的那条——Dart 侧按 `date_ms` 升序写入，且栅格时刻互不相同，
    /// 因此并列在实践中不会发生；这里与 Dart、安卓保持完全相同的取舍，
    /// 避免三端在边界上分叉。
    ///
    /// 返回 nil 表示列表尚未覆盖此刻（例如刚换代、照片还在下载），调用方应当
    /// **保持当前画面不变**，而不是清空或猜测。
    static func currentEntry(
        _ entries: [[String: Any]],
        nowMillis: Double
    ) -> [String: Any]? {
        var best: [String: Any]?
        var bestAt = -Double.greatestFiniteMagnitude
        for entry in entries {
            guard let at = (entry["date_ms"] as? NSNumber)?.doubleValue else { continue }
            if at > nowMillis { continue }
            if best == nil || at > bestAt {
                best = entry
                bestAt = at
            }
        }
        return best
    }

    /// 栅格中仍在未来的格子时刻（升序），最多 [limit] 个。
    static func upcomingGridTimes(
        _ grid: [[String: Any]],
        nowMillis: Double,
        limit: Int
    ) -> [Double] {
        let times = grid
            .compactMap { ($0["slot_at_ms"] as? NSNumber)?.doubleValue }
            .filter { $0 > nowMillis }
            .sorted()
        return Array(times.prefix(limit))
    }
}

/// 读取 Dart 单写者写下的权威状态 `carousel-state.json`。
///
/// 扩展**只读这张表，不做任何决策**：选哪一格、是否需要替补、下一格如何计算、
/// 缓存如何淘汰，全部由 Dart 的 tick 引擎在写入这份状态时已经决定。
enum BloomSharedState {
    /// 与 App、扩展两侧 entitlements 中的 App Group 必须一致。
    static let appGroup = "group.com.zhangbo.bloom.zb20260815"
    static let cacheDirectoryName = "widget-cache"
    static let fileName = "carousel-state.json"

    static func cacheDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return nil }
        return container.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    static func stateURL() -> URL? {
        cacheDirectory()?.appendingPathComponent(fileName)
    }

    /// 读取状态；文件缺失或损坏时返回 nil，绝不抛异常。
    static func load() -> [String: Any]? {
        guard let url = stateURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any]
        else { return nil }
        return object
    }

    static func timelineEntries(_ state: [String: Any]?) -> [[String: Any]] {
        (state?["timeline_entries"] as? [[String: Any]]) ?? []
    }

    static func grid(_ state: [String: Any]?) -> [[String: Any]] {
        (state?["grid"] as? [[String: Any]]) ?? []
    }

    /// 状态里的计划代次 `plan_id`。
    static func planId(_ state: [String: Any]?) -> Int {
        let plan = state?["plan"] as? [String: Any]
        return (plan?["plan_id"] as? NSNumber)?.intValue ?? 0
    }

    /// 状态里的「下次更新」绝对时间；缺失或为空时返回 nil。
    static func nextSlotAt(_ state: [String: Any]?) -> Double? {
        guard let value = state?["next_slot_at_ms"] as? NSNumber else { return nil }
        let at = value.doubleValue
        return at > 0 ? at : nil
    }

    /// 把共享状态的 `timeline_entries` 转成扩展内部使用的条目形状。
    ///
    /// 键名映射（snake_case → 扩展内部命名）：
    ///   * `item_id`            → `itemId`
    ///   * `date_ms`            → `displayAtMillis`
    ///   * `square_path`        → `squarePath`（Dart 已渲染好的信纸合成图）
    ///   * `large_square_path`  → `largeSquarePath`（同上）
    ///   * `original_path`      → `photoPath`（**原图**，仍需走信纸排版）
    ///
    /// 最后一条最容易写错：Dart 渲染出的 `portrait_path` 是**合成图**（文案已
    /// 画进像素里），而扩展的 `photoPath` 语义是「需要套信纸排版的原始照片」。
    /// 把两者混用会让文案消失——再套一次排版时已经没有文案的位置。
    ///
    /// 这个函数刻意放在 Foundation-only 文件里，好让 `tools/run_swift_vectors.sh`
    /// 直接验证映射；键名漂移本来会让 iOS **静默**读不到计划（不是报错，是
    /// 小组件不更新），只有测试能提前发现。
    static func planItems(from state: [String: Any]?) -> [[String: Any]] {
        timelineEntries(state).compactMap { entry in
            guard let itemID = (entry["item_id"] as? NSNumber)?.intValue,
                  let millis = (entry["date_ms"] as? NSNumber)?.doubleValue else {
                return nil
            }
            var item: [String: Any] = [
                "itemId": itemID,
                "displayAtMillis": millis,
            ]
            if let value = entry["square_path"] as? String, !value.isEmpty {
                item["squarePath"] = value
            }
            if let value = entry["large_square_path"] as? String, !value.isEmpty {
                item["largeSquarePath"] = value
            }
            if let value = entry["original_path"] as? String, !value.isEmpty {
                item["photoPath"] = value
            }
            if let value = entry["date"] as? String { item["date"] = value }
            if let value = entry["caption_zh"] as? String { item["captionZh"] = value }
            if let value = entry["caption_en"] as? String { item["captionEn"] = value }
            if let value = entry["captured_date_text"] as? String {
                item["capturedDateText"] = value
            }
            if let value = entry["location_text"] as? String {
                item["locationText"] = value
            }
            return item
        }
    }
}
