import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../api/bloom_api_client.dart';
import '../models/device_models.dart';
import '../../platform/widget_bridge.dart';
import '../rendering/mobile_letter_renderer.dart';
import 'display_preferences.dart';
import '../carousel/carousel_engine.dart';
import '../carousel/carousel_rules.dart';
import '../carousel/photo_gc.dart';
import '../carousel/state_store.dart';
import '../carousel/photo_store.dart';

class DailyContentRepository {
  DailyContentRepository({required this.api});
  final BloomApiClient api;

  Future<Directory> _dir() async {
    String? sharedPath;
    try {
      sharedPath = await WidgetBridge().cacheDirectory();
    } catch (_) {}
    if (sharedPath == null) {
      throw StateError('widget cache directory is unavailable');
    }
    final dir = Directory(sharedPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    for (final obsolete in ['mobile-local-landscape.png', 'landscape.json']) {
      final file = File('${dir.path}/$obsolete');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    return dir;
  }

  Future<DailyContent> sync(DeviceCredentials credentials) async {
    try {
      await WidgetBridge().clearCarouselSchedule();
    } catch (_) {}
    final manifest = await api.daily(credentials, target: 'mobile');
    final dir = await _dir();
    final metadataFile = File('${dir.path}/daily.json');

    String? previousEtag;
    if (await metadataFile.exists()) {
      try {
        previousEtag =
            (jsonDecode(await metadataFile.readAsString())
                    as Map<String, dynamic>)['photo_etag']
                as String?;
      } catch (_) {}
    }

    // ⭐ 这一版推荐的三张图都已经在本地了，就【不要再下载原图、再渲染一次】。
    //
    // sync() 原来每次都会：拉 /daily -> 下载原图（可能好几 MB）-> 在手机上把
    // 它渲染成 portrait / square / largeSquare 三种尺寸。这三步是纯本机 CPU 活，
    // 一次要几十秒到几分钟。
    //
    // 而设置保存之后也要重跑一次 sync（好让首页文案与小组件跟上），于是
    // "切一下模式"就变成一次全量重下重渲染 —— 用户看到的就是等好几分钟。
    // 版本号是图片的一部分，所以版本没变就没有任何东西需要重做。
    final alreadyRendered = <String>['portrait', 'square', 'largeSquare'].every(
      (family) =>
          _versionedImage(dir, family, manifest.recommendationId).existsSync(),
    );
    if (alreadyRendered &&
        await File(
          '${dir.path}/carousel-original-${manifest.recommendationId}.photo',
        ).exists()) {
      // 元数据仍然补写一次：它很便宜，而且能修好"图在但 daily.json 丢了"的状态。
      await metadataFile.writeAsString(
        jsonEncode({
          // ⚠️ photo_etag 必须一起写。漏掉它，下一次 sync 就没有 ETag 可用，
          //    只能无条件重下原图 —— 正好抵消掉这个跳过分支省下来的时间。
          'photo_etag': previousEtag,
          'date': manifest.date,
          'recommendation_id': manifest.recommendationId,
          'caption_zh': manifest.captionZh,
          'caption_en': manifest.captionEn,
          'captured_date_text': manifest.capturedDateText,
          'location_text': manifest.locationText,
          'photo_orientation': manifest.photoOrientation,
          'source_name': manifest.sourceName,
          'content_snapshot': manifest.artwork,
          'photo_metadata': {
            'url': manifest.photo?.url ?? '',
            'focus_x': manifest.photo?.focusX,
            'focus_y': manifest.photo?.focusY,
          },
        }),
        flush: true,
      );
      // ⭐ 和轮播引擎 tick 之后一样，必须通知原生小组件重载。
      //    少了这一句，App 里的文案已经换成新的、桌面小组件却还是上一张，
      //    App 的照片又取自小组件状态 —— 于是"文案新、照片旧"。
      try {
        await WidgetBridge().refresh();
      } catch (_) {}
      return manifest;
    }
    var response = await api.originalPhoto(credentials, etag: previousEtag);
    final photoFile = File('${dir.path}/original.photo');
    if (response.statusCode == 304 && !await photoFile.exists()) {
      response = await api.originalPhoto(credentials);
    }
    if (response.statusCode == 200) {
      final temp = File('${photoFile.path}.tmp');
      await temp.writeAsBytes(response.bodyBytes, flush: true);
      await temp.rename(photoFile.path);
    }
    if (!await photoFile.exists()) throw StateError('原图下载失败');
    final photoBytes = await photoFile.readAsBytes();
    final immutable = File(
      '${dir.path}/carousel-original-${manifest.recommendationId}.photo',
    );
    final immutableTemp = File('${immutable.path}.tmp');
    await immutableTemp.writeAsBytes(photoBytes, flush: true);
    await immutableTemp.rename(immutable.path);
    for (final family in ['portrait', 'square', 'largeSquare']) {
      final output = _versionedImage(dir, family, manifest.recommendationId);
      final rendered = await MobileLetterRenderer.render(
        photoBytes,
        manifest,
        family,
      );
      final temp = File('${output.path}.tmp');
      await temp.writeAsBytes(rendered, flush: true);
      await temp.rename(output.path);
      await _pruneVersionedImages(dir, family, keeping: {output.path});
    }
    final originals =
        await dir
            .list()
            .where(
              (e) =>
                  e is File &&
                  RegExp(r'carousel-original-\d+\.photo$').hasMatch(e.path),
            )
            .cast<File>()
            .toList();
    originals.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    for (final obsolete in originals.skip(9)) {
      if (obsolete.path != immutable.path) await obsolete.delete();
    }
    await metadataFile.writeAsString(
      jsonEncode({
        'photo_etag': response.headers['etag'],
        'date': manifest.date,
        'recommendation_id': manifest.recommendationId,
        'caption_zh': manifest.captionZh,
        'caption_en': manifest.captionEn,
        'captured_date_text': manifest.capturedDateText,
        'location_text': manifest.locationText,
        'photo_orientation': manifest.photoOrientation,
        'source_name': manifest.sourceName,
        'content_snapshot': manifest.artwork,
        'photo_metadata': {
          'url': manifest.photo?.url ?? '',
          'focus_x': manifest.photo?.focusX,
          'focus_y': manifest.photo?.focusY,
        },
      }),
      flush: true,
    );
    // ⭐ 同上：推荐这条路原来【从不通知小组件重载】（轮播引擎每次都通知），
    //    所以推荐模式下桌面小组件会一直停在旧图上。
    try {
      await WidgetBridge().refresh();
    } catch (_) {}
    return manifest;
  }

  /// 轮播同步：全部交给 [CarouselEngine]。
  ///
  /// 旧实现自己维护「批次窗口 + 计划池 + 游标」，并用 4 条的批次去推导
  /// 「下一格」——那一整套正是历史上文案空白、两端各显示一张的根源，已整体
  /// 删除。现在这里只做两件事：手动「下一张」时先让服务端把当前格后移，
  /// 然后跑一次 tick。
  ///
  /// ⭐ **关键路径与预取是分开的。** [CarouselEngine.tickCurrent] 只备「此刻该
  /// 显示的那一格」，落盘并通知原生之后立刻返回；另外 4 格由
  /// [CarouselEngine.prefetchAhead] 单独一轮去备。前台（界面）路径不 await 预取
  /// —— 这正是首屏出图从 69 秒降到十几秒的原因：原来 5 张备齐才返回，其中一格
  /// 超时 27 秒、替补又 15 秒，全算在了界面上。
  ///
  /// 后台路径仍然等预取做完：那里没有界面，而时间线必须烘焙完整 —— 预取失败
  /// 留的洞会让小组件在 App 被杀之后卡死在同一张照片上。
  Future<DailyContent> syncCarousel(
    DeviceCredentials credentials,
    BloomDisplaySettings settings, {
    bool next = false,
    bool foreground = false,
  }) async {
    if (next) {
      await _advanceCarouselOnServer(credentials, settings);
    }
    // 顺手清掉上一轮留下的半成品文件。引擎的所有写入都是「临时文件 + rename」，
    // 上一次运行被系统杀掉时可能留下 .tmp，这里按年龄兜底清理。
    try {
      await _sweepTempFiles(await _dir());
    } catch (_) {}
    final engine = CarouselEngine(api: api);
    final writer = foreground ? 'app-foreground' : 'app-background';
    final outcome = await engine.tickCurrent(
      credentials: credentials,
      settings: settings,
      writer: writer,
    );
    debugPrint('[BloomSync] $outcome');

    // 预取与「清理无主照片」必须绑在一起、且都在当前格提交之后：
    // 清理删的是「权威状态里不存在的照片文件」，而预取正在下载的那些文件在它
    // 提交之前恰好不在状态里 —— 两者并行会把刚下好的图删掉，时间线上留下一个洞。
    Future<void> rest() async {
      final plan = outcome.plan;
      if (plan != null) {
        await engine.prefetchAhead(
          credentials: credentials,
          settings: settings,
          writer: writer,
          plan: plan,
        );
      }
      try {
        await _sweepOrphanPhotos(await _dir(), settings);
      } catch (error) {
        debugPrint('[BloomSync] orphan sweep failed: $error');
      }
    }

    if (foreground) {
      // 界面路径：内容已经可以读了，把控制权立刻交回去，剩下的在后台跑。
      unawaited(rest());
    } else {
      await rest();
    }

    final content = await cachedContent();
    if (content == null) {
      throw StateError('轮播内容不可用: $outcome');
    }
    return content;
  }

  /// 手动「下一张」：让服务端把计划的当前格后移一格，再由 tick 按新计划重算。
  ///
  /// 本地不再自行改时间或跳格——栅格永远由服务端给定。
  Future<void> _advanceCarouselOnServer(
    DeviceCredentials credentials,
    BloomDisplaySettings settings,
  ) async {
    int? currentItemId;
    try {
      final state = await CarouselStateStore(directory: await _dir()).read();
      currentItemId = state.currentItemId;
    } catch (_) {}
    await api.carouselItem(
      credentials,
      settings,
      next: true,
      currentItemId: currentItemId,
    );
  }

  Future<CachedWidgetImage?> cached(String orientation) async {
    final dir = await _dir();
    Map<String, dynamic> data = {};
    final meta = File('${dir.path}/$orientation.json');
    final dailyMeta = File('${dir.path}/daily.json');
    final metadataSource = await meta.exists() ? meta : dailyMeta;
    if (await metadataSource.exists()) {
      try {
        data =
            jsonDecode(await metadataSource.readAsString())
                as Map<String, dynamic>;
      } catch (_) {}
    }
    final recommendationId = (data['recommendation_id'] as num?)?.toInt();
    var image =
        recommendationId == null
            ? File('${dir.path}/mobile-local-$orientation.png')
            : _versionedImage(dir, orientation, recommendationId);
    // An item ID is only valid with that item's immutable image.
    if (recommendationId == null && !await image.exists()) {
      image = File('${dir.path}/mobile-local-$orientation.png');
    }
    if (!await image.exists()) return null;
    return CachedWidgetImage(
      path: image.path,
      orientation: orientation,
      etag: (data['etag'] ?? data['photo_etag']) as String?,
      contentVersion: data['content_version'] as String?,
      date: data['date'] as String?,
      recommendationId: recommendationId,
    );
  }

  Future<String?> originalPhotoPath() async {
    final file = File('${(await _dir()).path}/original.photo');
    return await file.exists() ? file.path : null;
  }

  /// The photo that belongs to [itemId] — an **immutable** path per item.
  ///
  /// The page used to display `${dir}/original.photo`, a single mutable file that
  /// every sync rewrites in place. A background sync (widget recovery, the
  /// package-replaced job) could swap its bytes while the page still held the
  /// previous item's captions, so the photo changed and the caption did not — and
  /// a decode that raced the rewrite showed the letter fallback for a while.
  /// Deriving the path from the same id the caption comes from makes the card one
  /// unit again: it cannot show item A's picture next to item B's words.
  Future<String?> photoPathFor(int? itemId) async {
    if (itemId == null || itemId < 1) return null;
    final dir = await _dir();
    final versioned = File('${dir.path}/carousel-original-$itemId.photo');
    if (await versioned.exists()) return versioned.path;

    return null;
  }

  Future<DailyContent?> cachedContent() async {
    final file = File('${(await _dir()).path}/daily.json');
    if (!await file.exists()) return null;
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final id = (data['recommendation_id'] as num?)?.toInt();
      final date = data['date'] as String?;
      if (id == null || date == null) return null;
      return DailyContent(
        date: date,
        recommendationId: id,
        photo:
            data['photo_metadata'] is Map
                ? PhotoAsset.fromJson(
                  Map<String, dynamic>.from(data['photo_metadata'] as Map),
                )
                : null,
        captionZh: data['caption_zh'] as String?,
        captionEn: data['caption_en'] as String?,
        capturedDateText: data['captured_date_text'] as String?,
        locationText: data['location_text'] as String?,
        photoOrientation: data['photo_orientation'] as String?,
        sourceName: data['source_name'] as String? ?? 'personal',
        artwork: Map<String, dynamic>.from(
          data['content_snapshot'] as Map? ?? const {},
        ),
      );
    } catch (_) {
      return null;
    }
  }

  File _versionedImage(Directory dir, String family, int recommendationId) =>
      File('${dir.path}/mobile-local-$family-$recommendationId.png');

  Future<DailyContent> contentForNative(
    WidgetCurrentState state, {
    DailyContent? fallback,
  }) async {
    final local = await CarouselStateStore(directory: await _dir()).read();
    final entry =
        local.timelineEntries
            .where((item) => item.itemId == state.recommendationId)
            .firstOrNull;
    final matching =
        fallback?.recommendationId == state.recommendationId
            ? fallback
            : await cachedContent();
    final metadata =
        matching?.recommendationId == state.recommendationId ? matching : null;
    return DailyContent(
      date: state.date ?? '',
      recommendationId: state.recommendationId,
      photo:
          entry?.photoMetadata.isNotEmpty == true
              ? PhotoAsset.fromJson(entry!.photoMetadata)
              : metadata?.photo,
      captionZh: state.captionZh,
      captionEn: state.captionEn,
      capturedDateText: state.capturedDateText,
      locationText: state.locationText,
      sourceName:
          entry?.sourceName == 'art'
              ? 'art'
              : metadata?.sourceName ?? entry?.sourceName ?? 'personal',
      artwork:
          entry?.artwork.isNotEmpty == true
              ? entry!.artwork
              : metadata?.artwork ?? const {},
    );
  }

  /// **The next moment the page has something new to show.**
  ///

  /// Written by every sync (`next_slot_at_ms` in `daily.json`) and read here so
  /// the foreground can arm one timer for that instant instead of asking the
  /// cache every 30 seconds whether anything changed. Null when the day's slots
  /// are exhausted or the file is unreadable — the caller then simply leaves the
  /// existing behaviour alone rather than guessing a time.

  /// Prints whatever the iOS widget extension recorded about its last timeline
  /// builds and then clears the file, so it cannot grow without bound.
  ///
  /// The extension cannot be observed from the build machine, which is why every
  /// earlier explanation of "iOS repeats a photo" was a guess; this brings its own
  /// account of the decision into a stream the host app already writes to (visible in
  /// Console.app for the phone). No-op on Android, where the file never exists.
  Future<void> drainWidgetTimelineLog() async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/widget-timeline.log');
      if (!await file.exists()) return;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return;
      for (final line in const LineSplitter().convert(text)) {
        if (line.trim().isNotEmpty) {
          debugPrint('[BloomWidget] $line');
        }
      }
      await file.writeAsString('');
    } catch (error) {
      debugPrint('[BloomWidget] timeline log unavailable: $error');
    }
  }

  /// **What the native layer currently shows.**
  ///
  /// The widget is the single authority: it advances on its own at slot boundaries
  /// even while Flutter is asleep. The app used to consult it only while running a
  /// sync, so between two syncs the widget could move ahead and the card stayed on
  /// the previous photo (measured on iOS: two different photos on one phone). Read
  /// this periodically and the two cannot disagree.
  Future<DailyContent?> nativeContent() async {
    try {
      final state = await WidgetBridge().readCurrentState();
      if (state == null || state.recommendationId <= 0) return null;
      return await contentForNative(state);
    } catch (error) {
      debugPrint('[BloomSync] native current unavailable: $error');
      return null;
    }
  }

  /// 「下次更新」的毫秒时间戳。
  ///
  /// **以权威状态里的栅格为准，缓存字段只作兜底。**
  ///
  /// 方案定的规则是「已取回计划中晚于此刻的第一格」，而整天栅格就在状态文件里，
  /// 所以这个值本来不需要等网络。早先只读 `daily.json` 里的 `next_slot_at_ms`，
  /// 于是有一个真实的空窗：格子刚到、下一轮 tick 还没跑完时，那个字段指向的已经
  /// 是过去，界面那道「不显示过去时间」的兜底就把整段文案藏了起来。真机实测出现
  /// 过约 50 秒的空白（进程被系统杀掉、用户手动打开 App 时）。
  ///
  /// 栅格用尽（当天的格子都已过去）时才回退到缓存值——引擎把它写成明天第一格。
  Future<int?> nextSlotAtMillis() async {
    try {
      final dir = await _dir();
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      // ① 栅格：晚于此刻的第一格。这是方案原文那条规则，纯查表、不依赖网络。
      final state = await CarouselStateStore(directory: dir).read();
      final fromGrid = nextSlotAfter(
        state.grid.map((slot) => slot.slotAtMs),
        nowMs,
      );
      if (fromGrid != null) return fromGrid;

      // ② 当天已无未来格：用缓存的兜底值，它指向明天第一格。
      final file = File('${dir.path}/daily.json');
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final cached = (raw['next_slot_at_ms'] as num?)?.toInt();
      // 兜底值同样必须在未来——宁可什么都不显示，也不显示一个过去的时间。
      if (cached != null && cached > nowMs) return cached;
      return null;
    } catch (error) {
      debugPrint('[BloomSync] next slot unavailable: $error');
      return null;
    }
  }

  /// 页面是否**落后**了：此刻本应显示的那一格，比状态里记的当前格还要新。
  ///
  /// 这是给首页兜底轮询用的判据。**不能拿 [nextSlotAtMillis] 来判断**——它返回的
  /// 按定义永远是未来的一格，`at > now` 恒真，用它写的判据会让轮询一次都不执行。
  /// 这正是那个 30 秒兜底此前完全失效的原因：页面一旦错过那次一次性唤醒，就再也
  /// 没有补救（实测 21:15 该换的图拖到 21:17 才换）。
  ///
  /// 返回 true 表示「该补一次 sync」。判不出来时倾向返回 true——兜底的意义就在于
  /// 宁可多同步一次，也不要停在旧画面上。
  Future<bool> isBehind() async {
    try {
      final dir = await _dir();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final state = await CarouselStateStore(directory: dir).read();
      if (state.grid.isEmpty) return false;

      // 此刻应有的那一格：栅格中 `slot_at_ms <= now` 的最新一格。
      // 与两端原生侧「date_ms <= now 的最后一条」是同一条规则的同一侧。
      int? due;
      for (final slot in state.grid) {
        if (slot.slotAtMs > nowMs) continue;
        if (due == null || slot.slotAtMs > due) due = slot.slotAtMs;
      }
      // 此刻没有任何该显示的格（例如刚换代、栅格全是未来），谈不上落后。
      if (due == null) return false;
      final dueAt = due;
      // `currentSlotAtMs` 在「尚无当前格」时为空，那种情况一律算落后。
      return (state.currentSlotAtMs ?? 0) < dueAt;
    } catch (error) {
      debugPrint('[BloomSync] staleness check failed: $error');
      return true;
    }
  }

  /// **A killed write leaves a full-size `.tmp` behind, and nothing else ever
  /// looks at it.** `original.photo.tmp` matches neither pruner's name filter, so
  /// every interruption (a force-stop, a killed background task, a low-memory
  /// kill) used to add one whole photo to the cache forever — the exact
  /// "unbounded growth" the user asked to not have.
  ///
  /// The age floor matters: a live sync may be mid-write at this very moment, and
  /// deleting its temp file would turn a valid rename into an exception.
  Future<void> _sweepTempFiles(Directory dir) async {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.tmp')) continue;
      try {
        if (entity.statSync().modified.isAfter(cutoff)) continue;
        await entity.delete();
      } catch (_) {}
    }
  }

  /// 清理**没有任何状态引用**的照片文件。
  ///
  /// 引擎的淘汰只删「状态里记录过的」文件（它遍历 `photos` 求差集），所以磁盘上
  /// 没人认领的文件它永远看不见。两类来源会留下这种孤儿：
  ///
  ///   * **旧版本升级**——上一代的保留策略与命名不同，升级后那些文件既不在新
  ///     状态里，也没有任何代码会去删。实测 iOS 上升级后残留了 16 张。
  ///   * **下载完成到状态落盘之间被杀**——文件已写、状态未写。
  ///
  /// 只清理本项目自己的两种命名。iOS 扩展自己管理的
  /// `ios-widget-remote-*.jpg` 与 `widget-timeline.log` 不在范围内；`.tmp` 由
  /// [`_sweepTempFiles`] 按年龄处理。
  ///
  /// **只在轮播模式下清理**：推荐模式用的是同一套文件名
  /// （`mobile-local-{family}-{id}.png`、`carousel-original-{id}.photo`），两者
  /// 不会同时是「当前显示」，但保守起见仍然加这道判断。
  Future<void> _sweepOrphanPhotos(
    Directory dir,
    BloomDisplaySettings settings,
  ) async {
    if (!settings.usesScheduledPlan) return;
    try {
      final state = await CarouselStateStore(directory: dir).read();
      final alive = <String>{
        for (final photo in state.photos) ...[
          photo.path,
          '${dir.path}/mobile-render-${photo.itemId}.json',
          CarouselPhotoStore.originalFile(dir, photo.itemId).path,
          for (final family in ['portrait', 'square', 'largeSquare'])
            CarouselPhotoStore.renderedFile(dir, family, photo.itemId).path,
        ],
        for (final entry in state.timelineEntries) ...[
          entry.portraitPath,
          entry.squarePath,
          entry.largeSquarePath,
          entry.originalPath,
        ],
      }..removeWhere((path) => path.isEmpty);

      final swept = await sweepOrphanPhotos(
        dir: dir,
        alivePaths: alive,
        minimumAge: const Duration(minutes: 2),
      );
      if (swept > 0) {
        debugPrint('[BloomSync] 清理无主照片 $swept 张');
      }
    } catch (error) {
      debugPrint('[BloomSync] orphan sweep failed: $error');
    }
  }

  Future<void> _pruneVersionedImages(
    Directory dir,
    String family, {
    required Set<String> keeping,
  }) async {
    final candidates = <File>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('mobile-local-$family-') && name.endsWith('.png')) {
        candidates.add(entity);
      }
    }
    candidates.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    // Keep every referenced item plus a few unreferenced fallbacks. Android can
    // then switch locally without waking Flutter — and, unlike the old
    // newest-eight rule, it can still switch to the slot that is due *next*.
    var spares = 0;
    for (final file in candidates) {
      if (keeping.contains(file.path)) continue;
      if (spares < 8) {
        spares++;
        continue;
      }
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

/// The persisted carousel pool: every slot this phone has prepared for one local
/// day.
///
/// It lives next to the photos (step 1 of walking the day instead of replaying
/// its first four photos) so a refill can compute a union with what is already
/// scheduled. Writing it is what makes the cursor safe: the batch is merged into
/// this list, never substituted for it.
