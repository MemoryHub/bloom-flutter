import 'dart:convert';
import 'dart:io';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/daily_content_repository.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Behaviour pins for the **day-walking carousel cursor**.
///
/// The bug these exist for: every `/carousel/plan` request started at index 0,
/// so the phone replayed the same two or three photos forever. The first attempt
/// at the cursor had to be rolled back because the refill page — which by design
/// starts *after* the server's `current_item_id` — was required to contain that
/// current item. Every refill then threw `当前轮播照片不在计划批次中`, and because
/// the cursor advanced on each failure, no later attempt could recover.
///
/// These tests drive the real `syncCarousel` (real rendering, real file cache)
/// through a mocked method channel and a mocked HTTP client, so they pin the
/// whole pipeline, not just a helper:
///
///  1. two consecutive refills → the second carries the pool tail as its cursor
///     and the scheduled id set is the *union*, with no id twice;
///  2. a refill page that does **not** contain `current` still schedules, and the
///     current item does not move;
///  3. a new local day resets the cursor;
///  4. the pool stays bounded, and a page trimmed by the cap is not skipped.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final credentials = DeviceCredentials(
    deviceId: 'bloom-mobile-test',
    deviceToken: 'a' * 64,
  );
  const settings = BloomDisplaySettings(
    mode: BloomDisplayMode.carousel,
    intervalMinutes: 15,
  );

  // A real, decodable 64x64 PNG (a solid colour, so it stays tiny). The
  // repository decodes, crops and re-renders whatever the photo endpoint
  // returns, and the renderer asks the codec for a 720px-wide target — a 1x1
  // source is refused by the test engine's codec, so this is 64x64 on purpose.
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsIttEpMY0Ai+hcEK'
    'LNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgu0gSGlz2AY2gAAAABJRU5ErkJggg==',
  );

  late Directory cacheDir;
  late List<Map<String, Object?>> scheduledCalls;
  late List<Map<String, dynamic>> planRequests;
  Map<Object?, Object?>? nativeState;
  const channel = MethodChannel('com.bloom/widget');

  String dayOf(DateTime at) => at.toIso8601String().substring(0, 10);

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('bloom-carousel-test');
    scheduledCalls = [];
    planRequests = [];
    nativeState = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'cacheDirectory':
              return cacheDir.path;
            case 'scheduleCarousel':
              final arguments =
                  (call.arguments as Map).cast<String, Object?>();
              scheduledCalls.add(Map<String, Object?>.from(arguments));
              return null;
            case 'updateWidgetCache':
              return null;
            case 'readCurrentWidgetState':
              return nativeState;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  Map<String, dynamic> planWith({
    required int planId,
    required int currentItemId,
    required List<int> ids,
    required DateTime first,
  }) => {
    'plan_id': planId,
    'current_item_id': currentItemId,
    'next_check_at': first.add(const Duration(hours: 4)).toIso8601String(),
    'items': [
      for (var i = 0; i < ids.length; i++)
        {
          'item_id': ids[i],
          'display_at': first.add(Duration(minutes: 15 * i)).toIso8601String(),
          'caption': {'zh': '照片${ids[i]}', 'en': 'Photo ${ids[i]}'},
          'captured_date_text': '2026.09.24',
          'location_text': '天津',
          'photo_orientation': 'landscape',
          'photo': {
            'post_url':
                '/api/frame/devices/${credentials.deviceId}/carousel/photo',
            'format': 'image/jpeg',
            'width': 1,
            'height': 1,
            'orientation': 'landscape',
          },
        },
    ],
  };

  /// Serves [pages] in order from `/carousel/plan` and a valid PNG from
  /// `/carousel/photo`, recording every plan request body.
  BloomApiClient apiReturning(List<Map<String, dynamic>> pages) {
    var index = 0;
    return BloomApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/carousel/plan')) {
          planRequests.add(
            jsonDecode(request.body) as Map<String, dynamic>,
          );
          final page = pages[index < pages.length ? index : pages.length - 1];
          index++;
          return http.Response(
            jsonEncode(page),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path.endsWith('/carousel/photo')) {
          return http.Response.bytes(
            pngBytes,
            200,
            headers: {'etag': '"photo-etag"'},
          );
        }
        return http.Response('{}', 404);
      }),
    );
  }

  List<int> scheduledIds(int callIndex) {
    final entries =
        (scheduledCalls[callIndex]['entries'] as List)
            .cast<Map<Object?, Object?>>();
    return [
      for (final entry in entries) (entry['itemId'] as num).toInt(),
    ];
  }

  /// Writes a `carousel-pool.json` as the previous run would have left it.
  Future<void> writePool({
    required int planId,
    required int currentItemId,
    required int lastItemId,
    required List<int> itemIds,
    DateTime? day,
  }) async {
    final at = day ?? DateTime.now();
    await File('${cacheDir.path}/carousel-pool.json').writeAsString(
      jsonEncode({
        'day': dayOf(at),
        'plan_id': planId,
        'current_item_id': currentItemId,
        'last_item_id': lastItemId,
        'entries': [
          for (final id in itemIds)
            {
              'itemId': id,
              'displayAtMillis': at
                  .subtract(const Duration(minutes: 1))
                  .millisecondsSinceEpoch,
              'date': dayOf(at),
              'portraitPath': '${cacheDir.path}/mobile-local-portrait-$id.png',
              'squarePath': '${cacheDir.path}/mobile-local-square-$id.png',
              'largeSquarePath':
                  '${cacheDir.path}/mobile-local-largeSquare-$id.png',
              'originalPhotoPath':
                  '${cacheDir.path}/carousel-original-$id.photo',
            },
        ],
      }),
    );
  }

  test('连续两次补货：游标接在池尾，两批 id 不重叠且都进了排程', () async {
    final base = DateTime.now().subtract(const Duration(minutes: 1));
    final api = apiReturning([
      planWith(
        planId: 900,
        currentItemId: 101,
        ids: [101, 102, 103, 104],
        first: base,
      ),
      planWith(
        planId: 901,
        currentItemId: 101,
        ids: [105, 106, 107, 108],
        first: base.add(const Duration(minutes: 60)),
      ),
    ]);
    final repository = DailyContentRepository(api: api);

    await repository.syncCarousel(credentials, settings);
    await repository.syncCarousel(credentials, settings);

    expect(planRequests, hasLength(2));
    // The first page is the head of the stream: no cursor to send yet.
    expect(planRequests.first.containsKey('after_item_id'), isFalse);
    // The second page must start where the pool ended — not at index 0 again.
    expect(planRequests.last['after_item_id'], 104);

    final ids = scheduledIds(scheduledCalls.length - 1);
    expect(
      ids.toSet().length,
      ids.length,
      reason: '同一张照片不能在一次排程里出现两次',
    );
    expect(ids, containsAll(<int>[101, 102, 103, 104, 105, 106, 107, 108]));
  });

  test('补货批次不含 current：仍能排程，且当前项不变', () async {
    final base = DateTime.now().subtract(const Duration(minutes: 1));
    final api = apiReturning([
      planWith(
        planId: 910,
        currentItemId: 101,
        ids: [101, 102, 103, 104],
        first: base,
      ),
      // The refill page deliberately starts after `current_item_id` (101): this
      // is the shape that used to throw.
      planWith(
        planId: 911,
        currentItemId: 101,
        ids: [105, 106, 107, 108],
        first: base.add(const Duration(minutes: 60)),
      ),
    ]);
    final repository = DailyContentRepository(api: api);

    await repository.syncCarousel(credentials, settings);
    final second = await repository.syncCarousel(credentials, settings);

    expect(second.recommendationId, 101, reason: '补货不能把当前项推到未来的某一张');
    final daily =
        jsonDecode(await File('${cacheDir.path}/daily.json').readAsString())
            as Map<String, dynamic>;
    expect(daily['carousel_item_id'], 101);
    expect(daily['recommendation_id'], 101);

    expect(scheduledCalls, isNotEmpty, reason: '补货必须照常提交排程');
    expect(scheduledIds(scheduledCalls.length - 1), contains(101));
  });

  test('跨天：游标重置，请求不再带 after_item_id', () async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    await File('${cacheDir.path}/carousel-pool.json').writeAsString(
      jsonEncode({
        'day': dayOf(yesterday),
        'plan_id': 800,
        'current_item_id': 999,
        'last_item_id': 999,
        'entries': [
          {
            'itemId': 999,
            'displayAtMillis': yesterday.millisecondsSinceEpoch,
            'date': dayOf(yesterday),
            'portraitPath': '/tmp/does-not-exist.png',
            'squarePath': '/tmp/does-not-exist.png',
            'largeSquarePath': '/tmp/does-not-exist.png',
            'originalPhotoPath': '/tmp/does-not-exist.photo',
          },
        ],
      }),
    );
    final api = apiReturning([
      planWith(
        planId: 920,
        currentItemId: 201,
        ids: [201, 202],
        first: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
    ]);

    final result = await DailyContentRepository(
      api: api,
    ).syncCarousel(credentials, settings);

    expect(
      planRequests.single.containsKey('after_item_id'),
      isFalse,
      reason: '新的一天必须从流的开头开始，昨天的池子不能当游标',
    );
    expect(result.recommendationId, 201);
  });

  test('游标失效：服务端回空批次时自动从头发起一次，不会永久卡死', () async {
    final base = DateTime.now().subtract(const Duration(minutes: 1));
    // The pool came from plan 900; the server has rebuilt the day as plan 940
    // (a settings change, a mode switch, …), so id 104 is not in it and the
    // paged answer is an EMPTY batch.
    await writePool(
      planId: 900,
      currentItemId: 101,
      lastItemId: 104,
      itemIds: [104],
    );
    final api = apiReturning([
      {
        'plan_id': 940,
        'current_item_id': 501,
        'next_check_at': base.add(const Duration(hours: 4)).toIso8601String(),
        'items': <Map<String, dynamic>>[],
      },
      planWith(
        planId: 940,
        currentItemId: 501,
        ids: [501, 502, 503, 504],
        first: base,
      ),
    ]);

    final result = await DailyContentRepository(
      api: api,
    ).syncCarousel(credentials, settings);

    expect(planRequests, hasLength(2));
    expect(planRequests.first['after_item_id'], 104);
    expect(
      planRequests.last.containsKey('after_item_id'),
      isFalse,
      reason: '游标失效后必须从流的开头重取，而不是一直重发这个死游标',
    );
    expect(result.recommendationId, 501);
  });

  test('当天收工：池尾就是服务端当前项时空批次不重取，也不抛错', () async {
    final now = DateTime.now();
    await writePool(
      planId: 950,
      currentItemId: 104,
      lastItemId: 104,
      itemIds: [104],
    );
    // A real device still has the file; the pool's current entry must be usable.
    await File(
      '${cacheDir.path}/carousel-original-104.photo',
    ).writeAsBytes(pngBytes);
    final api = apiReturning([
      {
        'plan_id': 950,
        'current_item_id': 104,
        'next_check_at': now.add(const Duration(hours: 10)).toIso8601String(),
        'items': <Map<String, dynamic>>[],
      },
    ]);

    final result = await DailyContentRepository(
      api: api,
    ).syncCarousel(credentials, settings);

    expect(planRequests, hasLength(1), reason: '收工时的空批次不该再发一次请求');
    expect(result.recommendationId, 104);
  });

  test('无法确定当前项：排程仍然提交（闹钟链不断），失败只上报给上层', () async {
    final now = DateTime.now();
    await writePool(
      planId: 960,
      currentItemId: 105,
      lastItemId: 105,
      itemIds: [105],
    );
    // No original on disk and no daily.json: nothing can name a current slot.
    final api = apiReturning([
      {
        'plan_id': 960,
        'current_item_id': 105,
        'next_check_at': now.add(const Duration(hours: 10)).toIso8601String(),
        'items': <Map<String, dynamic>>[],
      },
    ]);

    await expectLater(
      DailyContentRepository(api: api).syncCarousel(credentials, settings),
      throwsA(isA<StateError>()),
    );
    expect(
      scheduledCalls,
      isNotEmpty,
      reason: 'scheduleCarousel 是原生重排补货闹钟的唯一入口，失败路径也必须提交，'
          '否则小组件既不动、又没有任何闹钟能再叫醒它',
    );
  });

  test('池子上限：连续补货不无限增长，被裁掉的一页不被游标跳过', () async {
    final base = DateTime.now().subtract(const Duration(minutes: 1));
    final pages = <List<int>>[
      [101, 102, 103, 104],
      [105, 106, 107, 108],
      [109, 110, 111, 112],
    ];
    final api = apiReturning([
      for (var i = 0; i < pages.length; i++)
        planWith(
          planId: 930 + i,
          currentItemId: 101,
          ids: pages[i],
          first: base.add(Duration(minutes: 60 * i)),
        ),
    ]);
    final repository = DailyContentRepository(api: api);
    for (var i = 0; i < pages.length; i++) {
      await repository.syncCarousel(credentials, settings);
    }

    final scheduled = scheduledIds(scheduledCalls.length - 1);
    expect(scheduled.length, lessThanOrEqualTo(8));
    expect(scheduled, contains(101));

    final pool =
        jsonDecode(
              await File('${cacheDir.path}/carousel-pool.json').readAsString(),
            )
            as Map<String, dynamic>;
    expect((pool['entries'] as List).length, lessThanOrEqualTo(8));
    // 12 张里裁到 8 张：被裁掉的是最远的未来（109–112）。游标停在池子真正持有的
    // 最大 id 上，所以下一轮还会把它们拿回来，而不是永久跳过。
    expect(pool['last_item_id'], 108);
  });
}
