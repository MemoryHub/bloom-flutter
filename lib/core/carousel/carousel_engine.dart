/// 轮播 tick 引擎：方案第四章「每格 tick 的执行步骤」的落地。
///
/// 固定次序：
///   ① 对表  —— 拉取全天计划（仅元数据）
///   ② 算文案 —— 计划栅格中晚于此刻的第一格，立刻更新
///   ③ 备照片 —— 当前格与后续若干格的照片，缺则下载；失败则要替补
///   ④ 提交  —— 单一写者 + 新者胜，写派生投影并通知对端
///   ⑤ 清理  —— 只留上一张、当前与已预取的后续若干张
///
/// 不做的事（刻意的）：不本地顺延时间、不把后续计划前移、不跳过格子。
/// 栅格永远不动，失败只替换同一格。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/widget_bridge.dart';
import '../api/bloom_api_client.dart';
import '../models/device_models.dart';
import '../storage/display_preferences.dart';
import 'carousel_rules.dart';
import 'carousel_state.dart';
import 'photo_store.dart';
import 'plan_client.dart';
import 'state_store.dart';

/// 一次 tick 的结局，用于日志与上层判断。
class CarouselTickOutcome {
  const CarouselTickOutcome({
    required this.planFetched,
    required this.committed,
    required this.status,
    required this.nextSlotSource,
    this.nextSlotAtMs,
    this.currentItemId,
    this.prepared = 0,
    this.unavailable = 0,
    this.generationChanged = false,
    this.note,
  });

  /// 是否成功取回计划（false 表示没网或服务端不可达）。
  final bool planFetched;

  /// 状态是否真的被写回（false 表示没抢到锁或判定己方更旧）。
  final bool committed;

  final CurrentStatus status;
  final NextSlotSource nextSlotSource;
  final int? nextSlotAtMs;
  final int? currentItemId;

  /// 本次新取回并渲染好的照片张数。
  final int prepared;

  /// 本次判定为取不到的格子数。
  final int unavailable;

  /// 本次是否发生了计划换代。
  final bool generationChanged;

  final String? note;

  @override
  String toString() =>
      'CarouselTickOutcome(plan=$planFetched committed=$committed '
      'status=${status.wire} next=$nextSlotAtMs '
      'source=${nextSlotSource.wire} prepared=$prepared '
      'unavailable=$unavailable generation=$generationChanged'
      '${note == null ? '' : ' note=$note'})';
}

class CarouselEngine {
  CarouselEngine({
    required this.api,
    WidgetBridge? bridge,
    DateTime Function()? clock,
    CarouselPlanClient? planClient,
    CarouselPhotoStore? photoStore,
  }) : bridge = bridge ?? WidgetBridge(),
       _clock = clock ?? DateTime.now,
       _planClient = planClient ?? CarouselPlanClient(api: api),
       _photoStore = photoStore ?? CarouselPhotoStore(api: api);

  final BloomApiClient api;
  final WidgetBridge bridge;
  final DateTime Function() _clock;

  final CarouselPlanClient _planClient;
  final CarouselPhotoStore _photoStore;

