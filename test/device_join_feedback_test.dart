import 'dart:async';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/ui/bloom_device_sharing_page.dart';
import 'package:bloom/ui/bloom_device_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class JoinApi extends BloomApiClient {
  final response = Completer<Map<String, dynamic>>();
  int calls = 0;
  @override
  Future<Map<String, dynamic>> userRequest(
    String token,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? deviceToken,
    Map<String, String>? query,
  }) {
    calls++;
    expect(path, 'device-invitations/join');
    expect(method, 'POST');
    return response.future;
  }
}

class LeaveApi extends BloomApiClient {
  LeaveApi(this.outcomes);
  final List<Object> outcomes;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> userRequest(
    String token,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? deviceToken,
    Map<String, String>? query,
  }) async {
    expect(path, 'devices/shared-frame/contribution');
    expect(method, 'DELETE');
    final outcome = outcomes[calls++];
    if (outcome is Map<String, dynamic>) return outcome;
    throw outcome;
  }
}

Future<void> confirmLeave(WidgetTester tester) async {
  await tester.tap(find.text('停止供图').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('停止供图').last);
  await tester.pumpAndSettle();
}

void main() {
  for (final outcome in ['success', 'expired', 'lost_response', 'invalid']) {
    testWidgets('join dialog shows confirmed result: $outcome', (tester) async {
      final api = JoinApi();
      bool? joined;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      joined = await joinBloomDevice(
                        context,
                        api,
                        'account-token',
                        rawCode:
                            outcome == 'invalid'
                                ? 'wrong-code'
                                : 'bloom://device/${'a' * 43}',
                      );
                    },
                    child: const Text('扫码加入'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('扫码加入'));
      await tester.pump();
      await tester.pump();
      if (outcome != 'invalid') {
        expect(find.text('正在加入设备'), findsOneWidget);
        expect(joined, isNull);
        expect(find.text('完成'), findsNothing);
        if (outcome == 'success') {
          api.response.complete({
            'status': 'joined',
            'device_id': 'frame-1',
            'name': '客厅',
            'device_type': 'eink',
            'relationship': 'contributor',
          });
        } else {
          api.response.completeError(
            outcome == 'expired'
                ? BloomApiException(404, 'device_code_invalid', 'expired')
                : TimeoutException('reply lost'),
          );
        }
      }
      await tester.pumpAndSettle();
      expect(api.calls, outcome == 'invalid' ? 0 : 1);
      expect(
        find.text(outcome == 'success' ? '已成功加入' : '尚未确认加入'),
        findsOneWidget,
      );
      if (outcome == 'expired') {
        expect(find.textContaining('已失效'), findsOneWidget);
      }
      if (outcome == 'lost_response') {
        expect(find.textContaining('重新扫码确认'), findsOneWidget);
      }
      expect(joined, isNull, reason: 'result stays visible until acknowledged');
      await tester.tap(find.text(outcome == 'success' ? '完成' : '知道了'));
      await tester.pumpAndSettle();
      expect(joined, outcome == 'success');
      expect(tester.takeException(), isNull);
    });
  }

  for (final outcome in [
    'success',
    'already_left',
    'unconfirmed',
    'forbidden',
    'missing_device',
  ]) {
    testWidgets('leave only finishes on confirmed absence: $outcome', (
      tester,
    ) async {
      final api = LeaveApi([
        switch (outcome) {
          'success' => <String, dynamic>{'status': 'left'},
          'already_left' => BloomApiException(
            404,
            'device_not_joined',
            'absent',
          ),
          'forbidden' => BloomApiException(
            403,
            'device_not_owned',
            'forbidden',
          ),
          'missing_device' => BloomApiException(
            404,
            'device_not_found',
            'missing',
          ),
          _ => <String, dynamic>{'status': 'unknown'},
        },
      ]);
      bool? left;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    left = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder:
                            (_) => BloomJoinedDevicePage(
                              api: api,
                              token: 'family-session',
                              device: const BloomDevice(
                                deviceId: 'shared-frame',
                                name: '客厅',
                                type: 'eink',
                                canManage: false,
                              ),
                            ),
                      ),
                    );
                  },
                  child: const Text('打开共享设备'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('打开共享设备'));
      await tester.pumpAndSettle();
      await confirmLeave(tester);
      expect(api.calls, 1);
      expect(
        left,
        outcome == 'success' || outcome == 'already_left' ? isTrue : isNull,
      );
      if (outcome == 'unconfirmed') {
        expect(find.textContaining('暂时无法确认退出结果'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('leave response lost after commit converges on retry', (
    tester,
  ) async {
    final api = LeaveApi([
      TimeoutException('server committed, reply lost'),
      BloomApiException(404, 'device_not_joined', 'already absent'),
    ]);
    bool? left;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  left = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder:
                          (_) => BloomJoinedDevicePage(
                            api: api,
                            token: 'family-session',
                            device: const BloomDevice(
                              deviceId: 'shared-frame',
                              name: '客厅',
                              type: 'eink',
                              canManage: false,
                            ),
                          ),
                    ),
                  );
                },
                child: const Text('打开共享设备'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('打开共享设备'));
    await tester.pumpAndSettle();
    await confirmLeave(tester);
    expect(left, isNull);
    expect(find.textContaining('暂时无法确认退出结果'), findsOneWidget);
    await confirmLeave(tester);
    expect(api.calls, 2);
    expect(left, isTrue);
    expect(tester.takeException(), isNull);
  });
}
