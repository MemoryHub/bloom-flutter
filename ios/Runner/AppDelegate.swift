import Flutter
import Security
import UIKit
import WidgetKit

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
    DispatchQueue.main.async { [weak self] in
      self?.configureBloomWidgetChannelWhenReady()
    }
    return didFinish
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
        WidgetCenter.shared.reloadAllTimelines()
        result(nil)
      case "scheduleCarousel":
        guard
          let arguments = call.arguments as? [String: Any],
          let planId = arguments["planId"] as? NSNumber,
          let entries = arguments["entries"] as? [[String: Any]],
          JSONSerialization.isValidJSONObject(entries),
          let data = try? JSONSerialization.data(withJSONObject: entries),
          let encoded = String(data: data, encoding: .utf8),
          let defaults = UserDefaults(suiteName: Self.bloomAppGroup)
        else {
          result(FlutterError(code: "invalid_carousel_plan", message: nil, details: nil))
          return
        }
        defaults.set(planId.intValue, forKey: "iosHostCarouselPlanId")
        defaults.set(encoded, forKey: "iosCarouselPlan")
        defaults.synchronize()
        WidgetCenter.shared.reloadAllTimelines()
        result(nil)
      case "clearCarouselSchedule":
        if let defaults = UserDefaults(suiteName: Self.bloomAppGroup) {
          defaults.removeObject(forKey: "iosHostCarouselPlanId")
          defaults.removeObject(forKey: "iosCarouselPlan")
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

    // WidgetKit advances future entries without launching Flutter. Resolve
    // the same shared plan here when the app is opened later.
    if mode == "carousel",
       let rawPlan = defaults.string(forKey: "iosCarouselPlan"),
       let data = rawPlan.data(using: .utf8),
       let plan = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      let now = Date().timeIntervalSince1970 * 1000
      let due = plan.compactMap { item -> [String: Any]? in
        guard let at = (item["displayAtMillis"] as? NSNumber)?.doubleValue, at <= now else { return nil }
        return item
      }.max { (left, right) in
        ((left["displayAtMillis"] as? NSNumber)?.doubleValue ?? 0) <
          ((right["displayAtMillis"] as? NSNumber)?.doubleValue ?? 0)
      }
      if let due,
         let id = (due["itemId"] as? NSNumber)?.intValue,
         let path = (due["photoPath"] as? String) ?? (due["originalPhotoPath"] as? String),
         FileManager.default.fileExists(atPath: path) {
        state["recommendationId"] = id
        state["originalPhotoPath"] = path
        put("portraitPath", due["portraitPath"] as? String)
        put("squarePath", due["squarePath"] as? String)
        put("largeSquarePath", due["largeSquarePath"] as? String)
        put("date", due["date"] as? String)
        put("captionZh", due["captionZh"] as? String)
        put("captionEn", due["captionEn"] as? String)
        put("capturedDateText", due["capturedDateText"] as? String)
        put("locationText", due["locationText"] as? String)
        state["updatedAtMillis"] = Int((due["displayAtMillis"] as? NSNumber)?.doubleValue ?? now)
      }
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
