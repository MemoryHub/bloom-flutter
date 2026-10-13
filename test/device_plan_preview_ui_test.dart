import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bloom/core/models/auth_models.dart';
import 'package:bloom/core/storage/device_plan_preview_repository.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:bloom/ui/bloom_device_pages.dart';
import 'package:bloom/ui/bloom_artwork_frame.dart';
import 'package:bloom/ui/bloom_glass_home.dart';
import 'package:bloom/ui/bloom_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    // 先绘制新图片组件，再让实际磁盘读取/解码在假时钟之外完成。
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('bloom-display-ui-');
    path = '${dir.path}/screen.png';
    File(path).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGPoXznnPwgzwBgAYzgLTcqgbmMAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });
  // 图片本身用实际解码完成的 fixture；假时钟用于界面动画和加载状态切换。
  Future<void> loadImage(WidgetTester tester) async {
    await tester.runAsync(() async {
      final done = Completer<void>();
      final stream = FileImage(File(path)).resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (info, synchronous) {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace? stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      try {
        await done.future.timeout(const Duration(seconds: 5));
      } finally {
        stream.removeListener(listener);
      }
    });
  }

  testWidgets(
    'switching devices shows separate cached screen, zooms it and returns to local content',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await loadImage(tester);
      var selected = 'phone';
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder:
                (context, setState) => BloomGlassHome(
                  loading: false,
                  nextLoading: false,
                  selectedTab: 0,
                  originalPhotoPath: path,
                  nextSlotAt:
                      DateTime.now()
                          .add(const Duration(minutes: 15))
                          .millisecondsSinceEpoch,
                  settings: const BloomDisplaySettings(),
                  devices: const [
                    BloomDevice(
                      deviceId: 'phone',
                      name: '本机',
                      type: 'mobile',
                      isLocal: true,
                    ),
                    BloomDevice(deviceId: 'frame', name: '客厅', type: 'eink'),
                  ],
                  selectedDeviceId: selected,
                  remotePlanPreviews: {
                    'frame': DevicePlanPreview(
                      deviceId: 'frame',
                      status: 'ready',
                      mode: 'carousel',
                      imagePath: path,
                      imageKey: 'frame-v1',
                      displayAt: DateTime(2026, 10, 13, 1),
                      nextCheckAt: DateTime.now().add(
                        const Duration(minutes: 15),
                      ),
                    ),
                  },
                  account: const AccountInfo(
                    id: 'account',
                    phone: '',
                    provisionStatus: 'ready',
                    immichReady: true,
                  ),
                  onTabChanged: (_) {},
                  onRefresh: () async {
                    refreshes++;
                  },
                  onNext: () {},
                  onDeviceChanged: (id) => setState(() => selected = id),
                  onOpenDevice: (_) {},
                  onAddDevice: () {},
                  onCopyDeviceId: () {},
                ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final frameFinder = find.byKey(const ValueKey('bloom-home-photo-frame'));
      final widgetFinder = find.byKey(
        const ValueKey('bloom-widget-photo-surface'),
      );
      final switcherFinder = find.byKey(
        const ValueKey('bloom-device-switcher'),
      );
      final localFrame = tester.getRect(widgetFinder);
      expect(find.byType(BloomArtworkFrame), findsNothing);
      expect(find.byKey(const ValueKey('bloom-mode-tag')), findsOneWidget);
      final localModeText =
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byKey(const ValueKey('bloom-mode-tag')),
                  matching: find.byType(Text),
                ),
              )
              .data;
      final widgetClip = find.descendant(
        of: widgetFinder,
        matching: find.byType(ClipRRect),
      );
      expect(
        tester.widget<ClipRRect>(widgetClip).borderRadius,
        BorderRadius.circular(27),
      );
      expect(
        tester.getRect(widgetClip),
        localFrame,
        reason: 'the original widget card has no inner frame padding',
      );
      final localGap = localFrame.top - tester.getRect(switcherFinder).bottom;
      expect(localGap, closeTo(BloomGlassHome.cardGap, .1));
      expect(localFrame.width / localFrame.height, closeTo(720 / 1200, .001));
      await tester.tap(find.byKey(const ValueKey('bloom-device-switcher')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('bloom-device-option-frame')));
      await settle(tester);
      expect(refreshes, 0, reason: 'selection itself cannot request a refresh');
      expect(find.byKey(const ValueKey('bloom-remote-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('bloom-next-slot')), findsNothing);
      expect(find.byKey(const ValueKey('remote-next-frame')), findsOneWidget);
      expect(find.textContaining('计划时间'), findsNothing);
      final labelFinder = find.byKey(const ValueKey('remote-next-frame'));
      final frameRect = tester.getRect(frameFinder);
      expect(frameRect.top, localFrame.top);
      expect(
        frameRect.width / frameRect.height,
        closeTo(1200 / 1600, .001),
        reason: 'E-Ink preserves its real screen proportions',
      );
      expect(find.byKey(const ValueKey('bloom-mode-tag')), findsNothing);
      expect(find.byKey(const ValueKey('remote-mode-frame')), findsOneWidget);
      expect(find.text('轮播模式'), findsOneWidget);
      expect(find.byType(BloomArtworkFrame), findsOneWidget);
      expect(
        find.descendant(of: frameFinder, matching: find.byType(ClipRRect)),
        findsNothing,
      );
      expect(
        find.descendant(of: frameFinder, matching: find.byType(CustomPaint)),
        findsNothing,
      );
      expect(
        frameRect.top - tester.getRect(switcherFinder).bottom,
        closeTo(localGap, .1),
      );
      final imageRect = tester.getRect(
        find.byKey(const ValueKey('bloom-remote-screen')),
      );
      expect(
        imageRect.left - frameRect.left,
        closeTo(BloomArtworkFrame.imageInset, .1),
      );
      expect(
        imageRect.top - frameRect.top,
        closeTo(BloomArtworkFrame.imageInset, .1),
      );
      expect(
        tester
            .widget<Image>(
              find.descendant(
                of: find.byKey(const ValueKey('bloom-remote-screen')),
                matching: find.byType(Image),
              ),
            )
            .fit,
        BoxFit.contain,
        reason: 'the frame must never crop the server composition',
      );
      final labelRect = tester.getRect(labelFinder);
      expect(labelRect.top, greaterThanOrEqualTo(frameRect.bottom + 7));
      expect((labelRect.right - frameRect.right).abs(), lessThan(1));
      expect(tester.widget<Text>(labelFinder).style, BloomType.meta);
      expect(tester.widget<Text>(labelFinder).data, startsWith('下次更新 '));
      expect(find.textContaining('设备确认'), findsNothing);
      expect(find.textContaining('联网确认'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('bloom-remote-screen')));
      await settle(tester);
      expect(find.byType(BloomImageViewer), findsOneWidget);
      expect(
        tester
            .widget<InteractiveViewer>(
              find.byKey(const ValueKey('bloom-image-zoom')),
            )
            .maxScale,
        8,
      );
      await tester.pageBack();
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('bloom-device-switcher')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('bloom-device-option-phone')));
      await settle(tester);
      expect(selected, 'phone');
      expect(find.byKey(const ValueKey('bloom-remote-screen')), findsNothing);
      expect(find.byType(BloomArtworkFrame), findsNothing);
      expect(tester.getRect(widgetFinder), localFrame);
      expect(find.byKey(const ValueKey('remote-mode-frame')), findsNothing);
      expect(find.text(localModeText!), findsOneWidget);
      expect(refreshes, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'loading masks old remote photo and time, failures show retry, local widget remains independent',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await loadImage(tester);
      var selected = 'frame';
      var remote = DevicePlanPreview(
        deviceId: 'frame',
        status: 'ready',
        imagePath: path,
        imageKey: 'old',
        mode: 'carousel',
        nextCheckAt: DateTime.now().add(const Duration(minutes: 15)),
      );
      late StateSetter update;
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return BloomGlassHome(
                loading: false,
                nextLoading: false,
                selectedTab: 0,
                originalPhotoPath: path,
                settings: const BloomDisplaySettings(),
                devices: const [
                  BloomDevice(
                    deviceId: 'phone',
                    name: '本机',
                    type: 'mobile',
                    isLocal: true,
                  ),
                  BloomDevice(
                    deviceId: 'frame',
                    name: 'Bloom-Ink',
                    type: 'eink',
                  ),
                ],
                selectedDeviceId: selected,
                remotePlanPreviews: {'frame': remote},
                account: const AccountInfo(
                  id: 'account',
                  phone: '',
                  provisionStatus: 'ready',
                  immichReady: true,
                ),
                onTabChanged: (_) {},
                onRefresh: () async {
                  refreshes++;
                },
                onNext: () {},
                onDeviceChanged: (id) => setState(() => selected = id),
                onOpenDevice: (_) {},
                onAddDevice: () {},
                onCopyDeviceId: () {},
              );
            },
          ),
        ),
      );
      await settle(tester);
      final frame = find.byKey(const ValueKey('bloom-home-photo-frame'));
      final previousRect = tester.getRect(frame);
      expect(find.byKey(const ValueKey('bloom-remote-screen')), findsOneWidget);
      update(() => remote = remote.loadingCurrent());
      await tester.pump();
      expect(
        find.byKey(const ValueKey('bloom-remote-loading')),
        findsOneWidget,
      );
      expect(find.text('正在从设备拉取图片'), findsOneWidget);
      expect(find.byKey(const ValueKey('bloom-remote-screen')), findsNothing);
      expect(
        find.descendant(of: frame, matching: find.byType(Image)),
        findsNothing,
        reason: 'cached photo is not a loading placeholder',
      );
      expect(find.byKey(const ValueKey('remote-next-frame')), findsNothing);
      expect(
        tester.getRect(frame),
        previousRect,
        reason: 'the real 3:4 frame must not resize while loading',
      );
      update(() => remote = remote.retainedOffline());
      await tester.pump();
      expect(find.byKey(const ValueKey('bloom-remote-loading')), findsNothing);
      expect(find.byKey(const ValueKey('bloom-remote-screen')), findsNothing);
      expect(find.text('当前照片加载失败，请重试'), findsOneWidget);
      await tester.tap(find.text('刷新'));
      expect(refreshes, 1);
      update(
        () =>
            remote = DevicePlanPreview(
              deviceId: 'frame',
              status: 'ready',
              imagePath: path,
              imageKey: 'new',
              mode: 'carousel',
            ),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('bloom-remote-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('bloom-remote-loading')), findsNothing);
      final image = tester.widget<Image>(
        find.descendant(
          of: find.byKey(const ValueKey('bloom-remote-screen')),
          matching: find.byType(Image),
        ),
      );
      expect(image.gaplessPlayback, isFalse);
      expect(
        find.descendant(of: frame, matching: find.byType(AnimatedSwitcher)),
        findsNothing,
      );
      update(() {
        selected = 'phone';
        remote = remote.loadingCurrent();
      });
      await settle(tester);
      expect(
        find.byKey(const ValueKey('bloom-widget-photo-surface')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('bloom-remote-loading')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
