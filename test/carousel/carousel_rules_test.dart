/// 共享测试向量的 Dart 侧执行器。
///
/// 本文件读取 test/vectors/carousel_vectors.json —— 与 iOS Swift 侧读取的是
/// **同一份文件**。任何一条用例在任一侧失败，即表示两端行为已经漂移。
///
/// 这些用例覆盖的正是历史上反复回归的场景：栅格用尽必须落明天第一格
/// （而不是空值，那是「文案整段不显示」的成因）、写入冲突必须新者胜
/// （那是「App 覆盖小组件」的成因）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:bloom/core/carousel/carousel_rules.dart';
import 'package:bloom/core/carousel/carousel_state.dart';
import 'package:flutter_test/flutter_test.dart';

const _vectorPath = 'test/vectors/carousel_vectors.json';

Map<String, Object?> _loadVectors() {
  final file = File(_vectorPath);
  if (!file.existsSync()) {
    fail('共享测试向量文件不存在: ${file.absolute.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

PlanIdentity? _plan(Object? raw) => PlanIdentity.fromJson(raw);

int? _intOrNull(Object? raw) => (raw as num?)?.toInt();

List<int> _intList(Object? raw) =>
    [for (final value in (raw as List? ?? const [])) (value as num).toInt()];

void main() {
  final vectors = _loadVectors();
  final groups = (vectors['groups'] as List).cast<Map<String, Object?>>();

  for (final groupSpec in groups) {
    final rule = groupSpec['rule'] as String;
    final cases = (groupSpec['cases'] as List).cast<Map<String, Object?>>();

    group('共享向量 · $rule', () {
      for (final testCase in cases) {
        final description = testCase['description'] as String;
        final input = (testCase['input'] as Map).cast<String, Object?>();
        final expected = (testCase['expected'] as Map).cast<String, Object?>();

        test(description, () {
          _assertRule(rule, input, expected);
        });
      }
    });
  }
}

void _assertRule(
  String rule,
  Map<String, Object?> input,
  Map<String, Object?> expected,
) {
  switch (rule) {
    case 'next_slot_after_now':
      final resolution = resolveNextSlot(
        gridMs: _intList(input['grid_ms']),
        nowMs: (input['now_ms'] as num).toInt(),
        tomorrowFirstMs: _intOrNull(input['tomorrow_first_ms']),
      );
      expect(resolution?.atMs, _intOrNull(expected['next_slot_at_ms']));
      expect(resolution?.usedFallback ?? false, expected['used_fallback']);

    case 'current_slot_from_grid':
      final slot = currentSlot(
        [
          for (final at in _intList(input['grid_ms']))
            Slot(slotAtMs: at, itemId: at, assetId: 'a$at'),
        ],
        (input['now_ms'] as num).toInt(),
      );
      expect(slot?.slotAtMs, _intOrNull(expected['current_slot_at_ms']));

    case 'plan_generation':
      expect(
        isNewGeneration(_plan(input['current']), _plan(input['incoming'])),
        expected['is_new_generation'],
      );

    case 'cache_retention':
      final photos = [
        for (final id in _intList(input['photos']))
          PhotoEntry(
            itemId: id,
            assetId: 'a$id',
            path: '/tmp/$id',
            fetchedAtMs: id,
          ),
      ];
      final mode = switch (input['mode'] as String) {
        'generation' => RetentionMode.generation,
        'new_day' => RetentionMode.newDay,
        _ => RetentionMode.normal,
      };
      final kept = retainPhotos(
        mode: mode,
        photos: photos,
        currentItemId: _intOrNull(input['current_item_id']),
        previousItemId: _intOrNull(input['previous_item_id']),
        nextItemIds: _intList(input['next_item_ids']),
        newGrid: [
          for (final id in _intList(input['new_grid_item_ids']))
            Slot(slotAtMs: id, itemId: id, assetId: 'a$id'),
        ],
      );
      expect(
        (kept.map((photo) => photo.itemId).toList()..sort()),
        (_intList(expected['kept_item_ids'])..sort()),
      );

    case 'failure_classification':
      expect(
        classifyStatus(
          planFetched: input['plan_fetched'] as bool,
          photoAvailable: input['photo_available'] as bool,
        ).wire,
        expected['current_status'],
      );

    case 'newer_wins':
      final existingRaw = input['existing'];
      final existing = existingRaw == null
          ? CarouselState.empty
          : CarouselState(
              plan: PlanIdentity(
                planId: ((existingRaw as Map)['plan_id'] as num).toInt(),
                settingsHash: 'h',
                day: '2026-09-28',
              ),
              revision: (existingRaw['revision'] as num).toInt(),
            );
      final incomingPlanId = _intOrNull(input['incoming_plan_id']);
      expect(
        shouldAcceptWrite(
          existing: existing,
          incomingPlan: incomingPlanId == null
              ? null
              : PlanIdentity(
                  planId: incomingPlanId,
                  settingsHash: 'h',
                  day: '2026-09-28',
                ),
          incomingRevision: (input['incoming_revision'] as num).toInt(),
        ),
        expected['accept'],
      );

    case 'current_from_entries':
      final entry = currentEntryFromTimeline(
        [
          for (final raw in (input['entries'] as List))
            TimelineEntry(
              dateMs: ((raw as Map)['date_ms'] as num).toInt(),
              itemId: (raw['item_id'] as num).toInt(),
            ),
        ],
        (input['now_ms'] as num).toInt(),
      );
      expect(entry?.itemId, _intOrNull(expected['item_id']));

    case 'lead_and_probe':
      final interval = (input['interval_minutes'] as num).toInt();
      expect(leadDuration(interval).inMinutes, expected['lead_minutes']);
      expect(probeBudget(interval).inMinutes, expected['probe_minutes']);

    default:
      fail('共享向量中出现了未知规则: $rule');
  }
}
