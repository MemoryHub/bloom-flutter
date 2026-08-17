import 'dart:io';
import 'package:bloom_widget_bridge/bloom_widget_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BloomDisplayMode { recommendation, carousel }

class BloomDisplaySettings {
  const BloomDisplaySettings({
    this.mode = BloomDisplayMode.recommendation,
    this.intervalMinutes = 1440,
    this.activeStart = '06:00',
    this.activeEnd = '22:00',
  });

  static const allowedIntervals = <int>[
    15,
    30,
    60,
    120,
    180,
    240,
    300,
    360,
    420,
    480,
    540,
    600,
    660,
    720,
    780,
    840,
    900,
    960,
    1020,
    1080,
    1140,
    1200,
    1260,
    1320,
    1380,
    1440,
  ];

  final BloomDisplayMode mode;
  final int intervalMinutes;
  final String activeStart;
  final String activeEnd;

  BloomDisplaySettings copyWith({
    BloomDisplayMode? mode,
    int? intervalMinutes,
    String? activeStart,
    String? activeEnd,
  }) => BloomDisplaySettings(
    mode: mode ?? this.mode,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    activeStart: activeStart ?? this.activeStart,
    activeEnd: activeEnd ?? this.activeEnd,
  );

  String get intervalLabel {
    if (intervalMinutes == 1440) return '每天一次';
    if (intervalMinutes == 15 || intervalMinutes == 30) {
      return '每$intervalMinutes分钟';
    }
    return '每${intervalMinutes ~/ 60}小时';
  }

  int get expectedDailyItems {
    if (intervalMinutes == 1440) return 1;
    final start = _minutes(activeStart);
    final end = _minutes(activeEnd);
    if (start == null || end == null || end <= start) return 0;
    return ((end - start - 1) ~/ intervalMinutes) + 1;
  }

  static int? _minutes(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      return null;
    }
    return hour * 60 + minute;
  }
}

class DisplayPreferences {
  static const _modeKey = 'bloom.display_mode';
  static const _intervalKey = 'bloom.carousel_interval_minutes';
  static const _startKey = 'bloom.carousel_active_start';
  static const _endKey = 'bloom.carousel_active_end';

  Future<BloomDisplaySettings> read() async {
    if (Platform.isIOS) {
      final values =
          await BloomWidgetBridgePlatform.readDisplayPreferences() ?? const {};
      final rawMode = values['mode'] as String?;
      final interval = (values['intervalMinutes'] as num?)?.toInt() ?? 1440;
      return BloomDisplaySettings(
        mode:
            rawMode == 'carousel'
                ? BloomDisplayMode.carousel
                : BloomDisplayMode.recommendation,
        intervalMinutes:
            BloomDisplaySettings.allowedIntervals.contains(interval)
                ? interval
                : 1440,
        activeStart: values['activeStart'] as String? ?? '06:00',
        activeEnd: values['activeEnd'] as String? ?? '22:00',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final rawMode = prefs.getString(_modeKey);
    final interval = prefs.getInt(_intervalKey) ?? 1440;
    return BloomDisplaySettings(
      mode:
          rawMode == 'carousel'
              ? BloomDisplayMode.carousel
              : BloomDisplayMode.recommendation,
      intervalMinutes:
          BloomDisplaySettings.allowedIntervals.contains(interval)
              ? interval
              : 1440,
      activeStart: prefs.getString(_startKey) ?? '06:00',
      activeEnd: prefs.getString(_endKey) ?? '22:00',
    );
  }

  Future<void> write(BloomDisplaySettings settings) async {
    if (Platform.isIOS) {
      await BloomWidgetBridgePlatform.writeDisplayPreferences(
        mode:
            settings.mode == BloomDisplayMode.carousel
                ? 'carousel'
                : 'recommendation',
        intervalMinutes: settings.intervalMinutes,
        activeStart: settings.activeStart,
        activeEnd: settings.activeEnd,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _modeKey,
      settings.mode == BloomDisplayMode.carousel
          ? 'carousel'
          : 'recommendation',
    );
    await prefs.setInt(_intervalKey, settings.intervalMinutes);
    await prefs.setString(_startKey, settings.activeStart);
    await prefs.setString(_endKey, settings.activeEnd);
  }
}
