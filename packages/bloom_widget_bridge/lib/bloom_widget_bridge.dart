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

  static Future<Map<Object?, Object?>?> readDisplayPreferences() =>
      _channel.invokeMapMethod<Object?, Object?>('readDisplayPreferences');

  static Future<void> writeDisplayPreferences({
    required String mode,
    required int intervalMinutes,
    required String activeStart,
    required String activeEnd,
  }) => _channel.invokeMethod<void>('writeDisplayPreferences', {
    'mode': mode,
    'intervalMinutes': intervalMinutes,
    'activeStart': activeStart,
    'activeEnd': activeEnd,
  });
}
