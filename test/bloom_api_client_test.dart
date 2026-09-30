import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/display_preferences.dart';

void main() {
  final credentials = DeviceCredentials(
    deviceId: 'bloom-mobile-test',
    deviceToken: 'a' * 64,
  );

  test('register uses frame token and expected public path', () async {
    late http.Request request;
    final client = BloomApiClient(
      baseUrl: 'https://bloom.jihu.top',
      client: MockClient((r) async {
        request = r;
        return http.Response(
          jsonEncode({
            'pairing_code': '719202',
            'pairing_expires_at': '2026-08-13T04:03:59Z',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final pairing = await client.register(credentials, name: '测试手机');
    expect(request.url.path, '/api/frame/devices/bloom-mobile-test/register');
    expect(request.headers['x-frame-token'], credentials.deviceToken);
    expect(jsonDecode(request.body)['screen_profile'], 'flutter-widget-v1');
    expect(pairing.code, '719202');
  });

  test('daily sends mobile target and parses photo metadata', () async {
    final client = BloomApiClient(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(jsonDecode(request.body)['target'], 'mobile');
        return http.Response(
          jsonEncode({
            'date': '2026-08-13',
            'recommendation_id': 3,
            'asset_id': 'asset-1',
            'target': 'mobile',
            'photo': {
              'url': '/api/frame/devices/x/daily/photo',
              'format': 'image/jpeg',
              'width': 4032,
              'height': 3024,
              'orientation': 'landscape',
            },
          }),
          200,
        );
      }),
    );
    final daily = await client.daily(credentials, target: 'mobile');
    expect(daily.photo!.url, startsWith('/api/frame/'));
    expect(daily.photo!.orientation, 'landscape');
  });

  test('carousel next is POST and keeps device-scoped schedule', () async {
    final client = BloomApiClient(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, contains('/carousel/item'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['action'], 'next');
        expect(body['interval_minutes'], 60);
        expect(body['active_start'], '06:00');
        expect(body['active_end'], '22:00');
        return http.Response(
          jsonEncode({
            'next_check_at': '2026-08-15T11:00:00+08:00',
            'item': {
              'item_id': 501,
              'display_at': '2026-08-15T10:12:00+08:00',
              'caption': {'zh': '测试轮播', 'en': 'Test'},
              'captured_date_text': '2024.01.02',
              'location_text': '天津',
              'photo_orientation': 'landscape',
              'photo': {
                'post_url': '/api/frame/devices/x/carousel/photo',
                'format': 'image/jpeg',
                'width': 4032,
                'height': 3024,
                'orientation': 'landscape',
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final result = await client.carouselItem(
      credentials,
      const BloomDisplaySettings(
        mode: BloomDisplayMode.carousel,
        intervalMinutes: 60,
      ),
      next: true,
      currentItemId: 500,
    );
    expect(result.item.itemId, 501);
    expect(result.item.photo.url, contains('/carousel/photo'));
  });

  test('settings get posts the target and parses the envelope', () async {
    late http.Request request;
    final client = BloomApiClient(
      client: MockClient((r) async {
        request = r;
        return http.Response(
          jsonEncode({
            'api_version': 1,
            'settings': {
              'device_id': 'bloom-mobile-test',
              'target': 'eink',
              'timezone': 'Asia/Shanghai',
              'active_start': '06:00',
              'active_end': '22:00',
              'interval_minutes': 15,
              'daily_slot_count': 65,
              'settings_hash': '6de216',
              'updated_at': '2026-09-21T09:00:00+08:00',
            },
            'allowed_interval_minutes': [15, 30, 60],
            'next_check_at': '2026-09-21T10:30:00+08:00',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final envelope = await client.getDeviceSettings(
      credentials,
      target: 'eink',
    );

    expect(request.method, 'POST');
    expect(
      request.url.path,
      '/api/frame/devices/${credentials.deviceId}/carousel/settings/get',
    );
    expect(request.headers['x-frame-token'], credentials.deviceToken);
    expect(jsonDecode(request.body), {'target': 'eink'});
    expect(envelope.settings.intervalMinutes, 15);
    expect(envelope.settings.dailySlotCount, 65);
    expect(envelope.allowedIntervalMinutes, [15, 30, 60]);
    expect(envelope.apiVersion, 1);
    expect(envelope.nextCheckAt, isNotNull);
  });

  test('settings set sends caller_device_id and surfaces 422 detail', () async {
    late http.Request request;
    final client = BloomApiClient(
      client: MockClient((r) async {
        request = r;
        return http.Response(
          jsonEncode({'detail': 'interval_minutes 不在允许的档位中'}),
          422,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await expectLater(
      client.setDeviceSettings(
        credentials,
        target: 'eink',
        timezone: 'Asia/Shanghai',
        activeStart: '06:00',
        activeEnd: '22:00',
        intervalMinutes: 45,
        callerDeviceId: credentials.deviceId,
      ),
      throwsA(
        isA<BloomApiException>()
            .having((error) => error.statusCode, 'statusCode', 422)
            .having((error) => error.message, 'message', contains('档位')),
      ),
    );

    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(
      request.url.path,
      '/api/frame/devices/${credentials.deviceId}/carousel/settings/set',
    );
    expect(body['caller_device_id'], credentials.deviceId);
    expect(body['interval_minutes'], 45);
    expect(body['target'], 'eink');
  });

  test('settings set surfaces 403 and list-shaped 422 details', () async {
    Future<void> expectFailure(Object body, int status, String needle) async {
      final client = BloomApiClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(body),
            status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await expectLater(
        client.setDeviceSettings(
          credentials,
          target: 'eink',
          timezone: 'Asia/Shanghai',
          activeStart: '06:00',
          activeEnd: '22:00',
          intervalMinutes: 60,
          callerDeviceId: 'bloom-frame-1',
        ),
        throwsA(
          isA<BloomApiException>()
              .having((error) => error.statusCode, 'statusCode', status)
              .having((error) => error.message, 'message', contains(needle)),
        ),
      );
    }

    await expectFailure(
      const {'detail': '两个设备不属于同一账号'},
      403,
      '同一账号',
    );
    await expectFailure(
      const {
        'detail': [
          {'loc': ['body', 'interval_minutes'], 'msg': 'not an allowed tier'},
        ],
      },
      422,
      'not an allowed tier',
    );
  });

  test('listMyDevices sends the account session, not the device token', () async {
    // F1 之前这里断言的是"恒抛 UnsupportedError"。现在它真的发请求了，
    // 所以断言换成更有价值的一条：**用的是 Bearer 用户会话，而不是设备令牌**。
    // 两者互换会让接口 401，而症状看起来像"登录了却读不到设备"。
    late http.Request captured;
    final client = BloomApiClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'devices': [
              {
                'device_id': 'bloom-eink-68ee8f606594',
                'name': 'E-Ink',
                'device_type': 'eink',
                'enabled': true,
                'last_seen_at': '2026-09-30T10:00:00+08:00',
                'bound_at': '2026-09-29T10:00:00+08:00',
                'bound_user_count': 1,
                'settings': {
                  'interval_minutes': 15,
                  'active_start': '06:00',
                  'active_end': '22:00',
                  'updated_at': '2026-09-30T09:00:00+08:00',
                },
              },
            ],
          }),
          200,
        );
      }),
    );

    final devices = await client.listMyDevices('account-session-token');

    expect(captured.url.path, '/api/frame/users/me/devices');
    expect(captured.headers['Authorization'], 'Bearer account-session-token');
    expect(captured.headers.containsKey('X-Frame-Token'), isFalse);

    expect(devices, hasLength(1));
    expect(devices.single.deviceId, 'bloom-eink-68ee8f606594');
    expect(devices.single.isFrame, isTrue);
    expect(devices.single.settings?.intervalMinutes, 15);
    expect(devices.single.boundUserCount, 1);
    expect(devices.single.lastSeenAt, isNotNull);
  });

  test('listMyDevices tolerates a missing settings object', () async {
    // 服务端在设备还没有设置行时整个 settings 都不给，不是给一个空对象。
    final client = BloomApiClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'devices': [
              {'device_id': 'd1', 'device_type': 'mobile', 'enabled': true},
            ],
          }),
          200,
        ),
      ),
    );
    final devices = await client.listMyDevices('t');
    expect(devices.single.settings, isNull);
    expect(devices.single.lastSeenAt, isNull);
  });
}
