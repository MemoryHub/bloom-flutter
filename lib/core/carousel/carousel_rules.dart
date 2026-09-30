/// 轮播核心规则：全部为纯函数，无 I/O，可脱离设备与网络单测。
///
/// 本文件是 iOS 与安卓共用的算法定义。任何一侧的实现若与这里的语义不符，
/// 即为缺陷——两端一致性由共享测试向量（test/vectors/carousel_vectors.json）
/// 保证。
library;

import 'carousel_state.dart';

/// 「下次更新」的解。
class NextSlotResolution {
  const NextSlotResolution({required this.atMs, required this.usedFallback});

  /// 绝对时间（UTC 纪元毫秒）。
  final int atMs;

  /// 是否用到「明天第一格」兜底（即当天栅格已用尽）。
  final bool usedFallback;
}

/// 下一格：`grid` 中**严格晚于** `nowMs` 的最小值。
///
/// 严格大于而非大于等于：恰好落在某格时间时，该格已经是在显示的那一张，
/// 下一个要更新的时刻是再下一格。
///
/// 返回 null 表示当天栅格已用尽——调用方必须用服务端给出的明天第一格兜底，
/// 绝不允许把 null 当作最终结果写进状态（这正是历史上「文案整段不显示」的成因）。
int? nextSlotAfter(Iterable<int> gridMs, int nowMs) {
  int? best;
  for (final at in gridMs) {
    if (at <= nowMs) continue;
    if (best == null || at < best) best = at;
  }
  return best;
}

/// 在栅格用尽时用服务端给出的明天第一格兜底，得到最终的「下次更新」。
///
/// [tomorrowFirstMs] 来自服务端：当天没有未来格时，服务端返回的
/// `next_check_at` 就是明天第一格。若连它也为空（例如首启且计划极短），
/// 返回 null，界面自行决定不显示。
NextSlotResolution? resolveNextSlot({
  required Iterable<int> gridMs,
  required int nowMs,
  int? tomorrowFirstMs,
}) {
  final direct = nextSlotAfter(gridMs, nowMs);
  if (direct != null) {
    return NextSlotResolution(atMs: direct, usedFallback: false);
  }
  if (tomorrowFirstMs == null) return null;
  // 服务端给的兜底值若也不在未来，则视为不可用——不显示错误的时间。
  if (tomorrowFirstMs <= nowMs) return null;
  return NextSlotResolution(atMs: tomorrowFirstMs, usedFallback: true);
}

/// 此刻所在的格子：`grid` 中**不晚于** `nowMs` 的最后一个。
///
/// 栅格为空或全部在未来时返回 null。
Slot? currentSlot(Iterable<Slot> grid, int nowMs) {
  Slot? best;
  for (final slot in grid) {
    if (slot.slotAtMs > nowMs) continue;
    if (best == null || slot.slotAtMs > best.slotAtMs) best = slot;
  }
  return best;
}

/// 是否需要换代：计划身份任一组成变化即为换代。
bool isNewGeneration(PlanIdentity? current, PlanIdentity? incoming) {
  if (incoming == null) return false;
  if (current == null) return true;
  return current != incoming;
}

/// 「新者胜」判定：本次写入是否应当被接受。
///
/// 规则：
///   * 现有状态没有计划时接受；
///   * 计划标识相同时比较 revision，较大者胜；
///   * 计划标识不同时比较 planId，较大者胜（plan id 由数据库自增，越大越新）。
///
/// 这条规则专门用于根治「App 把小组件刚取回的结果覆盖回去」。
bool shouldAcceptWrite({
  required CarouselState existing,
  required PlanIdentity? incomingPlan,
  required int incomingRevision,
}) {
  final current = existing.plan;
  if (current == null) return true;
  if (incomingPlan == null) {
    // 手上没有计划身份时，只允许在没有既有计划的情况下写入。
    return false;
  }
  if (incomingPlan.planId != current.planId) {
    return incomingPlan.planId > current.planId;
  }
  return incomingRevision > existing.revision;
}

/// 计划换代时的照片保留：只保留与新栅格 item_id 重合的部分。
///
/// 换代的常见原因是设置微调，新旧栅格往往大面积重合；全清会造成不必要的
/// 重复下载，因此按交集保留。
List<PhotoEntry> retainAcrossGeneration({
  required Iterable<PhotoEntry> photos,
  required Iterable<Slot> newGrid,
}) {
  final keep = <int>{for (final slot in newGrid) slot.itemId};
  return [
    for (final photo in photos)
      if (keep.contains(photo.itemId)) photo,
  ];
}

/// 常态缓存保留：只留「上一张」「当前」与「已预取的后续若干张」，其余删除。
///
/// 上一张的用途是当前格照片缺失时继续显示，同时作为回滚兜底。
///
/// **预取的那几张必须一起保留**：提前量的作用就是在格子到来之前把它们取到
/// 本地，若保留规则只认「当前 + 上一张」，刚预取到的会被立刻删掉，提前量
/// 就白做了。上限 = 预取深度 + 2，仍然有界。
///
/// 预取深度之所以大于 1：iOS 的 WidgetKit 对扩展唤醒有每日预算（约
/// 40～70 次）。若只提前烘一格，15 分钟间隔在 16 小时窗口内需要约 65 次
/// 唤醒，正好撞上预算上限，表现为更新被系统降频。一次烘若干格可把唤醒次数
/// 降到十几分之一。
List<PhotoEntry> retainRecentPhotos({
  required Iterable<PhotoEntry> photos,
  required int? currentItemId,
  required int? previousItemId,
  Iterable<int> nextItemIds = const [],
}) {
  final keep = <int>{
    if (previousItemId != null) previousItemId,
    if (currentItemId != null) currentItemId,
    ...nextItemIds,
  };
  return [
    for (final photo in photos)
      if (keep.contains(photo.itemId)) photo,
  ];
}

