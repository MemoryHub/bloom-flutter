import 'dart:convert';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('作品加入用账号权限和目标相框，保持幂等操作语义', () async {
    final requests = <http.Request>[];
    final api = BloomApiClient(
      client: MockClient((r) async {
        requests.add(r);
        return http.Response(
          jsonEncode({
            'revision': 1,
            'items': [],
            'status': 'waiting_for_sync',
          }),
          200,
        );
      }),
    );
    await api.changeContentSelection(
      'account-token',
      'selected-frame',
      kind: 'artwork',
      referenceId: 'painting-id',
      selected: true,
    );
    final request = requests.single;
    expect(request.method, 'PATCH');
    expect(
      request.url.path,
      '/api/frame/devices/selected-frame/content-selections',
    );
    expect(request.headers['Authorization'], 'Bearer account-token');
    expect(request.headers.containsKey('X-Frame-Token'), false);
    expect(jsonDecode(request.body), {
      'kind': 'artwork',
      'reference_id': 'painting-id',
      'selected': true,
    });
    expect(request.body, isNot(contains('interval_minutes')));
  });

  test('发现分页只请求元数据，图片仍是服务端发布的预览', () async {
    final api = BloomApiClient(
      client: MockClient((r) async {
        expect(r.url.path, '/api/frame/discover/collections/collection-id');
        expect(r.url.queryParameters['offset'], '12');
        expect(r.headers.containsKey('Authorization'), false);
        return http.Response(jsonEncode({'items': [], 'has_more': false}), 200);
      }),
    );
    await api.discoverCollection('collection-id', offset: 12);
    expect(
      api.discoverImageUrl('/api/frame/discover/artworks/id/image'),
      'https://bloom.jihu.top/api/frame/discover/artworks/id/image',
    );
  });

  test('相框作息读取鉴权手机，路径指向相框；来源权重保留', () async {
    final api = BloomApiClient(
      client: MockClient((r) async {
        expect(r.url.path, '/api/frame/devices/frame-id/carousel/settings/get');
        expect(r.headers['X-Frame-Token'], 'phone-token');
        expect(jsonDecode(r.body), {
          'target': 'eink',
          'caller_device_id': 'phone-id',
        });
        return http.Response(
          jsonEncode({
            'settings': {
              'timezone': 'Asia/Shanghai',
              'active_start': '06:00',
              'active_end': '22:00',
              'interval_minutes': 15,
              'sources': [
                {'name': 'personal', 'weight': 3},
                {'name': 'art', 'weight': 1},
              ],
            },
          }),
          200,
        );
      }),
    );
    final remote = await api.getDeviceSettings(
      const DeviceCredentials(deviceId: 'phone-id', deviceToken: 'phone-token'),
      target: 'eink',
      deviceId: 'frame-id',
    );
    expect(remote.settings.sourceWeights, {'personal': 3.0, 'art': 1.0});
  });
}
