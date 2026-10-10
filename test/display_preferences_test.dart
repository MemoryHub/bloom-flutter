import 'dart:convert';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  _carouselStashTests();

  _sourceWireTests();

  _sourcesTests();

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

  test(
    'recommendation shares the scheduled widget pipeline for art and personal photos',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = DisplayPreferences();
      const art = BloomDisplaySettings(
        mode: BloomDisplayMode.recommendation,
        sources: [BloomPhotoSource.personal, BloomPhotoSource.art],
      );
      expect(art.usesScheduledPlan, isTrue);
      await preferences.cacheLocal(art);
      final cached = await preferences.readLocal();
      expect(cached.mode, BloomDisplayMode.recommendation);
      expect(cached.sources, contains(BloomPhotoSource.art));
      expect(cached.usesScheduledPlan, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bloom.scheduled_plan'), isTrue);
      await preferences.cacheLocal(
        art.copyWith(sources: [BloomPhotoSource.personal]),
      );
      expect(prefs.getBool('bloom.scheduled_plan'), isTrue);
      expect(
        (await preferences.readLocal()).mode,
        BloomDisplayMode.recommendation,
      );
    },
  );
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
      'bloom.display_mode': 'recommend',
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

// ── 照片来源（sources）：协议词表 ─────────────────────────────────────
//
// sources 与 mode 正交：sources 决定"从哪些池子里取候选"，mode 决定
// "怎么给候选排序"。服务器对两者零特例，任意组合都合法。

void _sourcesTests() {
  group('BloomPhotoSource', () {
    test('wire 值与服务器 SUPPORTED_SOURCES 逐个一致', () {
      // 服务器那份名单是最权威的（frame-service/app/carousel.py）。
      // 这里钉死：客户端多认一个或少认一个，这条测试就会红。
      expect(
        BloomPhotoSource.values.map((s) => s.wire).toList(),
        bloomSourceWireValues,
      );
      expect(bloomSourceWireValues, ['personal', 'art', 'news', 'widget']);
    });

    test('四个值都在，且 personal 排第一（默认来源）', () {
      expect(BloomPhotoSource.values, hasLength(4));
      expect(BloomPhotoSource.values.first, BloomPhotoSource.personal);
    });

    test('fromWire 认协议值，认不出来返回 null 而不是猜', () {
      expect(BloomPhotoSource.fromWire('personal'), BloomPhotoSource.personal);
      expect(BloomPhotoSource.fromWire('art'), BloomPhotoSource.art);
      expect(BloomPhotoSource.fromWire('news'), BloomPhotoSource.news);
      expect(BloomPhotoSource.fromWire('widget'), BloomPhotoSource.widget);
      // 大小写、空格都不猜；未知来源留给服务器去丢弃并记警告。
      expect(BloomPhotoSource.fromWire('ART'), isNull);
      expect(BloomPhotoSource.fromWire(' personal'), isNull);
      expect(BloomPhotoSource.fromWire('hologram'), isNull);
      expect(BloomPhotoSource.fromWire(null), isNull);
    });

    test('implemented 只含真正能取到片的来源', () {
      // ⚠️ 服务器登记了四个，但只有 personal 能真正取出照片。
      // UI 若把 art/news/widget 也放出去，用户设完相框毫无变化 ——
      // 就是"设了没反应"。所以这里必须比 values 窄。
      expect(BloomPhotoSource.implemented, [
        BloomPhotoSource.personal,
        BloomPhotoSource.art,
      ]);
      expect(
        BloomPhotoSource.implemented.length,
        lessThan(BloomPhotoSource.values.length),
        reason: '登记 ≠ 实现；等 art 真能取片了再把这条改掉',
      );
    });

    test('label 与 wire 是两回事：label 可改，wire 不可改', () {
      expect(BloomPhotoSource.personal.label, '我的照片');
      expect(BloomPhotoSource.art.label, '艺术作品');
      // wire 是小写协议值，永远不要翻译。
      for (final s in BloomPhotoSource.values) {
        expect(s.wire, s.wire.toLowerCase());
      }
    });
  });
}

