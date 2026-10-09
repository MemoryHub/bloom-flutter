import SwiftUI
import WidgetKit
import CoreText
import ImageIO

private let bloomAppGroup = "group.com.zhangbo.bloom.zb20260815"
private let bloomBaseURL = URL(string: "https://bloom.jihu.top")!

struct BloomEntry: TimelineEntry {
  let date: Date
  let compositeImage: UIImage?
  let photoImage: UIImage?
  let captionZh: String?
  let captionEn: String?
  let capturedDateText: String?
  let locationText: String?
  // The plan item this entry was built from, when known. It is how an entry is
  // matched against the shared state's `current_item_id` — the shared state
  // decides which slot is on the wall, this id is the join key. Recommendation
  // mode entries have no such id and leave it `nil`.
  let itemID: Int?

  init(
    date: Date,
    compositeImage: UIImage?,
    photoImage: UIImage?,
    captionZh: String?,
    captionEn: String?,
    capturedDateText: String?,
    locationText: String?,
    itemID: Int? = nil
  ) {
    self.date = date
    self.compositeImage = compositeImage
    self.photoImage = photoImage
    self.captionZh = captionZh
    self.captionEn = captionEn
    self.capturedDateText = capturedDateText
    self.locationText = locationText
    self.itemID = itemID
  }

  static func placeholder(at date: Date = Date()) -> BloomEntry {
    BloomEntry(
      date: date,
      compositeImage: nil,
      photoImage: nil,
      captionZh: nil,
      captionEn: nil,
      capturedDateText: nil,
      locationText: nil
    )
  }
}

private struct BloomCaption: Decodable {
  let zh: String?
  let en: String?
}

private struct BloomPhotoDescriptor: Decodable {
  let url: String?
  let postURL: String?

  enum CodingKeys: String, CodingKey {
    case url
    case postURL = "post_url"
  }
}

private struct BloomDailyPayload: Decodable {
  let recommendationID: Int
  let caption: BloomCaption?
  let capturedDateText: String?
  let locationText: String?
  let nextCheckAt: String?
  let photo: BloomPhotoDescriptor

  enum CodingKeys: String, CodingKey {
    case recommendationID = "recommendation_id"
    case caption
    case capturedDateText = "captured_date_text"
    case locationText = "location_text"
    case nextCheckAt = "next_check_at"
    case photo
  }
}

private struct BloomCarouselItem: Decodable {
  let itemID: Int
  let displayAt: String
  let caption: BloomCaption?
  let capturedDateText: String?
  let locationText: String?
  let photo: BloomPhotoDescriptor

  enum CodingKeys: String, CodingKey {
    case itemID = "item_id"
    case displayAt = "display_at"
    case caption
    case capturedDateText = "captured_date_text"
    case locationText = "location_text"
    case photo
  }
}

private struct BloomCarouselPlanPayload: Decodable {
  let planID: Int
  let currentItemID: Int
  let nextCheckAt: String?
  let items: [BloomCarouselItem]

  enum CodingKeys: String, CodingKey {
    case planID = "plan_id"
    case currentItemID = "current_item_id"
    case nextCheckAt = "next_check_at"
    case items
  }
}

private struct BloomCarouselPayload: Decodable {
  let nextCheckAt: String?
  let item: BloomCarouselItem

  enum CodingKeys: String, CodingKey {
    case nextCheckAt = "next_check_at"
    case item
  }
}

private struct BloomRemoteContent {
  let revision: Int
  let captionZh: String?
  let captionEn: String?
  let capturedDateText: String?
  let locationText: String?
  let photoPath: String
}

private enum BloomWidgetNetworkError: Error {
  case invalidCredentials
  case invalidURL
  case invalidResponse
  case invalidImage
}

