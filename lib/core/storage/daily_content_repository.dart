import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
      for (var attempt = 0; attempt < 180 && await lock.exists(); attempt++) {
        final age = DateTime.now().difference((await lock.stat()).modified);
        if (age > const Duration(minutes: 3)) {
          try {
            await lock.delete();
          } catch (_) {}
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
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
  ) async {
    final plan = await api.carouselPlan(credentials, settings);
    if (plan.items.isEmpty) throw StateError('轮播计划为空');
    final scheduledEntries = <Map<String, Object?>>[];
    DailyContent? currentManifest;
    String? currentEtag;
    Uint8List? currentPhotoBytes;

    for (final item in plan.items) {
      final response = await api.carouselPhoto(credentials, item.itemId);
      if (response.statusCode != 200) {
        throw StateError('轮播计划照片下载失败');
      }
      final photoBytes = response.bodyBytes;
      final manifest = item.asDailyContent();
      final originalPath = '${dir.path}/carousel-original-${item.itemId}.photo';
      final originalTemp = File('$originalPath.tmp');
      await originalTemp.writeAsBytes(photoBytes, flush: true);
      await originalTemp.rename(originalPath);
      final paths = <String, String>{};
      for (final family in ['portrait', 'square', 'largeSquare']) {
        final output = _versionedImage(dir, family, item.itemId);
        final rendered = await MobileLetterRenderer.render(
          photoBytes,
          manifest,
          family,
        );
        final temp = File('${output.path}.tmp');
        await temp.writeAsBytes(rendered, flush: true);
        await temp.rename(output.path);
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
        currentEtag = response.headers['etag'];
        currentPhotoBytes = photoBytes;
      }
    }

    final manifest = currentManifest;
    if (manifest == null || currentPhotoBytes == null) {
      throw StateError('当前轮播照片不在计划批次中');
    }
    final photoFile = File('${dir.path}/original.photo');
    final photoTemp = File('${photoFile.path}.tmp');
    await photoTemp.writeAsBytes(currentPhotoBytes, flush: true);
    await photoTemp.rename(photoFile.path);
    await File('${dir.path}/daily.json').writeAsString(
      jsonEncode({
        'mode': 'carousel',
        'photo_etag': currentEtag,
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
    await WidgetBridge().scheduleCarousel(
      planId: plan.planId,
      entries: scheduledEntries,
    );
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
