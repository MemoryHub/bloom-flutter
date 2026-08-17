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
    case "stableDeviceCredentials":
      // iOS Keychain normally survives uninstall. Avoid identifierForVendor,
      // which can change after all apps from the vendor are removed.
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
