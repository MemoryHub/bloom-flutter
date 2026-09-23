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
    // **The day-walking cursor is not wired up yet.**
    //
    // `carousel/plan` accepts `after_item_id` and the app stores a per-day
    // `last_item_id` next to the photos — but feeding it in skipped the item the
    // server calls "current", and the scheduling below requires the current item
    // to be inside the batch it just fetched. The sync then threw
    // `Bad state: 当前轮播照片不在计划批次中` on every attempt, forever, and a
    // fresh install showed no photo at all.
    //
    // Repeating a few photos is a much smaller sin than a widget that never
    // updates, so the fetch stays cursor-less until the *reconciliation* is
    // taught that a refill batch is purely additive: keep the plan's current
    // item and append the new ones to the pool.
    final plan = await api.carouselPlan(credentials, settings);
    if (plan.items.isEmpty) throw StateError('轮播计划为空');

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

    final prefetchWatch = Stopwatch()..start();
    if (plan.items.any((item) => item.itemId == plan.currentItemId)) {
      await fetchPhoto(
        plan.currentItemId,
        timeout: const Duration(seconds: 30),
      );
      debugPrint(
        '[BloomSync] current photo item=${plan.currentItemId} ready in '
        '${prefetchWatch.elapsedMilliseconds}ms',
      );
    }
    for (final item in plan.items) {
      if (item.itemId == plan.currentItemId) continue;
      // Deliberately not awaited: they download while the loop renders.
      unawaited(fetchPhoto(item.itemId).catchError((Object _) {}));
    }
    debugPrint(
      '[BloomSync] carousel plan=${plan.planId} items=${plan.items.length} '
      'current=${plan.currentItemId}',
    );
    final scheduledEntries = <Map<String, Object?>>[];
    DailyContent? currentManifest;
    Uint8List? currentPhotoBytes;

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
        String? itemEtag;
        if (await original.exists()) {
          photoBytes = await original.readAsBytes();
          debugPrint('[BloomSync] reusing cached photo item=${item.itemId}');
        } else {
          // Never fetch here: the shared table owns that, so a photo being
          // downloaded in the background cannot be written twice.
          debugPrint('[BloomSync] waiting for photo item=${item.itemId}');
          await fetchPhoto(item.itemId);
          photoBytes = await original.readAsBytes();
          itemEtag = photoEtag[item.itemId];
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
        scheduledEntries.add({
          'itemId': item.itemId,
          'displayAtMillis': item.displayAt.toLocal().millisecondsSinceEpoch,
          'date': manifest.date,
          'portraitPath': paths['portrait']!,
          'squarePath': paths['square']!,
          'largeSquarePath': paths['largeSquare']!,
          'originalPhotoPath': originalPath,
          'captionZh': manifest.captionZh,
          'captionEn': manifest.captionEn,
          'capturedDateText': manifest.capturedDateText,
          'locationText': manifest.locationText,
        });
        if (item.itemId == plan.currentItemId) {
          currentManifest = manifest;
          currentPhotoBytes = photoBytes;
          final photoFile = File('${dir.path}/original.photo');
          final photoTemp = File('${photoFile.path}.tmp');
          await photoTemp.writeAsBytes(photoBytes, flush: true);
          await photoTemp.rename(photoFile.path);
          await File('${dir.path}/daily.json').writeAsString(
            jsonEncode({
              'mode': 'carousel',
              'photo_etag': itemEtag,
              'date': manifest.date,
              'recommendation_id': manifest.recommendationId,
              'carousel_item_id': plan.currentItemId,
              'carousel_plan_id': plan.planId,
              'next_check_at': plan.nextCheckAt.toIso8601String(),
              'caption_zh': manifest.captionZh,
              'caption_en': manifest.captionEn,
              'captured_date_text': manifest.capturedDateText,
              'location_text': manifest.locationText,
              'photo_orientation': manifest.photoOrientation,
            }),
            flush: true,
          );
          // Publish the current item immediately. If a later prefetch item is
          // slow, the widget still advances instead of discarding the batch.
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
        // later timeout can resume from cache without losing earlier work.
        await WidgetBridge().scheduleCarousel(
          planId: plan.planId,
          entries: scheduledEntries,
        );
        try {
          await lock.setLastModified(DateTime.now());
        } catch (_) {}
        debugPrint('[BloomSync] prepared photo item=${item.itemId}');
      } catch (error) {
        if (item.itemId == plan.currentItemId) rethrow;
        // A broken future asset must not invalidate the current photo and all
        // previously prepared slots. The final partial schedule will request
        // another batch at its last usable entry.
        debugPrint(
          '[BloomSync] skipping future photo item=${item.itemId}: $error',
        );
      }
    }

    final manifest = currentManifest;
    // **The one place alarms come from.** Everything above can throw, and when
    // it does this call is skipped and *no* alarm is ever armed — the widget then
    // stops updating with no evidence anywhere. Measured on device: three photos
    // prepared, `dumpsys alarm` empty. So both the decision and its outcome are
    // logged, including the cases that used to fail silently.
    // The slot the page should wake up for. `displayAtMillis` is already on
    // every entry, and the native layer derives its alarms from exactly this
    // number — so the same value is what a foreground "wake exactly at the next
    // slot" timer needs, instead of the poll that had to be rolled back.
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final upcoming = scheduledEntries
        .map((entry) => (entry['displayAtMillis'] as num?)?.toInt() ?? 0)
        .where((at) => at > nowMillis)
        .toList()
      ..sort();
    final nextSlotMillis = upcoming.isEmpty ? null : upcoming.first;
    debugPrint(
      '[BloomSync] scheduling plan=${plan.planId} '
      'entries=${scheduledEntries.length} current=${plan.currentItemId} '
      'manifest=${manifest != null} bytes=${currentPhotoBytes != null} '
      'next_slot=${nextSlotMillis ?? 'none'} '
      '(${nextSlotMillis == null ? '-' : DateTime.fromMillisecondsSinceEpoch(nextSlotMillis).toIso8601String()})',
    );
    if (manifest == null || currentPhotoBytes == null) {
      throw StateError('当前轮播照片不在计划批次中');
    }
    if (scheduledEntries.isEmpty) {
      throw StateError('没有任何可排程的槽位');
    }
    // ---- the pool, on disk, where the next refill can find it -------------
    //
    // Step 1 of walking the day instead of replaying its first four photos.
    //
    // Until now this list of scheduled entries existed **only** in the native
    // layer's SharedPreferences, and every `scheduleCarousel` call *overwrites*
    // it. So a refill could not compute a union — it had no way to know what was
    // already scheduled — which is the mechanical reason the old cursor attempt
    // dropped slots and had to be rolled back. Writing the same entries next to
    // the photos first gives the next sync something to merge with.
    final poolFile = File('${dir.path}/carousel-pool.json');
    try {
      await poolFile.writeAsString(
        jsonEncode({
          'day': DateTime.now().toIso8601String().substring(0, 10),
          'plan_id': plan.planId,
          'current_item_id': plan.currentItemId,
          'entries': scheduledEntries,
        }),
        flush: true,
      );
      debugPrint(
        '[BloomSync] pool saved: day=${DateTime.now().toIso8601String().substring(0, 10)} '
        'entries=${scheduledEntries.length} last=${scheduledEntries.last['itemId']}',
      );
    } catch (error) {
      debugPrint('[BloomSync] pool save failed: $error');
    }
    await WidgetBridge().scheduleCarousel(
      planId: plan.planId,
      entries: scheduledEntries,
    );
    debugPrint('[BloomSync] scheduled ${scheduledEntries.length} slots ok');
    for (final family in ['portrait', 'square', 'largeSquare']) {
      await _pruneVersionedImages(
        dir,
        family,
        keeping: _versionedImage(dir, family, plan.currentItemId).path,
      );
    }
    await _pruneCarouselOriginals(dir);
    return manifest;
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
