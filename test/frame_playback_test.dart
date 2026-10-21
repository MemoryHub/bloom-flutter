import 'dart:async';
import 'dart:convert';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/provisioning/frame_playback_controller.dart';
import 'package:bloom/ui/bloom_frame_playback_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> job(
  String state, {
  String phase = 'waiting_frame',
  String id = 'job-one',
  String at = '2026-10-15T00:00:00Z',
}) => {
  'id': id,
  'device_id': 'frame-one',
  'device_name': '客厅的相框',
  'state': state,
  'phase': phase,
  'created_at': at,
};
http.Response response(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('没有设备字节回报时显示等待，真实字节决定百分比', () {
    final data = {
      ...job('running', phase: 'downloading_first'),
      'received_bytes': 0,
      'total_bytes': 960000,
    };
    expect(FramePlaybackJob(data).percent, isNull);
    expect(FramePlaybackJob({...data, 'received_bytes': 480000}).percent, 50);
    expect(FramePlaybackJob({...data, 'received_bytes': 960000}).percent, 100);
  });

  test('退出后台和重开保留设备真实进度，不发送取消命令', () async {
    bool offline = false;
    final requests = <http.Request>[];
    final api = BloomApiClient(
      client: MockClient((r) async {
        requests.add(r);
        if (offline) throw const FormatException('offline');
        return response({
          'jobs': [job('running', phase: 'refreshing_screen')],
        });
      }),
    );
    final c = FramePlaybackController(api: api, poll: false);
    await c.setSession('token', 'account');
    await Future<void>.delayed(Duration.zero);
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    c.dispose();
    offline = true;
    final reopened = FramePlaybackController(api: api, poll: false);
    await reopened.setSession('token', 'account');
    expect(reopened.jobFor('frame-one')!.phase, 'refreshing_screen');
    expect(reopened.offline, isTrue);
    expect(reopened.jobFor('frame-one')!.complete, isFalse);
    offline = false;
    await reopened.refresh();
    expect(reopened.offline, isFalse);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    reopened.dispose();
  });

  test('切换账号隔离旧账号迟到响应', () async {
    final pending = Completer<http.Response>(), requested = Completer<void>();
    final c = FramePlaybackController(
      poll: false,
      api: BloomApiClient(
        client: MockClient((r) async {
          if (r.headers['Authorization'] == 'Bearer old') {
            requested.complete();
            return pending.future;
          }
          return response({'jobs': []});
        }),
      ),
    );
    final old = c.setSession('old', 'old-account');
    await requested.future;
    await c.setSession('new', 'new-account');
    pending.complete(
      response({
        'jobs': [job('running')],
      }),
    );
    await old;
    expect(c.jobs, isEmpty);
    c.dispose();
  });

  test('旧轮询响应不会覆盖刚创建的首次播放任务', () async {
    int gets = 0;
    final stale = Completer<http.Response>(), requested = Completer<void>();
    final c = FramePlaybackController(
      poll: false,
      api: BloomApiClient(
        client: MockClient((r) async {
          if (r.method == 'POST') return response({'command': job('queued')});
          if (++gets == 2) {
            requested.complete();
            return stale.future;
          }
          return response({'jobs': []});
        }),
      ),
    );
    await c.setSession('token', 'account');
    final refresh = c.refresh();
    await requested.future;
    await c.start('frame-one');
    stale.complete(response({'jobs': []}));
    await refresh;
    expect(c.jobFor('frame-one')!.id, 'job-one');
    c.dispose();
  });

  test('网络回执丢失重试沿用请求ID，新一轮配对使用新ID', () async {
    final ids = <String>[];
    bool fail = true;
    final c = FramePlaybackController(
      poll: false,
      api: BloomApiClient(
        client: MockClient((r) async {
          if (r.method == 'GET') return response({'jobs': []});
          ids.add(jsonDecode(r.body)['request_id'] as String);
          if (fail) throw const FormatException('reply lost');
          return response({'command': job('succeeded', phase: 'completed')});
        }),
      ),
    );
    await c.setSession('token', 'account');
    await expectLater(c.start('frame-one'), throwsFormatException);
    await expectLater(c.start('frame-one'), throwsFormatException);
    expect(ids[0], ids[1]);
    fail = false;
    await c.start('frame-one', newSetup: true);
    expect(ids[2], isNot(ids[0]));
    c.dispose();
  });

  test('完成最新任务后不再展示同一相框旧失败提示', () async {
    final c = FramePlaybackController(
      poll: false,
      api: BloomApiClient(
        client: MockClient(
          (_) async => response({
            'jobs': [
              job('succeeded', phase: 'completed', at: '2026-10-15T02:00:00Z'),
              job('failed', id: 'old', at: '2026-10-15T01:00:00Z'),
            ],
          }),
        ),
      ),
    );
    await c.setSession('token', 'account');
    c.dismiss(c.jobFor('frame-one')!);
    expect(c.bannerJob, isNull);
    c.dispose();
  });

  testWidgets('小屏可查看时间轴，时间流逝不会假完成，回执成功才显示完成按钮', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var state = 'running', phase = 'downloading_first';
    final c = FramePlaybackController(
      poll: false,
      api: BloomApiClient(
        client: MockClient(
          (_) async => response({
            'jobs': [job(state, phase: phase)],
          }),
        ),
      ),
    );
    await c.setSession('token', 'account');
    await tester.pumpWidget(
      MaterialApp(
        home: BloomFramePlaybackPage(controller: c, deviceId: 'frame-one'),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('后台运行'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '完成'), findsNothing);
    await tester.pump(const Duration(minutes: 5));
    expect(find.widgetWithText(FilledButton, '完成'), findsNothing);
    state = 'succeeded';
    phase = 'completed';
    await c.refresh();
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '完成'), findsOneWidget);
    expect(find.text('照片已经在相框里了'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('准备失败时停止阶段动画，允许重试', (tester) async {
    final c = FramePlaybackController(
      poll: false,
      api: BloomApiClient(
        client: MockClient(
          (_) async => response({
            'jobs': [job('failed', phase: 'refreshing_screen')],
          }),
        ),
      ),
    );
    await c.setSession('token', 'account');
    await tester.pumpWidget(
      MaterialApp(
        home: BloomFramePlaybackPage(controller: c, deviceId: 'frame-one'),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('再次配对不会短暂显示上一次首播的完成按钮', (tester) async {
    final pending = Completer<http.Response>();
    var started = false;
    final c = FramePlaybackController(
      poll: false,
      api: BloomApiClient(
        client: MockClient((r) async {
          if (r.method == 'POST') {
            started = true;
            return pending.future;
          }
          return response({
            'jobs': [
              started
                  ? job('queued', id: 'new')
                  : job('succeeded', phase: 'completed'),
            ],
          });
        }),
      ),
    );
    await c.setSession('token', 'account');
    await tester.pumpWidget(
      MaterialApp(
        home: BloomFramePlaybackPage(
          controller: c,
          deviceId: 'frame-one',
          autoStart: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '完成'), findsNothing);
    pending.complete(response({'command': job('queued', id: 'new')}));
    await tester.pump();
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '完成'), findsNothing);
    expect(c.jobFor('frame-one')!.id, 'new');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
