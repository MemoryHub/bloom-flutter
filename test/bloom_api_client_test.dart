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
}
