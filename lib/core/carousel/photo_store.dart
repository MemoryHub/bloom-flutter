/// 照片获取与本地渲染。
///
/// 文件命名沿用既有约定，因此 UI 侧的读取器（`cached()` / `photoPathFor()` /
/// `cachedContent()`）无需改动即可继续工作：
///
///   * 原图      `carousel-original-{itemId}.photo`
///   * 渲染图    `mobile-local-{family}-{itemId}.png`（portrait / square / largeSquare）
///   * 当前原图  `original.photo`（可变，供首页回退使用）
///
/// 所有写入都是「先写临时文件再 rename」，避免读到写了一半的图片。
library;

import 'carousel_diagnostics.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/bloom_api_client.dart';
import '../models/device_models.dart';
import '../rendering/mobile_letter_renderer.dart';
import 'carousel_state.dart';

/// 一张照片在本地就绪后产出的全部路径。
class PreparedPhoto {
  const PreparedPhoto({
    required this.itemId,
    required this.assetId,
    required this.originalPath,
    required this.portraitPath,
    required this.squarePath,
    required this.largeSquarePath,
    this.etag,
  });

  final int itemId;
  final String assetId;
  final String originalPath;
  final String portraitPath;
  final String squarePath;
  final String largeSquarePath;
  final String? etag;

  PhotoEntry toEntry(int fetchedAtMs) => PhotoEntry(
    itemId: itemId,
    assetId: assetId,
    path: portraitPath,
    etag: etag,
    fetchedAtMs: fetchedAtMs,
  );
}

/// 照片获取的结果分类。失败必须是可判定的，不能只吞掉异常。
enum PhotoFetchOutcome {
  /// 本地已有或本次成功取回。
  ready,

  /// 该格子取不到照片（重试后仍失败）。
  unavailable,
}

class PhotoFetchResult {
  const PhotoFetchResult({required this.outcome, this.photo, this.reason});

  final PhotoFetchOutcome outcome;
  final PreparedPhoto? photo;
  final String? reason;

  bool get isReady => outcome == PhotoFetchOutcome.ready;
}

/// 照片仓库：负责下载原图、渲染三个规格，并复用已存在的文件。
class CarouselPhotoStore {
  CarouselPhotoStore({required this.api, this.downloadLeash = const Duration(seconds: 25)});

  final BloomApiClient api;

  /// 单次下载的时间上限。对应方案第四章的「单次下载时限」。
  final Duration downloadLeash;

  static const List<String> _families = ['portrait', 'square', 'largeSquare'];

  static File originalFile(Directory dir, int itemId) =>
      File('${dir.path}/carousel-original-$itemId.photo');

  static File renderedFile(Directory dir, String family, int itemId) =>
      File('${dir.path}/mobile-local-$family-$itemId.png');

  /// 该 [itemId] 的四张本地文件是否齐全。
  static Future<bool> isReady(Directory dir, int itemId) async {
    if (!await originalFile(dir, itemId).exists()) return false;
    for (final family in _families) {
      if (!await renderedFile(dir, family, itemId).exists()) return false;
    }
    return true;
  }

