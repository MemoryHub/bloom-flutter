import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/models/device_models.dart';

void main() {
  const phone = DeviceCredentials(
    deviceId: 'phone',
    deviceToken: 'phone-token',
  );
  test('朝向请求指向所选相框，并使用手机的绑定身份', () async {
    final requests = <http.Request>[];
    final api = BloomApiClient(
      client: MockClient((request) async {
        requests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'device_id': 'frame', 'mode': body['mode'] ?? 'auto'}),
          200,
        );
      }),
    );
    expect(await api.frameOrientation(phone, frameDeviceId: 'frame'), 'auto');
    expect(
      await api.frameOrientation(phone, frameDeviceId: 'frame', mode: 'locked'),
      'locked',
    );
    expect(
      requests.first.url.path,
      '/api/frame/devices/frame/orientation/settings/get',
    );
    expect(
      requests.last.url.path,
      '/api/frame/devices/frame/orientation/settings/set',
    );
    for (final request in requests) {
      expect(request.headers['X-Frame-Token'], 'phone-token');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['caller_device_id'], 'phone');
      expect(body.containsKey('interval_minutes'), isFalse);
    }
  });
  test('未授权的朝向写入不伪造成功', () async {
    final api = BloomApiClient(
      client: MockClient(
        (_) async =>
            http.Response('{"detail":"device_not_bound_to_caller"}', 403),
      ),
    );
    expect(
      api.frameOrientation(phone, frameDeviceId: 'frame', mode: 'locked'),
      throwsA(isA<BloomApiException>()),
    );
  });
  test('错误朝向响应拒绝，避免显示错误模式', () async {
    final api = BloomApiClient(
      client: MockClient(
        (_) async => http.Response('{"mode":"portrait"}', 200),
      ),
    );
    expect(
      api.frameOrientation(phone, frameDeviceId: 'frame'),
      throwsFormatException,
    );
  });
}