private enum BloomWidgetRemoteLoader {
  static func timeline(family: String) async -> ([BloomEntry], Date) {
    let missingCredentialsNext = Date().addingTimeInterval(30 * 60)
    let networkRetryNext = Date().addingTimeInterval(5 * 60)
    guard
      let defaults = UserDefaults(suiteName: bloomAppGroup),
      let deviceID = defaults.string(forKey: "bloom.device_id"),
      let token = defaults.string(forKey: "bloom.device_token"),
      token.count >= 32
    else {
      return ([cachedEntry(family: family)], missingCredentialsNext)
    }

    let selectionMode = defaults.string(forKey: "bloom.display_mode") ?? "recommend"
    let mode = defaults.bool(forKey: "bloom.scheduled_plan") ? "carousel" : selectionMode
    let appEntry = freshAppCompositeEntry(family: family, defaults: defaults)
    do {
      if mode == "carousel" {
        // The host app pre-renders the current and future composites while it
        // is in the foreground. A WidgetKit extension has a short execution
        // budget and should not have to serially download several multi-MB
        // originals merely to advance an already-known local timeline.
        if let local = localCarouselTimeline(family: family, defaults: defaults) {
          logTimelineChoice(
            "family=\(family) source=local entries=\(local.0.count) "
              + "first=\(Int(local.0.first?.date.timeIntervalSince1970 ?? 0)) "
              + "last=\(Int(local.0.last?.date.timeIntervalSince1970 ?? 0))"
          )
          // **Never serve a timeline that can only repeat.** The local plan is
          // preferred because it needs no network, but a future timestamp alone
          // does not mean there is anything new left to show: once every entry in
          // the pool has already been displayed, `last.date > Date()` stays true
          // forever (the stale plan still carries future-dated slots) while the
          // wall just cycles the same few already-seen photos — the "iOS only
          // loops through a handful of old photos" symptom. The real question is
          // whether an *unseen* entry still exists; only then is there something
          // this local timeline can still advance to. Falling through to the
          // fetch path is what breaks the loop: it pulls the next page *and* its
          // pictures.
          // **「还有没有没看过的」也由共享状态回答，不再用本地 id 阈值。**
          //
          // 旧实现用 `iosLastShownItemId` 作单调阈值，前提是「同一代计划内
          // item_id 递增」——而计划换代时 id 会整段重排（实测 plan 127 → 132
          // 全部换号），阈值一跨代就会把新照片误判成「已看过」，表现就是
          // 「iOS 反复显示那几张老照片」。现在只问一件事：共享状态的栅格里
          // 还有没有未来格子。没有就落到取数路径，把新计划连同照片一起拉回来。
          let gridHasRunway: Bool = {
            guard let shared = BloomSharedState.load() else { return false }
            let nowMs = Date().timeIntervalSince1970 * 1000
            return BloomSharedState.grid(shared).contains {
              (($0["slot_at_ms"] as? NSNumber)?.doubleValue ?? 0) > nowMs
            }
          }()
          if let last = local.0.last, last.date > Date(), gridHasRunway {
            return local
          }
          // **本地池用尽：这里不会、也不能去联网。**
          //
          // 轮播模式下的扩展是纯离线的查表器（见 `localCarouselTimeline` 上方的说明），
          // 所以画面会停在当前这一张，一直等到宿主 App——或它的
          // `BGAppRefreshTask`——把新格子补进来。把这件事明确写进日志，是因为
          // "小组件卡住"必须能从设备上被认出来，而不是靠猜：历史上这段代码写的是
          // "fetching instead / source=online"，但被调用的函数只是把同一份本地数据
          // 再返回一次，于是日志一直在报告一件没发生的事。
          logTimelineChoice(
            "family=\(family) source=local-spent future=0 "
              + "gridHasRunway=\(gridHasRunway) action=hold-wait-for-host-refill"
          )
          return local
        }
        logTimelineChoice("family=\(family) source=local-empty (no usable local plan)")
        // 共享状态还没有内容（App 从未打开过）时**宁可什么都不排**：WidgetKit 会
        // 继续显示上一份时间线，也好过扩展凭空猜一张用户没看过的照片。
        return ([], Date().addingTimeInterval(15 * 60))
      }
      // In recommendation mode there are no future 15-minute entries to
      // preload. Preserve the host app's exact composite briefly so a native
      // fetch cannot overwrite a photo the user has just selected.
      if let appEntry {
        return ([appEntry], Date().addingTimeInterval(2 * 60))
      }
      return try await recommendationTimeline(
        family: family,
        deviceID: deviceID,
        token: token,
        defaults: defaults
      )
    } catch {
      // A timeline request can coincide with a temporary loss of network.
      // Ask WidgetKit for another opportunity soon after connectivity is
      // likely to have returned instead of leaving an exhausted carousel on
      // screen for another half hour.
      let next = mode == "carousel"
        ? nextCarouselCheck(proposed: nil, defaults: defaults)
        : networkRetryNext
      return ([cachedEntry(family: family)], next)
    }
  }

