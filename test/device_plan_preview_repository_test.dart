import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/storage/device_plan_preview_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bloom-display-test-');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  const keyA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const keyB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGPoXznnPwgzwBgAYzgLTcqgbmMAAAAASUVORK5CYII=',
  );

  test(
    'server-plan previews download only current items, restore offline and never share widget state',
    () async {
      var offline = false;
      final calls = <String>[];
      final api = BloomApiClient(
        client: MockClient((r) async {
          calls.add(r.url.path);
          expect(r.headers['Authorization'], 'Bearer account-token');
          expect(r.headers.containsKey('X-Frame-Token'), false);
          if (offline) throw const SocketException('offline');
          if (r.url.path.endsWith('/carousel/settings/get')) {
            expect(r.method, 'POST');
            expect(jsonDecode(r.body), {'target': 'eink'});
            return http.Response(
              jsonEncode({
                'settings': {
                  'active_start': '06:00',
                  'active_end': '23:30',
                  'interval_minutes': 15,
                  'mode':
                      r.url.path.contains('frame-a') ? 'carousel' : 'recommend',
                },
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/image')) {
            expect(r.url.path.contains('/plan-preview/image'), true);
            expect(
              r.url.queryParameters['item_id'],
              r.url.path.contains('frame-a') ? '100' : '200',
            );
            return http.Response.bytes(png, 200);
          }
          return http.Response(
            jsonEncode({
              'devices': [
                for (final pair in [('frame-a', keyA), ('frame-b', keyB)])
                  {
                    'device_id': pair.$1,
                    'status': 'ready',
                    'image_key': pair.$2,
                    'plan_id': 8,
                    'item_id': pair.$1 == 'frame-a' ? 100 : 200,
                    'next_check_at': '2026-10-13T01:15:00+08:00',
                    'display_at': '2026-10-13T01:00:00+08:00',
                  },
              ],
            }),
            200,
          );
        }),
      );
      final repo = DevicePlanPreviewRepository(api: api, directory: dir);
      await repo.restore('account', {'frame-a', 'frame-b'});
      await repo.refresh('account', 'account-token', {'frame-a', 'frame-b'});
      expect(
        repo.snapshots['frame-a']!.imagePath,
        isNot(repo.snapshots['frame-b']!.imagePath),
      );
      expect(repo.snapshots['frame-a']!.itemId, 100);
      expect(repo.snapshots['frame-b']!.itemId, 200);
      expect(repo.snapshots['frame-a']!.mode, 'carousel');
      expect(repo.snapshots['frame-b']!.mode, 'recommend');
      expect(
        repo.snapshots['frame-a']!.nextCheckAt,
        DateTime.parse('2026-10-13T01:15:00+08:00'),
      );
      expect(
        calls.any(
          (p) =>
              (p.contains('/carousel/') && !p.endsWith('/settings/get')) ||
              p.contains('/daily'),
        ),
        false,
      );
      final afterFirstDownload = calls.length;
      await repo.refresh('account', 'account-token', {'frame-a', 'frame-b'});
      expect(
        calls.length,
        afterFirstDownload + 3,
        reason: 'same current picture must not be downloaded again',
      );
      final restored = DevicePlanPreviewRepository(api: api, directory: dir);
      final count = calls.length;
      await restored.restore('account', {'frame-a', 'frame-b'});
      expect(restored.snapshots['frame-a']!.imageKey, keyA);
      expect(restored.snapshots['frame-a']!.mode, 'carousel');
      expect(restored.snapshots['frame-b']!.mode, 'recommend');
      expect(
        calls.length,
        count,
        reason: 'offline restoration and switching do not request content',
      );
      offline = true;
      await restored.refresh('account', 'account-token', {
        'frame-a',
        'frame-b',
      });
      expect(restored.snapshots['frame-a']!.offline, true);
      expect(restored.snapshots['frame-a']!.mode, 'carousel');
      expect(
        await File(restored.snapshots['frame-a']!.imagePath!).exists(),
        true,
      );
      await restored.restore('different-account', {'frame-a'});
      expect(
        restored.snapshots,
        isEmpty,
        reason: 'a different account must not see retained private screens',
      );
    },
  );

  test(
    'refresh immediately masks cached photos and completes each device independently',
    () async {
      final list = Completer<http.Response>();
      final slowImage = Completer<http.Response>();
      final downloading = Completer<void>();
      final fastReady = Completer<void>();
      final api = BloomApiClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('device-plan-previews')) return list.future;
          if (r.url.path.endsWith('/carousel/settings/get')) {
            return http.Response(
              jsonEncode({
                'settings': {'mode': 'carousel'},
              }),
              200,
            );
          }
          if (r.url.path.contains('frame-a')) {
            downloading.complete();
            return slowImage.future;
          }
          return http.Response.bytes(png, 200);
        }),
      );
      final repo = DevicePlanPreviewRepository(api: api, directory: dir);
      await repo.restore('account', {'frame-a', 'frame-b'});
      final old = File('${dir.path}/old.png')..writeAsBytesSync(png);
      repo.snapshots['frame-a'] = DevicePlanPreview(
        deviceId: 'frame-a',
        status: 'ready',
        imageKey: keyA,
        imagePath: old.path,
        itemId: 99,
      );
      final task = repo.refresh(
        'account',
        'token',
        {'frame-a', 'frame-b'},
        onChanged: () {
          if (repo.snapshots['frame-b']?.status == 'ready' &&
              !repo.snapshots['frame-b']!.loading &&
              !fastReady.isCompleted) {
            fastReady.complete();
          }
        },
      );
      expect(
        repo.snapshots['frame-a']!.loading,
        isTrue,
        reason: 'before plan response, old cache cannot appear as current',
      );
      expect(
        repo.snapshots['frame-a']!.imagePath,
        old.path,
        reason:
            'keep files internally for cache reuse, not for loading placeholders',
      );
      expect(repo.snapshots['frame-b']!.loading, isTrue);
      list.complete(
        http.Response(
          jsonEncode({
            'devices': [
              for (final id in ['frame-a', 'frame-b'])
                {
                  'device_id': id,
                  'status': 'ready',
                  'image_key': keyB,
                  'item_id': 100,
                  'plan_id': 8,
                },
            ],
          }),
          200,
        ),
      );
      await downloading.future;
      await fastReady.future;
      expect(
        repo.snapshots['frame-a']!.loading,
        isTrue,
        reason: 'new image is still downloading',
      );
      expect(
        repo.snapshots['frame-b']!.loading,
        isFalse,
        reason: 'one frame must not wait for another frame',
      );
      slowImage.complete(http.Response.bytes(png, 200));
      await task;
      expect(repo.snapshots['frame-a']!.loading, isFalse);
      expect(repo.snapshots['frame-a']!.offline, isFalse);
      expect(repo.snapshots['frame-a']!.itemId, 100);
      expect(repo.snapshots['frame-a']!.imagePath, isNot(old.path));
    },
  );

  test(
    'failure clears loading, retains cache internally, and missing access never spins forever',
    () async {
      var fail = true;
      final repo = DevicePlanPreviewRepository(
        directory: dir,
        api: BloomApiClient(
          client: MockClient((r) async {
            if (fail) throw const SocketException('offline');
            return http.Response(jsonEncode({'devices': []}), 200);
          }),
        ),
      );
      await repo.restore('account', {'frame-a'});
      final old = File('${dir.path}/old.png')..writeAsBytesSync(png);
      repo.snapshots['frame-a'] = DevicePlanPreview(
        deviceId: 'frame-a',
        status: 'ready',
        imagePath: old.path,
        imageKey: keyA,
      );
      await repo.refresh('account', 'token', {'frame-a'});
      expect(repo.snapshots['frame-a']!.loading, isFalse);
      expect(repo.snapshots['frame-a']!.offline, isTrue);
      expect(repo.snapshots['frame-a']!.imagePath, old.path);
      expect(old.existsSync(), isTrue);
      fail = false;
      await repo.refresh('account', 'token', {'frame-a'});
      expect(repo.snapshots['frame-a']!.status, 'unavailable');
      expect(repo.snapshots['frame-a']!.loading, isFalse);
      expect(repo.snapshots['frame-a']!.imagePath, isNull);
    },
  );

  test('late response after logout is discarded', () async {
    final response = Completer<http.Response>();
    final repo = DevicePlanPreviewRepository(
      api: BloomApiClient(client: MockClient((_) => response.future)),
      directory: dir,
    );
    await repo.restore('account', {'frame-a'});
    final future = repo.refresh('account', 'token', {'frame-a'});
    await repo.clear();
    response.complete(
      http.Response(
        jsonEncode({
          'devices': [
            {'device_id': 'frame-a', 'status': 'ready', 'image_key': keyA},
          ],
        }),
        200,
      ),
    );
    await future;
    expect(repo.snapshots, isEmpty);
  });
}