void _sourceWireTests() {
  group('来源的 wire 转换', () {
    test('转出去一律是对象形状，权重先占住', () {
      expect(bloomSourcesToWire([BloomPhotoSource.personal]), [
        {'name': 'personal', 'weight': 1},
      ]);
      expect(
        bloomSourcesToWire([BloomPhotoSource.personal, BloomPhotoSource.art]),
        [
          {'name': 'personal', 'weight': 1},
          {'name': 'art', 'weight': 1},
        ],
      );
    });

    test('空列表转出来是空 —— 调用方据此决定【不发送】', () {
      // 空列表不能当成"发 []"：服务器的语义是"没送 = 别动已存的值"，
      // 发 [] 会被 normalize_sources 当成什么都没说而回退 personal，
      // 等于把用户的选择悄悄改掉。
      expect(bloomSourcesToWire(const []), isEmpty);
    });

    test('解析服务器回显：对象、纯字符串、混合三种都认', () {
      expect(
        bloomSourcesFromWire([
          {'name': 'personal', 'weight': 1},
        ]),
        [BloomPhotoSource.personal],
      );
      expect(bloomSourcesFromWire(['art']), [BloomPhotoSource.art]);
      expect(
        bloomSourcesFromWire([
          'personal',
          {'name': 'art', 'weight': 2},
        ]),
        [BloomPhotoSource.personal, BloomPhotoSource.art],
      );
      // id 是另一种叫法，服务器两种都可能回。
      expect(
        bloomSourcesFromWire([
          {'id': 'widget'},
        ]),
        [BloomPhotoSource.widget],
      );
    });

    test('解析：认不出来的名字跳过，不崩、不清空', () {
      // 服务器加了新来源而这个 App 版本还不认识时，不该因此崩掉。
      expect(bloomSourcesFromWire(['hologram', 'personal']), [
        BloomPhotoSource.personal,
      ]);
      expect(bloomSourcesFromWire(['hologram']), isEmpty);
    });

    test('解析：去重、保持首次出现的顺序', () {
      expect(bloomSourcesFromWire(['art', 'personal', 'art']), [
        BloomPhotoSource.art,
        BloomPhotoSource.personal,
      ]);
    });

    test('解析：非列表输入一律当空，不抛异常', () {
      for (final bad in [
        null,
        'personal',
        42,
        {'name': 'personal'},
      ]) {
        expect(bloomSourcesFromWire(bad), isEmpty, reason: '$bad');
      }
    });

    test('往返：转出去再解析回来恒等', () {
      const original = [BloomPhotoSource.personal, BloomPhotoSource.art];
      expect(bloomSourcesFromWire(bloomSourcesToWire(original)), original);
    });
  });
}

void _carouselStashTests() {
  group('用户自己的轮播作息（切推荐前存的副本）', () {
    test('存进去再取回来恒等', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = DisplayPreferences();
      await prefs.rememberCarouselSchedule(
        const BloomDisplaySettings(
          mode: BloomDisplayMode.carousel,
          intervalMinutes: 1440,
          activeStart: '08:30',
          activeEnd: '20:30',
        ),
        target: 'mobile',
      );
      final back = await prefs.recallCarouselSchedule(target: 'mobile');
      expect(back, isNotNull);
      expect(back!.intervalMinutes, 1440);
      expect(back.activeStart, '08:30');
      expect(back.activeEnd, '20:30');
    });

    test('从来没存过 -> null（调用方据此保持原样）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(
        await DisplayPreferences().recallCarouselSchedule(target: 'mobile'),
        isNull,
      );
    });

    test('只存了一半 -> null，不会拼出一个半成品作息', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'bloom.carousel_stash_interval_mobile': 1440,
        'bloom.carousel_stash_start_mobile': '08:30',
        // 少了 end
      });
      expect(
        await DisplayPreferences().recallCarouselSchedule(target: 'mobile'),
        isNull,
      );
    });

    test('反复存会覆盖（跟着用户最新的设置走）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = DisplayPreferences();
      await prefs.rememberCarouselSchedule(
        const BloomDisplaySettings(
          intervalMinutes: 1440,
          activeStart: '08:30',
          activeEnd: '20:30',
        ),
        target: 'mobile',
      );
      await prefs.rememberCarouselSchedule(
        const BloomDisplaySettings(
          intervalMinutes: 60,
          activeStart: '07:00',
          activeEnd: '19:00',
        ),
        target: 'mobile',
      );
      final back = await prefs.recallCarouselSchedule(target: 'mobile');
      expect(back!.intervalMinutes, 60);
      expect(back.activeStart, '07:00');
      expect(back.activeEnd, '19:00');
    });

    test('⭐ 手机与相框各存各的：给相框切推荐不会污染手机的作息', () async {
      // 手机的作息是 15 分钟、相框的是 12 小时。两个 target 共用一组 key 时，
      // 后写的会把先写的盖掉 —— 于是"给相框切一次推荐、再给手机切回轮播"
      // 会把相框的作息还原到手机上。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = DisplayPreferences();
      await prefs.rememberCarouselSchedule(
        const BloomDisplaySettings(
          intervalMinutes: 15,
          activeStart: '07:30',
          activeEnd: '21:30',
        ),
        target: 'mobile',
      );
      await prefs.rememberCarouselSchedule(
        const BloomDisplaySettings(
          intervalMinutes: 720,
          activeStart: '06:00',
          activeEnd: '22:00',
        ),
        target: 'eink',
      );

      final mobile = await prefs.recallCarouselSchedule(target: 'mobile');
      final frame = await prefs.recallCarouselSchedule(target: 'eink');
      expect(mobile!.intervalMinutes, 15);
      expect(mobile.activeStart, '07:30');
      expect(frame!.intervalMinutes, 720);
      expect(frame.activeStart, '06:00');
    });
  });
}
