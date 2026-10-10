import SwiftUI
import WidgetKit
import CoreText
import ImageIO

private let bloomAppGroup = "group.com.zhangbo.bloom.zb20260815"

struct BloomEntry: TimelineEntry {
  let date: Date
  // Keep paths so five timeline entries do not retain five decoded bitmaps.
  let compositePath: String?
  let photoPath: String?
  let maxPixels: Int
  var compositeImage: UIImage? { load(compositePath) }
  var photoImage: UIImage? { load(photoPath) }
  private func load(_ path: String?) -> UIImage? {
    guard let path else { return nil }
    return BloomWidgetRenderer.image(at: URL(fileURLWithPath: path), maxPixels: maxPixels)
  }
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
    compositePath: String?,
    photoPath: String?,
    maxPixels: Int = 480,
    captionZh: String?,
    captionEn: String?,
    capturedDateText: String?,
    locationText: String?,
    itemID: Int? = nil
  ) {
    self.date = date
    self.compositePath = compositePath
    self.photoPath = photoPath
    self.maxPixels = maxPixels
    self.captionZh = captionZh
    self.captionEn = captionEn
    self.capturedDateText = capturedDateText
    self.locationText = locationText
    self.itemID = itemID
  }

  static func placeholder(at date: Date = Date()) -> BloomEntry {
    BloomEntry(
      date: date,
      compositePath: nil,
      photoPath: nil,
      captionZh: nil,
      captionEn: nil,
      capturedDateText: nil,
      locationText: nil
    )
  }
}

private enum BloomWidgetRemoteLoader {
  static func timeline(family: String) -> ([BloomEntry], Date) {
    if UserDefaults(suiteName: bloomAppGroup)?.bool(forKey: "bloom.signed_out") == true {
      return ([.placeholder()], .distantFuture)
    }
    guard let defaults = UserDefaults(suiteName: bloomAppGroup) else {
      return ([cachedEntry(family: family)], Date().addingTimeInterval(15 * 60))
    }
    let scheduled = defaults.bool(forKey: "bloom.scheduled_plan") ||
      defaults.string(forKey: "bloom.display_mode") == "carousel"
    if scheduled, let local = localCarouselTimeline(family: family, defaults: defaults) {
      logTimelineChoice("family=\(family) source=shared-state entries=\(local.0.count)")
      return local
    }
    // A missing/failed new download holds the last complete composition. Never
    // publish an empty timeline or change the current item before bytes exist.
    return ([cachedEntry(family: family)], Date().addingTimeInterval(scheduled ? 5 * 60 : 30 * 60))
  }

  static func cachedEntry(family: String) -> BloomEntry {
    guard let defaults = UserDefaults(suiteName: bloomAppGroup) else {
      return .placeholder()
    }
    if defaults.bool(forKey: "bloom.signed_out") { return .placeholder() }

    let scheduled = defaults.bool(forKey: "bloom.scheduled_plan") ||
      defaults.string(forKey: "bloom.display_mode") == "carousel"
    if scheduled, let local = localCarouselTimeline(family: family, defaults: defaults),
       let current = local.0.first, current.date <= Date() {
      return current
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
      compositePath: compositePath(family: family, defaults: defaults),
      photoPath: nil,
      maxPixels: family == "square" ? 480 : 800,
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
          let path = compositePath(family: family, defaults: defaults) else {
      return nil
    }
    return BloomEntry(
      date: Date(),
      compositePath: path,
      photoPath: nil,
      maxPixels: family == "square" ? 480 : 800,
      captionZh: nil,
      captionEn: nil,
      capturedDateText: nil,
      locationText: nil
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
    let file = root.appendingPathComponent("widget-cache/widget-timeline.log")
    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 64 * 1024 {
      try? FileManager.default.removeItem(at: file)
    }
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
      guard let selected else { return nil }
      let scheduled = Date(timeIntervalSince1970: millis / 1000)
      return (
        scheduled,
        BloomEntry(
          date: scheduled,
          compositePath: selected.isComposite ? selected.path : nil,
          photoPath: selected.isComposite ? nil : selected.path,
          maxPixels: family == "square" ? 480 : 800,
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
        compositePath: current.1.compositePath,
        photoPath: current.1.photoPath,
        maxPixels: current.1.maxPixels,
        captionZh: current.1.captionZh,
        captionEn: current.1.captionEn,
        capturedDateText: current.1.capturedDateText,
        locationText: current.1.locationText,
        itemID: current.1.itemID
      ))
    }
    entries.append(contentsOf: future.map { $0.1 })
    // WidgetKit must always receive a ready entry for now. If only a future
    // download succeeded, keep the last composition instead of starting a
    // timeline with a future image at its first position.
    guard current != nil, !entries.isEmpty else { return nil }
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

  // The only plan table is the App Group's canonical timeline. The extension
  // may refill it under the shared writer lease; it never keeps a private plan.
  private static func storedCarouselPlan(defaults: UserDefaults) -> [[String: Any]] {
    // Flutter 与扩展在同一批次锁内更新这份共享状态，键名映射在
    // BloomSharedState.planItems。播放不读取扩展私有计划表。
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

  private static func compositePath(
    family: String,
    defaults: UserDefaults
  ) -> String? {
    let scheduled = defaults.bool(forKey: "bloom.scheduled_plan") ||
      defaults.string(forKey: "bloom.display_mode") == "carousel"
    if scheduled,
       let due = BloomCarouselRule.currentEntry(BloomSharedState.timelineEntries(BloomSharedState.load()), nowMillis: Date().timeIntervalSince1970 * 1000),
       let path = due[family == "square" ? "square_path" : "large_square_path"] as? String,
       FileManager.default.fileExists(atPath: path) {
      return path
    }
    let key = family == "square" ? "squarePath" : "largeSquarePath"
    guard let path = defaults.string(forKey: key) else { return nil }
    return FileManager.default.fileExists(atPath: path) ? path : nil
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
    // Queue system-owned metadata/download work without awaiting transport.
    // The ready shared timeline is always returned during this provider pass.
    BloomWidgetSync.shared.refill()
    let (entries, next) = BloomWidgetRemoteLoader.timeline(family: family)
    completion(Timeline(entries: entries, policy: .after(next)))
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
      if UserDefaults(suiteName: bloomAppGroup)?.bool(forKey: "bloom.signed_out") == true {
        Color(red: 0.96, green: 0.95, blue: 0.91)
          .overlay(Text("请登录 Bloom").foregroundColor(.secondary))
      } else if let image = entry.photoImage {
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
    .onBackgroundURLSessionEvents(matching: BloomWidgetSync.sessionID) { identifier, completion in
      BloomWidgetSync.shared.handleEvents(identifier: identifier, completion: completion)
    }
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
    .onBackgroundURLSessionEvents(matching: BloomWidgetSync.sessionID) { identifier, completion in
      BloomWidgetSync.shared.handleEvents(identifier: identifier, completion: completion)
    }
  }
}

@main
struct BloomWidgetBundle: WidgetBundle {
  var body: some Widget {
    BloomSquareWidget()
    BloomLargeSquareWidget()
  }
}
