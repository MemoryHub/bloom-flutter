import 'dart:convert';
import 'dart:io';

import '../carousel/state_store.dart';
import '../carousel/photo_gc.dart';
import 'display_preferences.dart';

/// Settings saves invalidate work started with the previous schedule, including
/// a prefetch in another isolate. The token survives A → B → A switches.
class ContentSyncEpoch {
  ContentSyncEpoch(this.directory, this.token, {this.lease});

  final Directory directory;
  final String? token;
  final CarouselSyncLease? lease;
  static const fileName = 'content-sync-epoch.json';

  static String settingsKey(BloomDisplaySettings settings) => jsonEncode([
    settings.mode.name,
    settings.intervalMinutes,
    settings.activeStart,
    settings.activeEnd,
    settings.timezone,
    settings.sources.map((s) => s.wire).toList()..sort(),
  ]);

  static Future<Map<String, dynamic>> _read(Directory dir) async {
    try {
      return jsonDecode(await File('${dir.path}/$fileName').readAsString())
          as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<ContentSyncEpoch> capture(Directory dir) async =>
      ContentSyncEpoch(dir, (await _read(dir))['token'] as String?);

  Future<bool> isCurrent() async =>
      (await _read(directory))['token'] == token &&
      (lease == null || await lease!.isHeld());

  /// Account changes never reuse another account's offline fallback.
  static Future<void> resetAccount(Directory dir) async {
    await dir.create(recursive: true);
    final lock = CarouselLock('${dir.path}/content-sync-epoch.lock');
    for (var i = 0; !await lock.acquire(); i++) {
      if (i >= 100) throw StateError('content account is busy');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      await CarouselStateStore(directory: dir).resetAccount(
        onReset: () async {
          final target = File('${dir.path}/$fileName');
          final temporary = File('${target.path}.tmp');
          await temporary.writeAsString(
            jsonEncode({
              'token': DateTime.now().microsecondsSinceEpoch.toString(),
            }),
            flush: true,
          );
          await temporary.rename(target.path);
          await for (final entity in dir.list()) {
            if (entity is! File) continue;
            final name = entity.uri.pathSegments.last;
            if (name == fileName ||
                name == 'carousel-state.json' ||
                name.endsWith('.lock')) {
              continue;
            }
            if (RegExp(
              r'\.(photo|jpg|jpeg|png|webp|heic|json|tmp)$',
              caseSensitive: false,
            ).hasMatch(name)) {
              try {
                await entity.delete();
              } on FileSystemException {
                /* Late readers cannot republish with the revoked epoch. */
              }
            }
          }
        },
      );
    } finally {
      await lock.release();
    }
  }

  static Future<void> activate(
    Directory dir,
    BloomDisplaySettings settings,
  ) async {
    await dir.create(recursive: true);
    final lock = CarouselLock('${dir.path}/content-sync-epoch.lock');
    for (var i = 0; !await lock.acquire(); i++) {
      if (i >= 100) throw StateError('settings generation is busy');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      final previous = await _read(dir);
      final key = settingsKey(settings);
      if (previous['settings'] == key) return;
      final token = DateTime.now().microsecondsSinceEpoch.toString();
      final file = File('${dir.path}/$fileName');
      final temp = File('${file.path}.tmp');
      // Keep the last displayed photo for offline/outside-window use, but stop
      // native readers and late writers from applying the abandoned timeline.
      // Publish the token while holding the state lock, after invalidation. A
      // busy/abandoned lock must leave the old token intact so the next settings
      // read retries migration rather than treating a partial save as complete.
      await CarouselStateStore(directory: dir).invalidatePlan(
        onInvalidated: () async {
          await temp.writeAsString(
            jsonEncode({'settings': key, 'token': token}),
            flush: true,
          );
          await temp.rename(file.path);
          final projection = File('${dir.path}/daily.json');
          if (await projection.exists()) {
            try {
              final raw =
                  jsonDecode(await projection.readAsString())
                      as Map<String, dynamic>;
              raw['next_slot_at_ms'] = null;
              final staging = File('${projection.path}.tmp');
              await staging.writeAsString(jsonEncode(raw), flush: true);
              await staging.rename(projection.path);
            } catch (_) {}
          }
          final state = await CarouselStateStore(directory: dir).read();
          final alive = <String>{
            for (final entry in state.timelineEntries) ...[
              entry.originalPath,
              entry.portraitPath,
              entry.squarePath,
              entry.largeSquarePath,
            ],
            for (final photo in state.photos) ...[
              photo.path,
              '${dir.path}/carousel-original-${photo.itemId}.photo',
              '${dir.path}/mobile-original-${photo.itemId}.json',
              '${dir.path}/mobile-render-${photo.itemId}.json',
              for (final family in ['portrait', 'square', 'largeSquare'])
                '${dir.path}/mobile-local-$family-${photo.itemId}.png',
            ],
          };
          await sweepOrphanPhotos(dir: dir, alivePaths: alive);
        },
      );
    } finally {
      await lock.release();
    }
  }
}