  /// 共享目录：安卓为应用私有目录，iOS 为 App Group 容器。
  Future<Directory> sharedDirectory() async {
    final path = await bridge.cacheDirectory();
    if (path == null) throw StateError('widget cache directory is unavailable');
    final dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 执行一次 tick。
  Future<CarouselTickOutcome> tick({
    required DeviceCredentials credentials,
    required BloomDisplaySettings settings,
    required String writer,
  }) async {
    final dir = await sharedDirectory();
    final store = CarouselStateStore(directory: dir);
    final before = await store.read();
    final nowMs = _clock().millisecondsSinceEpoch;

    // ---- ① 对表 ----
    FullPlan? plan;
    String? planError;
    try {
      plan = await _planClient.fetchFullDay(credentials, settings);
    } catch (error) {
      planError = error.toString();
      debugPrint('[BloomCarousel] plan fetch failed: $error');
    }
    final planFetched = plan != null;

    // ---- ② 栅格与文案 ----
    final grid = plan?.grid ?? before.grid;
    final source = planFetched ? NextSlotSource.plan : NextSlotSource.cached;
    final generationChanged =
        plan != null && isNewGeneration(before.plan, plan.identity);
    final resolution = resolveNextSlot(
      gridMs: [for (final slot in grid) slot.slotAtMs],
      nowMs: nowMs,
      tomorrowFirstMs: plan?.serverNextCheckMs ?? before.nextSlotAtMs,
    );

    final slotNow = currentSlot(grid, nowMs);
    final upcoming = upcomingSlots(grid, nowMs);

    // ---- ②b 先落文案，再下照片 ----
    //
    // 文案只依赖计划元数据，取回计划后立刻可算；照片却可能要下载十几秒。
    // 若把文案压到照片之后才提交，用户在这十几秒里看到的是空白标签——这正是
    // 「下次更新」历史上出现得极晚的原因。因此这里先做一次轻量提交，只写
    // 栅格与文案，照片沿用上一轮的状态。
    if (planFetched) {
      try {
        await store.mutate(
          writer: writer,
          incomingPlan: plan.identity,
          update: (current) => current.copyWith(
            plan: plan!.identity,
            grid: grid,
            nextSlotAtMs: resolution?.atMs,
            nextSlotSource: source,
            clearNextSlot: resolution == null,
          ),
        );
        try {
        await bridge.refresh();
        } catch (error) {
          debugPrint('[BloomCarousel] early refresh failed: $error');
        }
      } catch (error) {
        debugPrint('[BloomCarousel] early commit failed: $error');
      }
    }

    // ---- ③ 备照片 ----
    final photos = [...before.photos];
    final attempted = <int>{};
    var prepared = 0;
    var unavailable = 0;

    Future<bool> prepareSlot(Slot slot) async {
      if (photoFor(photos, slot.itemId) != null) return true;
      if (!attempted.add(slot.itemId)) {
        return photoFor(photos, slot.itemId) != null;
      }
      final content = plan?.contentFor(slot.itemId);
      // 离线时拿不到内容描述符，本轮无法取图——这是 offline，不是 download_failed。
      if (content == null) return false;
      final result = await _photoStore.prepare(
        dir: dir,
        item: content,
        credentials: credentials,
        etag: photoFor(before.photos, slot.itemId)?.etag,
      );
      if (!result.isReady) {
        unavailable++;
        return false;
      }
      prepared++;
      photos.removeWhere((photo) => photo.itemId == slot.itemId);
      photos.add(result.photo!.toEntry(nowMs));
      return true;
    }

    // 当前格优先：它就是此刻应当显示的那张。
    final currentReady = slotNow == null ? false : await prepareSlot(slotNow);

    // **预取失败的格也必须替补，不能只补当前格。**
    //
    // 时间线只烘焙「照片已经在磁盘上」的条目。预取一旦失败，时间线上就留一个
    // 洞；App 被系统杀掉之后，原生侧做的是纯查表（这是批准过的架构：原生不做
    // 决策），它只能一路回退到洞前那一格——小组件会**卡死在同一张照片上**，
    // 直到有人再次打开 App。
    //
    // 真机实测：item 4700 连续两次 `timeout`，18:00 那一格因此缺失，小组件停在
    // 了 17:45；而自启动修好之后闹钟明明准时响了，画面却纹丝不动。
    //
    // 规则没有变，仍然是「失败只替换同一格、栅格永不动」，只是把时机从
    //「等它变成当前格」提前到了预取阶段。计划里本来就没有内容的格不在此列——
    // 那种空洞不是下载失败造成的，替补也补不出东西。
    final failedPreloads = <Slot>[];
    for (final slot in upcoming) {
      final ready = await prepareSlot(slot);
      if (!ready && plan?.contentFor(slot.itemId) != null) {
        failedPreloads.add(slot);
      }
    }

    // 当前格取不到时，向服务端申请替补——只替换这一格，栅格不动。
    var substitutedContent = plan?.contentFor(slotNow?.itemId);
    if (slotNow != null && !currentReady) {
      final replacement = await _trySubstitute(
        credentials: credentials,
        planId: plan?.identity.planId ?? before.plan?.planId ?? 0,
        dir: dir,
        slot: slotNow,
        nowMs: nowMs,
        photos: photos,
      );
      if (replacement != null) {
        substitutedContent = replacement;
        prepared++;
        if (unavailable > 0) unavailable--;
      }
    }

    for (final slot in failedPreloads) {
      final replacement = await _trySubstitute(
        credentials: credentials,
        planId: plan?.identity.planId ?? before.plan?.planId ?? 0,
        dir: dir,
        slot: slot,
        nowMs: nowMs,
        photos: photos,
      );
      if (replacement != null) {
        prepared++;
        if (unavailable > 0) unavailable--;
      }
    }

    // ---- 判定显示项与状态 ----
    final slotNowPhoto = slotNow == null ? null : photoFor(photos, slotNow.itemId);
    final displayedItemId = slotNowPhoto == null
        ? before.currentItemId
        : slotNow!.itemId;
    final displayedPhoto = slotNowPhoto ?? photoFor(photos, displayedItemId);
    // 文案必须与照片同属一格，否则会出现「照片是 A、文字是 B」。
    // 替补会换掉该格的 asset（文案可能随之变化），因此替补结果优先。
    final displayedContent =
        substitutedContent != null && substitutedContent.itemId == displayedItemId
        ? substitutedContent
        : plan?.contentFor(displayedItemId);

    final status = _statusFor(
      planFetched: planFetched,
      hasCurrentSlot: slotNow != null,
      currentPhotoAvailable: slotNowPhoto != null,
      fallbackPhotoAvailable: displayedPhoto != null,
    );

    final previousItemId = before.currentItemId != displayedItemId
        ? before.currentItemId
        : before.previousItemId;
    final upcomingIds = [for (final slot in upcoming) slot.itemId];

    // 烘焙时间线：把「已经拿到照片的格子」写成一张到点即可直接上屏的表。
    //
    // 两端原生侧只按 `currentEntryFromTimeline`（date_ms 不晚于此刻的最后一条）
    // 查表，不再各自做选取决策。没有照片的格子不进表——宁可不切换，也不切到
    // 一张空图。
    final timeline = <TimelineEntry>[
      for (final slot in grid)
        if (photoFor(photos, slot.itemId) != null &&
            plan?.contentFor(slot.itemId) != null)
          _timelineEntry(
            dir: dir,
            slot: slot,
            photo: photoFor(photos, slot.itemId)!,
            content: plan!.contentFor(slot.itemId)!,
          ),
    ]..sort((a, b) => a.dateMs.compareTo(b.dateMs));

    // ---- ④ 提交 + ⑤ 清理 ----
    // 清理必须与状态写入在同一次提交里完成：先算出保留集合并写进状态，
    // 再删除不在集合里的文件。反过来会删掉状态仍在引用的照片。
    final removed = <PhotoEntry>[];
    CarouselState? committed;
    try {
      committed = await store.mutate(
        writer: writer,
        incomingPlan: plan?.identity ?? before.plan,
        update: (current) {
          final kept = retainPhotos(
            mode: generationChanged
                ? RetentionMode.generation
                : RetentionMode.normal,
            photos: photos,
            currentItemId: displayedItemId,
            previousItemId: previousItemId,
            nextItemIds: upcomingIds,
            newGrid: grid,
          );
          final keptPaths = {for (final photo in kept) photo.path};
          removed
            ..clear()
            ..addAll(
              photos.where((photo) => !keptPaths.contains(photo.path)),
            );

          return current.copyWith(
            plan: plan?.identity,
            grid: grid,
            currentSlotAtMs: slotNow?.slotAtMs ?? before.currentSlotAtMs,
            currentItemId: displayedItemId,
            currentPhotoPath: displayedPhoto?.path,
            previousItemId: previousItemId,
            previousPhotoPath: photoFor(
              kept,
              previousItemId,
            )?.path,
            status: status,
            nextSlotAtMs: resolution?.atMs,
            nextSlotSource: source,
            photos: kept,
            timelineEntries: timeline,
            clearNextSlot: resolution == null,
          );
        },
        onCommitted: (state) async {
          if (displayedItemId != null) {
            await _photoStore.publishCurrent(dir, displayedItemId);
          }
          await _writeProjection(
            dir: dir,
            state: state,
            content: displayedContent,
            planFetched: planFetched,
          );
          await store.deletePhotos(removed);
        },
      );
    } catch (error) {
      debugPrint('[BloomCarousel] commit failed: $error');
    }

    if (committed != null) {
      try {
        await bridge.refresh();
      } catch (error) {
        debugPrint('[BloomCarousel] widget refresh failed: $error');
      }
    }

    return CarouselTickOutcome(
      planFetched: planFetched,
      committed: committed != null,
      status: status,
      nextSlotSource: source,
      nextSlotAtMs: resolution?.atMs,
      currentItemId: displayedItemId,
      prepared: prepared,
      unavailable: unavailable,
      generationChanged: generationChanged,
      note: planError,
    );
  }

  /// 把一个已就绪的格子写成时间线条目。
  TimelineEntry _timelineEntry({
    required Directory dir,
    required Slot slot,
    required PhotoEntry photo,
    required CarouselItemContent content,
  }) => TimelineEntry(
    dateMs: slot.slotAtMs,
    itemId: slot.itemId,
    portraitPath: photo.path,
    squarePath: CarouselPhotoStore.renderedFile(
      dir,
      'square',
      slot.itemId,
    ).path,
    largeSquarePath: CarouselPhotoStore.renderedFile(
      dir,
      'largeSquare',
      slot.itemId,
    ).path,
    originalPath: CarouselPhotoStore.originalFile(dir, slot.itemId).path,
    date: content.displayAt.toLocal().toIso8601String().substring(0, 10),
    captionZh: content.captionZh,
    captionEn: content.captionEn,
    capturedDateText: content.capturedDateText,
    locationText: content.locationText,
  );

  /// 状态归类。
  ///
  /// 「没有当前格」不等于「下载失败」——那只是计划里此刻还没有格子（例如
  /// 首启时下一格尚未到来）。把它判成失败会让界面平白显示失败提示。
  CurrentStatus _statusFor({
    required bool planFetched,
    required bool hasCurrentSlot,
    required bool currentPhotoAvailable,
    required bool fallbackPhotoAvailable,
  }) {
    if (!planFetched) return CurrentStatus.offline;
    if (!hasCurrentSlot) {
      return fallbackPhotoAvailable ? CurrentStatus.ok : CurrentStatus.pending;
    }
    return classifyStatus(
      planFetched: true,
      photoAvailable: currentPhotoAvailable,
    );
  }

  /// 申请替补并重新取图。任何失败都按「替补不可用」处理。
  Future<CarouselItemContent?> _trySubstitute({
    required DeviceCredentials credentials,
    required int planId,
    required Directory dir,
    required Slot slot,
    required int nowMs,
    required List<PhotoEntry> photos,
  }) async {
    if (planId <= 0) return null;
    try {
      final replacement = await api.substituteCarouselItem(
        credentials,
        planId: planId,
        itemId: slot.itemId,
      );
      // 该 item 的 asset 已被服务端替换，本地按 item_id 命名的旧文件必须清掉，
      // 否则会继续显示原来那张坏照片。
      for (final file in [
        CarouselPhotoStore.originalFile(dir, slot.itemId),
        CarouselPhotoStore.renderedFile(dir, 'portrait', slot.itemId),
        CarouselPhotoStore.renderedFile(dir, 'square', slot.itemId),
        CarouselPhotoStore.renderedFile(dir, 'largeSquare', slot.itemId),
      ]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      photos.removeWhere((photo) => photo.itemId == slot.itemId);
      final result = await _photoStore.prepare(
        dir: dir,
        item: replacement,
        credentials: credentials,
      );
      if (!result.isReady) return null;
      photos.add(result.photo!.toEntry(nowMs));
      debugPrint('[BloomCarousel] substitute applied item=${slot.itemId}');
      return replacement;
    } catch (error) {
      debugPrint(
        '[BloomCarousel] substitute unavailable item=${slot.itemId}: $error',
      );
      return null;
    }
  }

  /// 写派生投影 `daily.json`。
  ///
  /// 它**不是**第二份真相：权威状态是 `carousel-state.json`。投影存在的唯一
  /// 原因是首页的既有读取器（`cached()` / `cachedContent()` / `photoPathFor()`）
  /// 与原生小组件都读这个文件，写它可以让 UI 一行不改。投影与权威状态在同一个
  /// 锁内、同一次提交中写入，因此不会出现两者不一致。
  Future<void> _writeProjection({
    required Directory dir,
    required CarouselState state,
    required CarouselItemContent? content,
    required bool planFetched,
  }) async {
    try {
      final file = File('${dir.path}/daily.json');
      final raw = <String, Object?>{};
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, Object?>) raw.addAll(decoded);
        } catch (_) {}
      }

      raw['mode'] = 'carousel';
      raw['next_slot_at_ms'] = state.nextSlotAtMs;
      raw['next_slot_source'] = state.nextSlotSource.wire;
      raw['current_status'] = state.status.wire;
      raw['carousel_plan_id'] = state.plan?.planId;

      // 文案与照片只在「本次取回了计划」且「文案与当前显示的格子确实是同一格」
      // 时才更新。离线或串项时保持原样：屏幕上那一张本来也没有变。
      final sameItem = content != null && content.itemId == state.currentItemId;
      if (planFetched && sameItem) {
        raw['date'] = content.displayAt
            .toLocal()
            .toIso8601String()
            .substring(0, 10);
        raw['recommendation_id'] = content.itemId;
        raw['carousel_item_id'] = content.itemId;
        raw['caption_zh'] = content.captionZh;
        raw['caption_en'] = content.captionEn;
        raw['captured_date_text'] = content.capturedDateText;
        raw['location_text'] = content.locationText;
        raw['photo_orientation'] = content.photoOrientation;
      }

      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(raw), flush: true);
      await temp.rename(file.path);
    } catch (error) {
      debugPrint('[BloomCarousel] projection write failed: $error');
    }
  }
}
