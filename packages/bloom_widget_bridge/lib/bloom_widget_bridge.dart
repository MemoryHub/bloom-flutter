import 'dart:io';

import 'package:flutter/services.dart';

class BloomWidgetBridgePlatform {
  static const _channel = MethodChannel('com.bloom/widget');

  static Future<String?> cacheDirectory() =>
      _channel.invokeMethod<String>('cacheDirectory');

  static Future<void> update({
    required String portraitPath,
    String? squarePath,
    String? largeSquarePath,
    String? originalPhotoPath,
    required String date,
    required int recommendationId,
    String? captionZh,
    String? captionEn,
    String? capturedDateText,
    String? locationText,
    String? mode,
  }) => _channel.invokeMethod<void>('updateWidgetCache', {
    'portraitPath': portraitPath,
    'squarePath': squarePath,
    'largeSquarePath': largeSquarePath,
    'originalPhotoPath': originalPhotoPath,
    'date': date,
    'recommendationId': recommendationId,
    'captionZh': captionZh,
    'captionEn': captionEn,
    'capturedDateText': capturedDateText,
    'locationText': locationText,
    'mode': mode,
  });

  static Future<void> refresh() =>
      _channel.invokeMethod<void>('refreshWidgets');

  static Future<void> scheduleCarousel({
    required int planId,
    required List<Map<String, Object?>> entries,
  }) => _channel.invokeMethod<void>('scheduleCarousel', {
    'planId': planId,
    'entries': entries,
  });

  static Future<void> clearCarouselSchedule() =>
      _channel.invokeMethod<void>('clearCarouselSchedule');

  static Future<Map<Object?, Object?>?> readCurrentWidgetState() =>
      _channel.invokeMapMethod<Object?, Object?>('readCurrentWidgetState');

  static Future<Map<String, String>?> stableDeviceCredentials() async {
    final value = await _channel.invokeMapMethod<String, String>(
      'stableDeviceCredentials',
    );
    return value;
  }

  /// 把设备身份写进原生侧与小组件共享的那块存储。
  ///
  /// **iOS 上这不是可选的。** 小组件扩展是独立进程，它自己去拉
  /// `/carousel/plan`，令牌从 App Group 的 `bloom.device_id` /
  /// `bloom.device_token` 读（见 `BloomWidgets.swift` 的 `timeline`）；读不到就
  /// 退回缓存并等 30 分钟再试。
  ///
  /// 设备令牌以前是由 AppDelegate 顺手写进 App Group 的（在那个
  /// `stableDeviceCredentials` 分支里）。现在令牌改由服务端在登录时下发、
  /// 由 Dart 保存，所以必须显式镜像过去 —— 否则 iOS 小组件会静静地停止更新，
  /// 而 App 里一切正常，这是最难查的一类故障。
  ///
  /// Android 侧是同进程，Flutter 后台 isolate 直接读 SharedPreferences，
  /// 那里的实现是空操作。
  static Future<void> writeDeviceCredentials({
    required String deviceId,
    required String deviceToken,
  }) => _channel.invokeMethod<void>('writeDeviceCredentials', {
    'deviceId': deviceId,
    'deviceToken': deviceToken,
  });

  static Future<Map<Object?, Object?>?> readDisplayPreferences() =>
      _channel.invokeMapMethod<Object?, Object?>('readDisplayPreferences');

  static Future<void> writeDisplayPreferences({
    List<String> sources = const ['personal'],
    bool usesScheduledPlan = false,
    required String mode,
    required int intervalMinutes,
    required String activeStart,
    required String activeEnd,
  }) => _channel.invokeMethod<void>('writeDisplayPreferences', {
    'mode': mode,
    'sources': sources,
    'usesScheduledPlan': usesScheduledPlan,
    'intervalMinutes': intervalMinutes,
    'activeStart': activeStart,
    'activeEnd': activeEnd,
  });

  /// 后台保活自检：哪些开关还没开、以及怎么去开。
  ///
  /// **iOS 上恒为空**：那边没有任何需要用户授的权限——WidgetKit 的时间线由系统
  /// 自己驱动，不依赖 App 存活。所以这里直接返回空列表，界面自然不渲染，
  /// 不需要写任何 iOS 专属分支。
  static Future<List<KeepAliveItem>> keepAliveStatus() async {
    if (!Platform.isAndroid) return const [];
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'keepAliveStatus',
    );
    return [
      for (final item in raw ?? const <Map<Object?, Object?>>[])
        KeepAliveItem.fromMap(item),
    ];
  }

  /// 跳到某一项的设置页。**返回 false 表示跳不过去**（厂商页面路径变了或不存在），
  /// 此时界面应改展示 [KeepAliveItem.steps] 的文字步骤。
  /// 用户确认「我已经开好了」。只对 [KeepAliveItem.needsAck] 的项有意义——
  /// 系统读不到状态的那些（小米自启动）。存本地即可：这是用户的声明，
  /// 不是我们探测出来的事实。
  static Future<void> acknowledgeKeepAlive(String id) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('acknowledgeKeepAlive', {'id': id});
  }

  static Future<bool> openKeepAlive(String id) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('openKeepAlive', {'id': id}) ??
        false;
  }
}

/// 一个后台保活开关，由原生按机型和系统版本推导后传过来。
///
/// **Dart 侧不认识任何版本号**：小米5（Android 8）不会出现「精确闹钟」项，
/// 小米14（Android 14）会出现；换成非小米机型，「自启动」项自动消失。
/// 新增一个品牌只是原生那边加一行数据，界面一行都不用改。
class KeepAliveItem {
  const KeepAliveItem({
    required this.id,
    required this.title,
    required this.why,
    required this.satisfied,
    required this.canOpen,
    this.steps,
    this.needsAck = false,
  });

  final String id;
  final String title;
  final String why;

  /// true=已开启，false=未开启，**null=系统不提供查询接口**。
  ///
  /// 小米的自启动状态第三方读不到（securitycenter 的 provider 抛
  /// SecurityException），所以那一项永远是 null。界面必须把它显示成
  /// 「需手动确认」，**不能当成已开启给用户一个假的绿勾**。
  final bool? satisfied;

  /// 是否有一个确认存在的页面可以跳过去。
  final bool canOpen;

  /// 跳不过去时展示的手动步骤。
  final String? steps;

  /// 状态读不到、需要用户确认一次。界面据此显示「确认已开启」。
  final bool needsAck;

  static KeepAliveItem fromMap(Map<Object?, Object?> raw) => KeepAliveItem(
    id: raw['id'] as String? ?? '',
    title: raw['title'] as String? ?? '',
    why: raw['why'] as String? ?? '',
    satisfied: raw['satisfied'] as bool?,
    canOpen: raw['canOpen'] as bool? ?? false,
    steps: raw['steps'] as String?,
    needsAck: raw['needsAck'] as bool? ?? false,
  );
}
