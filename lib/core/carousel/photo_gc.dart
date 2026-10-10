/// 照片缓存的垃圾回收：删除**没有任何状态引用**的文件。
///
/// 引擎自己的淘汰只删「状态里记录过的」文件（它遍历 `photos` 求差集），所以磁盘上
/// 没人认领的文件它永远看不见。两类来源会留下这种孤儿：
///
///   * **旧版本升级**——上一代的保留策略与命名不同，升级后那些文件既不在新状态
///     里，也没有任何代码会去删。实测 iOS 上升级后残留了 16 张，而状态只跟踪 6 张。
///   * **下载完成到状态落盘之间被杀**——文件已写、状态未写。
///
/// 这里刻意做成独立函数，而不是塞进仓库的私有方法：它会**真的删文件**，必须有
/// 一条能脱离网络与渲染管线直接跑的测试。
library;

import 'dart:io';

import 'state_store.dart';

/// 本项目在缓存目录里拥有的两种照片命名。
///
/// 用**精确到带条目 id 的正则**，而不是宽松的前缀匹配：`mobile-local-{orientation}.png`
/// （没有 id 后缀）是推荐模式**当前正在用**的文件，宽松匹配会把它一起删掉。
/// iOS 扩展自己管理的 `ios-widget-remote-*.jpg`、`widget-timeline.log`，以及各种
/// `.json` 也都不在范围内。
final RegExp _originalFile = RegExp(r'^carousel-original-\d+\.photo$');
final RegExp _markerFile = RegExp(r'^mobile-(?:render|original)-\d+\.json$');
final RegExp _renderedFile = RegExp(r'^mobile-local-[A-Za-z]+-\d+\.png$');

bool isOwnedPhotoFile(String name) =>
    _originalFile.hasMatch(name) ||
    _renderedFile.hasMatch(name) ||
    _markerFile.hasMatch(name);

/// 删除 [dir] 中所有属于本项目命名、但不在 [alivePaths] 里的文件。
///
/// [alivePaths] 必须是**绝对路径**，与 `Directory.list()` 给出的形式一致。
/// 返回删除的个数。单个文件删除失败会被跳过——清垃圾失败不该影响主流程。
Future<int> sweepOrphanPhotos({
  required Directory dir,
  required Iterable<String> alivePaths,
  Duration minimumAge = Duration.zero,
}) async {
  // App Group paths may use /var or /private/var aliases on iOS.
  final alive = <String>{};
  for (final path in alivePaths.where((p) => p.isNotEmpty)) {
    alive.add(path);
    try {
      alive.add(await File(path).resolveSymbolicLinks());
    } catch (_) {}
  }
  var swept = 0;
  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    if (!isOwnedPhotoFile(entity.uri.pathSegments.last)) continue;
    if (minimumAge > Duration.zero &&
        DateTime.now().difference((await entity.stat()).modified) <
            minimumAge) {
      continue;
    }
    final id = RegExp(
      r'-(\d+)\.(?:photo|png|json)$',
    ).firstMatch(entity.path)?.group(1);
    if (alive.contains(entity.path)) continue;
    try {
      if (alive.contains(await entity.resolveSymbolicLinks())) continue;
    } catch (_) {}
    // Claim the same preparation lease, including its existing stale-owner
    // recovery. An abandoned lock must not protect orphaned bytes forever.
    final lock =
        id == null ? null : CarouselLock('${dir.path}/photo-prepare-$id.lock');
    if (lock != null && !await lock.acquire()) continue;
    try {
      await entity.delete();
      swept++;
    } catch (_) {
      // 被占用或已消失都无所谓，下一轮再来。
    } finally {
      await lock?.release();
    }
  }
  return swept;
}
