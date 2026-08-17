import 'package:bloom_widget_bridge/bloom_widget_bridge.dart';

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