  static func cachedEntry(family: String) -> BloomEntry {
    guard let defaults = UserDefaults(suiteName: bloomAppGroup) else {
      return .placeholder()
    }

    if let appEntry = freshAppCompositeEntry(family: family, defaults: defaults) {
      return appEntry
    }

    // **旧的 `iosWidgetPhotoPath` 兜底已删除。**
    //
    // 它把照片和文案从**两个不同的键**里取出来：照片用 `iosWidgetPhotoPath`
    // （可能停在很旧的一张，实测停在 item 4376），文案用 `iosWidgetCaptionZh`。
    // 这就是「照片换了、文案没换」以及「什么照片最后都变成同一个文案」的来源。
    //
    // 删掉之后这里会落到下面 `compositeImage(family:defaults:)` 那条路，它与
    // 小组件主体、宿主 App、安卓原生读的是**同一份共享状态、同一条时间线条目**，
    // 照片和文案同源，错配在结构上不可能发生。
    return BloomEntry(
      date: Date(),
      compositeImage: compositeImage(family: family, defaults: defaults),
      photoImage: nil,
      captionZh: nil,
      captionEn: nil,
      capturedDateText: nil,
      locationText: nil
    )
  }

  private static func freshAppCompositeEntry(
    family: String,
    defaults: UserDefaults
  ) -> BloomEntry? {
    let updatedAt = defaults.double(forKey: "appWidgetUpdatedAt")
    guard updatedAt > 0,
          Date().timeIntervalSince1970 - updatedAt < 2 * 60,
          let image = compositeImage(family: family, defaults: defaults) else {
      return nil
    }
    return BloomEntry(
      date: Date(),
      compositeImage: image,
      photoImage: nil,
      captionZh: nil,
      captionEn: nil,
      capturedDateText: nil,
      locationText: nil
    )
  }

  private static func recommendationTimeline(
    family: String,
    deviceID: String,
    token: String,
    defaults: UserDefaults
  ) async throws -> ([BloomEntry], Date) {
    let path = "/api/frame/devices/\(deviceID)/daily"
    let payload: BloomDailyPayload = try await requestJSON(
      path: path,
      token: token,
      method: "POST",
      body: ["target": "mobile"]
    )
    guard let photoPath = payload.photo.url else {
      throw BloomWidgetNetworkError.invalidURL
    }
    let photoData = try await requestData(
      path: photoPath,
      token: token,
      method: "GET"
    )
    let content = try cache(
      photoData: photoData,
      revision: payload.recommendationID,
      caption: payload.caption,
      capturedDateText: payload.capturedDateText,
          locationText: payload.locationText,
      defaults: defaults,
      mode: "recommend"
    )
    return (
      [entry(content)],
      normalizedNext(parseDate(payload.nextCheckAt))
    )
  }


