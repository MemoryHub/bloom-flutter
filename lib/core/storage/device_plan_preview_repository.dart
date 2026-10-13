import 'dart:convert';
import 'dart:io';

import '../api/bloom_api_client.dart';
import '../../platform/widget_bridge.dart';

class DevicePlanPreview {
  const DevicePlanPreview({
    required this.deviceId,
    required this.status,
    this.imagePath,
    this.imageKey,
    this.displayAt,
    this.checkedAt,
    this.nextCheckAt,
    this.planId,
    this.itemId,
    this.mode,
    this.offline = false,
    this.loading = false,
  });
  final String deviceId, status;
  final String? imagePath, imageKey;
  final DateTime? displayAt, checkedAt, nextCheckAt;
  final int? planId, itemId;
  final String? mode;
  final bool offline;
  final bool loading;
  DevicePlanPreview loadingCurrent() => DevicePlanPreview(
    deviceId: deviceId,
    status: status,
    imagePath: imagePath,
    imageKey: imageKey,
    displayAt: displayAt,
    checkedAt: checkedAt,
    nextCheckAt: nextCheckAt,
    planId: planId,
    itemId: itemId,
    mode: mode,
    loading: true,
  );
  DevicePlanPreview retainedOffline() => DevicePlanPreview(
    deviceId: deviceId,
    status: status,
    imagePath: imagePath,
    imageKey: imageKey,
    displayAt: displayAt,
    checkedAt: checkedAt,
    nextCheckAt: nextCheckAt,
    planId: planId,
    itemId: itemId,
    mode: mode,
    offline: true,
  );
}

/// One current server-plan preview per remote device, outside widget-cache.
/// No future pictures, firmware requests or WidgetBridge state writes.
class DevicePlanPreviewRepository {
  DevicePlanPreviewRepository({required this.api, this.directory});
  final BloomApiClient api;
  final Directory? directory;
  String? _account;
  int _generation = 0;
  final Map<String, DevicePlanPreview> snapshots = {};

  /// 缓存只用于复用已下载文件；确认当前计划前不能当作当前照片显示。
  void beginRefresh(String account, Set<String> allowed) {
    if (_account != account) {
      _account = account;
      _generation++;
      snapshots.clear();
    }
    snapshots.removeWhere((id, _) => !allowed.contains(id));
    for (final id in allowed) {
      snapshots[id] =
          snapshots[id]?.loadingCurrent() ??
          DevicePlanPreview(deviceId: id, status: 'loading', loading: true);
    }
  }

  void failRefresh(Set<String> allowed) {
    for (final id in allowed) {
      snapshots[id] =
          snapshots[id]?.retainedOffline() ??
          DevicePlanPreview(deviceId: id, status: 'unavailable', offline: true);
    }
  }

  Future<Directory> _dir(String account) async {
    final root =
        directory ??
        Directory(
          '${Directory((await WidgetBridge().cacheDirectory())!).parent.path}/device-plan-preview-cache',
        );
    final safe = base64Url.encode(utf8.encode(account));
    return Directory('${root.path}/$safe');
  }

  String _name(String id) => base64Url.encode(utf8.encode(id));

  Future<void> restore(String account, Set<String> allowed) async {
    if (_account != account) {
      _account = account;
      _generation++;
      snapshots.clear();
    }
    final generation = _generation;
    final dir = await _dir(account);
    if (directory == null) {
      final legacy = Directory(
        '${dir.parent.parent.path}/device-display-cache/${_name(account)}',
      );
      if (await legacy.exists()) await legacy.delete(recursive: true);
    }
    for (final id in allowed) {
      try {
        final raw =
            jsonDecode(
                  await File('${dir.path}/${_name(id)}.json').readAsString(),
                )
                as Map<String, dynamic>;
        if (raw['format'] != 2) continue;
        final key = raw['image_key'] as String?;
        if (key == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) continue;
        final path = '${dir.path}/${_name(id)}-$key.png';
        if (!await File(path).exists()) continue;
        if (_account != account || generation != _generation) return;
        if (snapshots[id]?.imagePath == null) {
          snapshots[id] = DevicePlanPreview(
            deviceId: id,
            status: 'ready',
            imagePath: path,
            imageKey: key,
            displayAt: DateTime.tryParse(raw['display_at'] ?? ''),
            checkedAt: DateTime.tryParse(raw['checked_at'] ?? ''),
            nextCheckAt: DateTime.tryParse(raw['next_check_at'] ?? ''),
            planId: raw['plan_id'] as int?,
            itemId: raw['item_id'] as int?,
            mode: raw['mode'] as String?,
            loading: snapshots[id]?.loading ?? false,
          );
        }
      } catch (_) {
        /* No cache for this device yet. */
      }
    }
    snapshots.removeWhere((id, _) => !allowed.contains(id));
    if (await dir.exists()) {
      final prefixes = allowed.map(_name).toSet();
      await for (final entry in dir.list()) {
        final name = entry.uri.pathSegments.last;
        if (entry is File &&
            !prefixes.any((p) => name == '$p.json' || name.startsWith('$p-'))) {
          await entry.delete();
        }
      }
    }
  }

