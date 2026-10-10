/// 照片缓存垃圾回收：只删自己的、且没人引用的文件。
///
/// 这条测试值得存在的理由很直接：**它会真的删文件**。误删的代价是小组件上出现
/// 空白或旧图，而不是一个红色断言，所以「不删什么」和「删什么」一样重要。
library;

import 'dart:io';

import 'package:bloom/core/carousel/photo_gc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bloom-gc');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> make(String name) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes([1, 2, 3]);
    return file;
  }

  Future<Set<String>> names() async {
    final out = <String>{};
    await for (final entity in dir.list()) {
      if (entity is File) out.add(entity.uri.pathSegments.last);
    }
    return out;
  }

  test('删掉无主照片，保留状态引用的', () async {
    // 真机现场：iOS 升级后磁盘上 22 张，状态只跟踪 6 张。
    final keptOriginal = await make('carousel-original-4402.photo');
    final keptPortrait = await make('mobile-local-portrait-4402.png');
    await make('carousel-original-4228.photo');
    await make('mobile-local-portrait-4228.png');
    await make('mobile-local-largeSquare-4230.png');

    final swept = await sweepOrphanPhotos(
      dir: dir,
      alivePaths: [keptOriginal.path, keptPortrait.path],
    );

    expect(swept, 3, reason: '三张旧版本孤儿都应被删除');
    expect(await names(), {
      'carousel-original-4402.photo',
      'mobile-local-portrait-4402.png',
    });
  });

  test('时间线引用但不在 photos 里的文件也要保留', () async {
    // 状态里两份清单理论上一致，但删文件这件事不值得赌它们一致。
    final only = await make('mobile-local-square-4405.png');

    final swept = await sweepOrphanPhotos(dir: dir, alivePaths: [only.path]);

    expect(swept, 0);
    expect(await names(), contains('mobile-local-square-4405.png'));
  });

  test('绝不碰 iOS 扩展自己的文件、JSON 与 .tmp', () async {
    await make('ios-widget-remote-4406.jpg');
    await make('widget-timeline.log');
    await make('carousel-state.json');
    await make('daily.json');
    await make('carousel-original-4402.photo.tmp');
    await make('mobile-local-portrait-4402.png.tmp');

    final swept = await sweepOrphanPhotos(dir: dir, alivePaths: const []);

    expect(swept, 0, reason: '这些都不是本项目拥有的缓存文件');
    expect((await names()).length, 6);
  });

  test('推荐模式的无 id 文件名必须原样保留', () async {
    // `mobile-local-{orientation}.png` 是推荐模式当前正在显示的那张。
    // 宽松的前缀匹配会把它误删——这条就是防那个。
    await make('mobile-local-portrait.png');
    await make('mobile-local-landscape.png');
    await make('mobile-local-largeSquare.png');

    final swept = await sweepOrphanPhotos(dir: dir, alivePaths: const []);

    expect(swept, 0);
    expect((await names()).length, 3);
  });

  test('空引用集合等于清空自有缓存，但不越界', () async {
    await make('carousel-original-1.photo');
    await make('mobile-local-portrait-1.png');
    await make('ios-widget-remote-1.jpg');

    final swept = await sweepOrphanPhotos(dir: dir, alivePaths: const []);

    expect(swept, 2);
    expect(await names(), {'ios-widget-remote-1.jpg'});
  });

  test('iOS-like symlink paths preserve all referenced bytes', () async {
    final photo = await make('carousel-original-9.photo');
    final alias = Link(
      '${dir.parent.path}/bloom-gc-alias-${dir.uri.pathSegments[dir.uri.pathSegments.length - 2]}',
    );
    await alias.create(dir.path);
    try {
      expect(
        await sweepOrphanPhotos(
          dir: dir,
          alivePaths: ['${alias.path}/carousel-original-9.photo'],
        ),
        0,
      );
      expect(await photo.exists(), isTrue);
    } finally {
      await alias.delete();
    }
  });
  test('in-flight render survives a concurrent garbage sweep', () async {
    final file = await make('carousel-original-9.photo');
    await make('photo-prepare-9.lock');
    expect(await sweepOrphanPhotos(dir: dir, alivePaths: []), 0);
    expect(await file.exists(), isTrue);
  });
  test(
    'abandoned preparation lock cannot retain orphan photos forever',
    () async {
      final file = await make('carousel-original-19.photo');
      final lock = await make('photo-prepare-19.lock');
      await lock.setLastModified(
        DateTime.now().subtract(const Duration(minutes: 3)),
      );
      expect(await sweepOrphanPhotos(dir: dir, alivePaths: []), 1);
      expect(await file.exists(), isFalse);
      expect(await lock.exists(), isFalse);
    },
  );
  test('空目录不报错', () async {
    expect(await sweepOrphanPhotos(dir: dir, alivePaths: const []), 0);
  });
}
