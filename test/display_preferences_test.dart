import 'dart:convert';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final credentials = DeviceCredentials(
    deviceId: 'bloom-mobile-test',
    deviceToken: 'a' * 64,
  );

  Map<String, dynamic> settingsPayload({
    int intervalMinutes = 45,
    int? dailySlotCount = 22,
    List<int> allowed = const [15, 30, 45, 60],
    String activeStart = '06:00',
    String activeEnd = '22:00',
  }) => {
    'api_version': 1,
    'settings': {
      'device_id': 'bloom-frame-1',
      'target': 'eink',
      'timezone': 'Asia/Shanghai',
      'active_start': activeStart,
      'active_end': activeEnd,
      'interval_minutes': intervalMinutes,
      if (dailySlotCount != null) 'daily_slot_count': dailySlotCount,
      'settings_hash': '6de216abc',
      'updated_at': '2026-09-21T10:00:00+08:00',
    },
    'allowed_interval_minutes': allowed,
    'next_check_at': '2026-09-21T10:30:00+08:00',
  };

  test('cacheLocal writes the four keys the native widgets read', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = DisplayPreferences();

    await preferences.cacheLocal(
      const BloomDisplaySettings(
        mode: BloomDisplayMode.carousel,
        intervalMinutes: 60,
        activeStart: '07:30',
        activeEnd: '21:15',
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    // Literal strings on purpose: Kotlin reads `flutter.bloom.display_mode`
    // (same key, Flutter's shared_preferences prefix) and Swift reads the
    // unprefixed name from the app group.
    expect(prefs.getString('bloom.display_mode'), 'carousel');
    expect(prefs.getInt('bloom.carousel_interval_minutes'), 60);
    expect(prefs.getString('bloom.carousel_active_start'), '07:30');
    expect(prefs.getString('bloom.carousel_active_end'), '21:15');

    expect(DisplayPreferences.modeKey, 'bloom.display_mode');
    expect(DisplayPreferences.intervalKey, 'bloom.carousel_interval_minutes');
    expect(DisplayPreferences.startKey, 'bloom.carousel_active_start');
    expect(DisplayPreferences.endKey, 'bloom.carousel_active_end');
  });

  test('read keeps a server interval that is not one of the UI tiers', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'bloom.display_mode': 'carousel',
      'bloom.carousel_interval_minutes': 1440,
      'bloom.carousel_active_start': '06:00',
      'bloom.carousel_active_end': '22:00',
    });
    final requests = <http.Request>[];
    final client = BloomApiClient(
      baseUrl: 'https://bloom.jihu.top',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(settingsPayload()),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final settings = await DisplayPreferences(
      api: client,
    ).read(credentials: credentials);

    // 45 is not in BloomDisplaySettings.allowedIntervals (15/30/60/120/720/1440).
    expect(BloomDisplaySettings.allowedIntervals, isNot(contains(45)));
    expect(settings.intervalMinutes, 45);
    expect(settings.intervalMinutes, isNot(1440));
    expect(settings.dailySlotCount, 22);
    expect(settings.expectedDailyItems, 22);
    expect(settings.allowedIntervalMinutes, const [15, 30, 45, 60]);
    expect(settings.timezone, 'Asia/Shanghai');
    // The display mode is phone-local and survives the server merge.
    expect(settings.mode, BloomDisplayMode.carousel);

    expect(requests, hasLength(1));
    expect(
      requests.single.url.path,
      '/api/frame/devices/bloom-mobile-test/carousel/settings/get',
    );
    expect(requests.single.headers['x-frame-token'], credentials.deviceToken);
    expect(jsonDecode(requests.single.body), {'target': 'eink'});

    // A successful server read refreshes the local mirror.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('bloom.carousel_interval_minutes'), 45);
    expect(prefs.getString('bloom.display_mode'), 'carousel');
  });

  test('read falls back to the local mirror when the server fails', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'bloom.display_mode': 'recommendation',
      'bloom.carousel_interval_minutes': 30,
      'bloom.carousel_active_start': '08:00',
      'bloom.carousel_active_end': '20:00',
    });
    final requests = <http.Request>[];
    final client = BloomApiClient(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{"detail":"upstream unavailable"}', 503);
      }),
    );

    final settings = await DisplayPreferences(
      api: client,
    ).read(credentials: credentials);

    expect(settings.intervalMinutes, 30);
    expect(settings.activeStart, '08:00');
    expect(settings.activeEnd, '20:00');
    expect(settings.timezone, DeviceCarouselSettings.defaultTimezone);
    expect(settings.dailySlotCount, isNull);
    // Only a read was attempted: local values are never pushed to the server.
    expect(requests, hasLength(1));
    expect(requests.single.url.path, endsWith('/carousel/settings/get'));
  });

  test('read without credentials never touches the network', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'bloom.carousel_interval_minutes': 180,
    });
    var calls = 0;
    final client = BloomApiClient(
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );

    final settings = await DisplayPreferences(api: client).read();

    // 180 is a legacy tier: accepted locally instead of rewritten to 1440.
    expect(settings.intervalMinutes, 180);
    expect(calls, 0);
  });

  test('intervalLabel covers the new tiers', () {
    expect(intervalLabel(720), '半天一次');
    expect(intervalLabel(1440), '每天一次');
    expect(intervalLabel(15), '每15分钟');
    expect(intervalLabel(30), '每30分钟');
    expect(intervalLabel(60), '每1小时');
    expect(intervalLabel(120), '每2小时');
    expect(intervalLabel(45), '每45分钟');
    expect(
      const BloomDisplaySettings(intervalMinutes: 720).intervalLabel,
      '半天一次',
    );
  });

  test('expectedDailyItems prefers the server slot count', () {
    const local = BloomDisplaySettings(
      intervalMinutes: 15,
      activeStart: '06:00',
      activeEnd: '22:00',
    );
    // Historical local formula (server reports 65 for the same window).
    expect(local.expectedDailyItems, 64);
    expect(local.copyWith(dailySlotCount: 65).expectedDailyItems, 65);
  });

  test('editing the schedule drops the stale server slot count', () {
    const fromServer = BloomDisplaySettings(
      intervalMinutes: 15,
      dailySlotCount: 65,
    );
    expect(fromServer.copyWith(intervalMinutes: 60).dailySlotCount, isNull);
    expect(fromServer.copyWith(activeStart: '07:00').dailySlotCount, isNull);
    expect(
      fromServer.copyWith(mode: BloomDisplayMode.carousel).dailySlotCount,
      65,
    );
  });

  test('DeviceCarouselSettings rejects a missing interval', () {
    expect(
      () => DeviceCarouselSettings.fromJson(const {
        'active_start': '06:00',
        'active_end': '22:00',
      }),
      throwsA(isA<FormatException>()),
    );
    final parsed = DeviceCarouselSettings.fromJson(const {
      'active_start': '06:00',
      'active_end': '22:00',
      'interval_minutes': 45,
    });
    expect(parsed.intervalMinutes, 45);
    expect(parsed.timezone, DeviceCarouselSettings.defaultTimezone);
    expect(parsed.dailySlotCount, isNull);
  });
}