  /// **Why did the widget pick that photo?**
  ///
  /// iOS release logs cannot be read from the build machine (no `idevicesyslog`, and
  /// `devicectl` has no console), so every past diagnosis of "iOS repeats a photo" was
  /// guesswork. This appends one line per timeline build into the App Group, where the
  /// host app can read it and print it. Diagnostic only: it changes no decision, and
  /// every failure path is swallowed so a full disk can never break the widget.
  private static func logTimelineChoice(_ line: String) {
    guard
      let root = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: bloomAppGroup
      )
    else { return }
    let file = root.appendingPathComponent("widget-timeline.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = "\(stamp) \(line)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(Data(entry.utf8))
      try? handle.close()
    } else {
      try? entry.write(to: file, atomically: true, encoding: .utf8)
    }
  }

  private static func localCarouselTimeline(
    family: String,
    defaults: UserDefaults
  ) -> ([BloomEntry], Date)? {
    let plan = storedCarouselPlan(defaults: defaults)
    guard !plan.isEmpty else { return nil }
    let now = Date()
    let resolved = plan.compactMap { item -> (Date, BloomEntry)? in
      guard let millis = (item["displayAtMillis"] as? NSNumber)?.doubleValue else {
        return nil
      }
      // Host-app paths are complete pre-rendered compositions. Extension
      // `photoPath` values are raw photos and must still pass through the
      // SwiftUI letter-paper layout. Treating both as `compositeImage` made
      // captions disappear whenever a native plan was replayed from disk.
      let compositePath = (family == "square"
        ? item["squarePath"]
        : item["largeSquarePath"]) as? String
      let photoPath = item["photoPath"] as? String
      let selected: (path: String, isComposite: Bool)?
      if let compositePath,
         FileManager.default.fileExists(atPath: compositePath) {
        selected = (compositePath, true)
      } else if let photoPath,
                FileManager.default.fileExists(atPath: photoPath) {
        selected = (photoPath, false)
      } else {
        selected = nil
      }
      guard let selected,
            let image = UIImage(contentsOfFile: selected.path) else { return nil }
      let scheduled = Date(timeIntervalSince1970: millis / 1000)
      return (
        scheduled,
        BloomEntry(
          date: scheduled,
          compositeImage: selected.isComposite ? image : nil,
          photoImage: selected.isComposite ? nil : image,
          captionZh: item["captionZh"] as? String,
          captionEn: item["captionEn"] as? String,
          capturedDateText: item["capturedDateText"] as? String,
          locationText: item["locationText"] as? String,
          itemID: (item["itemId"] as? NSNumber)?.intValue
        )
      )
    }.sorted { $0.0 < $1.0 }
    guard !resolved.isEmpty else { return nil }

    // **The slot that is due comes from the plan, not from the files.**
    //
    // `resolved` can only hold items whose image is really on disk. So when the
    // slot that is due now has no image yet, `resolved.last { $0.0 <= now }` is an
    // *older* entry — a photo the user has already seen, which is exactly the
    // "it updated, but to a photo I have seen" bug. The grid does not move: the
    // due time is read from the plan (files or no files), and the pictures shift
    // forward to the next item that does have an image, never backwards.
    let dueAt = plan.compactMap { item -> Date? in
      guard let millis = (item["displayAtMillis"] as? NSNumber)?.doubleValue else {
        return nil
      }
      let at = Date(timeIntervalSince1970: millis / 1000)
      return at <= now ? at : nil
    }.max()
    // **「此刻是哪一格」由共享状态决定，扩展不自行判断。**
    //
    // 旧实现这里有整整一套自己的决策：用 `iosLastShownItemId` 判断「是否
    // 看过」、并列时取最大 itemID、当前格没有照片时把未来格前移。方案把这
    // 几项全部列为 Swift 侧不得实现的决策，其中「前移」更是明确禁止——栅格
    // 永不动。实测到的「22:28 显示 22:30 那张照片」就是前移造成的。
    //
    // 现在只问共享状态一个问题：`timeline_entries` 里 `date_ms` 不晚于此刻的
    // 最后一条是谁。这与 Dart、安卓是同一条规则（共享向量
    // `current_from_entries`），任何一侧偏离都会表现为两端各显示一张。
    let sharedState = BloomSharedState.load()
    let sharedCurrentItemID = BloomCarouselRule
      .currentEntry(
        BloomSharedState.timelineEntries(sharedState),
        nowMillis: now.timeIntervalSince1970 * 1000
      )
      .flatMap { ($0["item_id"] as? NSNumber)?.intValue }

    // 兜底用：共享状态缺失时按计划时刻判断，并保留确定性的并列取舍。
    let dueMatch: (Date, BloomEntry)? = dueAt.flatMap { at in
      resolved
        .filter { abs($0.0.timeIntervalSince(at)) < 1 }
        .max { ($0.1.itemID ?? 0) < ($1.1.itemID ?? 0) }
    }

    let current: (Date, BloomEntry)?
    if let sharedCurrentItemID {
      // 共享状态给出了当前格：只有它算当前。它若还没有照片，就保持上一张，
      // **绝不把未来格前移**。
      current = resolved.last { $0.1.itemID == sharedCurrentItemID }
    } else {
      // 共享状态缺失（App 从未打开过）：退回按计划时刻判断。
      current = dueMatch
    }
    // **Not persisted here.** This function's result can still be discarded by
    // the caller (`BloomWidgetRemoteLoader.timeline` falls back to the online
    // fetch when the local plan has no future entry left) — marking the id as
    // shown before it is known to actually reach the wall would skip it later
    // even though the user never saw it. The caller records it once it commits
    // to returning this timeline.
    // 后续条目按**计划时刻**切分，而不是按「当前那一张」切分：当前格的照片
    // 还没下载好时，后面的格子照样要先烘进时间线，不能因为缺一张就整条不建。
    let futureCutoff = current?.0 ?? dueAt ?? now
    let future = resolved.filter { $0.0 > futureCutoff }
    // **No local floor on how many future entries there are.** Android builds
    // whatever union it has and lets the recovery alarm refill it, and the two
    // platforms have to behave identically: refusing to build a timeline because
    // only one — or no — future item is left is exactly what blanks the widget
    // on a slow night.
    var entries: [BloomEntry] = []
    if let current {
      entries.append(BloomEntry(
        date: now,
        compositeImage: current.1.compositeImage,
        photoImage: current.1.photoImage,
        captionZh: current.1.captionZh,
        captionEn: current.1.captionEn,
        capturedDateText: current.1.capturedDateText,
        locationText: current.1.locationText,
        itemID: current.1.itemID
      ))
    }
    entries.append(contentsOf: future.map { $0.1 })
    guard !entries.isEmpty else { return nil }
    // Ask for the next batch at the second-to-last stamp when there is one, at
    // the last known stamp when there is only one, and right away when the local
    // plan is spent.
    let refillAt: Date
    if future.count >= 2 {
      refillAt = future[future.count - 2].0
    } else if let last = future.last {
      refillAt = last.0
    } else {
      refillAt = now
    }
    return (entries, nextCarouselCheck(proposed: refillAt, defaults: defaults))
  }

  // 这里原本还有一个 `carouselTimeline(family:deviceID:token:defaults:currentOverride:)`。
  //
  // 它的文档说自己是"只读共享状态、不联网"，函数体确实是纯本地查询；但调用点
  // 把它当成"联网补货"来用（前一行日志写着 `fetching instead`），而且
  // `deviceID` / `token` / `currentOverride` 三个参数从头到尾没有被读过。那套
  // 扩展自建的在线补货——自己拉 `/carousel/plan`、自己挑分页游标、自己下载照片、
  // 自己合并进 `iosCarouselPlan`——是**重写之前遗留的第二写者**（最早见于
  // 2026-08-17 的初始提交），也正是「照片和文案来自两个不同来源」的源头：照片走
  // 共享状态、文案走它自己那张表，实测停在不同的条目上（照片 4376、共享状态已到
  // 4409）。方案把「选哪一格」明确列为 Swift 侧不得实现的决策。
  //
  // 现在整个扩展与小组件主体、宿主 App、安卓原生读**同一份共享状态**，规则只有
  // 一条：`date_ms <= now` 的最后一条。**Dart 是唯一的写者。**
  //
  // 那层空转已经被删掉了，调用点直接走本地查表 + 明确的"露底"日志。补货是宿主
  // App 的职责：前台靠 `_armNextSlotWake`，后台靠 `BGAppRefreshTask`；扩展不做
  // 也不该做网络。

  private static func localDay(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  /// The shared plan, or an empty one when it belongs to a previous day.
  ///
  /// A **missing** day key — a plan written before this bookkeeping existed — is
  /// treated as usable rather than discarded, so an update cannot blank a widget
  /// that is working.
  /// 扩展要烘焙的计划：**优先读共享状态**，本地缓存只作兜底。
  ///
  /// 方案要求扩展「从共享状态读取计划」。`carousel-state.json` 里的
  /// `timeline_entries` 恰好带着这里需要的全部信息，而且比扩展自建的
  /// `iosCarouselPlan` 更权威：它是 Dart 的单写者写下的，两端因此看到同一份
  /// 计划。扩展自建那份曾经是**第二个写者**——App 与小组件显示两张不同照片
  /// 的根源之一。
  ///
  /// 键名映射（snake_case → 扩展内部命名）：
  ///   * `item_id`        → `itemId`
  ///   * `date_ms`        → `displayAtMillis`
  ///   * `square_path`    → `squarePath`（Dart 已渲染好的信纸合成图）
  ///   * `large_square_path` → `largeSquarePath`（同上）
  ///   * `original_path`  → `photoPath`（**原图**，仍需走信纸排版）
  ///
  /// 注意最后一条：Dart 渲染出的 `portrait_path` 是合成图，而扩展的
  /// `photoPath` 语义是「需要套信纸排版的原始照片」，两者不能混用——混用会
  /// 让文案消失（那张图里已经把文案画进去了，再套一次排版就没有文案位置）。
  ///
  /// 共享状态缺失（App 从未打开过）时退回本地缓存，行为与从前一致。
  private static func storedCarouselPlan(defaults: UserDefaults) -> [[String: Any]] {
    // 优先读共享状态：它是 Dart 单写者写下的权威计划，键名映射在
    // `BloomSharedState.planItems`（那个文件可脱离模拟器被测试）。扩展自建的
    // `iosCarouselPlan` 曾经是**第二个写者**，正是 App 与小组件显示两张不同
    // 照片的根源之一。
    if let shared = BloomSharedState.load() {
      let items = BloomSharedState.planItems(from: shared)
      if !items.isEmpty {
        logTimelineChoice(
          "source=shared-state plan=\(BloomSharedState.planId(shared)) entries=\(items.count)"
        )
        return items
      }
    }
    // **旧的 `iosCarouselPlan` 兜底已删除**（重写前遗留，2026-08-17 初始提交）。
    //
    // 它是扩展自己维护的第二份计划表，与共享状态并存就意味着两个真相。实测正是
    // 它让 17:00 之后的任何时刻都解析出 item 4406 的文案——照片来自共享状态、
    // 文案来自这张旧表，于是「不管什么照片最后都变成同一个文案」。
    //
    // 共享状态缺失时（App 从未打开过）**宁可什么都不显示**：WidgetKit 会继续
    // 显示上一份时间线，也好过凭空猜一张。
    return []
  }

  /// 此刻是哪一格：**由 Dart 的单写者决定，扩展不自行判断**。
  ///
  /// 方案把「选哪一格」明确列为 Swift 侧不得实现的决策之一。扩展在自己的
  /// 计划响应里也能看到一个 `current_item_id`，但那是第二次独立判断：它和
  /// Dart 的判断依据同一份服务端计划、却在不同的时刻取数，一旦分叉就会让
  /// App 与小组件显示两张不同的照片。
  ///
  /// 因此：共享状态里能读到 `current_item_id` 时一律以它为准；只有在状态
  /// 缺失（App 从未打开过、扩展独立运行）时才退回服务端字段。
  ///
  /// 注意「都不是当前」是合法结果：此时整页条目都按各自时刻排期，WidgetKit
  /// 会继续显示上一份时间线的最后一条，而不是抢先跳到未来的某一格。
  private static func isCurrentSlot(
    itemID: Int,
    displayAt: Date,
    now: Date,
    shared: [String: Any]?,
    serverCurrentItemID: Int
  ) -> Bool {
    if let sharedItemID = (shared?["current_item_id"] as? NSNumber)?.intValue,
       sharedItemID > 0 {
      return itemID == sharedItemID
    }
    // Outside the active window the API may identify tomorrow's first item as
    // `currentItemID`. It is still a future entry and must not replace
    // tonight's final photo before its scheduled display time.
    return itemID == serverCurrentItemID &&
      displayAt <= now.addingTimeInterval(60)
  }

  // 这里曾有三个只服务于「扩展自己补货」的函数：`carouselCursor`（分页游标）、
  // `mergeCarouselPlan`（把它拉到的页并进本地表）、`persistCarouselPlan`（把这张
  // 表写进 `iosCarouselPlan`）。在线补货删除后它们全部失去调用者，一并删除。
  //
  // `persistCarouselPlan` 曾经是 `iosCarouselPlan` 的**写入端**——正是它让那张
  // 陈旧表一直活下去，进而覆盖宿主 App 的文案。

  private static func entry(
    _ content: BloomRemoteContent,
    at date: Date = Date(),
    itemID: Int? = nil
  ) -> BloomEntry {
    BloomEntry(
      date: date,
      compositeImage: nil,
      photoImage: UIImage(contentsOfFile: content.photoPath),
      captionZh: content.captionZh,
      captionEn: content.captionEn,
      capturedDateText: content.capturedDateText,
      locationText: content.locationText,
      itemID: itemID
    )
  }

  private static func cache(
    photoData: Data,
    revision: Int,
    caption: BloomCaption?,
    capturedDateText: String?,
    locationText: String?,
    defaults: UserDefaults,
    persistAsCurrent: Bool = true,
    mode: String = "recommend"
  ) throws -> BloomRemoteContent {
    guard let widgetImage = downsampleForWidget(photoData),
          let encoded = widgetImage.jpegData(compressionQuality: 0.88),
          let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: bloomAppGroup
          ) else {
      throw BloomWidgetNetworkError.invalidImage
    }
    let directory = root.appendingPathComponent("widget-cache", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let file = directory.appendingPathComponent("ios-widget-remote-\(revision).jpg")
    try encoded.write(to: file, options: .atomic)

    if persistAsCurrent {
      // **旧的六个键已停止写入**（`iosWidgetPhotoPath` / `iosWidgetRevision` /
      // `iosWidgetCaptionZh` / `iosWidgetCaptionEn` / `iosWidgetCapturedDate` /
      // `iosWidgetLocation`）。
      //
      // 它们是重写前那套「扩展自己下载、自己存照片和文案」的产物。照片用
      // `iosWidgetPhotoPath`、文案用 `iosWidgetCaptionZh`，**两者是两个不同的键**，
      // 实测停在不同的条目上（照片 4376、文案也 4376，但共享状态已经走到 4409），
      // 于是首页出现「照片换了、文案没换」。读取端已删除，这里也不再写。
      // Keep the host App's shared current-item reader in sync with the
      // extension process. Flutter can consume this path after WidgetKit has
      // advanced while the app was closed.
      defaults.set(revision, forKey: "recommendationId")
      defaults.set(file.path, forKey: "widgetCurrentOriginalPhotoPath")
      defaults.set(caption?.zh, forKey: "captionZh")
      defaults.set(caption?.en, forKey: "captionEn")
      defaults.set(capturedDateText, forKey: "capturedDateText")
      defaults.set(locationText, forKey: "locationText")
      defaults.set(mode, forKey: "mode")
      defaults.set(Date().timeIntervalSince1970 * 1000, forKey: "updatedAtMillis")
    }
    pruneRemoteImages(in: directory, keeping: file)

    return BloomRemoteContent(
      revision: revision,
      captionZh: caption?.zh,
      captionEn: caption?.en,
      capturedDateText: capturedDateText,
      locationText: locationText,
      photoPath: file.path
    )
  }

  private static func downsampleForWidget(_ data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 1000,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      options as CFDictionary
    ) else {
      return nil
    }
    return UIImage(cgImage: image)
  }

  private static func requestJSON<T: Decodable>(
    path: String,
    token: String,
    method: String,
    body: [String: Any]? = nil
  ) async throws -> T {
    let data = try await requestData(
      path: path,
      token: token,
      method: method,
      body: body
    )
    return try JSONDecoder().decode(T.self, from: data)
  }

  private static func requestData(
    path: String,
    token: String,
    method: String,
    body: [String: Any]? = nil
  ) async throws -> Data {
    guard let url = URL(string: path, relativeTo: bloomBaseURL)?.absoluteURL else {
      throw BloomWidgetNetworkError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue(token, forHTTPHeaderField: "X-Frame-Token")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode) else {
      throw BloomWidgetNetworkError.invalidResponse
    }
    return data
  }

  private static func compositeImage(
    family: String,
    defaults: UserDefaults
  ) -> UIImage? {
    let key = family == "square" ? "squarePath" : "largeSquarePath"
    guard let path = defaults.string(forKey: key) else { return nil }
    return UIImage(contentsOfFile: path)
  }

  private static func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
  }

  private static func normalizedNext(_ proposed: Date?) -> Date {
    let minimum = Date().addingTimeInterval(15 * 60)
    guard let proposed, proposed > minimum else { return minimum }
    return proposed
  }

  private static func nextCarouselCheck(
    proposed: Date?,
    defaults: UserDefaults
  ) -> Date {
    let now = Date()
    let minimum = now.addingTimeInterval(5 * 60)
    if let proposed, proposed > minimum { return proposed }

    let start = clockMinutes(
      defaults.string(forKey: "bloom.carousel_active_start") ?? "06:00",
      fallback: 6 * 60
    )
    let end = clockMinutes(
      defaults.string(forKey: "bloom.carousel_active_end") ?? "22:00",
      fallback: 22 * 60
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    let parts = calendar.dateComponents([.hour, .minute], from: now)
    let current = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    if current >= start && current < end { return minimum }

    var startParts = calendar.dateComponents([.year, .month, .day], from: now)
    startParts.hour = start / 60
    startParts.minute = start % 60
    startParts.second = 0
    guard var nextStart = calendar.date(from: startParts) else { return minimum }
    if current >= end || nextStart <= now {
      nextStart = calendar.date(byAdding: .day, value: 1, to: nextStart) ?? minimum
    }
    return nextStart
  }

  private static func clockMinutes(_ value: String, fallback: Int) -> Int {
    let pieces = value.split(separator: ":")
    guard pieces.count == 2,
          let hour = Int(pieces[0]), hour >= 0, hour <= 23,
          let minute = Int(pieces[1]), minute >= 0, minute <= 59 else {
      return fallback
    }
    return hour * 60 + minute
  }

  private static func pruneRemoteImages(in directory: URL, keeping: URL) {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    let candidates = files.filter {
      $0.lastPathComponent.hasPrefix("ios-widget-remote-") && $0 != keeping
    }
    let sorted = candidates.sorted {
      let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      return left > right
    }
    // A carousel timeline currently holds up to four UIImage file references.
    // Keep enough generations alive until WidgetKit replaces that timeline.
    for file in sorted.dropFirst(6) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}

private enum BloomWidgetFont {
  private static var didAttemptRegistration = false
  private static let postScriptName = "mmxj-Regular"

  static func custom(size: CGFloat, weight: Font.Weight? = nil) -> Font {
    registerIfNeeded()
    let font = Font.custom(postScriptName, fixedSize: size)
    return weight.map { font.weight($0) } ?? font
  }

  private static func registerIfNeeded() {
    guard !didAttemptRegistration else { return }
    didAttemptRegistration = true

    // Reuse Flutter's bundled font instead of shipping another 6 MB copy in
    // the widget extension.  Bundle.main here is Runner.app/PlugIns/*.appex.
    let hostApp = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fontURL = hostApp
      .appendingPathComponent("Frameworks/App.framework/flutter_assets")
      .appendingPathComponent("assets/fonts/mmxj.ttf")
    guard FileManager.default.fileExists(atPath: fontURL.path) else { return }
    CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
  }
}

struct BloomProvider: TimelineProvider {
  let family: String

  func placeholder(in context: Context) -> BloomEntry {
    .placeholder()
  }

  func getSnapshot(in context: Context, completion: @escaping (BloomEntry) -> Void) {
    completion(BloomWidgetRemoteLoader.cachedEntry(family: family))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<BloomEntry>) -> Void) {
    Task {
      let (entries, next) = await BloomWidgetRemoteLoader.timeline(family: family)
      completion(Timeline(entries: entries, policy: .after(next)))
    }
  }
}

