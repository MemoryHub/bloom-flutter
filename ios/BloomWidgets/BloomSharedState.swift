import Foundation
import Darwin

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

/// App 与小组件共用的权威状态。补货入口可以来自 Flutter 或 WidgetKit，
/// 但只能在同一批次锁和状态锁内提交；播放始终使用同一条 currentEntry 规则。
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

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    /// Pure merge used by native refill. No second current-item table: both
    /// readers choose the latest ready entry whose server time has arrived.
    static func merging(
        _ state: [String: Any], plan: [String: Any], grid: [[String: Any]],
        ready: [[String: Any]], nowMillis: Double, serverNext: Double?
    ) -> [String: Any] {
        let oldEntries = timelineEntries(state)
        let oldDue = BloomCarouselRule.currentEntry(oldEntries, nowMillis: nowMillis)
        let fallbackID = (oldDue?["item_id"] as? NSNumber)?.intValue
            ?? (state["current_item_id"] as? NSNumber)?.intValue
        let pointerID = (state["current_item_id"] as? NSNumber)?.intValue
        let previousID = fallbackID != pointerID ? pointerID
            : (state["previous_item_id"] as? NSNumber)?.intValue
        let existingPhotos = (state["photos"] as? [[String: Any]]) ?? []
        let readyIDs = Set(ready.compactMap { ($0["item_id"] as? NSNumber)?.intValue })
        var entries = oldEntries.filter { entry in
            guard let id = (entry["item_id"] as? NSNumber)?.intValue, !readyIDs.contains(id) else { return false }
            if id == fallbackID || id == previousID { return true }
            return grid.contains { slot in
                (slot["item_id"] as? NSNumber)?.intValue == id &&
                slot["asset_id"] as? String == (entry["asset_id"] as? String ?? existingPhotos.first { ($0["item_id"] as? NSNumber)?.intValue == id }?["asset_id"] as? String)
            }
        }
        entries += ready
        entries.sort { (($0["date_ms"] as? NSNumber)?.doubleValue ?? 0) < (($1["date_ms"] as? NSNumber)?.doubleValue ?? 0) }
        let due = BloomCarouselRule.currentEntry(entries, nowMillis: nowMillis)
        let id = (due?["item_id"] as? NSNumber)?.intValue ?? fallbackID
        let previous = id != fallbackID ? fallbackID : previousID
        let future = entries.filter { (($0["date_ms"] as? NSNumber)?.doubleValue ?? 0) > nowMillis }.prefix(4)
        let keepIDs = Set(future.compactMap { ($0["item_id"] as? NSNumber)?.intValue } + [id, previous].compactMap { $0 })
        entries = entries.filter { keepIDs.contains(($0["item_id"] as? NSNumber)?.intValue ?? 0) }
        let photos: [[String: Any]] = entries.map { entry in
            let entryID = (entry["item_id"] as? NSNumber)?.intValue ?? 0
            let old = existingPhotos.first { ($0["item_id"] as? NSNumber)?.intValue == entryID }
            return [
                "item_id": entryID,
                "asset_id": entry["asset_id"] ?? old?["asset_id"] ?? "",
                "path": entry["portrait_path"] ?? entry["original_path"] ?? "",
                "etag": old?["etag"] ?? NSNull(),
                "fetched_at_ms": old?["fetched_at_ms"] ?? Int(nowMillis),
            ]
        }
        let next = BloomCarouselRule.upcomingGridTimes(grid, nowMillis: nowMillis, limit: 1).first
            ?? (serverNext.flatMap { $0 > nowMillis ? $0 : nil })
        let currentSlot = grid.last { (($0["slot_at_ms"] as? NSNumber)?.doubleValue ?? 0) <= nowMillis }
        let dueID = (currentSlot?["item_id"] as? NSNumber)?.intValue
        var result = state
        result["plan"] = plan
        result["grid"] = grid
        result["timeline_entries"] = entries
        result["photos"] = photos
        result["current_item_id"] = id ?? 0
        result["current_photo_path"] = due?["portrait_path"] ?? state["current_photo_path"] ?? NSNull()
        result["current_slot_at_ms"] = currentSlot?["slot_at_ms"] ?? state["current_slot_at_ms"] ?? NSNull()
        result["previous_item_id"] = previous.map { $0 as Any } ?? NSNull()
        result["previous_photo_path"] = photos.first { ($0["item_id"] as? NSNumber)?.intValue == previous }?["path"] ?? NSNull()
        result["current_status"] = dueID == nil || dueID == id ? "ok" : "download_failed"
        result["next_slot_at_ms"] = next.map { Int($0) as Any } ?? NSNull()
        result["next_slot_source"] = "plan"
        result["revision"] = ((state["revision"] as? NSNumber)?.intValue ?? 0) + 1
        result["updated_at_ms"] = Int(nowMillis)
        result["writer"] = "ios-widget-refill"
        return result
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
            item["sourceName"] = entry["source_name"] ?? "personal"
            item["artwork"] = entry["content_snapshot"] ?? [:]
            item["photoMetadata"] = entry["photo_metadata"] ?? [:]
            return item
        }
    }
}

/// O_EXCL matches CarouselLock in Dart. No advisory flock: that would not
/// exclude Dart's file-create lock. Holds only short publications/preparations.
final class BloomSharedFileLock {
    private let url: URL
    private var held = false
    private let owner = "\(getpid()):\(UUID().uuidString)"
    private(set) var failureDescription = ""
    init(_ url: URL) { self.url = url }
    func acquire() -> Bool {
        for attempt in 0..<2 {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            if fd >= 0 {
                let bytes = Array(owner.utf8)
                _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
                close(fd)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                held = true
                return true
            }
            let openError = errno
            var attributes = stat()
            let present = lstat(url.path, &attributes) == 0
            let age = present ? Date().timeIntervalSince1970 - Double(attributes.st_mtimespec.tv_sec) : 0
            failureDescription = "errno=\(openError) age=\(Int(age))s"
            let existingOwner = try? String(contentsOf: url, encoding: .utf8)
            let ownerPID = existingOwner?.split(separator: ":").first.flatMap { Int32($0) }
            let ownerExited = ownerPID.map { $0 > 0 && kill($0, 0) == -1 && errno == ESRCH } ?? false
            if attempt == 0, openError == EEXIST, present, age > 90 || ownerExited {
                // Read POSIX timestamps directly: URL resource metadata can be
                // cached across extension suspension. An interrupted owner
                // leaves no heartbeat, so the next pass can recover it.
                // A killed Dart/native owner can be reclaimed immediately;
                // an existing owner (including EPERM) must never be stolen.
                guard unlink(url.path) == 0 || errno == ENOENT else {
                    failureDescription += " unlink=\(errno)"; return false
                }
                continue
            }
            return false
        }
        return false
    }
    func isHeld() -> Bool {
        held && (try? String(contentsOf: url, encoding: .utf8)) == owner
    }

    func release() {
        if held, (try? String(contentsOf: url, encoding: .utf8)) == owner {
            try? FileManager.default.removeItem(at: url)
        }
        held = false
    }
    deinit { release() }
}
