/// 全天计划拉取。
///
/// 与旧实现的根本区别：**一次性取回整天的计划栅格**，不再用 4 条的批次窗口
/// 去推导「下一格」。4 条是相框计划元数据的批次大小；相框只预存一张未来照片。
///
/// **服务端不必先升级，但也不能假设它宽容。** 曾经这里写着「尚未放开的服务端
/// 会按自己的上限返回并置 has_more」——那是错的：旧服务端把 `batch_limit`
/// 校验成 1..4，超限**直接 422 拒绝**。照那个假设，新客户端配旧服务端会一张
/// 计划都拿不到，比改动前更糟。
///
/// 所以这里带一次降级：请求被拒就退回 4，再用游标把整天翻完（96 格约 24 次
/// 请求，仍在页数上限内）。无论服务端是否已放开上限，都能拿到完整栅格。
library;

import 'package:flutter/foundation.dart';

import '../api/bloom_api_client.dart';
import '../models/device_models.dart';
import '../storage/display_preferences.dart';
import 'carousel_state.dart';

/// 一次拉取的完整结果。
class FullPlan {
  const FullPlan({
    required this.identity,
    required this.grid,
    required this.serverNextCheckMs,
    required this.currentItemId,
    this.contentById = const {},
    this.requestCount = 1,
  });

  final PlanIdentity identity;

  /// 当天栅格，按时间升序。起点是服务端判定的「当前格」。
  final List<Slot> grid;

  /// 服务端给出的下一格时间。
  ///
  /// 它的语义是「完整计划中第一个未来格」；当天栅格用尽时，服务端会把它
  /// 滚到明天第一格（`_next_carousel_check` / `next_slot_after`）。因此它同时
  /// 是「栅格用尽时的兜底」，也是本模块漏页时的安全网。
  final int? serverNextCheckMs;

  final int currentItemId;

  /// item_id → 该格的完整内容（照片描述符与文案）。
  ///
  /// 栅格只保留调度所需的三个字段，文案与照片描述符在这里单独保存，供渲染
  /// 与写入 daily.json 投影使用。
  final Map<int, CarouselItemContent> contentById;

  /// 实际发出的请求次数，用于观测与服务端上限是否已放开。
  final int requestCount;

  CarouselItemContent? contentFor(int? itemId) {
    if (itemId == null) return null;
    return contentById[itemId];
  }
}

class CarouselPlanClient {
  CarouselPlanClient({required this.api});

  final BloomApiClient api;

  /// 单次请求的条目上限。服务端若尚未放开，会**拒绝**（见类注释），
  /// 此时退回 [legacyPageSize] 继续翻页。
  static const int pageSize = 200;

  /// 旧服务端接受的上限。
  ///
  /// 4 是旧计划接口的批次上限，不是照片缓存数量。
  /// 新服务端已把上限放开，但客户端不能假设它一定升过级。
  static const int legacyPageSize = 4;

  /// 循环上限，防止服务端异常时无限翻页。
  ///
  /// 按 [legacyPageSize] 翻也需要 96 / 4 = 24 页，再加上一次被拒的尝试。
  static const int maxPages = 60;

  /// 拉取全天计划。
  ///
  /// 页码起点是服务端判定的当前格，因此返回的栅格天然包含「当前格及其之后
  /// 的全部格子」——这正是计算「下次更新」与预取下一张所需的全部信息。
  Future<FullPlan> fetchFullDay(
    DeviceCredentials credentials,
    BloomDisplaySettings settings, {
    List<int>? cachedItemIds,
  }) async {
    final slots = <int, Slot>{};
    final content = <int, CarouselItemContent>{};
    int? cursor;
    int planId = 0;
    String? settingsHash;
    String? localDate;
    DateTime? nextCheckAt;
    int currentItemId = 0;
    var requests = 0;

    // 本页的条目上限，以及是否已经因被拒而降级过（只降一次）。
    var limit = pageSize;
    var downgraded = false;

    for (var page = 0; page < maxPages; page++) {
      final CarouselPlanEnvelope envelope;
      try {
        envelope = await api.carouselPlan(
          credentials,
          settings,
          batchLimit: limit,
          afterItemId: cursor,
          cachedItemIds: cachedItemIds,
        );
      } on BloomApiException catch (error) {
        // 400/422 = 服务端不认这个上限（旧服务端是 Pydantic 的 le=4）。
        // 降一次级重来即可；游标与循环逻辑完全不用改。
        final rejected = error.statusCode == 400 || error.statusCode == 422;
        if (rejected && !downgraded) {
          limit = legacyPageSize;
          downgraded = true;
          debugPrint(
            '[BloomCarousel] batch_limit=$pageSize 被服务端拒绝，'
            '退回 $legacyPageSize 并按游标翻页',
          );
          continue;
        }
        rethrow;
      }
      requests++;

      planId = envelope.planId;
      settingsHash ??= envelope.settingsHash;
      localDate ??= envelope.localDate;
      nextCheckAt ??= envelope.nextCheckAt;
      if (envelope.currentItemId > 0) currentItemId = envelope.currentItemId;

      if (envelope.items.isEmpty) break;
      for (final item in envelope.items) {
        slots[item.itemId] = Slot(
          slotAtMs: item.displayAt.toLocal().millisecondsSinceEpoch,
          itemId: item.itemId,
          assetId: item.assetId,
        );
        content[item.itemId] = item;
      }

      if (!envelope.hasMore) break;
      final lastItemId = envelope.items.last.itemId;
      // 游标未前进说明服务端不再返回新内容，停止以免空转。
      if (cursor != null && lastItemId <= cursor) break;
      cursor = lastItemId;
    }

    final grid =
        slots.values.toList()..sort((a, b) => a.slotAtMs.compareTo(b.slotAtMs));

    return FullPlan(
      identity: PlanIdentity(
        planId: planId,
        settingsHash: settingsHash ?? '',
        day: localDate ?? _dayKey(DateTime.now()),
      ),
      grid: grid,
      serverNextCheckMs: nextCheckAt?.toLocal().millisecondsSinceEpoch,
      currentItemId: currentItemId,
      contentById: content,
      requestCount: requests,
    );
  }

  static String _dayKey(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}