struct BloomWidgetView: View {
  let entry: BloomEntry

  @ViewBuilder
  var body: some View {
    if #available(iOSApplicationExtension 17.0, *) {
      content
        .containerBackground(for: .widget) {
          Color(red: 0.96, green: 0.95, blue: 0.91)
        }
    } else {
      content
    }
  }

  private var content: some View {
    Group {
      if let image = entry.photoImage {
        GeometryReader { proxy in
          let paperHeight = proxy.size.height * 0.25
          VStack(spacing: 0) {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
              .frame(width: proxy.size.width, height: proxy.size.height - paperHeight)
              .clipped()
            BloomLetterPaper(
              captionZh: entry.captionZh,
              captionEn: entry.captionEn,
              capturedDateText: entry.capturedDateText,
              locationText: entry.locationText,
              compact: proxy.size.width < 200
            )
            .frame(width: proxy.size.width, height: paperHeight)
          }
        }
      } else if let image = entry.compositeImage {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color(red: 0.96, green: 0.95, blue: 0.91)
          .overlay(Text("Bloom").foregroundColor(.secondary))
      }
    }
    .clipShape(ContainerRelativeShape())
    .widgetURL(URL(string: "bloom://today"))
  }
}

private struct BloomLetterPaper: View {
  let captionZh: String?
  let captionEn: String?
  let capturedDateText: String?
  let locationText: String?
  let compact: Bool

