/// 「下次更新」的读取：以状态里的栅格为准，缓存字段只兜底。
///
/// 这里钉住一个**只在真机上暴露过的空窗**：格子刚到达、下一轮 tick 还没跑完时，
/// `daily.json` 里的 `next_slot_at_ms` 指向的已经是过去。界面有一道「不显示过去
/// 时间」的兜底，于是整段文案消失。实测空白约 50 秒（安卓，进程被系统杀掉后用户
/// 手动打开 App）。
///
/// 方案原文那条规则是「已取回计划中晚于此刻的第一格」——整天栅格就在状态文件
/// 里，所以这个值不需要等网络，也不该有空窗。
library;

import 'dart:convert';
import 'dart:io';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/storage/daily_content_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  const channel = MethodChannel('com.bloom/widget');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bloom-nextslot');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'cacheDirectory') return dir.path;
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// 写一份权威状态，栅格为 [slotMs] 这些时刻。
  Future<void> writeState(List<int> slotMs) async {
    await File('${dir.path}/carousel-state.json').writeAsString(
      jsonEncode({
        'plan': {
          'plan_id': 150,
          'settings_hash': 'h1',
          'day': '2026-09-28',
        },
        'grid': [
          for (var i = 0; i < slotMs.length; i++)
            {'slot_at_ms': slotMs[i], 'item_id': 5000 + i, 'asset_id': 'a$i'},
        ],
        'revision': 3,
        'writer': 'test',
      }),
    );
  }

  /// 写一份 `daily.json` 投影，只带 `next_slot_at_ms`。
  Future<void> writeProjection(int? nextSlotAtMs) async {
    await File('${dir.path}/daily.json').writeAsString(
      jsonEncode({'next_slot_at_ms': nextSlotAtMs}),
    );
  }

  int minutesFromNow(int minutes) => DateTime.now()
      .add(Duration(minutes: minutes))
      .millisecondsSinceEpoch;

  Future<int?> read() =>
      DailyContentRepository(api: BloomApiClient()).nextSlotAtMillis();

  test('回归：缓存值已过去时，必须由栅格给出未来那一格', () async {
    // 这正是真机上出现空窗的现场：整点刚过，投影还停在整点。
    final past = minutesFromNow(-2);
    final next = minutesFromNow(13);
    await writeState([minutesFromNow(-2), next, minutesFromNow(28)]);
    await writeProjection(past);

    final at = await read();

    expect(at, isNotNull, reason: '文案不能因为缓存值过期就整段消失');
    expect(
      at,
      next,
      reason: '应取栅格中晚于此刻的第一格，而不是已过去的缓存值',
    );
  });

  test('既有未来栅格时，缓存值再新也不采用', () async {
    final gridNext = minutesFromNow(13);
    await writeState([gridNext]);
    // 缓存值指向更远、也在未来——仍应以栅格为准，两端才不会显示不同时间。
    await writeProjection(minutesFromNow(58));

    expect(await read(), gridNext);
  });

  test('当天栅格用尽：回退到缓存里的明天第一格', () async {
    final tomorrow = minutesFromNow(600);
    await writeState([minutesFromNow(-30), minutesFromNow(-15)]);
    await writeProjection(tomorrow);

    expect(await read(), tomorrow);
  });

  test('栅格用尽且缓存值也已过去：返回 null，不显示过去的时间', () async {
    await writeState([minutesFromNow(-30), minutesFromNow(-15)]);
    await writeProjection(minutesFromNow(-1));

    expect(await read(), isNull);
  });

  test('状态文件缺失（旧版本残留）：退回 daily.json 的行为不变', () async {
    final cached = minutesFromNow(20);
    await writeProjection(cached);

    expect(await read(), cached);
  });

  test('两份文件都没有：返回 null 而不是抛错', () async {
    expect(await read(), isNull);
  });
}
