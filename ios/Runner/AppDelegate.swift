import BackgroundTasks
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
    // **插件注册必须显式发生，漏掉它等于关掉整个 iOS 后台补货。**
    //
    // Flutter 官方模板在 didFinishLaunching 里调用
    // `GeneratedPluginRegistrant.register(with: self)`，本项目此前没有这一行
    // ——全仓库唯一一次出现是在下面 `setPluginRegistrantCallback` 的闭包里，
    // 那是后台 isolate 用的，跟主 App 无关。于是主 App 一个插件都没注册。
    //
    // 之所以一直没暴露：iOS 上的存储全部刻意绕开了插件，走本类手写的
    // `com.bloom/widget` 通道（设备身份用 Keychain、显示偏好用 App Group、
    // 缓存目录用 App Group），所以 4 个插件里有 3 个「没注册也照样能用」。
    // 唯独 `workmanager` 没有替代通道，它安静地失败在 `_guardBackgroundSync`
    // 的 catch 里：回调句柄没写进 `UserDefaults(suiteName:)`，
    // `BGAppRefreshTaskRequest` 因此一次都没提交过。
    //
    // 后果与实测一致：iOS 侧没有任何后台补货，池子（当前格 + 未来 4 格）走完
    // 之后小组件定格，只有手动打开 App 才会前进。「苹果只显示预存照片」就是它。
    //
    // 位置：官方模板放在 `super` 之前；本机 iOS 18 上那样会拿到 nil registrar
    // 并在第一个 Swift 插件桥接时崩溃（见上面的说明），所以放在 `super` 之后。
    GeneratedPluginRegistrant.register(with: self)
    // The storyboard FlutterViewController is attached after the launch
    // callback. Register only Bloom's own channel on the next main-loop turn;
    // no Flutter plugin registrar is involved here.
    // **一次性清掉重写前遗留的键。** 现在没有任何代码读它们了，但老版本写下的
    // 值还躺在 App Group 的 UserDefaults 里，`iosLastShownItemId` 就是其中之一。
    // 留着它们只会让后来人误以为还存在第二份真相。
    Self.purgeLegacyCarouselKeys()
    Self.registerBackgroundSync()
    // **把「系统手里到底有没有我们的后台请求」写成可读的证据。**
    //
    // 2026-09-30 实测：句柄已正确落盘（`initialize` 通了），但 iPhone 整夜
    // 9 小时一次 `BGAppRefreshTask` 都没执行，而同一夜 WidgetKit 唤起了扩展
    // 十几次。这两件事必须能区分开：
    //   * 请求根本没提交 → 代码问题，能修
    //   * 请求在队列里但系统不给跑 → 系统策略问题（后台 App 刷新被关、低电量
    //     模式、或纯粹没轮到）
    // 在此之前只能靠推断，代价是整夜的等待。`getPendingTaskRequests` 是系统
    // 给出的唯一权威答案，写进 App Group 就能直接从电脑上读出来。
    //
    // 分两次读：第一次在 Dart 的 `registerPeriodicTask` 之前，第二次在其之后，
    // 这样「提交前 / 后」的差别也看得出来。
    for delay in [3.0, 20.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        Self.recordPendingBackgroundTasks()
      }
    }
    DispatchQueue.main.async { [weak self] in
      self?.configureBloomWidgetChannelWhenReady()
    }
    return didFinish
  }

  /// 把 `BGTaskScheduler` 里待执行的请求写进 App Group，供离线诊断读取。
  ///
  /// 正常情况下应当能看到 `com.bloom.bloom.dailySync`；列表为空说明请求压根
  /// 没提交成功（即 `registerPeriodicTask` 那一步失败了）。
  private static func recordPendingBackgroundTasks() {
    guard #available(iOS 13.0, *) else { return }
    BGTaskScheduler.shared.getPendingTaskRequests { requests in
      let summary = requests
        .map { request -> String in
          let begin = request.earliestBeginDate
            .map { String(Int($0.timeIntervalSince1970)) } ?? "-"
          return "\(request.identifier)@\(begin)"
        }
        .joined(separator: ",")
      guard let defaults = UserDefaults(suiteName: bloomAppGroup) else { return }
      defaults.set(summary, forKey: "bloom.pendingBgTasks")
      defaults.set(
        Int(Date().timeIntervalSince1970 * 1000),
        forKey: "bloom.pendingBgTasksAt"
      )
      // **系统级的「后台 App 刷新」开关状态。**
      //
      // 2026-09-30 实测：这个总开关一旦关闭，iOS 对**任何** App 都不会执行
      // `BGAppRefreshTask`。当时查了一整天代码（插件注册、handler 续排、提交
      // 路径），每一条都是真的问题、也都修对了，但**没有一条能让小组件动起来**
      // ——因为开关关着的时候，代码写得再对也一次都跑不起来。
      //
      // 症状是"iOS 只显示预存照片"，而它与任何代码缺陷的表现完全一样，从设备上
      // 分不出来。所以把它记下来：以后"系统到底让不让后台刷新"是一读就知道的
      // 事实，而不是要用户去翻设置才能确认的猜测。
      let refresh = UIApplication.shared.backgroundRefreshStatus
      let refreshText: String
      switch refresh {
      case .available: refreshText = "available"
      case .denied: refreshText = "denied"
      case .restricted: refreshText = "restricted"
      @unknown default: refreshText = "unknown"
      }
      defaults.set(refreshText, forKey: "bloom.bgRefreshStatus")
      defaults.synchronize()
    }
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
      // **自己注册 handler，而不是交给 `WorkmanagerPlugin.registerPeriodicTask`。**
      //
      // 插件那个 handler（`handlePeriodicTask`）的第一件事是查回调句柄，查不到就
      // **直接 `return`——连"续排下一次请求"都不做**（续排在它后面）。于是任务只要
      // 跑过一次却在那里提前返回，请求就被消费掉了：队列清空、下一次永远不来、
      // 而且没有任何痕迹。2026-09-30 实测到的正是"提交成功 + 队列为空 +
      // 后台从没跑过 Dart"。
      //
      // 这里改成：**先无条件续排一次**，再委托插件去跑 Dart。任何后续失败都不会
      // 再让链条断掉。执行时机仍由系统决定，但"下一次还排着"这件事由我们保证。
      let registered = BGTaskScheduler.shared.register(
        forTaskWithIdentifier: bgTaskIdentifier,
        using: nil
      ) { task in
        guard let refresh = task as? BGAppRefreshTask else {
          task.setTaskCompleted(success: false)
          return
        }
        Self.noteBackgroundTaskRan()
        Self.submitBackgroundRefresh(reason: "resubmit")
        SwiftWorkmanagerPlugin.handlePeriodicTask(
          identifier: Self.bgTaskIdentifier,
          task: refresh,
          earliestBeginInSeconds: 15 * 60
        )
      }
      // 后台 isolate 里也要能拿到插件，否则 Dart 侧的同步跑不起来。
      WorkmanagerPlugin.setPluginRegistrantCallback { registry in
        GeneratedPluginRegistrant.register(with: registry)
      }
      // **第一次提交也必须由我们自己发。**
      //
      // 插件把首次提交留给 Dart 的 `registerPeriodicTask`，而它在 `submit` 失败时
      // 只 `logInfo` 一句就把 `result(true)` 回给 Dart——失败在任何一端都看不见。
      // 自己提交一次，失败能被抓住、写进 App Group、也就能被修。
      //
      // `register` 的返回值同样**必须记下来**：注册失败时 `submit` 仍可能不报错，
      // 任务却永远唤不起来——那会表现成"提交成功、系统从不执行"，正是我们怀疑的
      // 那个症状，而它和"系统不给机会"是两回事。
      if let defaults = UserDefaults(suiteName: bloomAppGroup) {
        defaults.set(registered, forKey: "bloom.bgRegisterOk")
        defaults.synchronize()
      }
      submitBackgroundRefresh(reason: "launch")
    }
  }

  /// 后台任务真的被系统唤起过几次、最后一次是什么时候。
  ///
  /// 这是"系统到底有没有执行过我们"的唯一直接证据：Dart 侧只有真正跑到才会写
  /// `writer=app-background`，而系统可能唤起了却在插件里提前返回。
  private static func noteBackgroundTaskRan() {
    guard let defaults = UserDefaults(suiteName: bloomAppGroup) else { return }
    let count = defaults.integer(forKey: "bloom.bgTaskRuns") + 1
    defaults.set(count, forKey: "bloom.bgTaskRuns")
    defaults.set(
      Int(Date().timeIntervalSince1970 * 1000),
      forKey: "bloom.bgTaskLastAt"
    )
    defaults.synchronize()
  }

  /// 后台刷新任务的标识符。三处必须一致：本文件、`Info.plist` 的
  /// `BGTaskSchedulerPermittedIdentifiers`、Dart 的 `bloomDailySyncTask`。
  private static let bgTaskIdentifier = "com.bloom.bloom.dailySync"

  /// 提交一次 `BGAppRefreshTaskRequest`，并把结果写进 App Group。
  ///
  /// `bloom.bgSubmitResult` 会记录 `submitted` 或 `failed: <错误描述>`——这正是
  /// 之前完全不可见的那条信息。
  private static func submitBackgroundRefresh(reason: String) {
    guard #available(iOS 13.0, *) else { return }
    let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    let outcome: String
    do {
      try BGTaskScheduler.shared.submit(request)
      outcome = "submitted"
    } catch {
      outcome = "failed: \(error.localizedDescription)"
    }
    guard let defaults = UserDefaults(suiteName: bloomAppGroup) else { return }
    defaults.set(
      "\(reason) \(outcome) @\(Int(Date().timeIntervalSince1970))",
      forKey: "bloom.bgSubmitResult"
    )
    defaults.synchronize()
    NSLog("[Bloom] background refresh %@: %@", reason, outcome)
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
          "mode": defaults?.string(forKey: "bloom.display_mode") ?? "recommend",
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