  private var chinese: String {
    let raw = (captionZh ?? "今天，也值得看一眼。")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "「」"))
    return "「\(raw)」"
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(red: 0.985, green: 0.973, blue: 0.94),
                 Color(red: 0.945, green: 0.925, blue: 0.87)],
        startPoint: .top,
        endPoint: .bottom
      )
      VStack(alignment: .leading, spacing: compact ? 2 : 5) {
        Text(chinese)
          .font(BloomWidgetFont.custom(size: compact ? 11 : 18, weight: .medium))
          .foregroundColor(Color(red: 0.16, green: 0.16, blue: 0.16))
          .lineLimit(2)
          .minimumScaleFactor(0.72)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !compact,
           let english = captionEn?.trimmingCharacters(in: .whitespacesAndNewlines),
           !english.isEmpty,
           chinese.count <= 21 {
          Text("— \(english)")
            .font(BloomWidgetFont.custom(size: 10))
            .foregroundColor(Color(red: 0.30, green: 0.30, blue: 0.29))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        HStack(spacing: 6) {
          Text(capturedDateText ?? "")
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(locationText ?? "")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(BloomWidgetFont.custom(size: compact ? 7 : 9))
        .foregroundColor(Color(red: 0.44, green: 0.42, blue: 0.38))
        .lineLimit(1)
      }
      .padding(.horizontal, compact ? 9 : 20)
      .padding(.vertical, compact ? 4 : 9)
    }
  }
}

struct BloomSquareWidget: Widget {
  let kind = "BloomSquareWidget"

  var body: some WidgetConfiguration {
    configuration.contentMarginsDisabled()
  }

  private var configuration: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: BloomProvider(family: "square")) { entry in
      BloomWidgetView(entry: entry)
    }
    .configurationDisplayName("Bloom 方形 2×2")
    .description("每天展示一张今日推荐照片。")
    .supportedFamilies([.systemSmall])
  }
}

struct BloomLargeSquareWidget: Widget {
  let kind = "BloomLargeSquareWidget"

  var body: some WidgetConfiguration {
    configuration.contentMarginsDisabled()
  }

  private var configuration: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: BloomProvider(family: "largeSquare")) { entry in
      BloomWidgetView(entry: entry)
    }
    .configurationDisplayName("Bloom 方形 4×4")
    .description("每天展示一张今日推荐照片。")
    .supportedFamilies([.systemLarge])
  }
}

@main
struct BloomWidgetBundle: WidgetBundle {
  var body: some Widget {
    BloomSquareWidget()
    BloomLargeSquareWidget()
  }
}
