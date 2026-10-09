import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 轮播的**换图诊断日志**：把「哪一格、什么时候、照片成没成、失败原因、有没有
/// 通知对端重绘」按行写进一个 JSONL 文件。
///
/// ## 为什么需要它
///
/// 2026-09-28 真机上出现了两个查不清的现象：
///
/// 1. **里外不同步**——iOS 小组件显示「走路必须踩圆坑」，点进 App 却是
///    「把复杂画面生成背景」。两者现在读的是**同一份共享状态**，所以这不是数据
///    源分叉，而是「App 更新了、小组件没跟上」。
/// 2. **不卡点换图**——21:15 该换的，双端都拖到 21:17。
///
/// 这两个都必须回答「那一刻到底发生了什么」。iOS 上 `devicectl` **不支持真机
/// 日志**、App Group 里也没有日志文件，所以只能在客户端自己写一份。
///
/// ## 设计约束
///
/// - **两端同一套字段**：安卓和 iOS 走的是同一份 Dart，日志格式天然一致，对比
///   起来才有意义。
/// - **有界**：只保留最近 [maxLines] 行，超出后从头部裁掉。诊断日志绝不能长成
///   一个吃满磁盘的东西。
/// - **绝不抛异常**：日志失败不能影响换图。所有写入都包在 try/catch 里。
/// - **写进 App Group / 应用私有目录**：与 `carousel-state.json` 同一个目录，
///   这样两端用同样的方式取得到。
class CarouselDiagnostics {
  CarouselDiagnostics({required this.directory});

  final Directory directory;

  /// 保留的最大行数。15 分钟一格、每次 tick 若干行，1000 行足够回溯一天多。
  static const int maxLines = 1000;

  File get _file => File('${directory.path}/carousel-diagnostics.jsonl');

  /// 追加一条事件。字段两端一致。
  ///
  /// [event] 是事件名（`tick` / `photo` / `refresh` / `show`），其余是负载。
  Future<void> record(
    String event, {
    Map<String, Object?> data = const {},
  }) async {
    try {
      if (!await directory.exists()) return;
      final line = jsonEncode({
        'at': DateTime.now().toIso8601String(),
        'at_ms': DateTime.now().millisecondsSinceEpoch,
        'event': event,
        ...data,
      });
      await _file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      await _trim();
    } catch (error) {
      // 诊断日志永远不能影响换图。
      debugPrint('[BloomDiag] record failed: $error');
    }
  }

  /// 超过 [maxLines] 就把头部裁掉，保留最近的。
  Future<void> _trim() async {
    try {
      final lines = await _file.readAsLines();
      if (lines.length <= maxLines) return;
      final keep = lines.sublist(lines.length - maxLines);
      await _file.writeAsString('${keep.join('\n')}\n', flush: true);
    } catch (error) {
      debugPrint('[BloomDiag] trim failed: $error');
    }
  }

  /// 读出最近 [limit] 条，供排查使用。
  Future<List<Map<String, Object?>>> tail({int limit = 200}) async {
    try {
      if (!await _file.exists()) return const [];
      final lines = await _file.readAsLines();
      final slice =
          lines.length <= limit ? lines : lines.sublist(lines.length - limit);
      return [
        for (final line in slice)
          if (line.trim().isNotEmpty)
            (jsonDecode(line) as Map).cast<String, Object?>(),
      ];
    } catch (error) {
      debugPrint('[BloomDiag] tail failed: $error');
      return const [];
    }
  }
}
