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
import '../storage/content_sync_epoch.dart';
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
    this.plan,
    this.epoch,
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

  /// 本次拉取到的全天计划（没网时为 null）。
  ///
  /// 它跟着结局一起返回，是为了让 [CarouselEngine.prefetchAhead] 能**接着用同一份
  /// 计划**去备未来格子 —— 否则预取就得再拉一次全天计划，白白多一趟网络。
  final FullPlan? plan;
  final ContentSyncEpoch? epoch;

  @override
  String toString() =>
      'CarouselTickOutcome(plan=$planFetched committed=$committed '
      'status=${status.wire} next=$nextSlotAtMs '
      'source=${nextSlotSource.wire} prepared=$prepared '
      'unavailable=$unavailable generation=$generationChanged'
      '${note == null ? '' : ' note=$note'})';
}

/// 一轮备图的可变计数。
///
/// 关键路径（当前格）与预取（未来格）要各自统计，但 [CarouselEngine._prepareSlot]
/// 是两边共用的纯函数式片段，不能直接改调用方的局部变量，所以把计数装进一个
/// 可变对象传进去。
class CarouselPrepareStats {
  int prepared = 0;
  int unavailable = 0;
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
  ///
  /// [prefetch] 为 true（默认）时保持历史行为：当前格**与**未来若干格全部备好
  /// 才返回。
  ///
  /// ⚠️ **界面路径不要用默认值。** 一次完整 tick 实测要 60–70 秒（其中一格
  /// 超时 27 秒、替补又 15 秒），而那段时间里用户要看的只有当前那一格。界面
  /// 应该 [tickCurrent] + fire-and-forget [prefetchAhead]，两条腿分开跑。
  /// 默认值留给「就是要一次做完」的调用方：后台任务与测试。
  Future<CarouselTickOutcome> tick({
    required DeviceCredentials credentials,
    required BloomDisplaySettings settings,
    required String writer,
    bool prefetch = true,
  }) async {
    final outcome = await tickCurrent(
      credentials: credentials,
      settings: settings,
      writer: writer,
    );
    final plan = outcome.plan;
    if (prefetch && plan != null) {
      await prefetchAhead(
        credentials: credentials,
        settings: settings,
        writer: writer,
        plan: plan,
        epoch: outcome.epoch,
      );
    }
    return outcome;
  }

