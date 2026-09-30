/// tick 引擎的端到端测试（离线可跑，不需要设备与网络）。
///
/// 这里钉住的是三个曾经真实发生过的缺陷：
///   1. 默认设置（一天一格）当天格子已过时，「下次更新」变成空值——
///      首页整段文案消失；
///   2. 当前格照片取不到时状态错乱，界面无法给出准确提示；
///   3. 断网后文案不再推进，或显示出过去的错误时间。
library;

import 'dart:convert';
import 'dart:io';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/carousel/carousel_engine.dart';
import 'package:bloom/core/carousel/carousel_rules.dart';
import 'package:bloom/core/carousel/carousel_state.dart';
import 'package:bloom/core/carousel/photo_store.dart';
import 'package:bloom/core/carousel/state_store.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 某个本地时刻的纪元毫秒。测试全程使用本地时间字符串，避免依赖机器时区。
int at(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;

Map<String, dynamic> itemJson(int id, String displayAt) => {
  'item_id': id,
  'display_at': displayAt,
  'asset_id': 'asset-$id',
  'photo': {'url': '/carousel/photo', 'format': 'jpeg'},
  'caption': {'zh': '中文$id', 'en': 'en$id'},
  'captured_date_text': '2020-01-01',
  'location_text': '某地',
  'photo_orientation': 'portrait',
};

String planBody({
  required int planId,
  required List<Map<String, dynamic>> items,
  required String nextCheckAt,
  String settingsHash = 'h1',
  String localDate = '2026-09-28',
  bool hasMore = false,
}) => jsonEncode({
  'plan_id': planId,
  'current_item_id': items.isEmpty ? 0 : items.first['item_id'],
  'next_check_at': nextCheckAt,
  'has_more': hasMore,
  'settings_hash': settingsHash,
  'local_date': localDate,
  'items': items,
});

/// 假照片仓库：只落盘占位文件，不触发真实下载与渲染。
class _FakePhotoStore extends CarouselPhotoStore {
  _FakePhotoStore({
    required super.api,
    this.failFor = const {},
    this.failAssets = const {},
  });

  final Set<int> failFor;

  /// 按 assetId 失败。
  ///
  /// 替补会**保留 item_id、只换 asset**，所以用 itemId 区分不出「替补前那张」
  /// 和「替补后那张」——要覆盖替补成功的路径，必须能只让原 asset 失败。
  final Set<String> failAssets;
  final List<int> prepared = [];

  /// 第一次真正去准备照片时，权威状态里的「下次更新」是什么。
  ///
  /// 用来证明文案是在下载照片**之前**就落盘的——否则用户会在下载的十几秒里
  /// 看到空白标签。
  final List<int?> nextSlotSeenDuringPrepare = [];

  @override
  Future<PhotoFetchResult> prepare({
    required Directory dir,
    required CarouselItemContent item,
    required DeviceCredentials credentials,
    int attempts = 2,
    String? etag,
  }) async {
    if (failFor.contains(item.itemId) || failAssets.contains(item.assetId)) {
      return const PhotoFetchResult(
        outcome: PhotoFetchOutcome.unavailable,
        reason: 'fake failure',
      );
    }
    prepared.add(item.itemId);
    if (nextSlotSeenDuringPrepare.isEmpty) {
      final state = await CarouselStateStore(directory: dir).read();
      nextSlotSeenDuringPrepare.add(state.nextSlotAtMs);
    }
    final original = CarouselPhotoStore.originalFile(dir, item.itemId);
    await original.writeAsBytes([1, 2, 3]);
    final portrait = CarouselPhotoStore.renderedFile(dir, 'portrait', item.itemId);
    await portrait.writeAsBytes([1, 2, 3]);
    for (final family in ['square', 'largeSquare']) {
      await CarouselPhotoStore.renderedFile(
        dir,
        family,
        item.itemId,
      ).writeAsBytes([1, 2, 3]);
    }
    return PhotoFetchResult(
      outcome: PhotoFetchOutcome.ready,
      photo: PreparedPhoto(
        itemId: item.itemId,
        assetId: item.assetId,
        originalPath: original.path,
        portraitPath: portrait.path,
        squarePath: CarouselPhotoStore.renderedFile(dir, 'square', item.itemId).path,
        largeSquarePath: CarouselPhotoStore.renderedFile(
          dir,
          'largeSquare',
          item.itemId,
        ).path,
      ),
    );
  }
}

/// 构造一个 UTF-8 的 JSON 响应。
///
/// `http.Response(String, ...)` 默认按 latin1 编码请求体，中文会直接抛
/// 「Contains invalid characters」，必须走字节构造函数。
http.Response ok(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  const channel = MethodChannel('com.bloom/widget');
  final refreshCalls = <String>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bloom-engine');
    refreshCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'cacheDirectory':
              return dir.path;
            case 'refreshWidgets':
              refreshCalls.add(call.method);
              return null;
            default:
              return null;
          }
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  BloomApiClient apiWith(Future<http.Response> Function(http.Request) handler) =>
      BloomApiClient(client: MockClient(handler));

  const credentials = DeviceCredentials(deviceId: 'dev-1', deviceToken: 'tok');
  const settings = BloomDisplaySettings(intervalMinutes: 1440);

  CarouselEngine engineFor(
    BloomApiClient api, {
    required DateTime now,
    Set<int> failFor = const {},
    Set<String> failAssets = const {},
    _FakePhotoStore? photoStore,
  }) => CarouselEngine(
    api: api,
    clock: () => now,
    photoStore:
        photoStore ??
        _FakePhotoStore(api: api, failFor: failFor, failAssets: failAssets),
  );

  test('回归：默认设置当天格子已过，文案必须落明天第一格而不是空值', () async {
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(planBody(
            planId: 151,
            items: [itemJson(4434, '2026-09-28T06:00:00')],
            nextCheckAt: '2026-09-29T06:00:00',
          ));
      }
      return http.Response('nope', 404);
    });

    final engine = engineFor(api, now: DateTime.parse('2026-09-28T11:32:00'));
    final outcome = await engine.tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    expect(outcome.planFetched, isTrue);
    expect(outcome.committed, isTrue);
    expect(
      outcome.nextSlotAtMs,
      at('2026-09-29T06:00:00'),
      reason: '这正是历史上「下次更新整段不显示」的那条路径',
    );
    expect(outcome.nextSlotAtMs, isNotNull);
    expect(outcome.nextSlotSource, NextSlotSource.plan);

    final state = await CarouselStateStore(directory: dir).read();
    expect(state.nextSlotAtMs, at('2026-09-29T06:00:00'));
    expect(state.currentItemId, 4434, reason: '06:00 那张就是此刻应显示的');
  });

  test('15 分钟间隔：11:20 时下一格是 11:30，且当前格是 11:15', () async {
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(planBody(
            planId: 200,
            items: [
              itemJson(1, '2026-09-28T11:15:00'),
              itemJson(2, '2026-09-28T11:30:00'),
              itemJson(3, '2026-09-28T11:45:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ));
      }
      return http.Response('nope', 404);
    });

    final engine = engineFor(api, now: DateTime.parse('2026-09-28T11:20:00'));
    final outcome = await engine.tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    expect(outcome.nextSlotAtMs, at('2026-09-28T11:30:00'));
    expect(outcome.currentItemId, 1);

    final state = await CarouselStateStore(directory: dir).read();
    expect(state.currentSlotAtMs, at('2026-09-28T11:15:00'));
    expect(state.status, CurrentStatus.ok);
    expect(
      state.photos.map((photo) => photo.itemId).toSet(),
      containsAll(<int>[1, 2, 3]),
      reason: '当前格与后续预取的格子都应已就绪',
    );
  });

  test('当前格照片取不到且替补不可用：状态为下载失败，文案仍是下一格时间', () async {
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/item/substitute')) {
        return http.Response('{"detail":"not found"}', 404);
      }
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(planBody(
            planId: 201,
            items: [
              itemJson(10, '2026-09-28T11:15:00'),
              itemJson(11, '2026-09-28T11:30:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ));
      }
      return http.Response('nope', 404);
    });

    final engine = engineFor(
      api,
      now: DateTime.parse('2026-09-28T11:20:00'),
      failFor: {10},
    );
    final outcome = await engine.tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    expect(outcome.status, CurrentStatus.downloadFailed);
    expect(
      outcome.nextSlotAtMs,
      at('2026-09-28T11:30:00'),
      reason: '失败只影响当前格，栅格不动、时间照常推进',
    );

    final state = await CarouselStateStore(directory: dir).read();
    expect(state.status, CurrentStatus.downloadFailed);
    expect(state.nextSlotAtMs, at('2026-09-28T11:30:00'));
    // 下一格的照片必须照常备好，不能因为当前格失败就放弃预取。
    expect(state.photos.map((photo) => photo.itemId), contains(11));
  });

  test('替补成功：只换照片不换格子，栅格与下次更新时间一格未动', () async {
    // 「失败只替换同一格」的**正面**用例。
    //
    // 这是方案里最容易做错的一条：照片取不到时若把未来的格子前移，用户会提前
    // 看到还没到点的照片，观感上就是「这张怎么好像见过」。所以替补必须只换
    // 照片，item_id、display_at、以及整个栅格都要原样保留。
    final substituteCalls = <int>[];
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/item/substitute')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final itemId = body['item_id'] as int;
        substituteCalls.add(itemId);
        // 服务端换掉 asset，item_id 与 display_at 原样保留。
        return ok(
          jsonEncode({
            'item': {
              'item_id': itemId,
              'display_at': '2026-09-28T11:15:00',
              'asset_id': 'asset-replacement',
              'photo': {'url': '/carousel/photo', 'format': 'jpeg'},
              'caption': {'zh': '替补', 'en': 'replacement'},
              'photo_orientation': 'portrait',
            },
          }),
        );
      }
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(
          planBody(
            planId: 152,
            items: [
              itemJson(4481, '2026-09-28T11:15:00'),
              itemJson(4482, '2026-09-28T11:30:00'),
              itemJson(4483, '2026-09-28T11:45:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ),
        );
      }
      return http.Response('nope', 404);
    });

    final engine = engineFor(
      api,
      now: DateTime.parse('2026-09-28T11:20:00'),
      // 原 asset 取不到；替补换了 asset，所以替补后那张能取到。
      failAssets: {'asset-4481'},
    );
    final outcome = await engine.tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    expect(substituteCalls, [4481], reason: '只应为当前格申请一次替补');

    final state = await CarouselStateStore(directory: dir).read();

    // ① 照片确实换成了替补后的 asset。
    final current = state.photos.firstWhere((photo) => photo.itemId == 4481);
    expect(current.assetId, 'asset-replacement');
    expect(outcome.status, CurrentStatus.ok, reason: '替补成功后不应再报失败');

    // ② 当前格没动。
    expect(state.currentItemId, 4481);
    expect(state.currentSlotAtMs, at('2026-09-28T11:15:00'));

    // ③ 下次更新没动——替补不得影响时间推进。
    expect(state.nextSlotAtMs, at('2026-09-28T11:30:00'));

    // ④ 栅格整体逐格没动。这一条是「栅格永不动」的硬证据：如果实现改成了
    //    「取不到就换成下一格」，这里会立刻看到 4481 消失或时刻被顶掉。
    expect(
      state.grid.map((slot) => '${slot.itemId}@${slot.slotAtMs}').toList(),
      [
        '4481@${at('2026-09-28T11:15:00')}',
        '4482@${at('2026-09-28T11:30:00')}',
        '4483@${at('2026-09-28T11:45:00')}',
      ],
    );

    // ⑤ 后续格子照常预取，替补没有中断预取。
    expect(state.photos.map((photo) => photo.itemId), containsAll([4482, 4483]));
  });

  test('回归：预取失败的未来格也要替补，否则时间线留永久空洞', () async {
    // **真机现场。** App 被 MIUI 的上滑清理杀掉之后，原生侧做的是纯查表
    // （批准过的架构：原生不做决策）。时间线只烘焙「照片已经在磁盘上」的条目，
    // 所以预取一旦失败，时间线上就留一个洞，小组件**卡死在洞前那一格**。
    //
    // 实测：item 4700 连续两次 `timeout`，18:00 那一格因此缺失，小组件停在
    // 17:45；自启动修好之后闹钟明明准时响了，画面却纹丝不动。
    //
    // 修法是把替补从「等它变成当前格」提前到预取阶段。规则一个字没改：
    // 仍然只换失败的这一格，栅格永不动。
    final substituteCalls = <int>[];
    const when = {
      4482: '2026-09-28T11:30:00',
      4483: '2026-09-28T11:45:00',
    };
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/item/substitute')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final itemId = body['item_id'] as int;
        substituteCalls.add(itemId);
        // 服务端换掉 asset，item_id 与 display_at 原样保留。
        return ok(
          jsonEncode({
            'item': {
              'item_id': itemId,
              'display_at': when[itemId],
              'asset_id': 'asset-replacement-$itemId',
              'photo': {'url': '/carousel/photo', 'format': 'jpeg'},
              'caption': {'zh': '替补$itemId', 'en': 'replacement'},
              'photo_orientation': 'portrait',
            },
          }),
        );
      }
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(
          planBody(
            planId: 153,
            items: [
              itemJson(4481, '2026-09-28T11:15:00'),
              itemJson(4482, '2026-09-28T11:30:00'),
              itemJson(4483, '2026-09-28T11:45:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ),
        );
      }
      return http.Response('nope', 404);
    });

    final engine = engineFor(
      api,
      now: DateTime.parse('2026-09-28T11:20:00'),
      // 当前格 4481 正常；**预取里的 4482 取不到**——这正是要修的那一格。
      failAssets: {'asset-4482'},
    );
    await engine.tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    expect(
      substituteCalls,
      [4482],
      reason: '预取失败的那一格必须替补；当前格正常时不该打扰服务端',
    );

    final state = await CarouselStateStore(directory: dir).read();

    // ① 时间线上不再有洞——这是这条修复的全部意义。
    expect(
      state.timelineEntries.map((entry) => entry.dateMs).toList(),
      contains(at('2026-09-28T11:30:00')),
      reason: '预取那格替补成功后必须出现在时间线里，否则小组件会在 App 被杀后卡死',
    );

    // ② 替补只换了照片，格子没动。
    final filled = state.photos.firstWhere((photo) => photo.itemId == 4482);
    expect(filled.assetId, 'asset-replacement-4482');
    expect(
      state.grid.map((slot) => '${slot.itemId}@${slot.slotAtMs}').toList(),
      [
        '4481@${at('2026-09-28T11:15:00')}',
        '4482@${at('2026-09-28T11:30:00')}',
        '4483@${at('2026-09-28T11:45:00')}',
      ],
      reason: '替补不得改动栅格——「失败只替换同一格」对预取同样成立',
    );
  });

  test('预取全部成功时不申请任何替补', () async {
    // 上一条的反面：把替补扩展到预取窗口，**不能变成每轮都去打扰服务端**。
    final substituteCalls = <int>[];
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/item/substitute')) {
        substituteCalls.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['item_id'] as int,
        );
        return http.Response('unexpected', 500);
      }
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(
          planBody(
            planId: 154,
            items: [
              itemJson(4491, '2026-09-28T11:15:00'),
              itemJson(4492, '2026-09-28T11:30:00'),
              itemJson(4493, '2026-09-28T11:45:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ),
        );
      }
      return http.Response('nope', 404);
    });
    final engine = engineFor(api, now: DateTime.parse('2026-09-28T11:20:00'));
    await engine.tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );
    expect(substituteCalls, isEmpty, reason: '全都取到了就不该有替补请求');
  });

  test('断网：状态为离线，文案仍由缓存计划推进', () async {
    final offlineApi = apiWith((request) async {
      throw const SocketException('offline');
    });

    // 第一次在线，播下缓存。
    final onlineApi = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(planBody(
            planId: 202,
            items: [
              itemJson(20, '2026-09-28T11:15:00'),
              itemJson(21, '2026-09-28T11:30:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ));
      }
      return http.Response('nope', 404);
    });

    final first = engineFor(
      onlineApi,
      now: DateTime.parse('2026-09-28T11:20:00'),
    );
    await first.tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    // 第二次断网。
    final second = engineFor(offlineApi, now: DateTime.parse('2026-09-28T11:25:00'));
    final outcome = await second.tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    expect(outcome.planFetched, isFalse);
    expect(outcome.status, CurrentStatus.offline);
    expect(outcome.nextSlotSource, NextSlotSource.cached);
    expect(
      outcome.nextSlotAtMs,
      at('2026-09-28T11:30:00'),
      reason: '断网也要能靠缓存栅格算出下一格，而不是停止推进',
    );
  });

  test('写入成功后会通知对端刷新', () async {
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(planBody(
            planId: 203,
            items: [itemJson(30, '2026-09-28T11:15:00')],
            nextCheckAt: '2026-09-28T11:30:00',
          ));
      }
      return http.Response('nope', 404);
    });

    await engineFor(api, now: DateTime.parse('2026-09-28T11:20:00')).tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    expect(refreshCalls, isNotEmpty);
  });

  test('文案在下载照片之前就已落盘，用户不会对着空白标签等下载', () async {
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(
          planBody(
            planId: 205,
            items: [
              itemJson(50, '2026-09-28T11:15:00'),
              itemJson(51, '2026-09-28T11:30:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ),
        );
      }
      return http.Response('nope', 404);
    });

    final fake = _FakePhotoStore(api: api);
    await engineFor(
      api,
      now: DateTime.parse('2026-09-28T11:20:00'),
      photoStore: fake,
    ).tick(credentials: credentials, settings: settings, writer: 'test');

    expect(fake.prepared, isNotEmpty, reason: '必须真的走过下载照片这一步');
    expect(
      fake.nextSlotSeenDuringPrepare.single,
      at('2026-09-28T11:30:00'),
      reason: '去下照片的时候文案就应该已经写好了',
    );
  });

  test('烘焙时间线：两端原生侧据此纯查表，不再各自做选取决策', () async {
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(
          planBody(
            planId: 206,
            items: [
              itemJson(60, '2026-09-28T11:15:00'),
              itemJson(61, '2026-09-28T11:30:00'),
              itemJson(62, '2026-09-28T11:45:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ),
        );
      }
      return http.Response('nope', 404);
    });

    await engineFor(api, now: DateTime.parse('2026-09-28T11:20:00')).tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    final state = await CarouselStateStore(directory: dir).read();
    expect(
      state.timelineEntries.map((entry) => entry.itemId).toList(),
      [60, 61, 62],
      reason: '已就绪的格子都要进表，并按时间升序',
    );

    final first = state.timelineEntries.first;
    expect(first.dateMs, at('2026-09-28T11:15:00'));
    expect(
      first.portraitPath,
      CarouselPhotoStore.renderedFile(dir, 'portrait', 60).path,
    );
    expect(
      first.squarePath,
      CarouselPhotoStore.renderedFile(dir, 'square', 60).path,
    );
    expect(
      first.originalPath,
      CarouselPhotoStore.originalFile(dir, 60).path,
    );
    expect(first.date, '2026-09-28');
    expect(first.captionZh, '中文60');

    // 无论安卓还是 iOS，到点后问的都是同一个问题。
    expect(
      currentEntryFromTimeline(
        state.timelineEntries,
        at('2026-09-28T11:32:00'),
      )?.itemId,
      61,
    );
    expect(
      currentEntryFromTimeline(
        state.timelineEntries,
        at('2026-09-28T11:10:00'),
      ),
      isNull,
      reason: '列表尚未覆盖此刻时返回 null，由调用方回退到 current 指针',
    );
  });

  test('daily.json 投影与权威状态一致，且不产生第二份真相', () async {
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(planBody(
            planId: 204,
            items: [
              itemJson(40, '2026-09-28T11:15:00'),
              itemJson(41, '2026-09-28T11:30:00'),
            ],
            nextCheckAt: '2026-09-28T11:30:00',
          ));
      }
      return http.Response('nope', 404);
    });

    await engineFor(api, now: DateTime.parse('2026-09-28T11:20:00')).tick(
      credentials: credentials,
      settings: settings,
      writer: 'test',
    );

    final state = await CarouselStateStore(directory: dir).read();
    final projection =
        jsonDecode(File('${dir.path}/daily.json').readAsStringSync())
            as Map<String, dynamic>;

    expect(projection['recommendation_id'], state.currentItemId);
    expect(
      projection['next_slot_at_ms'],
      state.nextSlotAtMs,
      reason: '投影与权威状态在同一次提交内写入，必须一致',
    );
    expect(projection['next_slot_source'], state.nextSlotSource.wire);
    expect(projection['carousel_plan_id'], state.plan!.planId);
  });
  test('预取稳态：首轮把当前格加整个预取窗口一次取满，之后每轮只新增一张，历史始终只有 2 张', () async {
    // 这条回答「缓存上限为什么是当前 + 未来一整个窗口、而不是 2」。
    //
    //   * 历史（上一张 + 当前）**始终严格是 2 张**——方案说的「缓存留最近 2 张」
    //     在历史这个维度上是被严格满足的；
    //   * 其余 `kTimelineBakeDepth` 张是**未来**格子的预取，属于方案单独要求的
    //     「提前量」。
    //
    // 首轮没有上一张，必须把当前格与预取窗口一次取满；从第二轮起当前格早已在
    // 缓存里，每轮只新增最远的那一格。
    //
    // **断言一律跟着 `kTimelineBakeDepth` 走，不再写死 4。** 那个数字是策略，
    // 不是不变量；写死过一次，把窗口从 4 调到 8 时这条测试就假报警了。
    const window = kTimelineBakeDepth;
    final base = DateTime.parse('2026-09-28T11:15:00');
    // 多备几格，好让三轮都处在真正的稳态里（最后一轮要用到 times[2 + window]）。
    final times = [
      for (var i = 0; i < window + 4; i++) base.add(Duration(minutes: 15 * i)),
    ];
    String two(int value) => value.toString().padLeft(2, '0');
    String stamp(DateTime t) =>
        '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:00';

    final api = apiWith((request) async {
      if (request.url.path.endsWith('/carousel/plan')) {
        return ok(
          planBody(
            planId: 700,
            items: [
              for (var i = 0; i < times.length; i++)
                itemJson(4500 + i, stamp(times[i])),
            ],
            nextCheckAt: stamp(times[1]),
          ),
        );
      }
      return http.Response('nope', 404);
    });

    var now = times[0];
    final store = _FakePhotoStore(api: api);
    final engine = CarouselEngine(
      api: api,
      clock: () => now,
      photoStore: store,
    );
    final stateStore = CarouselStateStore(directory: dir);

    Future<({int downloads, int cached, int? current, int? previous})>
    tick() async {
      final before = store.prepared.length;
      await engine.tick(
        credentials: credentials,
        settings: settings,
        writer: 'test',
      );
      final state = await stateStore.read();
      return (
        downloads: store.prepared.length - before,
        cached: state.photos.length,
        current: state.currentItemId,
        previous: state.previousItemId,
      );
    }

    // ---- 第 1 轮：没有上一张，当前格 + 整个预取窗口一次取满 ----
    final first = await tick();
    expect(
      first.downloads,
      1 + window,
      reason: '首轮 = 当前 1 张 + 预取 $window 张',
    );
    expect(first.cached, 1 + window);
    expect(first.previous, isNull);

    // ---- 第 2 轮：当前格是上轮预取到的，不重复下载 ----
    now = times[1];
    final second = await tick();
    expect(second.downloads, 1, reason: '只新增最远的那一格');
    expect(second.cached, 2 + window, reason: '上一张 + 当前 + 未来 $window 格');
    expect(second.current, 4501);
    expect(second.previous, 4500);

    // ---- 第 3 轮：进入稳态 ----
    now = times[2];
    final third = await tick();
    expect(third.downloads, 1, reason: '稳态下每轮仍然只新增一张');
    expect(third.cached, 2 + window, reason: '稳态缓存不随轮次增长');

    // ---- 历史严格只有 2 张 ----
    final ids = (await stateStore.read()).photos
        .map((photo) => photo.itemId)
        .toList()
      ..sort();
    // 稳态池 = 上一张(4501) + 当前(4502) + 未来 window 格，即 4501..(4500+2+window)。
    expect(ids, [for (var i = 1; i <= 2 + window; i++) 4500 + i]);
    expect(
      ids,
      isNot(contains(4500)),
      reason: '比「上一张」更早的照片必须已被删除——历史就是 2 张',
    );
  });

}
