import Flutter
import UIKit
import WidgetKit

public final class BloomWidgetBridgePlugin: NSObject, FlutterPlugin {
  private static let appGroup = "group.com.zhangbo.bloom.zb20260815"


  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.bloom/widget", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BloomWidgetBridgePlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "cacheDirectory":
      guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroup
      ) else {
        result(FlutterError(code: "app_group_unavailable", message: "Bloom App Group is unavailable", details: nil))
        return
      }
      let directory = container.appendingPathComponent("widget-cache", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      result(directory.path)
    case "updateWidgetCache":
      if let arguments = call.arguments as? [String: Any],
         let defaults = UserDefaults(suiteName: Self.appGroup) {
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
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: "updatedAtMillis")
      }
      WidgetCenter.shared.reloadAllTimelines()
      result(nil)
    case "refreshWidgets":
      WidgetCenter.shared.reloadAllTimelines()
      result(nil)
    case "readCurrentWidgetState":
      guard let defaults = UserDefaults(suiteName: Self.appGroup) else {
        result(nil)
        return
      }
      result([
        "recommendationId": defaults.integer(forKey: "recommendationId"),
        "mode": defaults.string(forKey: "mode"),
        "date": defaults.string(forKey: "date"),
        "originalPhotoPath": defaults.string(forKey: "widgetCurrentOriginalPhotoPath"),
        "portraitPath": defaults.string(forKey: "portraitPath"),
        "squarePath": defaults.string(forKey: "squarePath"),
        "largeSquarePath": defaults.string(forKey: "largeSquarePath"),
        "captionZh": defaults.string(forKey: "captionZh"),
        "captionEn": defaults.string(forKey: "captionEn"),
        "capturedDateText": defaults.string(forKey: "capturedDateText"),
        "locationText": defaults.string(forKey: "locationText"),
        "updatedAtMillis": Int(defaults.double(forKey: "updatedAtMillis")),
      ])
    case "writeDeviceCredentials":
      // First-login mirroring must work while AppDelegate is still attaching
      // its richer channel; an unimplemented response leaves a stale token.
      guard let arguments = call.arguments as? [String: Any],
            let deviceID = arguments["deviceId"] as? String,
            let token = arguments["deviceToken"] as? String,
            let defaults = UserDefaults(suiteName: Self.appGroup) else {
        result(FlutterError(code: "bad_arguments", message: nil, details: nil))
        return
      }
      let changed = defaults.string(forKey: "bloom.device_id") != deviceID ||
        defaults.string(forKey: "bloom.device_token") != (token.isEmpty ? nil : token)
      if token.isEmpty {
        defaults.removeObject(forKey: "bloom.device_token")
      } else {
        defaults.set(deviceID, forKey: "bloom.device_id")
        defaults.set(token, forKey: "bloom.device_token")
      }
      defaults.synchronize()
      if changed { WidgetCenter.shared.reloadAllTimelines() }
      result(nil)
    case "stableDeviceCredentials":
      // 【已废】这个方法在 iOS 上由 AppDelegate 实现（Keychain + App Group）。
      //
      // 这里原来也实现过一次，后果是**同一个通道名 com.bloom/widget 被注册
      // 两遍**，而 FlutterMethodChannel 是同名覆盖：谁后 setMethodCallHandler
      // 谁生效。本插件由 GeneratedPluginRegistrant 先注册，AppDelegate 之后
      // 靠一个"等 rootViewController 出现"的循环抢回来 —— 那个循环有 2 秒硬
      // 上限且**静默放弃**。首次安装启动慢，抢不回来，通道上留下的就是这个
      // 返回 nil 的空壳：设备身份拿不到，App 卡在配对页；杀掉重开就好了。
      //
      // 现在设备身份改为**本地随机生成 + 登录时由服务端绑定**，不再需要跨重装
      // 稳定，方法本身已无人调用；保留 case 只为让老客户端拿到一个明确的错误
      // 而不是 FlutterMethodNotImplemented。
      result(
        FlutterError(
          code: "moved_to_app_delegate",
          message: "设备身份现在由 AppDelegate 提供",
          details: nil
        )
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