  /// **关键路径：只保证「此刻该显示的那一张」就位。**
  ///
  /// 次序与完整 tick 的前半段一模一样 —— 对表 → 先落文案 → 备当前格 → 当前格
  /// 取不到就替补 → 提交并通知原生 —— 只是**到此为止**。
  ///
  /// 未来格子的预取被剥到 [prefetchAhead] 里，于是界面上那一张不再被另外 4 张
  /// 的下载、以及它们失败后的替补拖住。这一条是量出来的：15:07:03 启动，
  /// `/plan` 15:07:06 就回来了，但整批做完是 15:08:12 —— 69 秒里，当前格
  /// （6124）在 15:07:29 之前就已经能显示，剩下的 43 秒全花在未来格 6127 的
  /// 超时与替补上。
  Future<CarouselTickOutcome> tickCurrent({
    required DeviceCredentials credentials,
    required BloomDisplaySettings settings,
    required String writer,
    ContentSyncEpoch? syncEpoch,
  }) async {
    final dir = await sharedDirectory();
    final store = CarouselStateStore(directory: dir);
    final epoch = syncEpoch ?? await ContentSyncEpoch.capture(dir);
    final nowMs = _clock().millisecondsSinceEpoch;
    final before = _withDueCurrent(await store.read(), nowMs);

    // ---- ① 对表 ----
    FullPlan? plan;
    String? planError;
    try {
      plan = await _planClient.fetchFullDay(
        credentials,
        settings,
        cachedItemIds: before.photos.map((photo) => photo.itemId).toList(),
      );
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
          canCommit: epoch.isCurrent,
          writer: writer,
          incomingPlan: plan.identity,
          update:
              (current) => current.copyWith(
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

    // ---- ③ 备照片：**只备此刻该显示的那一格** ----
    //
    // 未来格子由 [prefetchAhead] 单独一轮去备。原来它们在这里一条 `for` 循环里
    // 被逐张 await，于是「界面上那一张」要排在 4 张之后 —— 其中任何一张超时
    // （实测 27 秒）或触发替补（再 15 秒），首屏就一起被拖住。
    final photos = [...before.photos];
    final attempted = <int>{};
    final stats = CarouselPrepareStats();

    // 当前格优先：它就是此刻应当显示的那张。
    final currentReady =
        slotNow == null
            ? false
            : await _prepareSlot(
              dir: dir,
              plan: plan,
              slot: slotNow,
              credentials: credentials,
              photos: photos,
              before: before.photos,
              attempted: attempted,
              stats: stats,
              nowMs: nowMs,
              canPrepare: epoch.isCurrent,
            );

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
        canPrepare: epoch.isCurrent,
      );
      if (replacement != null) {
        substitutedContent = replacement;
        plan?.contentById[slotNow.itemId] = replacement;
        stats.prepared++;
        if (stats.unavailable > 0) stats.unavailable--;
      }
    }

    final prepared = stats.prepared;
    final unavailable = stats.unavailable;

    // ---- 判定显示项与状态 ----
    final slotNowPhoto =
        slotNow == null ? null : photoFor(photos, slotNow.itemId);
    final displayedItemId =
        slotNowPhoto == null ? before.currentItemId : slotNow!.itemId;
    final displayedPhoto = slotNowPhoto ?? photoFor(photos, displayedItemId);
    // 文案必须与照片同属一格，否则会出现「照片是 A、文字是 B」。
    // 替补会换掉该格的 asset（文案可能随之变化），因此替补结果优先。
    final displayedContent =
        substitutedContent != null &&
                substitutedContent.itemId == displayedItemId
            ? substitutedContent
            : plan?.contentFor(displayedItemId);

    final status = _statusFor(
      planFetched: planFetched,
      hasCurrentSlot: slotNow != null,
      currentPhotoAvailable: slotNowPhoto != null,
      fallbackPhotoAvailable: displayedPhoto != null,
    );

    final previousItemId =
        before.currentItemId != displayedItemId
            ? before.currentItemId
            : before.previousItemId;
    final upcomingIds = [for (final slot in upcoming) slot.itemId];

    // 烘焙时间线：把「已经拿到照片的格子」写成一张到点即可直接上屏的表。
    //
    // 两端原生侧只按 `currentEntryFromTimeline`（date_ms 不晚于此刻的最后一条）
    // 查表，不再各自做选取决策。没有照片的格子不进表——宁可不切换，也不切到
    // 一张空图。
    final readyIds = await _readyTimelineIds(dir, grid, photos, plan);
    final timeline = <TimelineEntry>[
      ...await _fallbackEntries(dir, before, nowMs, readyIds, grid, plan),
      for (final slot in grid)
        if (readyIds.contains(slot.itemId) &&
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
        canCommit: epoch.isCurrent,
        writer: writer,
        incomingPlan: plan?.identity ?? before.plan,
        update: (current) {
          final kept = retainPhotos(
            mode:
                generationChanged
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
            ..addAll(photos.where((photo) => !keptPaths.contains(photo.path)));

          return current.copyWith(
            plan: plan?.identity,
            grid: grid,
            currentSlotAtMs: slotNow?.slotAtMs ?? before.currentSlotAtMs,
            currentItemId: displayedItemId,
            currentPhotoPath: displayedPhoto?.path,
            previousItemId: previousItemId,
            previousPhotoPath: photoFor(kept, previousItemId)?.path,
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
      plan: plan,
      epoch: epoch,
    );
  }

  /// **未来格子的预取 —— 单独一轮，不挡界面。**
  ///
  /// 关键路径（[tickCurrent]）已经把当前格提交并通知原生；这里接着备未来若干格，
  /// 每张就绪即提交，后续下载中断不会丢掉已可到点上屏的条目。
  ///
  /// 为什么这件事必须做，而不能"等它变成当前格再下"：
  ///
  /// 时间线只烘焙「照片已经在磁盘上」的条目。预取一旦失败，时间线上就留一个洞；
  /// App 被系统杀掉之后，原生侧做的是纯查表（这是批准过的架构：原生不做决策），
  /// 它只能一路回退到洞前那一格 —— 小组件会**卡死在同一张照片上**，直到有人
  /// 再次打开 App。真机实测：item 4700 连续两次 `timeout`，18:00 那一格因此
  /// 缺失，小组件停在了 17:45；自启动修好之后闹钟准时响了，画面却纹丝不动。
  ///
  /// 所以这里不只是"提前下载"，它同时是**失败替补的执行点**。规则没变：失败只
  /// 替换同一格、栅格永不动。计划里本来就没有内容的格不在此列 —— 那种空洞不是
  /// 下载失败造成的，替补也补不出东西。
  ///
  /// [plan] 直接沿用 [tickCurrent] 返回的那一份，不再多拉一次全天计划。
  /// 本方法**自己吞掉所有异常**：调用方是 fire-and-forget，没人接的错误会变成
  /// unhandled exception。
  Future<void> prefetchAhead({
    required DeviceCredentials credentials,
    required BloomDisplaySettings settings,
    required String writer,
    required FullPlan plan,
    ContentSyncEpoch? epoch,
  }) async {
    try {
      final dir = await sharedDirectory();
      final store = CarouselStateStore(directory: dir);
      final session = epoch ?? await ContentSyncEpoch.capture(dir);
      if (!await session.isCurrent()) return;
      // ⭐ 必须重新读一次状态：上面那次提交刚写过它（当前格 + 时间线 + 清理），
      //    拿旧快照继续会把已删的照片又算进来。
      final nowMs = _clock().millisecondsSinceEpoch;
      final before = _withDueCurrent(await store.read(), nowMs);

      final grid = plan.grid;
      final upcoming = upcomingSlots(grid, nowMs);

      final photos = [...before.photos];
      final attempted = <int>{};
      final stats = CarouselPrepareStats();

      // Publish each complete photo before starting another network request.
      // A killed foreground app must not strand already prepared slots outside
      // the shared timeline while the rest of its batch is still downloading.
      Future<void> publishPrepared() async {
        if (!await session.isCurrent()) return;
        final nowMs = _clock().millisecondsSinceEpoch;
        final before = _withDueCurrent(await store.read(), nowMs);
        final slotNow = currentSlot(grid, nowMs);
        final resolution = resolveNextSlot(
          gridMs: [for (final slot in grid) slot.slotAtMs],
          nowMs: nowMs,
          tomorrowFirstMs: plan.serverNextCheckMs ?? before.nextSlotAtMs,
        );
        // 显示项判定与关键路径同一条规则：**宁可不切换，也不切到一张空图。**
        // 时间在这期间可能已经跨到下一格，若那一格的照片没备好，就仍然停在
        // `before.currentItemId`。
        final slotNowPhoto =
            slotNow == null ? null : photoFor(photos, slotNow.itemId);
        final displayedItemId =
            slotNowPhoto == null ? before.currentItemId : slotNow!.itemId;
        final previousItemId =
            before.currentItemId != displayedItemId
                ? before.currentItemId
                : before.previousItemId;
        final upcomingIds = [for (final slot in upcoming) slot.itemId];
        final generationChanged = isNewGeneration(before.plan, plan.identity);

        final readyIds = await _readyTimelineIds(dir, grid, photos, plan);
        final timeline = <TimelineEntry>[
          ...await _fallbackEntries(dir, before, nowMs, readyIds, grid, plan),
          for (final slot in grid)
            if (readyIds.contains(slot.itemId) &&
                plan.contentFor(slot.itemId) != null)
              _timelineEntry(
                dir: dir,
                slot: slot,
                photo: photoFor(photos, slot.itemId)!,
                content: plan.contentFor(slot.itemId)!,
              ),
        ]..sort((a, b) => a.dateMs.compareTo(b.dateMs));

        final removed = <PhotoEntry>[];
        CarouselState? committed;
        try {
          committed = await store.mutate(
            canCommit: session.isCurrent,
            writer: writer,
            incomingPlan: plan.identity,
            update: (current) {
              final kept = retainPhotos(
                mode:
                    generationChanged
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
                grid: grid,
                currentSlotAtMs: slotNow?.slotAtMs ?? before.currentSlotAtMs,
                currentItemId: displayedItemId,
                currentPhotoPath: slotNowPhoto?.path,
                previousItemId: previousItemId,
                previousPhotoPath: photoFor(kept, previousItemId)?.path,
                nextSlotAtMs: resolution?.atMs,
                nextSlotSource: NextSlotSource.plan,
                photos: kept,
                timelineEntries: timeline,
                clearNextSlot: resolution == null,
              );
            },
            onCommitted: (state) async {
              // 时间可能已经跨到下一格，而那一格的照片刚好在预取里备好了 ——
              // 那就顺手把「当前项」也推进过去，别等下一次 tick。
              if (slotNowPhoto != null && displayedItemId != null) {
                await _photoStore.publishCurrent(dir, displayedItemId);
              }
              await _writeProjection(
                dir: dir,
                state: state,
                content: plan.contentFor(state.currentItemId),
                planFetched: true,
              );
              await store.deletePhotos(removed);
            },
          );
        } catch (error) {
          debugPrint('[BloomCarousel] prefetch commit failed: $error');
        }

        if (committed != null) {
          try {
            await bridge.refresh();
          } catch (error) {
            debugPrint('[BloomCarousel] prefetch refresh failed: $error');
          }
        }
      }

      final failedPreloads = <Slot>[];
      for (final slot in upcoming) {
        if (!await session.isCurrent()) return;
        final ready = await _prepareSlot(
          dir: dir,
          plan: plan,
          slot: slot,
          credentials: credentials,
          photos: photos,
          before: before.photos,
          attempted: attempted,
          stats: stats,
          nowMs: nowMs,
          canPrepare: session.isCurrent,
        );
        if (ready) {
          await publishPrepared();
        } else if (plan.contentFor(slot.itemId) != null) {
          failedPreloads.add(slot);
        }
      }

      for (final slot in failedPreloads) {
        if (!await session.isCurrent()) return;
        final replacement = await _trySubstitute(
          credentials: credentials,
          planId: plan.identity.planId,
          dir: dir,
          slot: slot,
          nowMs: nowMs,
          photos: photos,
          canPrepare: session.isCurrent,
        );
        if (replacement != null) {
          plan.contentById[slot.itemId] = replacement;
          stats.prepared++;
          if (stats.unavailable > 0) stats.unavailable--;
          await publishPrepared();
        }
      }

      await publishPrepared();
      debugPrint(
        '[BloomCarousel] prefetch done prepared=${stats.prepared} '
        'unavailable=${stats.unavailable} entries=${(await store.read()).timelineEntries.length}',
      );
    } catch (error) {
      // 预取是"尽力而为"：它失败不该影响任何人，更不该变成 unhandled error。
      debugPrint('[BloomCarousel] prefetchAhead failed (ignored): $error');
    }
  }

  /// 备一格的照片：已在池子里就跳过，缺就下载并渲染，失败只记账不抛。
  ///
  /// 抽出来是因为关键路径（当前格）与预取（未来格）用的是同一套判定 ——
  /// 两边各写一份迟早会漂移。
  Future<bool> _prepareSlot({
    required Directory dir,
    required FullPlan? plan,
    required Slot slot,
    required DeviceCredentials credentials,
    required List<PhotoEntry> photos,
    required List<PhotoEntry> before,
    required Set<int> attempted,
    required CarouselPrepareStats stats,
    required int nowMs,
    required Future<bool> Function() canPrepare,
  }) async {
    if (!await canPrepare()) return false;
    final existing = photoFor(photos, slot.itemId);
    if (existing != null) {
      final descriptor = plan?.contentFor(slot.itemId);
      if (descriptor != null) {
        final result = await _photoStore.prepare(
          dir: dir,
          item: descriptor,
          credentials: credentials,
          etag: existing.etag,
          canPrepare: canPrepare,
        );
        if (result.isReady) {
          // A cached entry may still reference the legacy server-rendered file.
          // Preparing also migrates/rebuilds the local layout; publish its paths.
          photos.removeWhere((p) => p.itemId == slot.itemId);
          photos.add(result.photo!.toEntry(existing.fetchedAtMs));
          return true;
        }
      } else if (await CarouselPhotoStore.isReady(dir, slot.itemId)) {
        return true;
      }
      photos.removeWhere((p) => p.itemId == slot.itemId);
    }
    if (!attempted.add(slot.itemId)) {
      return photoFor(photos, slot.itemId) != null;
    }
    var content = plan?.contentFor(slot.itemId);
    // 离线时拿不到内容描述符，本轮无法取图——这是 offline，不是 download_failed。
    if (content == null) return false;
    try {
      content = await api.prepareCarouselItem(credentials, slot.itemId);
      plan!.contentById[slot.itemId] = content;
      final index = plan.grid.indexWhere((item) => item.itemId == slot.itemId);
      if (index >= 0) {
        plan.grid[index] = Slot(
          slotAtMs: slot.slotAtMs,
          itemId: slot.itemId,
          assetId: content.assetId,
        );
      }
    } catch (error) {
      debugPrint('[BloomCarousel] photo claim failed: $error');
      stats.unavailable++;
      return false;
    }
    final result = await _photoStore.prepare(
      dir: dir,
      item: content,
      credentials: credentials,
      etag: photoFor(before, slot.itemId)?.etag,
      canPrepare: canPrepare,
    );
    if (!result.isReady) {
      stats.unavailable++;
      return false;
    }
    stats.prepared++;
    photos.removeWhere((photo) => photo.itemId == slot.itemId);
    photos.add(result.photo!.toEntry(nowMs));
    return true;
  }

  Future<Set<int>> _readyTimelineIds(
    Directory dir,
    List<Slot> grid,
    List<PhotoEntry> photos,
    FullPlan? plan,
  ) async {
    final ready = <int>{};
    for (final slot in grid) {
      final photo = photoFor(photos, slot.itemId);
      final content = plan?.contentFor(slot.itemId);
      if (photo != null &&
          content != null &&
          photo.assetId == content.assetId &&
          await _photoStore.isReadyFor(dir, content)) {
        ready.add(slot.itemId);
      }
    }
    return ready;
  }

  CarouselState _withDueCurrent(CarouselState state, int nowMs) {
    final due = currentEntryFromTimeline(state.timelineEntries, nowMs);
    if (due == null) return state;
    return state.copyWith(
      currentItemId: due.itemId,
      currentPhotoPath: due.portraitPath,
      currentSlotAtMs: due.dateMs,
      previousItemId:
          state.currentItemId != due.itemId
              ? state.currentItemId
              : state.previousItemId,
    );
  }

  /// Keep the last successful photo when a new day's first download fails.
  /// Offline ticks must preserve already baked future slots as well: without
  /// descriptors they cannot rebuild the timeline, but the cached one is valid.
  Future<List<TimelineEntry>> _fallbackEntries(
    Directory dir,
    CarouselState before,
    int nowMs,
    Set<int> replaced,
    List<Slot> grid,
    FullPlan? plan,
  ) async {
    final keep = <TimelineEntry>[];
    final due = currentEntryFromTimeline(before.timelineEntries, nowMs);
    for (final entry in before.timelineEntries) {
      if (replaced.contains(entry.itemId)) continue;
      if (plan != null &&
          entry.itemId != due?.itemId &&
          entry.itemId != before.previousItemId) {
        continue;
      }
      if (plan == null &&
          !grid.any((s) => s.itemId == entry.itemId) &&
          entry.itemId != due?.itemId &&
          entry.itemId != before.previousItemId) {
        continue;
      }
      if (entry.originalPath.isNotEmpty &&
          await File(entry.originalPath).exists() &&
          await CarouselPhotoStore.isReady(dir, entry.itemId)) {
        keep.add(entry);
      }
    }
    return keep;
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
    squarePath:
        CarouselPhotoStore.renderedFile(dir, 'square', slot.itemId).path,
    largeSquarePath:
        CarouselPhotoStore.renderedFile(dir, 'largeSquare', slot.itemId).path,
    originalPath: CarouselPhotoStore.originalFile(dir, slot.itemId).path,
    date: content.displayAt.toLocal().toIso8601String().substring(0, 10),
    captionZh: content.captionZh,
    captionEn: content.captionEn,
    capturedDateText: content.capturedDateText,
    locationText: content.locationText,
    sourceName: content.sourceName,
    artwork: content.artwork,
    photoMetadata: {
      'url': content.photo.url,
      'focus_x': content.photo.focusX,
      'focus_y': content.photo.focusY,
    },
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
    required Future<bool> Function() canPrepare,
  }) async {
    if (planId <= 0 || !await canPrepare()) return null;
    try {
      final replacement = await api.substituteCarouselItem(
        credentials,
        planId: planId,
        itemId: slot.itemId,
      );
      if (!await canPrepare()) return null;
      // prepare validates the asset marker under its file lock and rebuilds
      // when the replacement changes identity. Do not delete another writer's
      // files outside that lock.
      photos.removeWhere((photo) => photo.itemId == slot.itemId);
      final result = await _photoStore.prepare(
        dir: dir,
        item: replacement,
        credentials: credentials,
        canPrepare: canPrepare,
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
      raw['pipeline'] = 'carousel';
      raw['next_slot_at_ms'] = state.nextSlotAtMs;
      raw['next_slot_source'] = state.nextSlotSource.wire;
      raw['current_status'] = state.status.wire;
      raw['carousel_plan_id'] = state.plan?.planId;

      // 文案与照片只在「本次取回了计划」且「文案与当前显示的格子确实是同一格」
      // 时才更新。离线或串项时保持原样：屏幕上那一张本来也没有变。
      final sameItem = content != null && content.itemId == state.currentItemId;
      if (planFetched && sameItem) {
        raw['date'] = content.displayAt.toLocal().toIso8601String().substring(
          0,
          10,
        );
        raw['recommendation_id'] = content.itemId;
        raw['carousel_item_id'] = content.itemId;
        raw['caption_zh'] = content.captionZh;
        raw['caption_en'] = content.captionEn;
        raw['captured_date_text'] = content.capturedDateText;
        raw['location_text'] = content.locationText;
        raw['photo_orientation'] = content.photoOrientation;
        raw['source_name'] = content.sourceName;
        raw['content_snapshot'] = content.artwork;
        raw['photo_metadata'] = {
          'url': content.photo.url,
          'focus_x': content.photo.focusX,
          'focus_y': content.photo.focusY,
        };
      }

      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(raw), flush: true);
      await temp.rename(file.path);
    } catch (error) {
      debugPrint('[BloomCarousel] projection write failed: $error');
    }
  }
}
