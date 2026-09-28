import Flutter
import Security
import UIKit
import WidgetKit
import workmanager

@main
@objc class AppDelegate: FlutterAppDelegate {
  private static let bloomAppGroup = "group.com.zhangbo.bloom.zb20260815"
  private var bloomWidgetChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // FlutterAppDelegate must finish creating the storyboard-backed
    // FlutterViewController before plugins ask it for a registrar.  On the
    // iOS 18 device this app targets, registering first returned a nil
    // registrar and crashed as soon as the first Swift plugin was bridged.
    let didFinish = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    // The storyboard FlutterViewController is attached after the launch
    // callback. Register only Bloom's own channel on the next main-loop turn;
    // no Flutter plugin registrar is involved here.
    // **一次性清掉重写前遗留的键。** 现在没有任何代码读它们了，但老版本写下的
    // 值还躺在 App Group 的 UserDefaults 里，`iosLastShownItemId` 就是其中之一。
    // 留着它们只会让后来人误以为还存在第二份真相。
    Self.purgeLegacyCarouselKeys()
    Self.registerBackgroundSync()
    DispatchQueue.main.async { [weak self] in
      self?.configureBloomWidgetChannelWhenReady()
    }
    return didFinish
  }

  /// 当前显示内容的指纹：`item_id@slot_at_ms`。**与安卓侧用同一个判据。**
  ///
  /// 用它去重，避免每次 tick 都消耗一次 WidgetKit 的重绘配额。
  private static let widgetStampKey = "lastPushedWidgetStamp"

  private static func currentEntryStamp() -> String {
    guard let state = BloomSharedState.load(),
          let entry = BloomCarouselRule.currentEntry(
            BloomSharedState.timelineEntries(state),
            nowMillis: Date().timeIntervalSince1970 * 1000
          ) else { return "0@0" }
    let id = (entry["item_id"] as? NSNumber)?.intValue ?? 0
    let at = (entry["date_ms"] as? NSNumber)?.int64Value ?? 0
    return "\(id)@\(at)"
  }

  /// **把后台周期任务登记到 iOS。** 这是 iOS 与安卓同构的那一半。
  ///
  /// 安卓侧早已接好：`WorkManager` 周期唤醒 → `BloomFlutterSync` 起 headless
  /// FlutterEngine → 跑 `lib/background_sync.dart` 里那个
  /// `@pragma('vm:entry-point')` 回调。而 iOS 侧一直缺这段登记——
  /// `Info.plist` 里声明了标识符、Dart 里也写好了任务，但**没有任何代码调用
  /// `BGTaskScheduler.register`**，系统因此永远不会唤我们。
  ///
  /// 后果与安卓实测一致：原生只剩精确闹钟链，而它**只做纯查表、不下载照片**，
  /// 所以窗口（当前格 + 未来 4 格）用完之后小组件就定格，直到用户手动打开 App。
  ///
  /// `registerPeriodicTask` 内部就是 `BGTaskScheduler.shared.register`，
  /// **必须在 didFinishLaunching 里调用**（iOS 的硬性要求），所以放在这里。
  ///
  /// 注意 iOS 的行为边界：执行时机由系统按用户使用习惯决定，**不保证准点**。
  /// 它负责"不断备货"，准点仍由闹钟/WidgetKit 负责。
  private static func registerBackgroundSync() {
    if #available(iOS 13.0, *) {
      // 标识符必须与 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 一致。
      WorkmanagerPlugin.registerPeriodicTask(
        withIdentifier: "com.bloom.bloom.dailySync",
        frequency: NSNumber(value: 15 * 60)
      )
      // 后台 isolate 里也要能拿到插件，否则 Dart 侧的同步跑不起来。
      WorkmanagerPlugin.setPluginRegistrantCallback { registry in
        GeneratedPluginRegistrant.register(with: registry)
      }
    }
  }

  /// 删除轮播重写（2026-09）之前遗留的持久化键。
  ///
  /// 这些键比轮播重写早一个多月（最初提交 2026-08-17）。它们的读取端已全部
  /// 删除，写入端也已停止；这里把最后残留的值抹掉，让共享状态成为唯一的真相。
  /// 幂等：删不存在的键没有副作用。
  private static func purgeLegacyCarouselKeys() {
    guard let defaults = UserDefaults(suiteName: bloomAppGroup) else { return }
    for key in [
      "iosCarouselPlan",          // 扩展自建的第二份计划表（陈旧表，曾让文案恒为 4406）
      "iosCarouselPlanDay",
      "iosHostCarouselPlanId",
      "iosLastShownItemId",       // 「不得倒退」的地板阈值，已无读者
      "iosWidgetPhotoPath",       // 旧的照片/文案持久化——照片与文案存在两个键里
      "iosWidgetRevision",
      "iosWidgetCaptionZh",
      "iosWidgetCaptionEn",
      "iosWidgetCapturedDate",
      "iosWidgetLocation",
    ] {
      defaults.removeObject(forKey: key)
    }
    defaults.synchronize()
  }

  private func configureBloomWidgetChannelWhenReady(attempt: Int = 0) {
    if let controller = window?.rootViewController as? FlutterViewController {
      configureBloomWidgetChannel(controller)
      return
    }
    guard attempt < 40 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.configureBloomWidgetChannelWhenReady(attempt: attempt + 1)
    }
  }

  private func configureBloomWidgetChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.bloom/widget",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "cacheDirectory":
        guard let container = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: Self.bloomAppGroup
        ) else {
          result(FlutterError(
            code: "app_group_unavailable",
            message: "Bloom App Group is unavailable",
            details: nil
          ))
          return
        }
        let directory = container.appendingPathComponent("widget-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        result(directory.path)
      case "updateWidgetCache":
        if let arguments = call.arguments as? [String: Any],
           let defaults = UserDefaults(suiteName: Self.bloomAppGroup) {
          // Flutter encodes Dart null values as NSNull in a method-channel
          // map. UserDefaults cannot store NSNull and aborts the process on
          // iOS 18, so optional widget metadata must be set or removed.
          func setOptional(_ key: String, _ value: Any?) {
            if let value, !(value is NSNull) {
              defaults.set(value, forKey: key)
            } else {
              defaults.removeObject(forKey: key)
            }
          }
          setOptional("portraitPath", arguments["portraitPath"])
          setOptional("squarePath", arguments["squarePath"])
          setOptional("largeSquarePath", arguments["largeSquarePath"])
          setOptional("widgetCurrentOriginalPhotoPath", arguments["originalPhotoPath"])
          setOptional("date", arguments["date"])
          setOptional("recommendationId", arguments["recommendationId"])
          setOptional("captionZh", arguments["captionZh"])
          setOptional("captionEn", arguments["captionEn"])
          setOptional("capturedDateText", arguments["capturedDateText"])
          setOptional("locationText", arguments["locationText"])
          setOptional("mode", arguments["mode"])
          setOptional("widgetCurrentPortraitPath", arguments["portraitPath"])
          setOptional("widgetCurrentSquarePath", arguments["squarePath"])
          setOptional("widgetCurrentLargeSquarePath", arguments["largeSquarePath"])
          defaults.set(Date().timeIntervalSince1970 * 1000, forKey: "updatedAtMillis")
          // Mark this cache as an explicit host-app render.  A WidgetKit
          // timeline reload may start its own network request immediately;
          // without this marker that request can replace the PNG that the
          // user has just selected in the app before it is ever displayed.
          defaults.set(
            Date().timeIntervalSince1970,
            forKey: "appWidgetUpdatedAt"
          )
          // The app and extension are separate processes. Flush the tiny
          // manifest before asking WidgetKit to create the new timeline.
          defaults.synchronize()
        }
        WidgetCenter.shared.reloadAllTimelines()
        // Immediately after installation WidgetKit can still be registering
        // the new extension/timeline. A single delayed retry avoids leaving
        // the first snapshot stale until the user's next manual action.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          WidgetCenter.shared.reloadAllTimelines()
        }
        result(nil)
      case "refreshWidgets":
        // **只在画面真的会变时才请小组件重绘。**
        //
        // WidgetKit 的重绘是有配额的。这里原本**每次 tick 都无条件**调用
        // `reloadAllTimelines()`，而一次换图前后会有好几次 tick（对表、预取、替补、
        // 提交），配额很快被烧光——于是**真正要紧的那次被系统推迟**。
        //
        // 实测 23:22：App 已经把当前格推进到 4431 并发了重绘请求，小组件却还停在
        // 上一次烘焙的旧时间线上（显示「花开得正好，你也刚好在看我」，而该条目
        // 已经不在时间线里了）。这不是"数据没前进"，是"重绘没生效"。
        //
        // 判据与安卓侧完全一致：`current_item_id@current_slot_at_ms` 变了才重绘。
        let stamp = Self.currentEntryStamp()
        if UserDefaults.standard.string(forKey: Self.widgetStampKey) != stamp {
          UserDefaults.standard.set(stamp, forKey: Self.widgetStampKey)
          WidgetCenter.shared.reloadAllTimelines()
        }
        result(nil)
      case "scheduleCarousel":
        // **Retired.** The host app used to push a baked entry list here, which
        // the extension then merged into `iosCarouselPlan` — a *second* writer
        // of the carousel plan next to the extension's own fetches, and the
        // reason the app and the widget could disagree about what was on the
        // wall.
        //
        // The authoritative plan now travels through the shared state file
        // (`carousel-state.json`, written by the single Dart writer and read by
        // the extension through `BloomSharedState`). The method name is kept so
        // an older client calling it does not crash; it simply reloads the
        // timelines and lets the extension read the shared state.
        WidgetCenter.shared.reloadAllTimelines()
        result(nil)
      case "clearCarouselSchedule":
        if let defaults = UserDefaults(suiteName: Self.bloomAppGroup) {
          defaults.removeObject(forKey: "iosHostCarouselPlanId")
          defaults.removeObject(forKey: "iosCarouselPlan")
          defaults.removeObject(forKey: "iosCarouselPlanDay")
          defaults.synchronize()
        }
        WidgetCenter.shared.reloadAllTimelines()
        result(nil)
      case "readCurrentWidgetState":
        result(Self.currentWidgetState())
      case "stableDeviceCredentials":
        let credentials = Self.stableDeviceCredentials()
        if let credentials,
           let defaults = UserDefaults(suiteName: Self.bloomAppGroup) {
          defaults.set(credentials["deviceId"], forKey: "bloom.device_id")
          defaults.set(credentials["deviceToken"], forKey: "bloom.device_token")
        }
        result(credentials)
      case "readDisplayPreferences":
        let defaults = UserDefaults(suiteName: Self.bloomAppGroup)
        result([
          "mode": defaults?.string(forKey: "bloom.display_mode") ?? "recommendation",
          "intervalMinutes": defaults?.integer(forKey: "bloom.carousel_interval_minutes") ?? 1440,
          "activeStart": defaults?.string(forKey: "bloom.carousel_active_start") ?? "06:00",
          "activeEnd": defaults?.string(forKey: "bloom.carousel_active_end") ?? "22:00",
        ])
      case "writeDisplayPreferences":
        guard
          let arguments = call.arguments as? [String: Any],
          let defaults = UserDefaults(suiteName: Self.bloomAppGroup)
        else {
          result(FlutterError(code: "invalid_preferences", message: nil, details: nil))
          return
        }
        defaults.set(arguments["mode"], forKey: "bloom.display_mode")
        defaults.set(arguments["intervalMinutes"], forKey: "bloom.carousel_interval_minutes")
        defaults.set(arguments["activeStart"], forKey: "bloom.carousel_active_start")
        defaults.set(arguments["activeEnd"], forKey: "bloom.carousel_active_end")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    bloomWidgetChannel = channel
  }

  /// The local day (`yyyy-MM-dd`) a shared carousel plan belongs to — the iOS
  /// half of the cursor bookkeeping the Dart repository keeps in its pool file.
  private static func localDay(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private static let keychainService = "com.zhangbo.bloom.device-identity"

  private static func currentWidgetState() -> [String: Any]? {
    guard let defaults = UserDefaults(suiteName: bloomAppGroup) else { return nil }
    let mode = defaults.string(forKey: "mode") ?? defaults.string(forKey: "bloom.display_mode")
    var state: [String: Any] = [
      "recommendationId": defaults.integer(forKey: "recommendationId"),
      "updatedAtMillis": Int(defaults.double(forKey: "updatedAtMillis")),
    ]
    func put(_ key: String, _ value: String?) {
      if let value { state[key] = value }
    }
    put("mode", mode)
    put("date", defaults.string(forKey: "date"))
    put("originalPhotoPath", defaults.string(forKey: "widgetCurrentOriginalPhotoPath"))
    put("portraitPath", defaults.string(forKey: "widgetCurrentPortraitPath") ?? defaults.string(forKey: "portraitPath"))
    put("squarePath", defaults.string(forKey: "widgetCurrentSquarePath") ?? defaults.string(forKey: "squarePath"))
    put("largeSquarePath", defaults.string(forKey: "widgetCurrentLargeSquarePath") ?? defaults.string(forKey: "largeSquarePath"))
    put("captionZh", defaults.string(forKey: "captionZh"))
    put("captionEn", defaults.string(forKey: "captionEn"))
    put("capturedDateText", defaults.string(forKey: "capturedDateText"))
    put("locationText", defaults.string(forKey: "locationText"))

    // **旧的 `iosCarouselPlan` 路径已删除。**
    //
    // 那是重写之前（2026-08-17 初始提交）的第二写者留下的计划表。它是个陷阱：
    // 表里的最后一条永远胜出——实测 17:00 之后任何时刻都解析出 item 4406，
    // 于是不管小组件正在显示哪张照片，首页文案都被覆盖成 4406 的
    // 「被稳稳抱在怀里的安全感，比什么都重要」。照片来自新源、文案来自旧表，
    // 两者必然错配。
    //
    // 现在与小组件走**同一条规则、同一份数据**：共享状态里 `date_ms <= now`
    // 的最后一条。照片与文案取自**同一条目**，错配在结构上就不可能发生。
    // 安卓原生读的也是这份状态，三端因此同源。
    if mode == "carousel",
       let shared = BloomSharedState.load(),
       let due = BloomCarouselRule.currentEntry(
         BloomSharedState.timelineEntries(shared),
         nowMillis: Date().timeIntervalSince1970 * 1000
       ) {
      state["recommendationId"] = (due["item_id"] as? NSNumber)?.intValue ?? 0
      put("originalPhotoPath", due["original_path"] as? String)
      put("portraitPath", due["portrait_path"] as? String)
      put("squarePath", due["square_path"] as? String)
      put("largeSquarePath", due["large_square_path"] as? String)
      put("date", due["date"] as? String)
      // 文案与照片出自同一条目——这是本次修复的核心。
      put("captionZh", due["caption_zh"] as? String)
      put("captionEn", due["caption_en"] as? String)
      put("capturedDateText", due["captured_date_text"] as? String)
      put("locationText", due["location_text"] as? String)
      state["updatedAtMillis"] = Int((due["date_ms"] as? NSNumber)?.doubleValue ?? 0)
    }
    guard (state["recommendationId"] as? Int ?? 0) > 0 else { return nil }
    return state
  }

  private static func stableDeviceCredentials() -> [String: String]? {
    let idAccount = "device-id"
    let tokenAccount = "device-token"
    if let id = keychainRead(account: idAccount),
       let token = keychainRead(account: tokenAccount),
       token.count >= 32 {
      return ["deviceId": id, "deviceToken": token]
    }

    // The widget already needs the credentials in the shared App Group.  If
    // Keychain is temporarily unavailable (or the signing profile changed),
    // restore the exact previous pair instead of silently creating a new
    // device that would require pairing again.
    if let defaults = UserDefaults(suiteName: bloomAppGroup),
       let id = defaults.string(forKey: "bloom.device_id"),
       let token = defaults.string(forKey: "bloom.device_token"),
       !id.isEmpty,
       token.count >= 32 {
      _ = keychainWrite(id, account: idAccount)
      _ = keychainWrite(token, account: tokenAccount)
      return ["deviceId": id, "deviceToken": token]
    }

    let id = "bloom-mobile-\(UUID().uuidString.lowercased())"
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      return nil
    }
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    guard keychainWrite(id, account: idAccount),
          keychainWrite(token, account: tokenAccount) else {
      return nil
    }
    return ["deviceId": id, "deviceToken": token]
  }

  private static func keychainRead(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func keychainWrite(_ value: String, account: String) -> Bool {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]
    let data = Data(value.utf8)
    let updateStatus = SecItemUpdate(
      base as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return true }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }
}
