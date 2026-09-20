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

    let mode = defaults.string(forKey: "bloom.display_mode") ?? "recommendation"
    let appEntry = freshAppCompositeEntry(family: family, defaults: defaults)
    do {
      if mode == "carousel" {
        // The host app pre-renders the current and future composites while it
        // is in the foreground. A WidgetKit extension has a short execution
        // budget and should not have to serially download several multi-MB
        // originals merely to advance an already-known local timeline.
        if let local = localCarouselTimeline(family: family, defaults: defaults) {
          return local
        }
        return try await carouselTimeline(
          family: family,
          deviceID: deviceID,
          token: token,
          defaults: defaults,
          currentOverride: appEntry
        )
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

    let nativeRevision = defaults.integer(forKey: "iosWidgetRevision")
    let appRevision = defaults.integer(forKey: "recommendationId")
    if let path = defaults.string(forKey: "iosWidgetPhotoPath"),
       FileManager.default.fileExists(atPath: path),
       nativeRevision == appRevision || compositeImage(family: family, defaults: defaults) == nil {
      return BloomEntry(
        date: Date(),
        compositeImage: nil,
        photoImage: UIImage(contentsOfFile: path),
        captionZh: defaults.string(forKey: "iosWidgetCaptionZh"),
        captionEn: defaults.string(forKey: "iosWidgetCaptionEn"),
        capturedDateText: defaults.string(forKey: "iosWidgetCapturedDate"),
        locationText: defaults.string(forKey: "iosWidgetLocation")
      )
    }

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
      mode: "recommendation"
    )
    return (
      [entry(content)],
      normalizedNext(parseDate(payload.nextCheckAt))
    )
  }

  private static func localCarouselTimeline(
    family: String,
    defaults: UserDefaults
  ) -> ([BloomEntry], Date)? {
    guard let rawPlan = defaults.string(forKey: "iosCarouselPlan"),
          let data = rawPlan.data(using: .utf8),
          let plan = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return nil
    }
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
          locationText: item["locationText"] as? String
        )
      )
    }.sorted { $0.0 < $1.0 }
    guard !resolved.isEmpty else { return nil }

    let current = resolved.last { $0.0 <= now }
    let future = resolved.filter { $0.0 > now }
    // Refill before the local timeline is exhausted. WidgetKit may delay a
    // policy boundary while the phone is locked or under power management;
    // asking for the next batch while one future item remains leaves a local
    // fallback entry even if the network request takes a little longer.
    guard future.count >= 2 else { return nil }
    var entries: [BloomEntry] = []
    if let current {
      entries.append(BloomEntry(
        date: now,
        compositeImage: current.1.compositeImage,
        photoImage: current.1.photoImage,
        captionZh: current.1.captionZh,
        captionEn: current.1.captionEn,
        capturedDateText: current.1.capturedDateText,
        locationText: current.1.locationText
      ))
    }
    entries.append(contentsOf: future.map { $0.1 })
    guard !entries.isEmpty else { return nil }
    let refillAt = future[future.count - 2].0
    return (entries, nextCarouselCheck(proposed: refillAt, defaults: defaults))
  }

  private static func carouselTimeline(
    family: String,
    deviceID: String,
    token: String,
    defaults: UserDefaults,
    currentOverride: BloomEntry? = nil
  ) async throws -> ([BloomEntry], Date) {
    let interval = max(15, defaults.integer(forKey: "bloom.carousel_interval_minutes"))
    let activeStart = defaults.string(forKey: "bloom.carousel_active_start") ?? "06:00"
    let activeEnd = defaults.string(forKey: "bloom.carousel_active_end") ?? "22:00"
    let path = "/api/frame/devices/\(deviceID)/carousel/plan"
    let payload: BloomCarouselPlanPayload = try await requestJSON(
      path: path,
      token: token,
      method: "POST",
      body: [
        "target": "mobile",
        "timezone": "Asia/Shanghai",
        "active_start": activeStart,
        "active_end": activeEnd,
        "interval_minutes": interval,
        "batch_limit": 4,
      ]
    )
    let now = Date()
    var entries: [BloomEntry] = []
    var sharedPlan: [[String: Any]] = []
    for item in payload.items {
      guard let displayAt = parseDate(item.displayAt),
            let photoPath = item.photo.postURL else { continue }
      // Outside the active window the API may identify tomorrow's first item
      // as `currentItemID`. It is still a future entry and must not replace
      // tonight's final photo before its scheduled display time.
      let isCurrent = item.itemID == payload.currentItemID &&
        displayAt <= now.addingTimeInterval(60)
      guard isCurrent || displayAt > now.addingTimeInterval(-60) else { continue }
      // A single unsupported/corrupt asset must not discard the rest of the
      // already-prefetchable timeline.
      do {
        let photoData = try await requestData(
          path: photoPath,
          token: token,
          method: "POST",
          body: ["item_id": item.itemID]
        )
        let content = try cache(
          photoData: photoData,
          revision: item.itemID,
          caption: item.caption,
          capturedDateText: item.capturedDateText,
          locationText: item.locationText,
          defaults: defaults,
          persistAsCurrent: isCurrent,
          mode: "carousel"
        )
        if isCurrent, let currentOverride {
          // Keep the exact PNG written by Flutter as the first entry, while
          // still downloading and registering every future WidgetKit entry.
          entries.append(BloomEntry(
            date: now,
            compositeImage: currentOverride.compositeImage,
            photoImage: currentOverride.photoImage,
            captionZh: currentOverride.captionZh,
            captionEn: currentOverride.captionEn,
            capturedDateText: currentOverride.capturedDateText,
            locationText: currentOverride.locationText
          ))
        } else {
          entries.append(entry(content, at: isCurrent ? now : displayAt))
        }
        var sharedItem: [String: Any] = [
          "itemId": item.itemID,
          "displayAtMillis": displayAt.timeIntervalSince1970 * 1000,
          "date": item.displayAt,
          "photoPath": content.photoPath,
        ]
        if let value = item.caption?.zh { sharedItem["captionZh"] = value }
        if let value = item.caption?.en { sharedItem["captionEn"] = value }
        if let value = item.capturedDateText { sharedItem["capturedDateText"] = value }
        if let value = item.locationText { sharedItem["locationText"] = value }
        sharedPlan.append(sharedItem)
        // Persist every usable item immediately. Widget extensions have a
        // short execution budget and can be terminated between downloads;
        // keeping partial progress prevents a successful first/second image
        // from being discarded with the rest of the unfinished batch.
        persistCarouselPlan(sharedPlan, defaults: defaults)
      } catch {
        continue
      }
    }
    guard !entries.isEmpty else { throw BloomWidgetNetworkError.invalidResponse }
    persistCarouselPlan(sharedPlan, defaults: defaults)
    entries.sort { $0.date < $1.date }
    // Refill while one prefetched entry is still available. WidgetKit may
    // delay networking, but the already-created timeline keeps switching.
    let refill: Date? = if entries.count >= 3 {
      entries[entries.count - 2].date
    } else if entries.count == 2 {
      entries.last?.date
    } else {
      parseDate(payload.nextCheckAt)
    }
    return (entries, nextCarouselCheck(proposed: refill, defaults: defaults))
  }

  private static func persistCarouselPlan(
    _ plan: [[String: Any]],
    defaults: UserDefaults
  ) {
    guard let data = try? JSONSerialization.data(withJSONObject: plan),
          let encoded = String(data: data, encoding: .utf8) else { return }
    defaults.set(encoded, forKey: "iosCarouselPlan")
    defaults.synchronize()
  }

  private static func entry(
    _ content: BloomRemoteContent,
    at date: Date = Date()
  ) -> BloomEntry {
    BloomEntry(
      date: date,
      compositeImage: nil,
      photoImage: UIImage(contentsOfFile: content.photoPath),
      captionZh: content.captionZh,
      captionEn: content.captionEn,
      capturedDateText: content.capturedDateText,
      locationText: content.locationText
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
    mode: String = "recommendation"
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
      defaults.set(file.path, forKey: "iosWidgetPhotoPath")
      defaults.set(revision, forKey: "iosWidgetRevision")
      defaults.set(caption?.zh, forKey: "iosWidgetCaptionZh")
      defaults.set(caption?.en, forKey: "iosWidgetCaptionEn")
      defaults.set(capturedDateText, forKey: "iosWidgetCapturedDate")
      defaults.set(locationText, forKey: "iosWidgetLocation")
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
