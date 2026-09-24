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
      await _pruneVersionedImages(dir, family, keeping: {output.path});
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
    bool foreground = false,
  }) async {
    if (!next) {
      return _syncCarouselPlan(
        credentials,
        settings,
        foreground: foreground,
      );
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
    // Version the original too, so the manual "next" item gets an immutable path
    // of its own (see `photoPathFor`) instead of being reachable only through the
    // mutable `original.photo`.
    try {
      await photoFile.copy(
        '${dir.path}/carousel-original-${envelope.item.itemId}.photo',
      );
    } catch (_) {}
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
      await _pruneVersionedImages(dir, family, keeping: {output.path});
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
    BloomDisplaySettings settings, {
    bool foreground = false,
  }) async {
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
      // **The foreground waits briefly and then shows what it has; the
      // background waits the full window and then fails.** The foreground's job
      // is to put the right photo on screen now — blocking the page for the old
      // 90 s and then throwing "正在显示上一张" is what made a slot look like it
      // never changed. WorkManager, by contrast, *must* fail so it retries
      // instead of reporting a success it did not earn.
      final attempts = foreground ? 12 : 180;
      for (var attempt = 0; attempt < attempts && await lock.exists(); attempt++) {
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
        return _syncCarouselPlan(
          credentials,
          settings,
          foreground: foreground,
        );
      }
      // The other task did not finish within the wait window. Returning the
      // previous cache here reports SUCCESS to WorkManager even though no new
      // plan was downloaded, so the stale lock can leave the widget frozen
      // indefinitely. Fail this attempt and let WorkManager retry; a later
      // attempt will either observe the real owner finishing or remove the
      // lock once it passes the stale threshold above.
      if (await lock.exists()) {
        if (foreground) {
          // Another engine (the widget's background task) is mid-sync. Hand back
          // the last complete state instead of an error: the native side may
          // already have advanced to the due slot, and the card stays whole
          // either way. No message — nothing actually went wrong for the reader.
          final cached = await cachedContent();
          if (cached != null) return cached;
        }
        // **The open page never fails on the lock.** WorkManager has to fail so it
        // retries, but the foreground only has to show what it has: throwing here is
        // what produced the failure toast and left the card on the previous slot
        // while the background was still downloading (measured on iOS: the widget
        // advanced, the in-app card did not until the app was relaunched).
        if (foreground) {
          // **Do not go quiet.** Handing back what we have keeps the page
          // responsive, but the slot still has to advance: measured on iOS, the
          // widget moved on while the in-app card stayed on the old photo — with no
          // error and, worse, no retry, because the failure had been silenced. One
          // short self-retry closes that gap and touches nothing else: if the lock
          // is still held the retry lands here again, and once the background sync
          // finishes it goes through and the card catches up.
          _scheduleForegroundRetry(credentials, settings);
          final cached = await cachedContent();
          if (cached != null) return cached;
          final native = await WidgetBridge().readCurrentState();
          if (native != null) return _nativeManifest(native);
        }
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
    final storedEntries = <Map<String, Object?>>[
      if (storedPool != null && storedPool.day == today) ...storedPool.entries,
    ];
    // **A pool entry whose photo is gone must not pin the cursor.**
    //
    // Pruning (or a crash between the render and the write) can leave entries
    // that can never be shown again. Keeping them is unrecoverable: the cursor
    // sits *past* them, so the missing slots are never requested again and the
    // day freezes on the last photo that still exists. Dropping them recomputes
    // the anchor, and a request without a cursor always returns the page that
    // starts at the slot which is due *now* — the app then re-renders it and
    // publishes it in the same pass. Measured before this check: at 08:30 the
    // server said `current=3271`, the pool held 3271, its file had been pruned,
    // and the app stayed on the 08:15 photo.
    final pool = <Map<String, Object?>>[];
    for (final entry in storedEntries) {
      final path = entry['originalPhotoPath'] as String?;
      if (path == null || await File(path).exists()) pool.add(entry);
    }
    if (pool.length != storedEntries.length) {
      debugPrint(
        '[BloomSync] dropped ${storedEntries.length - pool.length} pool '
        'entries whose photo file is gone; the walk restarts from the current '
        'slot',
      );
    }
    // **Step 2 — the refill anchor.** The largest id the pool actually holds,
    // i.e. the last page boundary this phone prepared. A page that failed to
    // render never entered the pool, so it is asked for again instead of being
    // silently stepped over. It is per local day: a new day starts from the top.
    var cursor = _maxItemId(pool);
    var plan = await api.carouselPlan(
      credentials,
      settings,
      afterItemId: cursor > 0 ? cursor : null,
    );
    // **The label must not wait for anything.** "下次更新" is a property of the slot
    // grid, not of the photos: a failed download swaps the *picture*, the *time*
    // never moves. So the plan response is enough — the earliest slot still in the
    // future if the page carries one, otherwise the slot the page is anchored at
    // plus one interval. No reliance on the download loop, on the pool, or on any
    // "future entry" being prepared.
    final nowForLabel = DateTime.now().millisecondsSinceEpoch;
    final futureFromPlan = plan.items
        .map((item) => item.displayAt.toLocal().millisecondsSinceEpoch)
        .where((at) => at > nowForLabel)
        .toList()
      ..sort();
    var labelMillis = futureFromPlan.isEmpty ? null : futureFromPlan.first;
    if (labelMillis == null) {
      final anchorFromPage = plan.items
          .map((item) => item.displayAt.toLocal().millisecondsSinceEpoch)
          .where((at) => at <= nowForLabel)
          .toList()
        ..sort();
      final anchor = anchorFromPage.isEmpty
          ? pool
                .map(_poolAt)
                .where((at) => at <= nowForLabel)
                .fold<int?>(null, (best, at) => best == null || at > best ? at : best)
          : anchorFromPage.last;
      if (anchor != null) {
        final step = Duration(minutes: settings.intervalMinutes > 0 ? settings.intervalMinutes : 15);
        labelMillis = anchor + step.inMilliseconds;
      }
    }
    if (labelMillis != null) {
      await _publishNextSlotAt(dir, labelMillis);
    } else {
      debugPrint('[BloomSync] no next_slot known from the plan response');
    }


    debugPrint(
      '[BloomSync] carousel plan=${plan.planId} items=${plan.items.length} '
      'current=${plan.currentItemId} after=${cursor > 0 ? cursor : 'none'} '
      'pool=${pool.length}',
    );
    // ---- **a cursor the server no longer knows is answered with NOTHING** --
    //
    // `_carousel_plan_response` sets `start_index = len(items)` when the id is
    // not found in the plan, so a stale cursor comes back as an *empty batch* —
    // not as an error. Left alone that is a permanent stall: the anchor never
    // moves, every later refill re-sends the same dead id, and the pool can
    // never grow again. It happens whenever the day's plan is rebuilt underneath
    // the pool: a settings change (interval / window), a mode switch, or a sync
    // during the server's 15-minute post-window grace, when it still serves
    // yesterday's plan.
    //
    // The recovery is to drop the stale pool and ask from the top, which is what
    // a fresh install does. The test is "the server's current item is not
    // something we already hold": at a genuine end-of-day the current item *is*
    // the pool's last entry, so the normal exhausted path is left untouched and
    // does not spin.
    if (cursor > 0 &&
        plan.items.isEmpty &&
        !pool.any((entry) => _poolItemId(entry) == plan.currentItemId)) {
      debugPrint(
        '[BloomSync] cursor $cursor is not in plan ${plan.planId} '
        '(pool plan=${storedPool?.planId}, empty batch, '
        'current=${plan.currentItemId}); restarting the walk',
      );
      pool.clear();
      cursor = 0;
      plan = await api.carouselPlan(credentials, settings);
      debugPrint(
        '[BloomSync] restarted plan=${plan.planId} items=${plan.items.length} '
        'current=${plan.currentItemId} pool=${pool.length}',
      );
    }
    if (plan.items.isEmpty && pool.isEmpty) throw StateError('轮播计划为空');

    // ---- **and the union must contain the slot that is due now** ----------
    //
    // Same accident, other face: the pool can end up holding only *future* slots
    // while the one that should be on screen has no file left. The walk then
    // never asks for it again — the cursor is past it — so `dueEntry` stays null
    // and the page keeps the previous photo until the pool's own window slides
    // forward. Measured on the device after installing the pruning fix: the
    // current slot was 3275, the pool held only 10:30 and later, and the photo
    // would have stayed on the morning's first shot for another 45 minutes.
    //
    // A request without a cursor returns the page that *starts* at the current
    // slot, so one extra call repairs exactly that, and the slot is re-rendered
    // and published in this same pass instead of at the next one.
    // **The pool must not merely hold *a* due entry; it must hold the one due
    // now.** With a cursor the page starts *after* the pool, so when a slot's
    // photo timed out and its entry was dropped, the pool's newest due entry
    // stayed on the previous slot and the page never even mentioned the current
    // one — measured at 15:00: page [3305…], newest due 14:45, and opening the app
    // still showed 14:45. Item ids ascend with time within a plan, so comparing
    // against the server's own `current_item_id` is the sharp test; the cursorless
    // page it triggers starts exactly at the current slot.
    final newestPoolDue = pool
        .where((entry) => _poolAt(entry) <= nowMillis)
        .map(_poolItemId)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final pageHasDue = plan.items.any(
      (item) => !item.displayAt.toLocal().isAfter(now.add(const Duration(seconds: 60))),
    );
    if (cursor > 0 &&
        !pageHasDue &&
        plan.currentItemId > 0 &&
        newestPoolDue < plan.currentItemId) {
      debugPrint(
        '[BloomSync] nothing due in the pool or the page (plan=${plan.planId}, '
        'current=${plan.currentItemId}); re-reading from the current slot',
      );
      plan = await api.carouselPlan(credentials, settings);
      debugPrint(
        '[BloomSync] re-read plan=${plan.planId} items=${plan.items.length} '
        'current=${plan.currentItemId}',
      );
    }

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
    // A due slot that cannot be prepared must not take the whole refill down with
    // it. It is flagged here and in the render loop, and reported *after* the
    // union has been submitted — because that submission is also what re-arms the
    // native refill alarm, and the caller's 2-minute retry is useless without it.
    var batchCurrentFailed = false;
    if (batchCurrent != null) {
      try {
        await fetchPhoto(
          batchCurrent.itemId,
          timeout: const Duration(seconds: 30),
        );
        debugPrint(
          '[BloomSync] current photo item=${batchCurrent.itemId} ready in '
          '${prefetchWatch.elapsedMilliseconds}ms',
        );
      } catch (error) {
        batchCurrentFailed = true;
        debugPrint(
          '[BloomSync] current photo item=${batchCurrent.itemId} failed: $error',
        );
      }
    }
    // **Sequential, not four-at-once.** These are large photos and the phone has
    // one connection: kicking all four off together is what blew the 25s leash
    // (`skipping future photo ... TimeoutException after 0:00:25`) and, through
    // the old "drop the slot" path, made a 15-minute cadence look like 30 or 45.
    // The current slot is fetched above and keeps its own generous leash; the rest
    // are fetched by the render loop one at a time, each with the whole link.
    //
    // (Nothing to pre-start here: the loop below awaits each item in order, so the
    // downloads happen in the same order — just without competing for bandwidth.)
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
        if (batchCurrent != null && item.itemId == batchCurrent.itemId) {
          // The slot that should be on screen now could not be prepared. Do not
          // `rethrow`: that skips the submission below, so the native chain loses
          // the very refill that could have recovered it. Flag it, let the union
          // go out, and report the failure at the end of the method.
          //
          // The cursor deliberately does *not* hold a place for it either. A
          // permanently broken asset would then be asked for forever and the pool
          // would never grow past it; one skipped slot beats a stalled day, and
          // the caller's retry still re-requests it whenever it is the page head.
          batchCurrentFailed = true;
          // **Keep its slot too.** This is the branch that swallowed the slot the
          // label was about to name: at 20:45 the current slot (21:00) failed to
          // prepare, its entry was dropped, and `next_slot` jumped straight to
          // 21:15 — the quarter hour simply disappeared from the timeline, and the
          // widget had no new photo to move to. The *cursor* still does not hold a
          // place (a permanently broken asset must not stall the day), but the
          // slot stays in the union with the paths it will have.
          incoming.add(
            _poolEntry(
              item,
              item.asDailyContent(),
              {
                for (final family in _families)
                  family: _versionedImage(dir, family, item.itemId).path,
              },
              '${dir.path}/carousel-original-${item.itemId}.photo',
            ),
          );
          debugPrint(
            '[BloomSync] current photo item=${item.itemId} failed: $error',
          );
          continue;
        }
        // **A late photo must not delete its slot.** Dropping the item here is
        // what left the union with no future entry at all: measured on device at
        // 20:12 with `fetched=4`, the pool's newest item was the *current* one, so
        // `next_slot` came out `none` (the "下次更新" line had nothing to say, and
        // the skeleton had nothing to hold) and the widget had nothing to advance
        // to — the same few photos came round again. The cadence is the grid; only
        // the picture may be late. The slot goes into the union with the paths it
        // will have, and the native side keeps the current photo on the wall until
        // the file really exists.
        incoming.add(
          _poolEntry(
            item,
            item.asDailyContent(),
            {
              for (final family in _families)
                family: _versionedImage(dir, family, item.itemId).path,
            },
            '${dir.path}/carousel-original-${item.itemId}.photo',
          ),
        );
        debugPrint(
          '[BloomSync] future photo item=${item.itemId} not ready yet: $error',
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
    // An empty union is no longer fatal *here*. `scheduleCarousel` with no entries
    // still arms the native recovery alarm, so throwing at this point would leave
    // the widget with no alarm at all — the one failure that cannot be recovered
    // from without opening the app. It is reported after the submission instead.

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
    // Set when this slot's own photo was missing and the next ready photo was
    // pulled into its place. That is a *handled* slot, not a failed one.
    var pulledForward = false;
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
      // A slot is due when its time has come — its photo being absent does not
      // change that. Before the window's first slot (or after its last) nothing is
      // due, and a future photo must not be pulled in early.
      var slotIsDue = dueEntry != null;
      final serverSaysDue = plan.items.any(
        (item) =>
            item.itemId == plan.currentItemId &&
            !item.displayAt.toLocal().isAfter(now.add(const Duration(seconds: 60))),
      );
      if (dueEntry != null) {
        final path = dueEntry['originalPhotoPath'] as String?;
        if (path == null || !await File(path).exists()) dueEntry = null;
      }
      // **If this slot's photo is not here yet, the next one takes its place.**
      // The grid does not move — 15:00 stays 15:00 — so the only way to keep a
      // *fresh* photo in every slot (not a skip, and not the previous slot's
      // picture held over) is to shift the pictures forward: the entry that would
      // have been shown next is pulled into this slot. `cachedContent()` is the id
      // already on screen, so a pulled-forward entry is not shown a second time
      // when its own slot comes around.
      if (dueEntry == null && (slotIsDue || serverSaysDue)) {
        final shownId = (await cachedContent())?.recommendationId ?? 0;
        for (final entry in scheduled) {
          final id = _poolItemId(entry);
          if (id <= shownId) continue;
          final path = entry['originalPhotoPath'] as String?;
          if (path != null && await File(path).exists()) {
            dueEntry = entry;
            pulledForward = true;
            debugPrint(
              '[BloomSync] this slot has no photo yet; pulling item=$id forward '
              '(already shown $shownId)',
            );
            break;
          }
        }
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
    var resolvedManifest = currentManifest;
    if (resolvedManifest == null || currentItemId < 1) {
      // Last look before giving up: the mirror on disk already names a current
      // photo, and keeping it is strictly better than failing the whole refill.
      final cached = await cachedContent();
      if (cached != null && cached.recommendationId > 0) {
        resolvedManifest = cached;
        currentItemId = cached.recommendationId;
      }
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
    // **`next_slot_at_ms` is the plan's next slot, not the next *prepared* one.**
    // When a future photo times out — the server can take longer than the 25s
    // leash — that slot used to vanish from the union, and with it its alarm and
    // the page's own wake-up. Measured on device: 15:00 and 15:15 disappeared and
    // the next update was announced as 15:30, so both were skipped. The batch
    // knows those times whether or not the photo arrived, so it is asked too; a
    // slot whose photo is still missing is simply retried when its turn comes.
    final upcoming = <int>{
      ...scheduled.map(_poolAt),
      for (final item in plan.items)
        item.displayAt.toLocal().millisecondsSinceEpoch,
    }.where((at) => at > nowMillis).toList()
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

    var currentReady = resolvedManifest;
    if (currentReady != null && currentItemId > 0) {
      // `daily.json` is the Dart-side mirror of "what is on screen now". A pure
      // refill must not move it: the resolved current above is deliberately the
      // due slot, not the newest fetched one.
      await _writeDailyManifest(
        dir,
        manifest: currentReady,
        itemId: currentItemId,
        planId: plan.planId,
        nextCheckAt: plan.nextCheckAt,
        nextSlotAtMillis: nextSlotMillis,
        etag: photoEtag[currentItemId],
      );

      if (publishCurrent) {
        // **Materialise the app's own copy too.** `original.photo` is what the
        // photo page falls back to when the native state is stale or its file is
        // gone, and only the in-batch publish below used to write it. With the
        // cursor in use the fetched page starts *after* the current, so
        // `batchCurrent` is normally null and that copy was never refreshed — the
        // page sat on the first photo of the day. Same bytes: a copy, not a
        // re-render.
        final originalPath = publishEntry?['originalPhotoPath'] as String?;
        if (originalPath != null && await File(originalPath).exists()) {
          final target = File('${dir.path}/original.photo');
          final temp = File('${target.path}.tmp');
          await temp.writeAsBytes(
            await File(originalPath).readAsBytes(),
            flush: true,
          );
          await temp.rename(target.path);
        }
        final portraitPath = publishEntry?['portraitPath'] as String?;
        if (portraitPath != null && await File(portraitPath).exists()) {
          await WidgetBridge().update(
            portraitPath: portraitPath,
            squarePath:
                (publishEntry?['squarePath'] as String?) ?? portraitPath,
            largeSquarePath:
                (publishEntry?['largeSquarePath'] as String?) ?? portraitPath,
            originalPhotoPath: publishEntry?['originalPhotoPath'] as String?,
            date: currentReady.date,
            recommendationId: currentItemId,
            captionZh: currentReady.captionZh,
            captionEn: currentReady.captionEn,
            capturedDateText: currentReady.capturedDateText,
            locationText: currentReady.locationText,
            mode: 'carousel',
          );
        }
      }
    } else {
      debugPrint(
        '[BloomSync] no current slot could be named; the union is still '
        'submitted so the native refill alarm survives',
      );
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
    // **Submitted even when no current slot could be named.** This call is also
    // what re-arms the native refill alarm, so skipping it would freeze the
    // widget *and* remove the only thing that could have woken it up again — a
    // failure that outlives itself. The Dart-side failure is still reported
    // below (and the foreground arms its 2-minute retry), but the alarm chain
    // survives either way.
    await WidgetBridge().scheduleCarousel(
      planId: plan.planId,
      entries: scheduled,
    );
    debugPrint('[BloomSync] scheduled ${scheduled.length} slots ok');
    // **Prune by reference, not by age.** Everything the pool or the item on
    // screen still points at has to survive: deleting one makes the next slot
    // unresolvable, and the app then silently keeps showing the previous photo.
    final referencedImages = <String>{
      for (final family in _families)
        _versionedImage(dir, family, currentItemId).path,
      for (final entry in scheduled)
        for (final family in _families) entry['${family}Path'] as String? ?? '',
    }..removeWhere((path) => path.isEmpty);
    final referencedOriginals = <String>{
      for (final entry in scheduled) entry['originalPhotoPath'] as String? ?? '',
    }..removeWhere((path) => path.isEmpty);
    for (final family in _families) {
      await _pruneVersionedImages(dir, family, keeping: referencedImages);
    }
    await _pruneCarouselOriginals(dir, keeping: referencedOriginals);
    await _sweepTempFiles(dir);
    // ---- everything below is reported *after* the alarm chain was re-armed ----
    if (scheduled.isEmpty) {
      // A whole page that failed to prepare and no pool to fall back on: fail so
      // the caller retries in two minutes rather than at the next slot.
      throw StateError('本轮没有任何可排程的槽位，等待重试');
    }
    if (currentReady == null || currentItemId < 1) {
      throw StateError('当前轮播照片既不在计划批次中，也没有可用的本地副本');
    }
    if (batchCurrentFailed && !pulledForward) {
      // The schedule is already submitted, so the alarm chain survives this; the
      // failure only asks the caller to try again sooner than the next slot.
      //
      // Not thrown when a photo was pulled forward: the slot did get a fresh
      // picture, which is the whole point of the shift, so there is nothing for
      // the caller to retry.
      throw StateError('当前轮播照片未能准备，已保留原照片并重排闹钟');
    }
    // **The native is the single authority for what is on screen.**
    //
    // The widget and the app used to decide independently — each with its own rule
    // and its own inputs — which is exactly how a phone ended up showing two
    // different photos (measured: the widget advanced at 22:00 while the in-app
    // card stayed on the previous slot). The app's job is to *publish* the plan and
    // the photos; what it draws is then whatever the native holds, as long as that
    // item really has a photo on disk. From here the two cannot disagree.
    final nativeNow = await WidgetBridge().readCurrentState();
    final nativeNowId = nativeNow?.recommendationId ?? 0;
    if (nativeNow != null && nativeNowId > 0 && nativeNowId != currentItemId) {
      if (await photoPathFor(nativeNowId) != null) {
        // `_nativeManifest` is total: it always yields a usable manifest.
        debugPrint(
          '[BloomSync] app follows native item=$nativeNowId '
          '(own resolution was $currentItemId)',
        );
        currentItemId = nativeNowId;
        currentReady = _nativeManifest(nativeNow);
      }
    }
    return currentReady;
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
    // The mutable file is only trustworthy while the mirror next to it still
    // names the same item.
    if ((await cachedContent())?.recommendationId == itemId) {
      final mutable = File('${dir.path}/original.photo');
      if (await mutable.exists()) return mutable.path;
    }
    final portrait = _versionedImage(dir, 'portrait', itemId);
    if (await portrait.exists()) return portrait.path;
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
        planId: (data['plan_id'] as num?)?.toInt() ?? 0,
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

  /// One short retry after a foreground sync could not take the lock. Bounded by
  /// construction: the retry re-enters the same guard, so it can only be pending
  /// while a sync is actually in flight.
  void _scheduleForegroundRetry(
    DeviceCredentials credentials,
    BloomDisplaySettings settings,
  ) {
    if (_foregroundRetryPending) return;
    _foregroundRetryPending = true;
    unawaited(
      Future<void>.delayed(const Duration(seconds: 5), () async {
        _foregroundRetryPending = false;
        try {
          await syncCarousel(credentials, settings, foreground: true);
        } catch (_) {}
      }),
    );
  }

  bool _foregroundRetryPending = false;


  /// Writes only `next_slot_at_ms` into the Dart-side mirror, leaving every other
  /// field alone. Used as soon as the plan's slot times are known so the label is
  /// decoupled from the photo downloads; the end-of-run write repeats the same
  /// value, so running this early is idempotent.
  Future<void> _publishNextSlotAt(Directory dir, int atMillis) async {
    final file = File('${dir.path}/daily.json');
    try {
      // A missing mirror is not a reason to stay silent: this runs *before* the
      // photos are fetched, which on a cold start is exactly when the file has not
      // been written yet. The end-of-run write replaces it wholesale a moment later.
      final raw = <String, Object?>{};
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, Object?>) raw.addAll(decoded);
      }
      if (raw['next_slot_at_ms'] == atMillis) {
        debugPrint('[BloomSync] next_slot already published = $atMillis');
        return;
      }
      raw['next_slot_at_ms'] = atMillis;
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(raw), flush: true);
      await temp.rename(file.path);
      debugPrint('[BloomSync] next_slot published with the plan = $atMillis');
    } catch (error) {
      debugPrint('[BloomSync] early next_slot write skipped: $error');
    }
  }


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

  /// Deletes carousel originals that nothing points at any more.
  ///
  /// **`keeping` is not an optimisation, it is the bug fix.** This used to keep
  /// the eight most recently *written* files and delete the rest, and the pool
  /// fetch-then-trim cycle keeps writing files the pool then drops — so the
  /// newest eight were exactly the ones nobody needed, and the file for the slot
  /// that was about to come due got deleted. Measured on the device: at 08:30 the
  /// server said `current=3271`, the pool held 3271, and the resolved current was
  /// still 3270 because `carousel-original-3271.photo` had been pruned — the app
  /// sat on the 08:15 photo. Nothing referenced is deleted now.
  Future<void> _pruneCarouselOriginals(
    Directory dir, {
    required Set<String> keeping,
  }) async {
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
    var spares = 0;
    for (final file in files) {
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
class _CarouselPool {
  const _CarouselPool({
    required this.day,
    required this.planId,
    required this.lastItemId,
    required this.entries,
  });

  /// Local day (`yyyy-MM-dd`) the entries belong to. A different day means the
  /// cursor restarts from the top of the stream.
  final String day;

  /// `plan_id` the entries were built from. The server answers a cursor that is
  /// not in the *current* plan with an empty batch, so this is what tells a
  /// rebuilt plan (settings change, mode switch) apart in the logs.
  final int planId;

  /// Largest `itemId` the pool held when it was written — the next refill's
  /// `after_item_id` anchor.
  final int lastItemId;

  final List<Map<String, Object?>> entries;
}