  Future<void> refresh(
    String account,
    String token,
    Set<String> allowed, {
    void Function()? onChanged,
  }) async {
    beginRefresh(account, allowed);
    onChanged?.call();
    final generation = _generation;
    bool current() => _account == account && generation == _generation;
    try {
      final response = await api.userRequest(token, 'device-plan-previews');
      if (!current()) return;
      final authorized =
          (response['devices'] as List? ?? [])
              .whereType<Map>()
              .map((e) => e['device_id'])
              .whereType<String>()
              .toSet();
      // A successful authoritative response can revoke access. A network
      // failure instead keeps the last downloaded plan picture.
      await restore(account, allowed.intersection(authorized));
      if (!current()) return;
      for (final id in allowed.difference(authorized)) {
        snapshots[id] = DevicePlanPreview(deviceId: id, status: 'unavailable');
      }
      final dir = await _dir(account);
      await dir.create(recursive: true);
      // One device's slow image cannot stop other device previews being published.
      await Future.wait(
        (response['devices'] as List? ?? []).whereType<Map>().map((
          entry,
        ) async {
          final id = entry['device_id'] as String?;
          if (id == null || !allowed.contains(id) || !current()) return;
          var mode = snapshots[id]?.mode;
          try {
            mode =
                (await api.getUserDeviceSettings(
                  token,
                  id,
                  target: BloomApiClient.settingsTargetEink,
                )).settings.mode;
          } catch (_) {
            // Failed settings reads keep this device's cached mode; never borrow
            // the phone's mode or prevent its current plan picture loading.
          }
          if (!current()) return;
          try {
            if (entry['status'] != 'ready') {
              // This device has no content in its server plan; no online frame ACK needed.
              snapshots[id] = DevicePlanPreview(
                deviceId: id,
                status: entry['status'] as String? ?? 'unavailable',
                checkedAt: DateTime.now(),
                nextCheckAt: DateTime.tryParse(entry['next_check_at'] ?? ''),
                mode: mode,
              );
              final prefix = _name(id);
              await for (final file in dir.list()) {
                if (file is File &&
                    (file.uri.pathSegments.last == '$prefix.json' ||
                        file.uri.pathSegments.last.startsWith('$prefix-'))) {
                  await file.delete();
                }
              }
            } else {
              final key = entry['image_key'] as String;
              if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
                throw const FormatException('invalid display key');
              }
              final path = '${dir.path}/${_name(id)}-$key.png';
              if (!await File(path).exists()) {
                final bytes = await api.devicePlanPreviewImage(
                  token,
                  id,
                  entry['item_id'] as int,
                  key,
                );
                if (!current()) return;
                if (bytes.length < 8 ||
                    bytes.length > 8 * 1024 * 1024 ||
                    bytes.take(8).join(',') != '137,80,78,71,13,10,26,10') {
                  throw const FormatException('invalid display PNG');
                }
                final tmp = File('$path.tmp');
                await tmp.writeAsBytes(bytes, flush: true);
                await tmp.rename(path);
              }
              if (!current()) return;
              final raw = {
                'format': 2,
                'plan_id': entry['plan_id'],
                'item_id': entry['item_id'],
                'next_check_at': entry['next_check_at'],
                'image_key': key,
                'display_at': entry['display_at'],
                'checked_at': DateTime.now().toIso8601String(),
                'mode': mode,
              };
              final meta = File('${dir.path}/${_name(id)}.json');
              await File(
                '${meta.path}.tmp',
              ).writeAsString(jsonEncode(raw), flush: true);
              await File('${meta.path}.tmp').rename(meta.path);
              if (!current()) return;
              snapshots[id] = DevicePlanPreview(
                deviceId: id,
                status: 'ready',
                imagePath: path,
                imageKey: key,
                displayAt: DateTime.tryParse(entry['display_at'] ?? ''),
                checkedAt: DateTime.now(),
                nextCheckAt: DateTime.tryParse(entry['next_check_at'] ?? ''),
                planId: entry['plan_id'] as int?,
                itemId: entry['item_id'] as int?,
                mode: mode,
              );
              await for (final file in dir.list()) {
                if (file is File &&
                    file.uri.pathSegments.last.startsWith('${_name(id)}-') &&
                    file.path != path) {
                  await file.delete();
                }
              }
            }
            if (current()) onChanged?.call();
          } catch (_) {
            if (current()) {
              final previous = snapshots[id];
              snapshots[id] =
                  previous?.retainedOffline() ??
                  DevicePlanPreview(
                    deviceId: id,
                    status: 'unavailable',
                    mode: mode,
                    offline: true,
                  );
              onChanged?.call();
            }
          }
        }),
      );
      if (current()) onChanged?.call();
    } catch (_) {
      if (current()) {
        failRefresh(allowed);
        onChanged?.call();
      }
    }
  }

  Future<void> clear() async {
    final previous = _account;
    _account = null;
    _generation++;
    snapshots.clear();
    if (previous != null) {
      try {
        final dir = await _dir(previous);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        /* A missing platform channel must not prevent logout. */
      }
    }
  }
}
