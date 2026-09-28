import 'package:bloom_widget_bridge/bloom_widget_bridge.dart';

export 'package:bloom_widget_bridge/bloom_widget_bridge.dart'
    show KeepAliveItem;

class WidgetBridge {
  Future<String?> cacheDirectory() =>
      BloomWidgetBridgePlatform.cacheDirectory();

  Future<void> update({
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
  }) async {
    await BloomWidgetBridgePlatform.update(
      portraitPath: portraitPath,
      squarePath: squarePath,
      largeSquarePath: largeSquarePath,
      originalPhotoPath: originalPhotoPath,
      date: date,
      recommendationId: recommendationId,
      captionZh: captionZh,
      captionEn: captionEn,
      capturedDateText: capturedDateText,
      locationText: locationText,
      mode: mode,
    );
  }

  Future<void> refresh() => BloomWidgetBridgePlatform.refresh();

  /// 后台保活自检：哪些开关还没开、以及怎么去开。
  ///
  /// **iOS 上恒为空列表**（见 [BloomWidgetBridgePlatform.keepAliveStatus]），
  /// 所以调用方不必判断平台，直接按「空就不渲染」处理即可。
  Future<List<KeepAliveItem>> keepAliveStatus() =>
      BloomWidgetBridgePlatform.keepAliveStatus();

  /// 跳到某一项的设置页。**false 表示跳不过去**，界面应改展示文字步骤。
  Future<bool> openKeepAlive(String id) =>
      BloomWidgetBridgePlatform.openKeepAlive(id);

  /// 用户确认「我已经开好了」。只对读不到状态的那一项有意义。
  Future<void> acknowledgeKeepAlive(String id) =>
      BloomWidgetBridgePlatform.acknowledgeKeepAlive(id);

  Future<void> scheduleCarousel({
    required int planId,
    required List<Map<String, Object?>> entries,
  }) => BloomWidgetBridgePlatform.scheduleCarousel(
    planId: planId,
    entries: entries,
  );

  Future<void> clearCarouselSchedule() =>
      BloomWidgetBridgePlatform.clearCarouselSchedule();

  Future<WidgetCurrentState?> readCurrentState() async {
    final raw = await BloomWidgetBridgePlatform.readCurrentWidgetState();
    if (raw == null) return null;
    String? stringValue(String key) => raw[key] as String?;
    final id = (raw['recommendationId'] as num?)?.toInt() ?? 0;
    if (id < 1) return null;
    return WidgetCurrentState(
      recommendationId: id,
      mode: stringValue('mode'),
      date: stringValue('date'),
      originalPhotoPath: stringValue('originalPhotoPath'),
      portraitPath: stringValue('portraitPath'),
      squarePath: stringValue('squarePath'),
      largeSquarePath: stringValue('largeSquarePath'),
      captionZh: stringValue('captionZh'),
      captionEn: stringValue('captionEn'),
      capturedDateText: stringValue('capturedDateText'),
      locationText: stringValue('locationText'),
      updatedAtMillis: (raw['updatedAtMillis'] as num?)?.toInt(),
    );
  }
}

class WidgetCurrentState {
  const WidgetCurrentState({
    required this.recommendationId,
    this.mode,
    this.date,
    this.originalPhotoPath,
    this.portraitPath,
    this.squarePath,
    this.largeSquarePath,
    this.captionZh,
    this.captionEn,
    this.capturedDateText,
    this.locationText,
    this.updatedAtMillis,
  });

  final int recommendationId;
  final String? mode;
  final String? date;
  final String? originalPhotoPath;
  final String? portraitPath;
  final String? squarePath;
  final String? largeSquarePath;
  final String? captionZh;
  final String? captionEn;
  final String? capturedDateText;
  final String? locationText;
  final int? updatedAtMillis;
}
