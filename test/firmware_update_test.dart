import 'dart:async';
import 'dart:convert';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/firmware/firmware_update_controller.dart';
import 'package:bloom/core/models/firmware_models.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:bloom/ui/bloom_device_pages.dart';
import 'package:bloom/ui/bloom_firmware_page.dart';
import 'package:bloom/ui/bloom_glass_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const release = FirmwareRelease(
  id: 'release-B',
  version: 'test-B',
  notes: '改进更新流程',
  size: 1024,
);
Map<String, dynamic> job(
  String state, {
  String id = 'job-1',
  int bytes = 128,
}) => {
  'id': id,
  'device_id': 'frame-1',
  'release_id': release.id,
  'state': state,
  'version': release.version,
  'size': 1024,
  'bytes_downloaded': bytes,
  'created_at': '2026-10-13T07:00:00Z',
  'reported_at': DateTime.now().toUtc().toIso8601String(),
};
http.Response jsonResponse(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Map<String, dynamic> checkResponse({Map<String, dynamic>? current}) => {
  'current_version': 'test-A',
  'ota_ready': true,
  'presence': 'waiting_for_device',
  'release': {
    'id': release.id,
    'version': release.version,
    'notes': release.notes,
    'size': release.size,
  },
  'job': current,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('App 重开恢复服务器任务，离线保留真实进度；销毁不发送取消', () async {
    var disconnected = false;
    final requests = <http.Request>[];
    final api = BloomApiClient(
      client: MockClient((r) async {
        requests.add(r);
        if (disconnected) throw const FormatException('offline');
        return jsonResponse({
          'jobs': [job('downloading', bytes: 512)],
        });
      }),
    );
    final first = FirmwareUpdateController(api: api, poll: false);
    await first.setSession('token', 'account');
    expect(first.bannerJob!.progress, .5);
    first.dispose();
    disconnected = true;
    final reopened = FirmwareUpdateController(api: api, poll: false);
    await reopened.setSession('token', 'account');
    expect(reopened.bannerJob!.progress, .5);
    expect(reopened.offline, isTrue);
    disconnected = false;
    await reopened.refresh();
    expect(reopened.offline, isFalse);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    reopened.dispose();
  });

  test('切换账号不会采用上一账号迟到的任务响应', () async {
    final pending = Completer<http.Response>(), requested = Completer<void>();
    final api = BloomApiClient(
      client: MockClient((r) async {
        if (r.headers['Authorization'] == 'Bearer old') {
          requested.complete();
          return pending.future;
        }
        return jsonResponse({'jobs': []});
      }),
    );
    final updates = FirmwareUpdateController(api: api, poll: false);
    final old = updates.setSession('old', 'old-account');
    await requested.future;
    await updates.setSession('new', 'new-account');
    pending.complete(
      jsonResponse({
        'jobs': [job('installing')],
      }),
    );
    await old;
    expect(updates.bannerJob, isNull);
    await updates.setSession(null, null);
    expect(updates.signedIn, isFalse);
    updates.dispose();
  });

  test('关闭完成结果后，重新检查和重开 App 不再弹出同一结果', () async {
    final api = BloomApiClient(
      client: MockClient(
        (r) async => jsonResponse(
          r.url.path.endsWith('/firmware')
              ? checkResponse(current: job('succeeded', bytes: 1024))
              : {
                'jobs': [job('succeeded', bytes: 1024)],
              },
        ),
      ),
    );
    final updates = FirmwareUpdateController(api: api, poll: false);
    await updates.setSession('token', 'account');
    await updates.dismiss(updates.bannerJob!);
    await updates.check('frame-1');
    expect(updates.bannerJob, isNull);
    updates.dispose();
    final reopened = FirmwareUpdateController(api: api, poll: false);
    await reopened.setSession('token', 'account');
    expect(reopened.bannerJob, isNull);
    reopened.dispose();
  });

  test('迟到的轮询不会抹除刚开始的升级任务', () async {
    var getCount = 0;
    final pending = Completer<http.Response>(), requested = Completer<void>();
    final api = BloomApiClient(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          return jsonResponse({'job': job('queued', bytes: 0)});
        }
        if (++getCount == 2) {
          requested.complete();
          return pending.future;
        }
        return jsonResponse({'jobs': []});
      }),
    );
    final updates = FirmwareUpdateController(api: api, poll: false);
    await updates.setSession('token', 'account');
    final staleRead = updates.refresh();
    await requested.future;
    await updates.start('frame-1', release);
    pending.complete(jsonResponse({'jobs': []}));
    await staleRead;
    expect(updates.bannerJob!.state, 'queued');
    updates.dispose();
  });

  test('下载取消需等待确认；安装阶段不再发送停止请求', () async {
    final posts = <http.Request>[];
    var state = 'downloading';
    final api = BloomApiClient(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          posts.add(r);
          return jsonResponse({'job': job('cancel_requested')});
        }
        return jsonResponse({
          'jobs': [job(state)],
        });
      }),
    );
    final updates = FirmwareUpdateController(api: api, poll: false);
    await updates.setSession('token', 'account');
    await updates.cancel(updates.bannerJob!);
    expect(updates.bannerJob!.state, 'cancel_requested');
    expect(updates.hasActiveFor('frame-1'), isTrue);
    state = 'installing';
    await updates.refresh();
    await updates.cancel(updates.bannerJob!);
    expect(posts, hasLength(1));
    updates.dispose();
  });

  testWidgets('全局进度条跨页面保留，安装中停止按钮禁用', (tester) async {
    var state = 'downloading';
    final api = BloomApiClient(
      client: MockClient(
        (r) async => jsonResponse({
          'jobs': [job(state, bytes: 512)],
        }),
      ),
    );
    final updates = FirmwareUpdateController(api: api, poll: false);
    await updates.setSession('token', 'account');
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder:
            (_, child) => BloomFirmwareOverlay(
              updates: updates,
              navigatorKey: navigator,
              child: child!,
            ),
        home: Scaffold(
          body: Center(
            child: TextButton(
              onPressed:
                  () => navigator.currentState!.push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('其他页面')),
                    ),
                  ),
              child: const Text('打开其他页面'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开其他页面'));
    await tester.pumpAndSettle();
    expect(find.text('其他页面'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bloom-firmware-global-banner')),
      findsOneWidget,
    );
    expect(find.text('下载固件 50%'), findsOneWidget);
    state = 'installing';
    await updates.refresh();
    await tester.pump();
    final stop = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '停止'),
    );
    expect(stop.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    updates.dispose();
  });

  testWidgets('独立更新页展示发布说明、四节点；取消后原位置可以重新更新', (tester) async {
    Map<String, dynamic>? current;
    var starts = 0;
    final api = BloomApiClient(
      client: MockClient((r) async {
        if (r.url.path.endsWith('/cancel')) {
          current = job('cancelled', bytes: 0);
          return jsonResponse({'job': current});
        }
        if (r.method == 'POST') {
          current = job('queued', id: 'job-${++starts}', bytes: 0);
          return jsonResponse({'job': current});
        }
        if (r.url.path.endsWith('/firmware')) {
          return jsonResponse(checkResponse(current: current));
        }
        return jsonResponse({
          'jobs': current == null ? [] : [current],
        });
      }),
    );
    final updates = FirmwareUpdateController(api: api, poll: false);
    await updates.setSession('token', 'account');
    await tester.pumpWidget(
      MaterialApp(
        home: BloomFirmwarePage(deviceId: 'frame-1', updates: updates),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('改进更新流程'), findsOneWidget);
    expect(find.textContaining('中键'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bloom-firmware-start')));
    await tester.pumpAndSettle();
    expect(find.text('等待相框联网'), findsOneWidget);
    for (final label in FirmwareTimeline.labels) {
      expect(find.text(label), findsOneWidget);
    }
    await updates.cancel(updates.jobFor('frame-1')!);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('bloom-firmware-start')),
    );
    await tester.tap(find.byKey(const ValueKey('bloom-firmware-start')));
    await tester.pumpAndSettle();
    expect(starts, 2);
    await tester.pumpWidget(const SizedBox());
    updates.dispose();
  });

  testWidgets('固件入口只在相框最下方，不使用黑色卡片；活动更新禁用解绑', (tester) async {
    final api = BloomApiClient(
      client: MockClient((r) async {
        if (r.url.path.endsWith('/firmware/jobs')) {
          return jsonResponse({
            'jobs': [job('installing')],
          });
        }
        return jsonResponse({
          'settings': {
            'mode': 'carousel',
            'interval_minutes': 60,
            'active_start': '06:00',
            'active_end': '22:00',
            'sources': [
              {'name': 'personal', 'weight': 1},
            ],
          },
        });
      }),
    );
    final updates = FirmwareUpdateController(api: api, poll: false);
    await updates.setSession('token', 'account');
    Future<void> show(String type) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BloomDeviceDetailPage(
            key: ValueKey(type),
            device: BloomDevice(deviceId: 'frame-1', name: '设备', type: type),
            preferences: DisplayPreferences(api: api),
            settings: const BloomDisplaySettings(),
            userToken: 'token',
            firmwareUpdates: updates,
            onUnbind: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('eink');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bloom-firmware-entry')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final entry = find.byKey(const ValueKey('bloom-firmware-entry'));
    expect(
      find.ancestor(of: entry, matching: find.byType(BloomPanel)),
      findsNothing,
    );
    final unbind = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('bloom-device-unbind')),
    );
    expect(unbind.onPressed, isNull);
    await show('mobile');
    expect(find.byKey(const ValueKey('bloom-firmware-entry')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    updates.dispose();
  });
}