  /// 确保某个格子的照片在本地就绪。
  ///
  /// [attempts] 为总尝试次数（方案规定「首次 + 重试 1 次」共 2 次）。
  /// 已存在的文件直接复用，不重复下载。
  Future<PhotoFetchResult> prepare({
    required Directory dir,
    required CarouselItemContent item,
    required DeviceCredentials credentials,
    int attempts = 2,
    String? etag,
  }) async {
    final itemId = item.itemId;
    final startedMs = DateTime.now().millisecondsSinceEpoch;
    try {
      if (await isReady(dir, itemId)) {
        return PhotoFetchResult(
          outcome: PhotoFetchOutcome.ready,
          photo: _pathsFor(dir, item, etag: etag),
        );
      }

      var lastReason = 'unknown';
      for (var attempt = 0; attempt < attempts; attempt++) {
        try {
          final bytes = await _download(
            credentials: credentials,
            itemId: itemId,
            etag: etag,
            destination: originalFile(dir, itemId),
          );
          await _renderAll(dir, item, bytes);
          return PhotoFetchResult(
            outcome: PhotoFetchOutcome.ready,
            photo: _pathsFor(dir, item, etag: etag),
          );
        } on TimeoutException {
          lastReason = 'timeout';
        } on BloomApiException catch (error) {
          lastReason = 'http_${error.statusCode}';
          // 404 表示该条目在服务端已不存在，重试没有意义。
          if (error.statusCode == 404) break;
        } catch (error) {
          lastReason = error.toString();
        }
      }
      debugPrint('[BloomCarousel] photo unavailable item=$itemId reason=$lastReason');
      // **诊断日志。** 2026-09-28 两端各有一张反复 timeout，而服务端实测是正常
      // 200——只靠服务端日志无法区分「服务端慢」和「客户端处理慢」，必须在这里
      // 记下耗时和原因。字段两端一致（同一份 Dart）。
      await CarouselDiagnostics(directory: dir).record(
        'photo',
        data: {
          'item_id': itemId,
          'outcome': 'unavailable',
          'reason': lastReason,
          'attempts': attempts,
          'elapsed_ms': DateTime.now().millisecondsSinceEpoch - startedMs,
        },
      );
      return PhotoFetchResult(
        outcome: PhotoFetchOutcome.unavailable,
        reason: lastReason,
      );
    } catch (error) {
      debugPrint('[BloomCarousel] photo prepare failed item=$itemId: $error');
      return PhotoFetchResult(
        outcome: PhotoFetchOutcome.unavailable,
        reason: error.toString(),
      );
    }
  }

  /// 取回原图并原子落盘。304 表示本地副本仍然有效。
  Future<Uint8List> _download({
    required DeviceCredentials credentials,
    required int itemId,
    required String? etag,
    required File destination,
  }) async {
    if (await destination.exists() && etag != null) {
      final cached = await api.carouselPhoto(credentials, itemId, etag: etag);
      if (cached.statusCode == 304) {
        return destination.readAsBytes();
      }
      final bytes = cached.bodyBytes;
      await _writeAtomic(destination, bytes);
      return bytes;
    }
    final response = await api
        .carouselPhoto(credentials, itemId, etag: etag)
        .timeout(downloadLeash);
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) {
      throw StateError('empty photo body for item $itemId');
    }
    await _writeAtomic(destination, bytes);
    return bytes;
  }

  /// 渲染三个规格。已存在的规格不重渲染。
  Future<void> _renderAll(
    Directory dir,
    CarouselItemContent item,
    Uint8List photoBytes,
  ) async {
    final manifest = item.asDailyContent();
    for (final family in _families) {
      final output = renderedFile(dir, family, item.itemId);
      if (await output.exists()) continue;
      final rendered = await MobileLetterRenderer.render(
        photoBytes,
        manifest,
        family,
      );
      await _writeAtomic(output, rendered);
    }
  }

  /// 把「当前」原图写成首页使用的可变副本。
  ///
  /// 首页在拿不到按 id 版本化的原图时会回退到这个文件，因此每次切换都要刷新。
  Future<void> publishCurrent(Directory dir, int itemId) async {
    try {
      final source = originalFile(dir, itemId);
      if (!await source.exists()) return;
      final target = File('${dir.path}/original.photo');
      await _writeAtomic(target, await source.readAsBytes());
    } catch (error) {
      debugPrint('[BloomCarousel] publish current failed: $error');
    }
  }

  PreparedPhoto _pathsFor(
    Directory dir,
    CarouselItemContent item, {
    String? etag,
  }) => PreparedPhoto(
    itemId: item.itemId,
    assetId: item.assetId,
    originalPath: originalFile(dir, item.itemId).path,
    portraitPath: renderedFile(dir, 'portrait', item.itemId).path,
    squarePath: renderedFile(dir, 'square', item.itemId).path,
    largeSquarePath: renderedFile(dir, 'largeSquare', item.itemId).path,
    etag: etag,
  );

  Future<void> _writeAtomic(File target, List<int> bytes) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  }
}
