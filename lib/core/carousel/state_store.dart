/// 共享状态的存储与写入互斥。
///
/// 这是方案第二章「五条硬性规则」中规则一、二、三的落地处：
///
///   * 规则一（单一状态）——整份状态只存在于一个文件里，App 首页与小组件
///     都只是它的读取者；
///   * 规则二（单一写者）——所有写入必须经过 [CarouselStateStore.mutate]，
///     由文件锁保证同一时刻只有一个写者；
///   * 规则三（新者胜）——写入前比较计划身份，己方更旧即放弃。
///
/// 存放目录来自 `WidgetBridge().cacheDirectory()`：安卓是应用私有目录
/// （provider 与应用同进程，可直接读），iOS 是 App Group 容器（宿主 App 与
/// 小组件扩展都可读写）。因此两端都不需要为共享状态新增通道方法。
library;

import 'dart:convert';
import 'dart:io';

import 'carousel_rules.dart';
import 'carousel_state.dart';

/// 跨 isolate / 跨进程的文件锁。
///
/// 用 `File.create(exclusive: true)` 建立，等价于 O_EXCL 的创建语义；持有者
/// 若在 [staleAfter] 内没有释放（进程被杀、后台被系统终止），锁会被判定为
/// 残留并夺回——否则一次异常退出就会让之后所有的 tick 都拿不到锁。
class CarouselLock {
  CarouselLock(this.path);

  final String path;

  static const Duration defaultStaleAfter = Duration(seconds: 90);

  Future<bool> acquire({Duration staleAfter = defaultStaleAfter}) async {
    final file = File(path);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await file.create(exclusive: true);
        await file.writeAsString(
          '${DateTime.now().millisecondsSinceEpoch}',
          flush: true,
        );
        return true;
      } on FileSystemException {
        // 已存在：可能是别人持有，也可能是一次异常退出留下的残留。
        if (attempt == 0 && await _isStale(file, staleAfter)) {
          try {
            await file.delete();
          } catch (_) {}
          continue;
        }
        return false;
      }
    }
    return false;
  }

  Future<void> release() async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<bool> _isStale(File file, Duration staleAfter) async {
    try {
      final stat = await file.stat();
      return DateTime.now().difference(stat.modified) > staleAfter;
    } catch (_) {
      // 读不到状态（刚被释放）时按残留处理，交由下一轮重试。
      return true;
    }
  }
}

/// 共享状态的读写入口。
class CarouselStateStore {
  CarouselStateStore({required this.directory});

  final Directory directory;

  static const String stateFileName = 'carousel-state.json';
  static const String lockFileName = 'carousel-state.lock';

  File get stateFile => File('${directory.path}/$stateFileName');
  File get lockFile => File('${directory.path}/$lockFileName');

  /// 读取当前状态。文件缺失或损坏一律返回空状态，绝不抛异常——
  /// 状态读取失败不应该让整个 tick 崩掉。
  Future<CarouselState> read() async {
    try {
      if (!await stateFile.exists()) return CarouselState.empty;
      final raw = await stateFile.readAsString();
      if (raw.trim().isEmpty) return CarouselState.empty;
      return CarouselState.fromJson(jsonDecode(raw));
    } catch (_) {
      return CarouselState.empty;
    }
  }

  /// 在锁内完成「读取 → 计算 → 新者胜判定 → 写入 → 递增 revision」。
  ///
  /// [update] 接收锁内读到的最新状态，返回期望写入的新状态。它应当是纯计算，
  /// 不要在其中做网络或磁盘 I/O：锁的持有时间必须尽可能短。
  ///
  /// 返回值：写入成功时返回写入后的状态；未获得锁或判定己方更旧时返回 null。
  ///
  /// [onCommitted] 在锁内、状态落盘之后立刻执行，用于写派生投影（`daily.json`）
  /// 与通知对端。放在锁内是为了让「权威状态」与「派生视图」永远一致。
  Future<CarouselState?> mutate({
    required String writer,
    required PlanIdentity? incomingPlan,
    required CarouselState Function(CarouselState current) update,
    Future<void> Function(CarouselState committed)? onCommitted,
    Duration staleAfter = CarouselLock.defaultStaleAfter,
  }) async {
    final lock = CarouselLock(lockFile.path);
    if (!await lock.acquire(staleAfter: staleAfter)) return null;
    try {
      final current = await read();
      final proposed = update(current);

      // 规则三：新者胜。己方计划更旧时放弃写入——这一条专门用于根治
      // 「App 把小组件刚取回的结果覆盖回去」。
      if (!shouldAcceptWrite(
        existing: current,
        incomingPlan: incomingPlan,
        incomingRevision: current.revision + 1,
      )) {
        return null;
      }

      final committed = proposed.copyWith(
        revision: current.revision + 1,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        writer: writer,
      );
      await _writeAtomic(committed);
      if (onCommitted != null) await onCommitted(committed);
      return committed;
    } finally {
      await lock.release();
    }
  }

  /// 原子写入：先写临时文件再 rename，避免读到写了一半的 JSON。
  Future<void> _writeAtomic(CarouselState state) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final temp = File('${stateFile.path}.tmp');
    await temp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await temp.rename(stateFile.path);
  }

  /// 删除不再被状态引用的照片文件。
  ///
  /// 调用方必须先保证「保留集合」已经写进状态，再来删这里传进来的条目；
  /// 顺序反了会删掉状态仍然引用的照片。
  Future<void> deletePhotos(Iterable<PhotoEntry> photos) async {
    for (final photo in photos) {
      try {
        final file = File(photo.path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 删不掉（被占用等）不影响状态推进，下一轮再试。
      }
    }
  }
}
