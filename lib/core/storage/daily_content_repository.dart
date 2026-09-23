import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../api/bloom_api_client.dart';
import '../models/device_models.dart';
import '../../platform/widget_bridge.dart';
import '../rendering/mobile_letter_renderer.dart';
import 'display_preferences.dart';

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
      await _pruneVersionedImages(dir, family, keeping: output.path);
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
      }),
      flush: true,
    );
    return manifest;
  }

  Future<DailyContent> syncCarousel(
    DeviceCredentials credentials,
    BloomDisplaySettings settings, {
    bool next = false,
  }) async {
    if (!next) {
      return _syncCarouselPlan(credentials, settings);
    }
    final dir = await _dir();
    final metadataFile = File('${dir.path}/daily.json');
    String? previousEtag;
    int? currentItemId;
    if (await metadataFile.exists()) {
      try {
        final previous =
            jsonDecode(await metadataFile.readAsString())
                as Map<String, dynamic>;
        previousEtag = previous['photo_etag'] as String?;
        currentItemId = (previous['carousel_item_id'] as num?)?.toInt();
      } catch (_) {}
    }
    final envelope = await api.carouselItem(
      credentials,
      settings,
      next: next,
      currentItemId: currentItemId,
    );
    final manifest = envelope.item.asDailyContent();
    var response = await api.carouselPhoto(
      credentials,
      envelope.item.itemId,
      etag: previousEtag,
    );
    final photoFile = File('${dir.path}/original.photo');
    if (response.statusCode == 304 && !await photoFile.exists()) {
      response = await api.carouselPhoto(credentials, envelope.item.itemId);
    }
    if (response.statusCode == 200) {
      final temp = File('${photoFile.path}.tmp');
      await temp.writeAsBytes(response.bodyBytes, flush: true);
      await temp.rename(photoFile.path);
    }
    if (!await photoFile.exists()) throw StateError('轮播原图下载失败');
    final photoBytes = await photoFile.readAsBytes();
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
      await _pruneVersionedImages(dir, family, keeping: output.path);
    }
    await metadataFile.writeAsString(
      jsonEncode({
        'mode': 'carousel',
        'photo_etag': response.headers['etag'] ?? previousEtag,
        'date': manifest.date,
        'recommendation_id': manifest.recommendationId,
        'carousel_item_id': envelope.item.itemId,
        'next_check_at': envelope.nextCheckAt.toIso8601String(),
        'caption_zh': manifest.captionZh,
        'caption_en': manifest.captionEn,
        'captured_date_text': manifest.capturedDateText,
        'location_text': manifest.locationText,
        'photo_orientation': manifest.photoOrientation,
      }),
      flush: true,
    );
    return manifest;
  }

  Future<DailyContent> _syncCarouselPlan(
    DeviceCredentials credentials,
    BloomDisplaySettings settings,
  ) async {
    final dir = await _dir();
    final lock = File('${dir.path}/carousel-sync.lock');
    var ownsLock = false;
    try {
      await lock.create(exclusive: true);
      ownsLock = true;
    } on FileSystemException {
      // WorkManager and the foreground app can wake at the same time. Let the
      // existing owner finish rather than downloading and rendering the same
      // four large photos in two Flutter engines.
      var removedStaleLock = false;
      for (var attempt = 0; attempt < 180 && await lock.exists(); attempt++) {
        final age = DateTime.now().difference((await lock.stat()).modified);
        if (age > const Duration(minutes: 3)) {
          try {
            await lock.delete();
            removedStaleLock = true;
          } catch (_) {}
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      // The previous process may have been killed while downloading a batch.
      // Deleting its stale lock and then returning the old cache reports a
      // false success to WorkManager and can leave the carousel stuck. Take
      // ownership again and perform the sync for real.
      if (removedStaleLock) {
        return _syncCarouselPlan(credentials, settings);
      }
      // The other task did not finish within the wait window. Returning the
      // previous cache here reports SUCCESS to WorkManager even though no new
      // plan was downloaded, so the stale lock can leave the widget frozen
      // indefinitely. Fail this attempt and let WorkManager retry; a later
      // attempt will either observe the real owner finishing or remove the
      // lock once it passes the stale threshold above.
      if (await lock.exists()) {
        throw StateError('轮播计划同步仍在进行，等待后台重试');
      }
      final cached = await cachedContent();
      if (cached != null) return cached;
      throw StateError('轮播计划正在由另一个任务更新');
    }

    try {
      return await _downloadAndScheduleCarouselPlan(
        credentials,
        settings,
        dir,
        lock,
      );
    } finally {
      if (ownsLock && await lock.exists()) {
        try {
          await lock.delete();
        } catch (_) {}
      }
    }
  }

  Future<DailyContent> _downloadAndScheduleCarouselPlan(
    DeviceCredentials credentials,
    BloomDisplaySettings settings,
    Directory dir,
    File lock,
  ) async {
    // ---- **walk the day with a cursor; let the pool own "current"** ------
    //
    // The two jobs used to be tangled in this one method, and that is exactly
    // why the first cursor attempt had to be rolled back: `carousel/plan`
    // deliberately returns the page that *starts after* the server's
    // `current_item_id`, while the old code insisted the current item be inside
    // the fetched batch. Every refill then threw
    // `Bad state: 当前轮播照片不在计划批次中`, and because the cursor advanced on
    // each failure, no later attempt could recover — a fresh install showed no
    // photo at all.
    //
    // They are separated here:
    //
    //   * the **cursor** (`after_item_id`) decides which *new* photos to fetch
    //     and only ever appends them to the pool;
    //   * the **pool** decides which photo is on screen *now*, and a refill page
    //     may not change it.
    //
    // The native layer always receives the **whole union**, because
    // `scheduleCarousel` overwrites what it stores — submitting only the new page
    // would drop every slot that is already armed.
    final now = DateTime.now();
    final nowMillis = now.millisecondsSinceEpoch;
    final today = _dayKey(now);
    final storedPool = await _readPool(dir);
    final pool = <Map<String, Object?>>[
      if (storedPool != null && storedPool.day == today) ...storedPool.entries,
    ];
    // **Step 2 — the refill anchor.** The largest id the pool actually holds,
    // i.e. the last page boundary this phone prepared. A page that failed to
    // render never entered the pool, so it is asked for again instead of being
    // silently stepped over. It is per local day: a new day starts from the top.
    final anchor =
        storedPool != null &&
            storedPool.day == today &&
            storedPool.lastItemId > 0
        ? storedPool.lastItemId
        : _maxItemId(pool);
    final plan = await api.carouselPlan(
      credentials,
      settings,
      afterItemId: anchor > 0 ? anchor : null,
    );
    debugPrint(
      '[BloomSync] carousel plan=${plan.planId} items=${plan.items.length} '
      'current=${plan.currentItemId} after=${anchor > 0 ? anchor : 'none'} '
      'pool=${pool.length}',
    );
    if (plan.items.isEmpty && pool.isEmpty) throw StateError('轮播计划为空');

    // ---- **the plan's own "now", then the rest** ------------------------
    //
    // Two things were wrong before. The four photos were fetched one after
    // another (four × ~6s of empty home page), and the fetch that mattered —
    // **the item the plan says belongs in the current slot**
    // (`plan.currentItemId`), not whichever download happens to finish first —
    // was queued behind the other three.
    //
    // So: one shared table of download tasks. Every task is created once, which
    // is what makes this safe — the render loop below and this prefetch can both
    // ask for item 3093 and only one of them will ever write the file. The
    // current slot's photo is awaited; the rest are already in flight behind it
    // and are collected as they land.
    String originalPathOf(int itemId) =>
        '${dir.path}/carousel-original-$itemId.photo';
    final photoEtag = <int, String?>{};
    final pending = <int, Future<void>>{};
    // A photo nobody is waiting for gets a short leash. The measured failure was
    // `Connection closed while receiving data` after **25 seconds** (the shared
    // request timeout) on one future asset, which held the whole refill — and the
    // whole background task — for 25s while the photo that actually belonged on
    // screen had been ready in 0ms. The current slot keeps the generous timeout
    // (it must not be skipped, so it deserves the patience); a future asset gives
    // up quickly, is skipped, and is simply retried on the next refill.
    // **25 seconds, not 8.** The 8s leash was a mistake with a measurable
    // cause-and-effect: these are big photos fetched four-at-a-time, so each one
    // shares the phone's bandwidth and legitimately takes far longer than it did
    // when they went out one by one. Measured on device: the current item comes
    // back in 0-105ms (cached) but a fresh photo needed 7s — right at the old
    // limit — and the rest died at exactly `TimeoutException after 0:00:08`.
    // The effect was that *every* new photo was skipped, the pool never refilled,
    // and the widget sat on one cached photo forever. The skip-and-retry
    // machinery is still worth having for a download that is genuinely dead; it
    // just needs a limit that a real photo can meet.
    Future<void> fetchPhoto(
      int itemId, {
      Duration timeout = const Duration(seconds: 25),
    }) => pending.putIfAbsent(itemId, () async {
      final path = originalPathOf(itemId);
      if (await File(path).exists()) return;
      final response =
          await api.carouselPhoto(credentials, itemId).timeout(timeout);
      if (response.statusCode != 200) {
        throw StateError('轮播计划照片下载失败');
      }
      photoEtag[itemId] = response.headers['etag'];
      final temp = File('$path.tmp');
      await temp.writeAsBytes(response.bodyBytes, flush: true);
      await temp.rename(path);
    });

    // **"Current" is the slot that is due now — not merely the id the server
    // labelled.** Outside the active window the server names *tomorrow's* first
    // item as `current_item_id` (the iOS timeline has guarded against this for a
    // while). Treating that as current would push tomorrow's photo onto the
    // widget tonight.
    CarouselItemContent? batchCurrentCandidate;
    for (final item in plan.items) {
      if (item.itemId != plan.currentItemId) continue;
      if (item.displayAt.toLocal().isAfter(now.add(const Duration(seconds: 60)))) {
        continue;
      }
      batchCurrentCandidate = item;
      break;
    }
    final batchCurrent = batchCurrentCandidate;
    final prefetchWatch = Stopwatch()..start();
    if (batchCurrent != null) {
      await fetchPhoto(
        batchCurrent.itemId,
        timeout: const Duration(seconds: 30),
      );
      debugPrint(
        '[BloomSync] current photo item=${batchCurrent.itemId} ready in '
        '${prefetchWatch.elapsedMilliseconds}ms',
      );
    }
    for (final item in plan.items) {
      if (batchCurrent != null && item.itemId == batchCurrent.itemId) continue;
      // Deliberately not awaited: they download while the loop renders.
      unawaited(fetchPhoto(item.itemId).catchError((Object _) {}));
    }
    final incoming = <Map<String, Object?>>[];
    DailyContent? currentManifest;

    for (final item in plan.items) {
      try {
        final manifest = item.asDailyContent();
        final originalPath =
            '${dir.path}/carousel-original-${item.itemId}.photo';
        final original = File(originalPath);
        final outputs = <String, File>{
          for (final family in ['portrait', 'square', 'largeSquare'])
            family: _versionedImage(dir, family, item.itemId),
        };
        Uint8List photoBytes;
        if (await original.exists()) {
          photoBytes = await original.readAsBytes();
          debugPrint('[BloomSync] reusing cached photo item=${item.itemId}');
        } else {
          // Never fetch here: the shared table owns that, so a photo being
          // downloaded in the background cannot be written twice.
          debugPrint('[BloomSync] waiting for photo item=${item.itemId}');
          await fetchPhoto(item.itemId);
          photoBytes = await original.readAsBytes();
        }
        final paths = <String, String>{};
        for (final family in ['portrait', 'square', 'largeSquare']) {
          final output = outputs[family]!;
          if (!await output.exists()) {
            final rendered = await MobileLetterRenderer.render(
              photoBytes,
              manifest,
              family,
            );
            final temp = File('${output.path}.tmp');
            await temp.writeAsBytes(rendered, flush: true);
            await temp.rename(output.path);
          }
          paths[family] = output.path;
        }
        incoming.add(_poolEntry(item, manifest, paths, originalPath));
        if (batchCurrent != null && item.itemId == batchCurrent.itemId) {
          currentManifest = manifest;
          // Keep `original.photo` pointing at the slot the app shows now.
          final photoFile = File('${dir.path}/original.photo');
          final photoTemp = File('${photoFile.path}.tmp');
          await photoTemp.writeAsBytes(photoBytes, flush: true);
          await photoTemp.rename(photoFile.path);
          // Publish the current item immediately. If a later prefetch item is
          // slow, the widget still advances instead of discarding the batch.
          // `daily.json` is written once at the end, when the union — and with
          // it the true `next_slot_at_ms` — is known.
          await WidgetBridge().update(
            portraitPath: paths['portrait']!,
            squarePath: paths['square']!,
            largeSquarePath: paths['largeSquare']!,
            date: manifest.date,
            recommendationId: manifest.recommendationId,
            originalPhotoPath: originalPath,
            captionZh: manifest.captionZh,
            captionEn: manifest.captionEn,
            capturedDateText: manifest.capturedDateText,
            locationText: manifest.locationText,
            mode: 'carousel',
          );
        }

        // Persist a usable partial timeline after every completed item. A
        // later timeout can resume from cache without losing earlier work. The
        // batch is merged with the stored pool so this partial write never drops
        // a slot that is already armed.
        await WidgetBridge().scheduleCarousel(
          planId: plan.planId,
          entries: _mergePool(pool, incoming),
        );
        try {
          await lock.setLastModified(DateTime.now());
        } catch (_) {}
        debugPrint('[BloomSync] prepared photo item=${item.itemId}');
      } catch (error) {
        if (batchCurrent != null && item.itemId == batchCurrent.itemId) rethrow;
        // A broken future asset must not invalidate the current photo and all
        // previously prepared slots. The final partial schedule will request
        // another batch at its last usable entry.
        debugPrint(
          '[BloomSync] skipping future photo item=${item.itemId}: $error',
        );
      }
    }

    // ---- steps 4, 6, 7: append, submit the union, keep it bounded --------
    //
    // The page is *added* to the pool, never substituted for it, and the native
    // layer receives the whole union: `scheduleCarousel` overwrites what it
    // stores, so a submission of "just the new page" would silently drop every
    // slot that was already armed.
    final union = _mergePool(pool, incoming);
    final scheduled = _capPool(union, nowMillis);
    if (scheduled.isEmpty) throw StateError('没有任何可排程的槽位');

    // **The cursor is the largest id the pool actually holds** (step 2), not the
    // largest id fetched: a photo that timed out or was trimmed by the cap is
    // therefore asked for again on the next refill instead of being stepped over
    // for good. The one exception is a page that produced *nothing at all* — then
    // the cursor advances anyway, so one poisoned item cannot stall the day.
    var lastItemId = _maxItemId(scheduled);
    final fetchedMax = plan.items.fold<int>(
      0,
      (max, item) => item.itemId > max ? item.itemId : max,
    );
    if (incoming.isEmpty && fetchedMax > lastItemId) {
      lastItemId = fetchedMax;
      debugPrint(
        '[BloomSync] cursor advanced past a page that rendered nothing to=$lastItemId',
      );
    }

    var currentItemId = batchCurrent?.itemId ?? 0;
    Map<String, Object?>? publishEntry;
    var publishCurrent = false;
    if (currentManifest == null) {
      // **Step 5 — the current slot is not decided by the batch.**
      //
      // A pure refill page starts *after* the server's current item, so it
      // simply does not contain it. That is not an error: the due slot is read
      // back from the persisted pool, or from whatever the native layer already
      // shows. This is the exact case the previous attempt crashed on.
      Map<String, Object?>? dueEntry;
      for (final entry in scheduled) {
        if (_poolAt(entry) <= nowMillis) dueEntry = entry;
      }
      if (dueEntry != null) {
        final path = dueEntry['originalPhotoPath'] as String?;
        if (path == null || !await File(path).exists()) dueEntry = null;
      }
      final native = await WidgetBridge().readCurrentState();
      final nativeCarousel =
          native != null && (native.mode == null || native.mode == 'carousel')
          ? native
          : null;
      final duePoolId = dueEntry == null ? 0 : _poolItemId(dueEntry);
      final nativeId = nativeCarousel?.recommendationId ?? 0;
      if (nativeCarousel != null && nativeId > duePoolId) {
        // The native timeline moved on (an alarm fired while Flutter was not
        // running): it is newer than the pool, so it stays the current item.
        currentItemId = nativeId;
        currentManifest = _nativeManifest(nativeCarousel);
      } else if (dueEntry != null) {
        currentItemId = duePoolId;
        currentManifest = _manifestFromPoolEntry(dueEntry);
        publishEntry = dueEntry;
        // Catch the native share up when the alarm never ran (device off, widget
        // not installed) — but never roll it back to an older slot.
        publishCurrent = nativeId < duePoolId;
      } else if (nativeCarousel != null) {
        currentItemId = nativeId;
        currentManifest = _nativeManifest(nativeCarousel);
      } else {
        final cached = await cachedContent();
        if (cached != null) {
          currentManifest = cached;
          currentItemId = cached.recommendationId;
        }
      }
    }
    // The batch's own current slot was already published inside the loop, so the
    // only path that can still need a native write is the pool/native one above
    // (and the fresh-install fallback below).

    if (currentManifest == null && plan.items.isNotEmpty) {
      // Nothing due anywhere — a fresh install opened outside the active window,
      // where the server names tomorrow's first item as `current_item_id`. Show
      // that item rather than nothing, but do not push it over a photo that is
      // already on screen.
      final fallbackItem = plan.items.firstWhere(
        (item) => item.itemId == plan.currentItemId,
        orElse: () => plan.items.first,
      );
      currentItemId = fallbackItem.itemId;
      currentManifest = fallbackItem.asDailyContent();
      publishEntry = scheduled.firstWhere(
        (entry) => _poolItemId(entry) == currentItemId,
        orElse: () => const <String, Object?>{},
      );
      final native = await WidgetBridge().readCurrentState();
      publishCurrent = native == null || native.recommendationId < 1;
    }
    final resolvedManifest = currentManifest;
    if (resolvedManifest == null || currentItemId < 1) {
      throw StateError('当前轮播照片既不在计划批次中，也没有可用的本地副本');
    }

    // **The one place alarms come from.** Everything above can throw, and when
    // it does the `scheduleCarousel` below is skipped and *no* alarm is ever
    // armed — the widget then stops updating with no evidence anywhere. Measured
    // on device: three photos prepared, `dumpsys alarm` empty. So both the
    // decision and its outcome are logged, including the cases that used to fail
    // silently.
    //
    // `next_slot_at_ms` is the union's earliest future slot — the same number the
    // native alarm chain arms itself with, so an open page turns with the widget
    // instead of polling for it.
    final upcoming = scheduled
        .map(_poolAt)
        .where((at) => at > nowMillis)
        .toList()
      ..sort();
    final nextSlotMillis = upcoming.isEmpty ? null : upcoming.first;
    final nextSlotLabel = nextSlotMillis == null
        ? 'none'
        : '$nextSlotMillis '
              '(${DateTime.fromMillisecondsSinceEpoch(nextSlotMillis).toIso8601String()})';
    debugPrint(
      '[BloomSync] scheduling plan=${plan.planId} entries=${scheduled.length} '
      'current=$currentItemId batch_current=${batchCurrent?.itemId ?? 'none'} '
      'next_slot=$nextSlotLabel',
    );

    // `daily.json` is the Dart-side mirror of "what is on screen now". A pure
    // refill must not move it: the resolved current above is deliberately the due
    // slot, not the newest fetched one.
    await _writeDailyManifest(
      dir,
      manifest: resolvedManifest,
      itemId: currentItemId,
      planId: plan.planId,
      nextCheckAt: plan.nextCheckAt,
      nextSlotAtMillis: nextSlotMillis,
      etag: photoEtag[currentItemId],
    );

    if (publishCurrent) {
      final portraitPath = publishEntry?['portraitPath'] as String?;
      if (portraitPath != null && await File(portraitPath).exists()) {
        await WidgetBridge().update(
          portraitPath: portraitPath,
          squarePath:
              (publishEntry?['squarePath'] as String?) ?? portraitPath,
          largeSquarePath:
              (publishEntry?['largeSquarePath'] as String?) ?? portraitPath,
          originalPhotoPath: publishEntry?['originalPhotoPath'] as String?,
          date: resolvedManifest.date,
          recommendationId: currentItemId,
          captionZh: resolvedManifest.captionZh,
          captionEn: resolvedManifest.captionEn,
          capturedDateText: resolvedManifest.capturedDateText,
          locationText: resolvedManifest.locationText,
          mode: 'carousel',
        );
      }
    }

    // ---- the pool, on disk, where the next refill can find it -------------
    //
    // Step 1 of walking the day instead of replaying its first four photos: this
    // is what makes the union above possible at all. Before it, the scheduled
    // entries existed **only** in the native layer's SharedPreferences, and every
    // `scheduleCarousel` call overwrites that — so a refill had nothing to merge
    // with, which is the mechanical reason the old cursor attempt dropped slots.
    final poolFile = File('${dir.path}/carousel-pool.json');
    try {
      await poolFile.writeAsString(
        jsonEncode({
          'day': today,
          'plan_id': plan.planId,
          'current_item_id': currentItemId,
          'last_item_id': lastItemId,
          'entries': scheduled,
        }),
        flush: true,
      );
      debugPrint(
        '[BloomSync] pool saved: day=$today entries=${scheduled.length} '
        'current=$currentItemId last=$lastItemId fetched=${plan.items.length}',
      );
    } catch (error) {
      debugPrint('[BloomSync] pool save failed: $error');
    }
    await WidgetBridge().scheduleCarousel(
      planId: plan.planId,
      entries: scheduled,
    );
    debugPrint('[BloomSync] scheduled ${scheduled.length} slots ok');
    for (final family in _families) {
      await _pruneVersionedImages(
        dir,
        family,
        keeping: _versionedImage(dir, family, currentItemId).path,
      );
    }
    await _pruneCarouselOriginals(dir);
    return resolvedManifest;
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
    if (!await image.exists()) {
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
        captionZh: data['caption_zh'] as String?,
        captionEn: data['caption_en'] as String?,
        capturedDateText: data['captured_date_text'] as String?,
        locationText: data['location_text'] as String?,
        photoOrientation: data['photo_orientation'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  File _versionedImage(Directory dir, String family, int recommendationId) =>
      File('${dir.path}/mobile-local-$family-$recommendationId.png');

  // ---- the carousel pool ------------------------------------------------
  //
  // A slot is one `itemId` plus the four files and the caption that belong to
  // it. The pool is the list of slots this phone has prepared for one local day,
  // persisted next to the photos so a refill can merge with it (see
  // `_downloadAndScheduleCarouselPlan`).

  /// Pool size. Every entry needs one original and three rendered images on
  /// disk, and the pruners below keep **eight** of each — the cap and the
  /// pruners are deliberately the same number, so a slot is never deleted
  /// underneath the alarm that still points at it.
  static const _poolLimit = 8;
  static const _families = ['portrait', 'square', 'largeSquare'];

  String _dayKey(DateTime at) => at.toIso8601String().substring(0, 10);

  int _poolItemId(Map<String, Object?> entry) =>
      (entry['itemId'] as num?)?.toInt() ?? 0;

  int _poolAt(Map<String, Object?> entry) =>
      (entry['displayAtMillis'] as num?)?.toInt() ?? 0;

  int _maxItemId(Iterable<Map<String, Object?>> entries) {
    var max = 0;
    for (final entry in entries) {
      final id = _poolItemId(entry);
      if (id > max) max = id;
    }
    return max;
  }

  Map<String, Object?> _poolEntry(
    CarouselItemContent item,
    DailyContent manifest,
    Map<String, String> paths,
    String originalPath,
  ) => {
    'itemId': item.itemId,
    'displayAtMillis': item.displayAt.toLocal().millisecondsSinceEpoch,
    'date': manifest.date,
    'portraitPath': paths['portrait'],
    'squarePath': paths['square'],
    'largeSquarePath': paths['largeSquare'],
    'originalPhotoPath': originalPath,
    'captionZh': manifest.captionZh,
    'captionEn': manifest.captionEn,
    'capturedDateText': manifest.capturedDateText,
    'locationText': manifest.locationText,
  };

  /// Appends [incoming] to [existing]. The incoming copy of an id wins (it was
  /// just re-rendered), and the result is ordered by slot time so the native
  /// layer always receives a chronological timeline.
  List<Map<String, Object?>> _mergePool(
    List<Map<String, Object?>> existing,
    List<Map<String, Object?>> incoming,
  ) {
    final byId = <int, Map<String, Object?>>{};
    for (final entry in [...existing, ...incoming]) {
      final id = _poolItemId(entry);
      if (id > 0) byId[id] = entry;
    }
    return byId.values.toList()
      ..sort((a, b) => _poolAt(a).compareTo(_poolAt(b)));
  }

  /// **Step 7 — keep the pool bounded.**
  ///
  /// The current slot, the one before it, and the run of future slots that fits
  /// inside [limit] are all the widget can still use. Anything older can never
  /// be shown again, and anything further ahead is fetched again by a later
  /// refill — so dropping it keeps the list, the alarms and the image files the
  /// same size.
  List<Map<String, Object?>> _capPool(
    List<Map<String, Object?>> entries,
    int nowMillis, {
    int limit = _poolLimit,
  }) {
    if (entries.length <= limit) return entries;
    var currentIndex = entries.lastIndexWhere((entry) => _poolAt(entry) <= nowMillis);
    if (currentIndex < 0) currentIndex = 0;
    final start = (currentIndex - 1).clamp(0, entries.length - limit).toInt();
    return entries.sublist(start, start + limit);
  }

  DailyContent _manifestFromPoolEntry(Map<String, Object?> entry) =>
      DailyContent(
        date: entry['date'] as String? ?? '',
        recommendationId: _poolItemId(entry),
        captionZh: entry['captionZh'] as String?,
        captionEn: entry['captionEn'] as String?,
        capturedDateText: entry['capturedDateText'] as String?,
        locationText: entry['locationText'] as String?,
      );

  DailyContent _nativeManifest(WidgetCurrentState state) => DailyContent(
    date: state.date ?? '',
    recommendationId: state.recommendationId,
    captionZh: state.captionZh,
    captionEn: state.captionEn,
    capturedDateText: state.capturedDateText,
    locationText: state.locationText,
  );

  /// Writes the one `daily.json` a run produces.
  ///
  /// It is written **once**, after the current slot has been resolved, so
  /// `next_slot_at_ms` describes the union that was actually scheduled rather
  /// than the single page that happened to be fetched.
  Future<void> _writeDailyManifest(
    Directory dir, {
    required DailyContent manifest,
    required int itemId,
    required int planId,
    required DateTime nextCheckAt,
    required int? nextSlotAtMillis,
    String? etag,
  }) async {
    await File('${dir.path}/daily.json').writeAsString(
      jsonEncode({
        'mode': 'carousel',
        'photo_etag': etag,
        'date': manifest.date,
        'recommendation_id': manifest.recommendationId,
        'carousel_item_id': itemId,
        'carousel_plan_id': planId,
        'next_check_at': nextCheckAt.toIso8601String(),
        // **Turn the page at the right moment.** The earliest slot in the union
        // that has not passed yet is the same number the native alarm chain arms
        // itself with, so the foreground can wake once for that instant instead
        // of polling.
        'next_slot_at_ms': nextSlotAtMillis,
        'caption_zh': manifest.captionZh,
        'caption_en': manifest.captionEn,
        'captured_date_text': manifest.capturedDateText,
        'location_text': manifest.locationText,
        'photo_orientation': manifest.photoOrientation,
      }),
      flush: true,
    );
  }

  /// Reads the persisted pool. A missing, unreadable or malformed file is simply
  /// an empty pool — never an exception on the sync path.
  Future<_CarouselPool?> _readPool(Directory dir) async {
    final file = File('${dir.path}/carousel-pool.json');
    if (!await file.exists()) return null;
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final day = data['day'] as String?;
      final rawEntries = data['entries'];
      if (day == null || rawEntries is! List) return null;
      return _CarouselPool(
        day: day,
        lastItemId: (data['last_item_id'] as num?)?.toInt() ?? 0,
        entries: [
          for (final raw in rawEntries)
            if (raw is Map) Map<String, Object?>.from(raw),
        ],
      );
    } catch (error) {
      debugPrint('[BloomSync] pool read failed: $error');
      return null;
    }
  }

  /// **The next moment the page has something new to show.**
  ///
  /// Written by every sync (`next_slot_at_ms` in `daily.json`) and read here so
  /// the foreground can arm one timer for that instant instead of asking the
  /// cache every 30 seconds whether anything changed. Null when the day's slots
  /// are exhausted or the file is unreadable — the caller then simply leaves the
  /// existing behaviour alone rather than guessing a time.
  Future<int?> nextSlotAtMillis() async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/daily.json');
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (raw['next_slot_at_ms'] as num?)?.toInt();
    } catch (error) {
      debugPrint('[BloomSync] next slot unavailable: $error');
      return null;
    }
  }

  Future<void> _pruneCarouselOriginals(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('carousel-original-') &&
          entity.path.endsWith('.photo')) {
        files.add(entity);
      }
    }
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    for (final file in files.skip(8)) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _pruneVersionedImages(
    Directory dir,
    String family, {
    required String keeping,
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
    // Keep the current item plus a complete four-item prefetched timeline and
    // a few fallbacks. Android can then switch locally without waking Flutter.
    for (final file in candidates.skip(8)) {
      if (file.path == keeping) continue;
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
class _CarouselPool {
  const _CarouselPool({
    required this.day,
    required this.lastItemId,
    required this.entries,
  });

  /// Local day (`yyyy-MM-dd`) the entries belong to. A different day means the
  /// cursor restarts from the top of the stream.
  final String day;

  /// Largest `itemId` the pool held when it was written — the next refill's
  /// `after_item_id` anchor.
  final int lastItemId;

  final List<Map<String, Object?>> entries;
}
