/// 状态存储的单元测试：单一状态、单一写者、新者胜。
library;

import 'dart:io';

import 'package:bloom/core/carousel/carousel_state.dart';
import 'package:bloom/core/carousel/state_store.dart';
import 'package:flutter_test/flutter_test.dart';

PlanIdentity _plan(int id) =>
    PlanIdentity(planId: id, settingsHash: 'h$id', day: '2026-09-28');

void main() {
  late Directory dir;
  late CarouselStateStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bloom-state-store');
    store = CarouselStateStore(directory: dir);
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('目录为空时读取返回空状态，不抛异常', () async {
    final state = await store.read();
    expect(state.plan, isNull);
    expect(state.revision, 0);
    expect(state.grid, isEmpty);
  });

  test('损坏的状态文件被当作空状态而不是崩溃', () async {
    await store.stateFile.writeAsString('{ this is not json');
    final state = await store.read();
    expect(state.plan, isNull);
    expect(state.revision, 0);
  });

  test('提交后 revision 递增，且能原样读回', () async {
    final first = await store.mutate(
      writer: 'test',
      incomingPlan: _plan(151),
      update: (current) => current.copyWith(
        plan: _plan(151),
        grid: const [Slot(slotAtMs: 1000, itemId: 7, assetId: 'a7')],
        currentItemId: 7,
        nextSlotAtMs: 2000,
      ),
    );
    expect(first, isNotNull);
    expect(first!.revision, 1);
    expect(first.writer, 'test');

    final second = await store.mutate(
      writer: 'test',
      incomingPlan: _plan(151),
      update: (current) => current.copyWith(nextSlotAtMs: 3000),
    );
    expect(second!.revision, 2);

    final reloaded = await store.read();
    expect(reloaded.revision, 2);
    expect(reloaded.nextSlotAtMs, 3000);
    expect(reloaded.currentItemId, 7);
    expect(reloaded.grid.single.itemId, 7);
  });

  test('锁被占用时写入直接放弃，不阻塞也不覆盖', () async {
    // 模拟另一个写者正持有锁。
    await store.lockFile.writeAsString('${DateTime.now().millisecondsSinceEpoch}');

    final result = await store.mutate(
      writer: 'test',
      incomingPlan: _plan(151),
      update: (current) => current.copyWith(nextSlotAtMs: 2000),
    );

    expect(result, isNull, reason: '拿不到锁必须放弃，而不是等待或强写');
    expect((await store.read()).nextSlotAtMs, isNull);
  });

  test('残留锁过期后可以被夺回，不会永久卡死', () async {
    await store.lockFile.writeAsString('0');
    // 把修改时间改到很久以前，模拟进程被杀留下的残留锁。
    final old = DateTime.now().subtract(const Duration(minutes: 10));
    await store.lockFile.setLastModified(old);

    final result = await store.mutate(
      writer: 'test',
      incomingPlan: _plan(151),
      update: (current) => current.copyWith(nextSlotAtMs: 2000),
    );

    expect(result, isNotNull);
    expect(result!.nextSlotAtMs, 2000);
  });

  test('新者胜：己方计划更旧时拒绝写入', () async {
    await store.mutate(
      writer: 'ios',
      incomingPlan: _plan(152),
      update: (current) => current.copyWith(plan: _plan(152), nextSlotAtMs: 9000),
    );

    final stale = await store.mutate(
      writer: 'android',
      incomingPlan: _plan(151),
      update: (current) => current.copyWith(plan: _plan(151), nextSlotAtMs: 1000),
    );

    expect(stale, isNull, reason: '旧计划不得覆盖新计划');
    final reloaded = await store.read();
    expect(reloaded.plan!.planId, 152);
    expect(reloaded.nextSlotAtMs, 9000, reason: '小组件刚取回的结果必须保住');
  });

  test('新者胜：同计划下 revision 更大者胜出', () async {
    await store.mutate(
      writer: 'ios',
      incomingPlan: _plan(151),
      update: (current) => current.copyWith(plan: _plan(151), nextSlotAtMs: 1000),
    );
    final next = await store.mutate(
      writer: 'android',
      incomingPlan: _plan(151),
      update: (current) => current.copyWith(nextSlotAtMs: 2000),
    );
    expect(next, isNotNull);
    expect(next!.revision, 2);
    expect(next.nextSlotAtMs, 2000);
  });

  test('deletePhotos 真正删除文件，且容忍文件已不存在', () async {
    final present = File('${dir.path}/gone.png')..writeAsBytesSync([1, 2, 3]);
    final missing = File('${dir.path}/never.png');

    await store.deletePhotos([
      PhotoEntry(
        itemId: 1,
        assetId: 'a',
        path: present.path,
        fetchedAtMs: 0,
      ),
      PhotoEntry(
        itemId: 2,
        assetId: 'b',
        path: missing.path,
        fetchedAtMs: 0,
      ),
    ]);

    expect(present.existsSync(), isFalse);
  });

  test('onCommitted 在锁内执行，能观察到已落盘的状态', () async {
    CarouselState? seen;
    await store.mutate(
      writer: 'test',
      incomingPlan: _plan(151),
      update: (current) => current.copyWith(plan: _plan(151), nextSlotAtMs: 5000),
      onCommitted: (committed) async {
        seen = committed;
        // 回调执行时权威状态必须已经落盘，派生投影才能与之一致。
        expect((await store.read()).nextSlotAtMs, committed.nextSlotAtMs);
      },
    );
    expect(seen, isNotNull);
    expect(seen!.nextSlotAtMs, 5000);
  });

  test('序列化后的键名与两端读取方的约定一致', () {
    // Dart 写入 `carousel-state.json`，iOS 与安卓读它。键名一旦漂移，两端都
    // **不会报错**——只是静默读不到计划，表现为小组件不再更新。Swift 侧的
    // 对应断言在 tools/run_swift_vectors.sh 里，两边一起钉住这份契约。
    final state = CarouselState(
      plan: const PlanIdentity(
        planId: 152,
        settingsHash: 'h',
        day: '2026-09-28',
      ),
      grid: const [Slot(slotAtMs: 1000, itemId: 4481, assetId: 'asset-4481')],
      nextSlotAtMs: 1790567100000,
      currentItemId: 4481,
      currentSlotAtMs: 1790566800000,
      status: CurrentStatus.ok,
      nextSlotSource: NextSlotSource.plan,
      timelineEntries: const [
        TimelineEntry(
          dateMs: 1790566800000,
          itemId: 4481,
          portraitPath: '/tmp/mobile-local-portrait-4481.png',
          squarePath: '/tmp/mobile-local-square-4481.png',
          largeSquarePath: '/tmp/mobile-local-largeSquare-4481.png',
          originalPath: '/tmp/carousel-original-4481.photo',
          date: '2026-09-28',
          captionZh: '中文',
        ),
      ],
    );

    final json = state.toJson();
    expect(json['next_slot_at_ms'], 1790567100000);
    expect(json['current_item_id'], 4481);
    expect(json['current_status'], 'ok');
    expect(json['next_slot_source'], 'plan');
    expect((json['plan']! as Map)['plan_id'], 152);

    final entry = (json['timeline_entries']! as List).single as Map;
    expect(
      entry.keys.toSet(),
      {
        'date_ms',
        'item_id',
        'portrait_path',
        'square_path',
        'large_square_path',
        'original_path',
        'date',
        'caption_zh',
        'caption_en',
        'captured_date_text',
        'location_text',
      },
      reason: 'IOS 的 BloomSharedState.planItems 逐个按这些键名取值',
    );

    final slot = (json['grid']! as List).single as Map;
    expect(slot.keys.toSet(), {'slot_at_ms', 'item_id', 'asset_id'});

    // 回环：写出去再读回来必须完全等价，否则重启后状态会静默退化。
    final restored = CarouselState.fromJson(json);
    expect(restored.plan, state.plan);
    expect(restored.grid.single.itemId, 4481);
    expect(restored.nextSlotAtMs, 1790567100000);
    expect(restored.status, CurrentStatus.ok);
    expect(restored.timelineEntries.single.originalPath, entry['original_path']);
    expect(restored.timelineEntries.single.captionZh, '中文');
  });
}