/// 缓存保留的三种情形。
enum RetentionMode {
  /// 常态切换后：只留上一张、当前与已预取的后续若干张。
  normal,

  /// 计划换代：按 item_id 与新栅格求交集。
  generation,

  /// 跨天：清空。
  newDay,
}

/// 缓存保留的统一入口，三种情形共用一条实现，避免两端各写一套。
List<PhotoEntry> retainPhotos({
  required RetentionMode mode,
  required Iterable<PhotoEntry> photos,
  int? currentItemId,
  int? previousItemId,
  Iterable<int> nextItemIds = const [],
  Iterable<Slot> newGrid = const [],
}) {
  switch (mode) {
    case RetentionMode.normal:
      return retainRecentPhotos(
        photos: photos,
        currentItemId: currentItemId,
        previousItemId: previousItemId,
        nextItemIds: nextItemIds,
      );
    case RetentionMode.generation:
      return retainAcrossGeneration(photos: photos, newGrid: newGrid);
    case RetentionMode.newDay:
      return const [];
  }
}

/// 时间线的烘焙深度：一次向前准备多少格。
///
/// 它限制的是**照片预取与时间线烘焙的深度**（计划本身永远是全天全量），
/// 与旧实现的 `batch_limit = 4` 不是一回事：后者限制的是**计划元数据的分页
/// 大小**，那是相框固件的照片缓存深度，被误用到了接口上。
///
/// **这个数字直接决定冷启动、以及每次补货要下多少张。** 它同时也是"App 不在
/// 跑时小组件还能自己走多久"，但那个方向的收益**远远不及**它的代价：
///
/// 2026-09-29 真机实测（小米 14，晚高峰）：单张照片下载 **6–24 秒**
/// （1.2–3.7 MB，约 100–130 KB/s）。曾把它调到 8，想给 iOS 多留一点余量，
/// 结果冷启动从"下 4 张"变成"下 8 张"，预取把带宽占满、当前格的照片反而排在
/// 队尾并超时（实测 3 次 `reason=timeout`）——用户看到的就是
/// **"第一次打开 App 照片非常慢才出来"**。
///
/// iOS"池子用完就冻住"的根因是**根本没有后台补货路径**，已经由
/// `BGAppRefreshTask`（见 `background_sync.dart`）修掉；那才是正解，不需要靠
/// 加深窗口来兜。真要把窗口调大，前提是先让单张下载回到秒级。
const int kTimelineBakeDepth = 4;

/// 取栅格中接下来的 [depth] 个格子（严格晚于 [nowMs]）。
List<Slot> upcomingSlots(Iterable<Slot> grid, int nowMs, {int depth = kTimelineBakeDepth}) {
  final future = [
    for (final slot in grid)
      if (slot.slotAtMs > nowMs) slot,
  ]..sort((a, b) => a.slotAtMs.compareTo(b.slotAtMs));
  if (future.length <= depth) return future;
  return future.sublist(0, depth);
}

/// 从缓存中按 item_id 取照片。
PhotoEntry? photoFor(Iterable<PhotoEntry> photos, int? itemId) {
  if (itemId == null) return null;
  for (final photo in photos) {
    if (photo.itemId == itemId) return photo;
  }
  return null;
}

/// iOS 专用：由烘焙好的条目列表推算「此刻屏幕上是谁」。
///
/// 扩展在条目展示时不会被唤醒，因此不能用扩展回写的 current 指针判断此刻
/// 画面——该指针在两次唤醒之间必然滞后。正确做法是取列表中**日期不晚于
/// 当前时间**的最后一条。
///
/// 返回 null 表示列表尚未覆盖此刻，调用方应回退到 current 指针。
TimelineEntry? currentEntryFromTimeline(
  Iterable<TimelineEntry> entries,
  int nowMs,
) {
  TimelineEntry? best;
  for (final entry in entries) {
    if (entry.dateMs > nowMs) continue;
    if (best == null || entry.dateMs > best.dateMs) best = entry;
  }
  return best;
}

/// 失败归类：把一次取数结果映射为状态取值。
///
/// * [planFetched] 为假 —— 手机没网或服务端不可达，归类为 offline；
/// * [planFetched] 为真但照片不可得 —— 归类为 download_failed；
/// * 照片可用 —— 归类为 ok。
CurrentStatus classifyStatus({
  required bool planFetched,
  required bool photoAvailable,
}) {
  if (!planFetched) return CurrentStatus.offline;
  return photoAvailable ? CurrentStatus.ok : CurrentStatus.downloadFailed;
}

/// 提前量：min(5 分钟, 间隔 ÷ 3)。
Duration leadDuration(int intervalMinutes) {
  final step = intervalMinutes > 0 ? intervalMinutes : 15;
  final minutes = step ~/ 3;
  return Duration(minutes: minutes < 5 ? minutes : 5);
}

/// 后续格试探上限：min(2 × 间隔, 15 分钟)。
///
/// 单说「往后两个间隔」在大间隔设置下会失控——间隔为 1440 分钟时两个间隔
/// 等于两天。因此必须同时按绝对时间封顶。
Duration probeBudget(int intervalMinutes) {
  final step = intervalMinutes > 0 ? intervalMinutes : 15;
  final byInterval = step * 2;
  return Duration(minutes: byInterval < 15 ? byInterval : 15);
}
