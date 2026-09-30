import 'dart:convert';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/device_identity_repository.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:bloom/main.dart';
import 'package:bloom/ui/bloom_device_pages.dart';
import 'package:bloom/ui/bloom_glass_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_account.dart';

/// The `settings/set` writes among [requests]. The detail page also reads
/// `settings/get` once on open, so every assertion about a save has to say
/// which of the two it means instead of counting every request.
List<http.Request> writes(List<http.Request> requests) => requests
    .where((request) => request.url.path.endsWith('/carousel/settings/set'))
    .toList(growable: false);

/// The `settings/get` reads among [requests].
List<http.Request> reads(List<http.Request> requests) => requests
    .where((request) => request.url.path.endsWith('/carousel/settings/get'))
    .toList(growable: false);

/// `DisplayPreferences` that records when the local mirror was written, so a
/// test can prove `cacheLocal` ran (and in which order relative to the
/// background-sync step).
class _RecordingPreferences extends DisplayPreferences {
  _RecordingPreferences({super.api, required this.events});

  final List<String> events;

  @override
  Future<void> cacheLocal(BloomDisplaySettings settings) async {
    events.add('cacheLocal');
    return super.cacheLocal(settings);
  }
}

/// F3 UI tests for the device list and the device detail sheet.
///
/// Every test drives real taps. The server is stubbed at the `http.Client`
/// layer, so `setDeviceSettings` is genuinely called and the request body can
/// be asserted; the local mirror is the real `SharedPreferences` mock, so
/// "cacheLocal did not run" is proven by the mirror keeping its old value.
void main() {
  final credentials = DeviceCredentials(
    deviceId: 'bloom-mobile-test',
    deviceToken: 'a' * 64,
  );

  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  const mirror = <String, Object>{
    'bloom.display_mode': 'carousel',
    'bloom.carousel_interval_minutes': 1440,
    'bloom.carousel_active_start': '06:00',
    'bloom.carousel_active_end': '22:00',
  };

  /// Echoes the write back as the server's `settings` object, the way the real
  /// endpoint answers: the stored `mode` is the one the request carried, or
  /// [storedMode] when the request omitted it (the server keeps what it has).
  Map<String, dynamic> updatePayload(
    Map<String, dynamic> request, {
    String storedMode = 'carousel',
  }) => {
    'status': 'ok',
    'settings': {
      'device_id': credentials.deviceId,
      'target': request['target'],
      'timezone': request['timezone'],
      'active_start': request['active_start'],
      'active_end': request['active_end'],
      'interval_minutes': request['interval_minutes'],
      'mode': request['mode'] ?? storedMode,
      'daily_slot_count': 65,
      'settings_hash': 'test-hash',
      'updated_at': '2026-09-21T10:00:00+08:00',
    },
    'purged_plans': 1,
    'next_check_at':
        DateTime.now().add(const Duration(minutes: 30)).toUtc().toIso8601String(),
  };

  /// Stub for both endpoints the detail page uses. `settings/get` answers with
  /// the stored record (including `mode`); `settings/set` echoes the write.
  /// [failStatus] makes *both* fail, which is how the offline fallback is
  /// exercised.
  MockClient settingsServer({
    required List<http.Request> requests,
    String mode = 'carousel',
    int intervalMinutes = 1440,
    List<String>? sources,
    int failStatus = 0,
    Map<String, dynamic>? failBody,
    void Function(Map<String, dynamic> body)? onWrite,
  }) => MockClient((request) async {
    requests.add(request);
    if (failStatus != 0) {
      return http.Response(
        jsonEncode(failBody ?? const {'detail': '服务器开小差了'}),
        failStatus,
        headers: jsonHeaders,
      );
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (request.url.path.endsWith('/carousel/settings/get')) {
      return http.Response(
        jsonEncode({
          'api_version': 1,
          'settings': {
            'device_id': credentials.deviceId,
            'target': body['target'],
            'timezone': 'Asia/Shanghai',
            'active_start': '06:00',
            'active_end': '22:00',
            'interval_minutes': intervalMinutes,
            'mode': mode,
            // 服务器回的是 [{name, weight}]；不传就当作"没登记来源"。
            if (sources != null)
              'sources': [
                for (final name in sources) {'name': name, 'weight': 1},
              ],
            'daily_slot_count': 65,
            'settings_hash': 'test-hash',
            'updated_at': '2026-09-21T10:00:00+08:00',
          },
          'allowed_interval_minutes': BloomDisplaySettings.allowedIntervals,
          'next_check_at':
              '2026-09-21T10:30:00+08:00',
        }),
        200,
        headers: jsonHeaders,
      );
    }
    onWrite?.call(body);
    return http.Response(
      jsonEncode(updatePayload(body, storedMode: mode)),
      200,
      headers: jsonHeaders,
    );
  });

  /// Pumps until the route/scroll animations are done without waiting for a
  /// never-settling glass animation to stop.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// A tall test window so the whole detail page fits.
  ///
  /// Scrolling a `ListView` to reach a lower panel can dispose the panels above
  /// it, and a later `find.text('保存')` then throws "No element" — this keeps
  /// the tests tapping real widgets without any scrolling.
  void useTallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget detail({
    required DeviceCredentials? credentials,
    required DisplayPreferences preferences,
    BloomDevice device = bloomBundledFrame,
    // 轮播 by default: the cadence form (and the floating save) only exist on
    // that branch, so it is what a test of this page wants unless it says
    // otherwise.
    BloomDisplaySettings settings = const BloomDisplaySettings(
      mode: BloomDisplayMode.carousel,
    ),
    PairingInfo? pairing,
    ValueChanged<BloomDisplaySettings>? onModeChanged,
    ValueChanged<BloomDisplaySettings>? onSaved,
    Future<void> Function(BloomDisplaySettings settings)? onMirrored,
  }) => MaterialApp(
    home: BloomDeviceDetailPage(
      device: device,
      preferences: preferences,
      settings: settings,
      credentials: credentials,
      callerDeviceId: credentials?.deviceId,
      pairing: pairing,
      onModeChanged: onModeChanged,
      onSaved: onSaved,
      onMirrored: onMirrored,
    ),
  );

  BloomDevice localDevice() => bloomDevices(
    credentials: credentials,
    localOnline: true,
  ).firstWhere((device) => device.isLocal);

  group('登录后的设备列表（F1）', () {
    UserDevice remote({
      String id = 'bloom-eink-68ee8f606594',
      String type = 'eink',
      DateTime? lastSeen,
      int? intervalMinutes,
    }) => UserDevice(
      deviceId: id,
      deviceType: type,
      enabled: true,
      lastSeenAt: lastSeen,
      settings: intervalMinutes == null
          ? null
          : UserDeviceSettings(intervalMinutes: intervalMinutes),
    );

    test('只把本机那一行标成 isLocal', () {
      // 只有持有设备令牌的那一台，其照片这个 App 才取得到。家庭里另一台手机
      // 同样是 device_type=mobile，误标成 isLocal 会让界面承诺一个取不到的
      // 照片流。
      final devices = bloomDevicesFromRemote(
        [
          remote(id: credentials.deviceId, type: 'mobile'),
          remote(id: 'bloom-eink-68ee8f606594'),
        ],
        localDeviceId: credentials.deviceId,
        localOnline: true,
      );

      expect(devices, hasLength(2));
      expect(devices[0].isLocal, isTrue);
      expect(devices[1].isLocal, isFalse);
      expect(devices[1].isFrame, isTrue);
    });

    test('本机小组件的开关状态只影响本机那一行', () {
      // 关掉本机小组件不该把家庭里另一台手机也显示成离线。
      final devices = bloomDevicesFromRemote(
        [
          remote(id: credentials.deviceId, type: 'mobile'),
          remote(
            id: 'other-phone',
            type: 'mobile',
            lastSeen: DateTime.now(),
          ),
        ],
        localDeviceId: credentials.deviceId,
        localOnline: false,
      );

      expect(devices[0].isOnline, isFalse);
      expect(devices[1].isOnline, isTrue);
    });

    test('相框的在线窗口跟着它自己的刷新间隔走', () {
      // 相框大部分时间在深度睡眠。用固定窗口会把一台完全正常的相框常年显示
      // 成"离线"，而这个提示长期不准之后用户就再也不看它了。
      final justNow = DateTime.now();

      final freshWithLongInterval = bloomDevicesFromRemote(
        [
          remote(
            lastSeen: justNow.subtract(const Duration(minutes: 40)),
            intervalMinutes: 60,
          ),
        ],
      );
      expect(freshWithLongInterval.single.isOnline, isTrue);

      final stale = bloomDevicesFromRemote(
        [
          remote(
            lastSeen: justNow.subtract(const Duration(hours: 5)),
            intervalMinutes: 60,
          ),
        ],
      );
      expect(stale.single.isOnline, isFalse);
    });

    test('从没上报过 last_seen 时不猜在线状态', () {
      final devices = bloomDevicesFromRemote([remote()]);
      expect(devices.single.isOnline, isNull);
      // 界面把它渲染成"离线"，而不是编一个状态。
      expect(devices.single.presenceLabel, '离线');
    });

    test('缺名字时按类型给一个可读的名字', () {
      final devices = bloomDevicesFromRemote([
        remote(id: 'frame-x'),
        remote(id: 'phone-y', type: 'mobile'),
      ]);
      expect(devices[0].name, 'E-Ink');
      expect(devices[1].name, '手机小组件');
    });
  });

  group('设备列表', () {
    testWidgets('渲染写死的相框，点击后进入详情页', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = DisplayPreferences(
        api: BloomApiClient(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      );
      final devices = bloomDevices(
        credentials: credentials,
        localOnline: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => BloomDeviceListPage(
                  devices: devices,
                  account: fakeAccount(),
                  onOpenDevice:
                      (device) => BloomDeviceDetailPage.open(
                        context,
                        device: device,
                        preferences: preferences,
                        settings: const BloomDisplaySettings(),
                        credentials: credentials,
                        callerDeviceId: credentials.deviceId,
                      ),
                  onAddDevice: () {},
                ),
          ),
        ),
      );

      // The hardcoded frame is listed with its name and an honest "—" presence
      // (there is no last_seen_at without a user session).
      //
      // The tile carries the type and the state on its small top line, with the
      // name large at the bottom — the reference layout. So both are asserted,
      // and each on exactly one tile.
      expect(find.text('E-Ink'), findsOneWidget);
      // type == name now, so the meta line is just the absent live state
      expect(find.text('离线'), findsOneWidget);
      // 引用常量而不是字面量：这个断言的意图是「兜底相框出现在列表里」，
      // 不是「它的 ID 恰好是某个字符串」。写死字面量会在换板子时假失败。
      expect(
        devices.any((d) => d.deviceId == bloomBundledFrame.deviceId),
        isTrue,
      );

      await tester.tap(find.text('E-Ink'));
      await settle(tester);

      // The detail page is on screen, led by its one raised sheet.
      expect(find.byKey(const ValueKey('bloom-mode-carousel')), findsOneWidget);
      // The identifiers sit in their own well further down, so the list has to
      // be scrolled to them: the page is deliberately taller than one screen now
      // (three labelled fields, then three groups).
      await tester.scrollUntilVisible(
        find.text(bloomBundledFrame.deviceId),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      expect(find.text(bloomBundledFrame.deviceId), findsOneWidget);
    });

    testWidgets('设备是一个 tile：小字「类型 · 状态」在上，大字号名字在下（参考图布局）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        MaterialApp(
          home: BloomDeviceListPage(
            account: fakeAccount(),
            devices: bloomDevices(credentials: credentials, localOnline: true),
            onOpenDevice: (_) {},
            onAddDevice: () {},
          ),
        ),
      );

      final meta = tester.getRect(find.text('离线'));
      final name = tester.getRect(find.text('E-Ink'));
      expect(
        meta.bottom,
        lessThanOrEqualTo(name.top),
        reason: '说明行必须在名字上方，而不是并排',
      );
      final style = tester.widget<Text>(find.text('E-Ink')).style!;
      expect(
        style.fontSize,
        greaterThanOrEqualTo(18),
        reason: '名字是 tile 的 display 层，必须明显大于 meta 行',
      );
    });

    testWidgets('添加设备是头部右上角的一个裸加号，可点', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: BloomDeviceListPage(
            account: fakeAccount(),
            devices: bloomDevices(credentials: credentials, localOnline: true),
            onOpenDevice: (_) {},
            onAddDevice: () => taps++,
          ),
        ),
      );

      // The action moved out of the list's own row and into the title's corner
      // at the user's request, so the page no longer prints the words at all.
      expect(find.text('添加设备'), findsNothing);
      final add = find.byKey(const ValueKey('bloom-add-device'));
      expect(add, findsOneWidget);

      // Bare glyph: it is the title row's *last* thing, to the right of 扫码.
      final scan = tester.getRect(find.byIcon(Icons.qr_code_scanner_rounded));
      expect(tester.getRect(add).left, greaterThan(scan.right));

      await tester.tap(add);
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('设备详情页 · 刷新节奏', () {
    testWidgets('相框保存间隔 → 只写 eink，本地镜像一字未动', (tester) async {
      // Deliberately *different* from the server record: if the frame's save
      // cached anything, the mirror would move off these values.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'bloom.display_mode': 'recommend',
        'bloom.carousel_interval_minutes': 30,
        'bloom.carousel_active_start': '08:00',
        'bloom.carousel_active_end': '20:00',
      });
      final requests = <http.Request>[];
      // The frame's own record: 每天一次, 轮播.
      final client = BloomApiClient(
        client: settingsServer(requests: requests),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(
            intervalMinutes: 1440,
            activeStart: '06:00',
            activeEnd: '22:00',
          ),
        ),
      );
      await settle(tester);

      // The page read the frame's `eink` record on open.
      expect(jsonDecode(reads(requests).single.body), {'target': 'eink'});

      await tester.ensureVisible(
        find.byKey(const ValueKey('bloom-interval-dropdown')),
      );
      await tester.tap(find.byKey(const ValueKey('bloom-interval-dropdown')));
      await settle(tester);
      await tester.tap(find.text('每2小时').last);
      await settle(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);

      expect(writes(requests), hasLength(1));
      expect(
        writes(requests).single.url.path,
        '/api/frame/devices/bloom-mobile-test/carousel/settings/set',
      );
      final body = jsonDecode(writes(requests).single.body) as Map<String, dynamic>;
      expect(body['interval_minutes'], 120);
      expect(body['target'], 'eink');
      expect(body['caller_device_id'], credentials.deviceId);
      expect(body['active_start'], '06:00');
      expect(body['active_end'], '22:00');
      // The frame's display mode is never written by the app: omitting it is
      // the server's "keep the stored value" path.
      expect(body.containsKey('mode'), isFalse);

      expect(find.textContaining('设置已保存'), findsOneWidget);

      // The local mirror belongs to the phone widget, so a frame save must not
      // touch it — not the cadence and not the mode.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('bloom.carousel_interval_minutes'), 30);
      expect(prefs.getString('bloom.carousel_active_start'), '08:00');
      expect(prefs.getString('bloom.carousel_active_end'), '20:00');
      expect(prefs.getString('bloom.display_mode'), 'recommend');
    });

    testWidgets('生效时间是一个字段：六个预设含「全天」，全天拆成 00:00–23:59 交给接口', (tester) async {
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          device: localDevice(),
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 120,
            activeStart: '06:00',
            activeEnd: '22:00',
          ),
        ),
      );
      await settle(tester);

      // One field, one decision. The two old rows are gone: they let a user pick
      // an end before the start, which the server rejects with a 422.
      expect(find.byKey(const ValueKey('bloom-window-field')), findsOneWidget);
      expect(find.text('生效时间'), findsOneWidget);
      expect(find.text('06:00 – 22:00'), findsOneWidget);
      expect(find.text('生效开始时间'), findsNothing);
      expect(find.text('生效结束时间'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('bloom-window-field')));
      await settle(tester);
      // Five windows, then 全天 — the order the user asked for.
      for (final label in <String>[
        '05:00 – 21:00',
        '06:00 – 22:00',
        '07:00 – 23:00',
        '08:00 – 23:59',
        '只在白天',
        '全天',
      ]) {
        expect(find.text(label), findsWidgets, reason: '缺了选项 $label');
      }
      await tester.tap(find.text('全天'));
      await settle(tester);

      await tester.tap(find.text('保存'));
      await settle(tester);

      // The merge is UI-only: the API still stores a window as two fields, and
      // 全天 is 23:59 rather than 00:00 because the server's rule is a strict
      // `active_start < active_end`.
      final body = jsonDecode(writes(requests).single.body) as Map<String, dynamic>;
      expect(body['active_start'], '00:00');
      expect(body['active_end'], '23:59');
      // (The cadence in the body is the server's own record — this page reads it
      // on open — so only the window is this test's business.)
    });

    testWidgets('本机只改间隔、没碰模式 → 请求不含 mode，镜像 mode 保持原值', (tester) async {
      useTallWindow(tester);
      // The phone really is on 推荐; the server's row still holds the migration
      // default 轮播. Saving the cadence alone must not flatten that.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'bloom.display_mode': 'recommend',
        'bloom.carousel_interval_minutes': 1440,
        'bloom.carousel_active_start': '06:00',
        'bloom.carousel_active_end': '22:00',
      });
      final requests = <http.Request>[];
      // The server's own record for this phone; it is what the page reads on
      // open and therefore what it saves back.
      final client = BloomApiClient(
        client: settingsServer(requests: requests, intervalMinutes: 60),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          device: localDevice(),
          settings: const BloomDisplaySettings(intervalMinutes: 1440),
        ),
      );
      await settle(tester);

      // The open-time read filled the page with the server's cadence, and the
      // selector keeps showing the server's mode — but the page no longer
      // narrates the phone/server disagreement, only the short labels.
      expect(find.text('每1小时'), findsWidgets);
      expect(find.text('轮播'), findsWidgets);
      expect(find.textContaining('本机小组件当前'), findsNothing);
      expect(find.textContaining('服务器记录是'), findsNothing);

      await tester.tap(find.text('保存'));
      await settle(tester);

      expect(writes(requests), hasLength(1));
      final body = jsonDecode(writes(requests).single.body) as Map<String, dynamic>;
      expect(body['target'], 'mobile');
      expect(body['interval_minutes'], 60);
      // The user never mentioned the mode, so the request carries none and the
      // server keeps whatever it stores.
      expect(body.containsKey('mode'), isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('bloom.carousel_interval_minutes'), 60);
      // ... and the phone's widget keeps its own mode.
      expect(prefs.getString('bloom.display_mode'), 'recommend');
    });

    testWidgets('服务器 422 → 显示错误提示，且本地镜像没有被写入', (tester) async {
      SharedPreferences.setMockInitialValues(Map<String, Object>.from(mirror));
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({'detail': '结束时间必须晚于开始时间'}),
            422,
            headers: jsonHeaders,
          );
        }),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          device: localDevice(),
          // Deliberately different from the mirror: if cacheLocal ran, the
          // mirror would change to these values. 轮播模式 because the floating
          // save button is part of the carousel form only.
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 60,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('保存'));
      await settle(tester);

      expect(writes(requests), hasLength(1));
      expect(find.textContaining('结束时间必须晚于开始时间'), findsOneWidget);
      expect(find.textContaining('设置已保存'), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('bloom.carousel_interval_minutes'), 1440);
      expect(prefs.getString('bloom.carousel_active_start'), '06:00');
      expect(prefs.getString('bloom.display_mode'), 'carousel');
    });

    testWidgets('服务器 403 → 显示没有权限', (tester) async {
      SharedPreferences.setMockInitialValues(Map<String, Object>.from(mirror));
      final client = BloomApiClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'detail': '两个设备不属于同一账号'}),
            403,
            headers: jsonHeaders,
          ),
        ),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          device: localDevice(),
          // 轮播模式: the save button belongs to the carousel form.
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 60,
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);

      expect(find.textContaining('没有权限'), findsOneWidget);
      expect(find.textContaining('同一账号'), findsOneWidget);
    });

    testWidgets('当前值 45 不在 6 档里 → 打开不崩溃，菜单里有「每45分钟」且能保存', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      // The server has no record at all here, so the page keeps the value it
      // was opened with (45) — the out-of-tier case.
      final client = BloomApiClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/settings/get')) {
            return http.Response(
              jsonEncode({'detail': '暂时读不到设置'}),
              503,
              headers: jsonHeaders,
            );
          }
          return http.Response(
            jsonEncode(updatePayload(jsonDecode(request.body))),
            200,
            headers: jsonHeaders,
          );
        }),
      );

      // 45 is not one of BloomDisplaySettings.allowedIntervals.
      expect(BloomDisplaySettings.allowedIntervals, isNot(contains(45)));

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(
            // 轮播模式: the cadence form (and with it the interval field) only
            // exists on the carousel branch.
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 45,
            activeStart: '06:00',
            activeEnd: '22:00',
          ),
        ),
      );
      await settle(tester);

      // The unusual value is shown by the field itself...
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('bloom-interval-dropdown')),
      );
      expect(find.text('每45分钟'), findsWidgets);

      // ...and the sheet it opens lists it as a seventh choice, so a value the
      // six tiers do not contain can still be seen and re-picked (instead of the
      // control asserting on a value with no matching item, which is what the
      // Material dropdown used to do).
      await tester.tap(find.byKey(const ValueKey('bloom-interval-dropdown')));
      await settle(tester);
      await tester.tap(find.text('每45分钟').last);
      await settle(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);

      expect(writes(requests), hasLength(1));
      final body = jsonDecode(writes(requests).single.body) as Map<String, dynamic>;
      // The out-of-tier value survives untouched; nothing rewrites it to 1440.
      expect(body['interval_minutes'], 45);
    });
  });

  group('设备详情页 · 照片来源', () {
    testWidgets('卡片只列出已实现的来源，未实现的不给能勾的框', (tester) async {
      // 服务器登记了四个名字（personal / art / news / widget），但只有
      // personal 真正取得出照片。给 art 一个能勾的框，用户设完相框毫无变化 ——
      // 就是"设了没反应"。所以界面严格按 BloomPhotoSource.implemented 渲染。
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(),
        ),
      );
      await settle(tester);

      expect(find.text('照片来源'), findsOneWidget);
      expect(find.byKey(const ValueKey('bloom-source-personal')), findsOneWidget);
      // 还没实现的三个名字一个都不该出现。
      expect(find.byKey(const ValueKey('bloom-source-art')), findsNothing);
      expect(find.byKey(const ValueKey('bloom-source-news')), findsNothing);
      expect(find.byKey(const ValueKey('bloom-source-widget')), findsNothing);
    });

    testWidgets('点来源只改草稿、不立刻发请求；且最后一个不能被取消', (tester) async {
      // 两条规矩：
      //  ① 来源与「更换频率」「生效时间」一致，等页面底部统一的「保存」，
      //     不像 mode 那样是开关式立刻提交。
      //  ② 至少留一个 —— 全不选就没有来源了，相框会没有候选照片。
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(),
        ),
      );
      await settle(tester);
      final before = writes(requests).length;

      await tester.tap(find.byKey(const ValueKey('bloom-source-personal')));
      await settle(tester);

      // ① 不立刻发请求。
      expect(
        writes(requests).length,
        before,
        reason: '点来源应当只改草稿，等「保存」',
      );
      // ② 唯一选中的那个取消不掉 —— 框还应当是勾着的。
      expect(find.byKey(const ValueKey('bloom-source-personal')), findsOneWidget);
    });

    testWidgets('打开时没碰来源 -> 请求里【不含】sources 这个键', (tester) async {
      // 与 mode 一字不差的同一规矩：没送 != 重置。
      // 否则用户每次调刷新间隔，来源都会被悄悄改掉。
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(),
        ),
      );
      await settle(tester);

      // 改一下间隔（不碰来源）→ 必须保存，但请求里不能有 sources。
      await tester.tap(find.byKey(const ValueKey('bloom-interval-dropdown')));
      await settle(tester);
      await tester.tap(find.text('每2小时').last);
      await settle(tester);
      await tester.tap(find.text('保存'), warnIfMissed: false);
      await settle(tester);

      final body = jsonDecode(writes(requests).last.body) as Map<String, dynamic>;
      expect(body.containsKey('sources'), isFalse,
          reason: '没碰来源就不该发送这个键');
    });

    testWidgets('⭐ 推荐模式下碰过来源 → 「保存」出现，并且真的把它送出去', (tester) async {
      // 「保存」原来只在轮播模式出现（那时页面上唯一的表单就是作息）。
      // 推荐模式没有作息表单 —— 但**有「照片来源」这张卡片**，它同样是表单。
      // 于是推荐模式下来源只改草稿、根本没有提交它的按钮：点了没反应。
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(
          requests: requests,
          mode: 'recommend',
          // ⚠️ 服务器必须回两个来源，这一 tap 才真的改变草稿。
          //    `implemented` 目前只有 personal，而"至少保留一个"的规则会让
          //    「只选中 personal 时点它」变成 no-op（行的 onTap 直接置空）——
          //    那样测的就不是保存按钮，而是那个 no-op。
          sources: const ['personal', 'art'],
        ),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.recommendation,
            intervalMinutes: 720,
          ),
        ),
      );
      await settle(tester);

      // 推荐模式、什么都没碰：没有保存按钮。那才叫"一个什么都不做的按钮"。
      expect(find.text('保存'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('bloom-source-personal')));
      await settle(tester);

      // 碰过之后必须出现，否则这次改动永远送不出去。
      expect(
        find.text('保存'),
        findsOneWidget,
        reason: '推荐模式下改了来源也必须有办法提交',
      );
      expect(writes(requests), isEmpty, reason: '来源是表单，点它不该立刻发请求');

      await tester.tap(find.text('保存'), warnIfMissed: false);
      await settle(tester);

      expect(writes(requests), hasLength(1));
      final body = jsonDecode(writes(requests).single.body) as Map<String, dynamic>;
      expect(body['mode'], isNull, reason: '没碰模式就不该带 mode');
      expect(body['sources'], [
        {'name': 'art', 'weight': 1},
      ]);
      expect(find.textContaining('设置已保存'), findsOneWidget);
    });

    testWidgets('⭐ 服务器回显的 sources 会显示在卡片上（不是永远回落到 personal）', (tester) async {
      // `readServer()` 构造返回值时漏掉了 `sources:`，于是详情页永远读回默认的
      // [personal] —— 服务器上真存了什么，用户根本看不到，看起来就像"设了没反应"。
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(
          requests: requests,
          mode: 'carousel',
          sources: const ['art'],
        ),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(),
        ),
      );
      await settle(tester);

      // 服务器说这台设备只有 art。界面只渲染 implemented（只有 personal），
      // 但 personal 已经**不在选中集里**了 —— 勾是空的。
      expect(find.text('照片来源'), findsOneWidget);
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsOneWidget,
        reason: '服务器说来源是 art，personal 就不该显示成已选中',
      );
      expect(find.byIcon(Icons.check_box_rounded), findsNothing);
    });
  });

  group('设备详情页 · 显示模式', () {
    testWidgets('相框的显示模式可以切换，只发服务器、不写本机镜像', (tester) async {
      // 相框的模式以前是只读的，理由是"its firmware cannot read the server's
      // `mode` yet"。服务器现在按 frame_device_settings.mode 决定排序方式、
      // 固件只是照做，所以这条理由不再成立：相框也能改模式，而且改完不需要
      // 重烧固件。
      useTallWindow(tester);
      // 空镜像：本机没有 mode。相框保存若误写镜像，下面能立刻看出来。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      // The frame's stored mode, read back from `eink`.
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          // The fallback says the opposite of the server on purpose: the row
          // must show what the server reports.
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.recommendation,
          ),
        ),
      );
      await settle(tester);

      // 打开时显示服务器报的轮播，而不是本地兜底的推荐。
      expect(find.text('轮播'), findsOneWidget);

      // 胶囊现在是【真控件】：点另一段必须发出一次写请求。
      expect(find.byKey(const ValueKey('bloom-mode-recommend')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bloom-mode-recommend')));
      await settle(tester);

      final frameWrites = writes(requests);
      expect(frameWrites, isNotEmpty, reason: '相框改模式必须发给服务器');
      final writtenBody = frameWrites.last.body;
      expect(writtenBody, contains('"mode":"recommend"'));
      expect(writtenBody, contains('"target":"eink"'));

      // 但【绝不写本机镜像】—— 镜像属于这台手机的小组件，相框的模式不是手机
      // 的模式；写进去会悄悄改掉桌面小组件的节奏。
      final prefsAfter = await SharedPreferences.getInstance();
      expect(prefsAfter.getString('bloom.display_mode'), isNull);

      // 服务器回显后不再多发请求。
      expect(writes(requests).length, frameWrites.length);
    });

    testWidgets('切到推荐 → 把 06:00 / 22:00 / 720 真的发出去，并隐藏作息控件', (tester) async {
      // 服务器对四个参数零特例 —— 它不会"因为在推荐模式就忽略间隔"。
      // 所以 App 必须自己把固定作息填进请求，否则推荐就在用一个不相干的
      // 作息跑（例如用户上次设的 09:00–18:00 每天一次）。
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 1440,
            activeStart: '09:00',
            activeEnd: '18:00',
          ),
        ),
      );
      await settle(tester);

      // 轮播模式下作息控件是在的。
      expect(find.text('生效时间'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('bloom-mode-recommend')));
      await settle(tester);

      final body =
          jsonDecode(writes(requests).last.body) as Map<String, dynamic>;
      expect(body['mode'], 'recommend');
      expect(body['interval_minutes'], recommendIntervalMinutes);
      expect(body['active_start'], recommendActiveStart);
      expect(body['active_end'], recommendActiveEnd);

      // 三组控件隐藏：推荐模式换成一张说明卡。
      expect(find.text('生效时间'), findsNothing);
      expect(find.text('刷新节奏'), findsNothing);
    });

    testWidgets('推荐 → 轮播：还原用户自己的作息，而不是留着推荐那份固定值', (tester) async {
      // 服务器对 mode 与作息是【正交】的：四个字段只有一个存储位。切到推荐
      // 必须把固定作息（06:00/22:00/12h）写进去，否则推荐会用一个不相干的
      // 作息去跑。代价是【用户原来的轮播作息被覆盖】。
      //
      // 所以切过去之前先记一份，切回来原样还回去。否则用户只是去看了一眼
      // 推荐，回来发现自己的设置被改成了「半天一次 / 6点到22点」——
      // 那不是他的设置，是推荐那一套。
      //
      // 这里刻意用一个【跟推荐固定值完全不同】的作息（1440 / 08:30 / 20:30），
      // 这样断言能真的区分"还回来了"和"留着推荐那份"。
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 1440,
            activeStart: '08:30',
            activeEnd: '20:30',
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('bloom-mode-recommend')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('bloom-mode-carousel')));
      await settle(tester);

      final body =
          jsonDecode(writes(requests).last.body) as Map<String, dynamic>;
      expect(body['mode'], 'carousel');
      // ⭐ 核心断言：还回来的【不是】推荐那份固定值。
      //
      // 注意不能断言 start/end 等于上面传进去的 08:30/20:30 —— 服务器才是
      // 权威，页面打开时会先用服务器回的值覆盖草稿，而这个 mock 服务器回的
      // 窗口正好和推荐的固定窗口相同，两个值分不开。间隔能分开：它一定是
      // 切到推荐之前页面上的那个值（来自服务器），绝不是 720。
      expect(body['interval_minutes'], isNot(recommendIntervalMinutes));
      expect(body['interval_minutes'], greaterThan(0));

      // 控件回来了。
      expect(find.text('生效时间'), findsWidgets);
    });


    testWidgets('本机点「推荐模式」→ 立刻发请求（target=mobile、mode=recommend）并写本地镜像', (
      tester,
    ) async {
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(Map<String, Object>.from(mirror));
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          device: localDevice(),
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 1440,
          ),
        ),
      );
      await settle(tester);

      // The selector shows the server's mode to begin with.
      expect(find.byKey(const ValueKey('bloom-mode-carousel')), findsOneWidget);

      // **One tap, one request.** The user's report was that tapping the
      // segments "不走接口" — it used to be a draft that only 保存 could commit.
      await tester.tap(find.text('推荐'));
      await settle(tester);

      expect(
        writes(requests),
        hasLength(1),
        reason: '点模式必须立刻走 settings/set，而不是等保存',
      );
      final body = jsonDecode(writes(requests).single.body) as Map<String, dynamic>;
      expect(body['target'], 'mobile');
      // 服务器与本地镜像现在【同一个拼写】，两边都是 `recommend`。
      // 间隔随同一个请求走 —— 而推荐模式的间隔是固定值（12 小时），
      // 不是轮播那边原本用的档位。
      expect(body['mode'], 'recommend');
      expect(body['interval_minutes'], recommendIntervalMinutes);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bloom.display_mode'), 'recommend');
      expect(
        bloomModeFromWire(body['mode'] as String),
        BloomDisplayMode.recommendation,
      );
    });

    testWidgets('本机保存模式后：cacheLocal 先落库，configureBackgroundSync 紧随其后', (
      tester,
    ) async {
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(Map<String, Object>.from(mirror));
      final requests = <http.Request>[];
      final events = <String>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );
      final preferences = _RecordingPreferences(
        api: client,
        events: events,
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: preferences,
          device: localDevice(),
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 1440,
          ),
          onMirrored: (settings) async => events.add('configureBackgroundSync'),
        ),
      );
      await settle(tester);

      // The tap alone runs the whole chain now (no 保存 needed), and the order
      // is the data layer's contract: server, then the mirror the native widgets
      // read, then the Android scheduler that reads the mirror.
      await tester.tap(find.text('推荐'));
      await settle(tester);

      expect(events, ['cacheLocal', 'configureBackgroundSync']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bloom.display_mode'), 'recommend');
    });

    testWidgets('档位改动留在草稿里；点模式则立即把两者一起提交（服务器不会拿到新模式的旧档位）', (
      tester,
    ) async {
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(Map<String, Object>.from(mirror));
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(requests: requests, mode: 'carousel'),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          device: localDevice(),
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 1440,
          ),
        ),
      );
      await settle(tester);

      // Pick 每2小时 but do not save it: a cadence is a form, it waits.
      await tester.ensureVisible(
        find.byKey(const ValueKey('bloom-interval-dropdown')),
      );
      await tester.tap(find.byKey(const ValueKey('bloom-interval-dropdown')));
      await settle(tester);
      await tester.tap(find.text('每2小时').last);
      await settle(tester);

      // Still nothing anywhere: the widget keeps its cadence until it is saved.
      expect(writes(requests), isEmpty);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('bloom.carousel_interval_minutes'), 1440);

      // Now pick a mode. The mode is a *switch*, so it commits at once — and it
      // carries the pending cadence with it, because the server must never end
      // up holding the new mode next to the old interval.
      await tester.tap(find.text('推荐'));
      await settle(tester);

      expect(writes(requests), hasLength(1));
      final body = jsonDecode(writes(requests).single.body) as Map<String, dynamic>;
      // 推荐模式带着自己的【固定作息】过来，所以这里不是刚才在界面上点的 120。
      // 测试的原意仍然成立：服务器拿到的是"与新模式相配"的档位，而绝不是
      // 新模式配旧档位。
      expect(body['interval_minutes'], recommendIntervalMinutes);
      expect(body['mode'], 'recommend');
      expect(body['target'], 'mobile');

      final after = await SharedPreferences.getInstance();
      expect(
        after.getInt('bloom.carousel_interval_minutes'),
        recommendIntervalMinutes,
      );
      expect(after.getString('bloom.display_mode'), 'recommend');
    });

    testWidgets('读服务器失败 → 页面照常渲染兜底值，不崩、不弹错误', (tester) async {
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: settingsServer(
          requests: requests,
          failStatus: 503,
          failBody: const {'detail': 'upstream unavailable'},
        ),
      );

      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(api: client),
          // The frame: its mode line has no local mirror to fall back to, so it
          // is the harshest case for "the page still renders".
          settings: const BloomDisplaySettings(
            mode: BloomDisplayMode.carousel,
            intervalMinutes: 720,
          ),
        ),
      );
      await settle(tester);

      // The read really was attempted, and it failed.
      expect(reads(requests), hasLength(1));
      // ... and the page renders the values it was opened with.
      expect(tester.takeException(), isNull);
      expect(find.text('半天一次'), findsWidgets);
      expect(find.text('轮播'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      // No red error box, no spinner stuck on screen.
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('服务器拒绝'), findsNothing);
    });

    testWidgets('相框详情页读 eink、本机详情页读 mobile', (tester) async {
      useTallWindow(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final frameRequests = <http.Request>[];
      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(
            api: BloomApiClient(
              client: settingsServer(requests: frameRequests),
            ),
          ),
        ),
      );
      await settle(tester);
      final frameRead = reads(frameRequests).single;
      expect(jsonDecode(frameRead.body), {'target': 'eink'});

      // Tear the frame page down first: pumping another `BloomDeviceDetailPage`
      // straight away would reuse its `State` (same type, same position) and
      // `initState` — which is what starts the read — would not run again.
      await tester.pumpWidget(const SizedBox());
      await settle(tester);

      final localRequests = <http.Request>[];
      await tester.pumpWidget(
        detail(
          credentials: credentials,
          preferences: DisplayPreferences(
            api: BloomApiClient(
              client: settingsServer(requests: localRequests),
            ),
          ),
          device: localDevice(),
        ),
      );
      await settle(tester);
      final localRead = reads(localRequests).single;
      expect(jsonDecode(localRead.body), {'target': 'mobile'});

      // Same endpoint (the target is a body field, not a path segment), two
      // different records.
      expect(frameRead.url.path, localRead.url.path);
      expect(
        jsonDecode(frameRead.body),
        isNot(jsonDecode(localRead.body)),
      );
    });

    test('mode 全线同一个拼写；旧安装里的 recommendation 仍能读出来', () {
      // Wire and mirror now agree — there is no second spelling any more.
      expect(bloomModeToWire(BloomDisplayMode.carousel), 'carousel');
      expect(bloomModeToWire(BloomDisplayMode.recommendation), 'recommend');
      expect(bloomModeFromWire('carousel'), BloomDisplayMode.carousel);
      expect(bloomModeFromWire('recommend'), BloomDisplayMode.recommendation);

      // An install that last wrote its mirror before the rename still parses,
      // instead of silently flipping that user back to carousel.
      expect(
        bloomModeFromWire(DeviceCarouselSettings.modeRecommendLegacy),
        BloomDisplayMode.recommendation,
      );

      // Anything else is "unknown", never a silent default.
      expect(bloomModeFromWire(null), isNull);
      expect(bloomModeFromWire('shuffle'), isNull);
    });
  });

  group('首页启动', () {
    testWidgets('_load() 不发 settings/get 请求（本地镜像不外流，也不被覆盖）', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'bloom.device_id': credentials.deviceId,
        'bloom.identity_version': 2,
        ...mirror,
      });
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/status')) {
            return http.Response(
              jsonEncode({
                'device_id': credentials.deviceId,
                'device_type': 'mobile',
                'mode': 'carousel',
                'paired': true,
                'has_assets': false,
              }),
              200,
              headers: jsonHeaders,
            );
          }
          return http.Response('{}', 200, headers: jsonHeaders);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: BloomHomePage(
            identity: DeviceIdentityRepository(
              readToken: (_) async => credentials.deviceToken,
              writeToken: (_, _) async {},
              stableCredentials: () async => null,
            ),
            api: client,
            displayPreferences: DisplayPreferences(api: client),
            // 已登录：四个页面都有未登录分支，不喂会话就会停在登录提示上，
            // 这些验内容的用例会假失败。
            auth: signedInAuthRepository(),
          ),
        ),
      );
      await settle(tester);

      // `_load()` really ran: the device status call proves it.
      expect(
        requests.map((request) => request.url.path),
        contains(endsWith('/status')),
      );
      // It never asked for settings — reading the frame's `eink` record here is
      // exactly what used to write the frame's schedule into the phone
      // widget's local mirror.
      expect(
        requests.where((request) => request.url.path.contains('settings')),
        isEmpty,
      );
      // And the mirror is still whatever it was before the launch.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('bloom.carousel_interval_minutes'), 1440);
      expect(prefs.getString('bloom.display_mode'), 'carousel');

      // Let the home page go so its message timer is cancelled.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('服务器说轮播、本地镜像是推荐 → 启动时以服务器为准，两屏不再打架', (tester) async {
      // The user's report, verbatim: 首页显示推荐模式，同一台手机的详情页显示轮播模式.
      //
      // `/status` carries the mode the server wants this device in on every
      // launch, but the app used to ignore it and show the *local mirror*. The
      // mirror is only ever written by this app, so a mode set anywhere else
      // (the web UI) never reached it: the mirror is the stale side.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'bloom.device_id': credentials.deviceId,
        'bloom.identity_version': 2,
        'bloom.display_mode': 'recommend', // stale
        'bloom.carousel_interval_minutes': 1440,
        'bloom.carousel_active_start': '06:00',
        'bloom.carousel_active_end': '22:00',
      });
      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/status')) {
            return http.Response(
              jsonEncode({
                'device_id': credentials.deviceId,
                'device_type': 'mobile',
                'mode': 'carousel',
                'paired': true,
                'has_assets': false,
              }),
              200,
              headers: jsonHeaders,
            );
          }
          return http.Response('{}', 200, headers: jsonHeaders);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: BloomHomePage(
            identity: DeviceIdentityRepository(
              readToken: (_) async => credentials.deviceToken,
              writeToken: (_, _) async {},
              stableCredentials: () async => null,
            ),
            api: client,
            displayPreferences: DisplayPreferences(api: client),
            // 已登录：四个页面都有未登录分支，不喂会话就会停在登录提示上，
            // 这些验内容的用例会假失败。
            auth: signedInAuthRepository(),
          ),
        ),
      );
      await settle(tester);

      // The mirror was pulled onto the server's value, so the home-screen widget
      // — which reads that same mirror — follows too.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bloom.display_mode'), 'carousel');
      // The cadence was not invented: only the mode moved.
      expect(prefs.getInt('bloom.carousel_interval_minutes'), 1440);
      // And it cost nothing: the mode rides on the /status call the app already
      // makes, so there is still no settings round trip from this page.
      expect(
        requests.where((request) => request.url.path.contains('settings')),
        isEmpty,
      );
      // The home page now states what the device page states.
      expect(find.text('轮播模式'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('⭐ 推荐模式冷启动也有「下次更新」（它不在计划戳里，按固定作息算）', (tester) async {
      // `next_slot_at_ms` 是**轮播**的概念（引擎把计划落盘时写进 daily.json），
      // 推荐路径从不写它。而首页原来只读那个字段 —— 于是推荐模式下这一行永远
      // 是空的，只有"保存过一次设置"之后才出现（那条路会把固定作息算出来的值
      // 塞进 `_nextSlotAt`）。冷启动和保存后必须走同一个来源。
      //
      // 这条用例刻意用 `has_assets: false`：那行文案讲的是**作息**，不是照片，
      // 所以它必须在任何同步之前就算出来 —— 也让这条测试完全不碰下载与渲染。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'bloom.device_id': credentials.deviceId,
        'bloom.identity_version': 2,
        'bloom.display_mode': 'recommend',
        'bloom.carousel_interval_minutes': 720,
        'bloom.carousel_active_start': '06:00',
        'bloom.carousel_active_end': '22:00',
      });

      final requests = <http.Request>[];
      final client = BloomApiClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/status')) {
            return http.Response(
              jsonEncode({
                'device_id': credentials.deviceId,
                'device_type': 'mobile',
                'mode': 'recommend',
                'paired': true,
                'has_assets': false,
              }),
              200,
              headers: jsonHeaders,
            );
          }
          return http.Response('{}', 200, headers: jsonHeaders);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: BloomHomePage(
            identity: DeviceIdentityRepository(
              readToken: (_) async => credentials.deviceToken,
              writeToken: (_, _) async {},
              stableCredentials: () async => null,
            ),
            api: client,
            displayPreferences: DisplayPreferences(api: client),
            // 已登录：四个页面都有未登录分支，不喂会话就会停在登录提示上，
            // 这些验内容的用例会假失败。
            auth: signedInAuthRepository(),
          ),
        ),
      );
      // `settle` 推进 720ms 假时钟，够 `_paintLocalContent` 那 600ms 有界等待超时
      // （测试里没有平台通道，它必然超时；真机上它在毫秒级就返回）。
      await settle(tester);

      final label = find.byKey(const ValueKey('bloom-next-slot'));
      expect(
        label,
        findsOneWidget,
        reason: '推荐的节奏由固定作息唯一决定，冷启动就该有这一行',
      );
      expect(tester.widget<Text>(label).data ?? '', startsWith('下次更新 '));

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('首页设备切换', () {
    testWidgets('默认显示本机照片，切到相框时不假装能取到它的照片', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final devices = bloomDevices(
        credentials: credentials,
        localOnline: true,
      );
      final frame = devices.firstWhere((device) => device.isFrame);
      var selectedId = devices.firstWhere((device) => device.isLocal).deviceId;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder:
                (context, setState) => BloomGlassHome(
                  loading: false,
                  paired: true,
                  pairingRefreshing: false,
                  nextLoading: false,
                  selectedTab: 0,
                  credentials: credentials,
                  settings: const BloomDisplaySettings(
                    mode: BloomDisplayMode.carousel,
                    intervalMinutes: 60,
                  ),
                  devices: devices,
                  selectedDeviceId: selectedId,
                  onTabChanged: (_) {},
                  onRefresh: () async {},
                  onNext: () {},
                  onDeviceChanged:
                      (deviceId) => setState(() => selectedId = deviceId),
                  onOpenDevice: (_) {},
                  onAddDevice: () {},
                  onRefreshPairingCode: () {},
                  onCopyDeviceId: () {},
                  onCopyPairingCode: () {},
                  // 首页现在也要登录才显示内容，这个用例验的是内容本身。
                  account: fakeAccount(),
                ),
          ),
        ),
      );
      await settle(tester);

      // The switcher starts on this phone, so no placeholder is shown.
      expect(find.text('照片只显示在相框自己的屏幕上'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('bloom-device-switcher')));
      await settle(tester);
      await tester.tap(
        find.byKey(ValueKey('bloom-device-option-${frame.deviceId}')),
      );
      await settle(tester);

      expect(selectedId, frame.deviceId);
      // 切到相框时不能假装它的照片取得到。
      //
      // ⚠️ 这里原先断言的是"登录后可查看此设备的照片"。那句话在 F1 落地后
      // **依然兑现不了**：相框的照片由 `/carousel/plan` 提供，而它认的是相框
      // 自己的设备令牌，用户会话解不开（服务端也没有对应的用户会话取图接口）。
      // 所以文案改成了实话，这条断言跟着改 —— 它守的是"不许承诺做不到的事"。
      expect(find.text('照片只显示在相框自己的屏幕上'), findsOneWidget);
      expect(find.text('登录后可查看此设备的照片'), findsNothing);
    });
  });
}
