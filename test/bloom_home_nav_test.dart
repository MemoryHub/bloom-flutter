import 'dart:convert';
import 'dart:io';

import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:bloom/ui/bloom_device_pages.dart';
import 'package:bloom/ui/bloom_glass_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'support/fake_account.dart';

/// F4 UI tests for the restored three-tab navigation and the home page.
///
/// Every test drives real taps on the nav bar. The page itself is
/// [BloomGlassHome] with injected values, the same seam the F3 tests use, so
/// nothing here touches the network.
///
/// Note on the `IndexedStack` assertions: the three pages are all *built* (the
/// stack keeps their state), so `find.text` alone cannot tell which one is on
/// screen. The index of the `IndexedStack` is what decides that, so the tests
/// assert both it and the page's own content.
void main() {
  final credentials = DeviceCredentials(
    deviceId: 'bloom-mobile-test',
    deviceToken: 'a' * 64,
  );

  // A real, decodable 1x1 PNG: the home page's card is an `Image.file`, so the
  // path has to exist or the widget falls back to its placeholder.
  late final String photoPath;
  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('bloom-home-nav-test');
    final file = File('${dir.path}/photo.png');
    file.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ),
    );
    photoPath = file.path;
  });

  /// Pumps until the nav pill's spring and the page transitions are done
  /// without waiting for a never-settling glass animation to stop.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  final nav = find.byType(LiquidGlassBottomNavBar);

  /// The home page; [_Harness] owns the selected tab, so `onTabChanged` really
  /// switches pages.
  Widget home({int initialTab = 0, String? message}) => MaterialApp(
    home: _Harness(
      initialTab: initialTab,
      onTabChanged: (_) {},
      photoPath: photoPath,
      credentials: credentials,
      message: message,
    ),
  );

  int tabIndex(WidgetTester tester) =>
      tester.widget<IndexedStack>(find.byType(IndexedStack)).index!;

  Future<void> tapTab(WidgetTester tester, String label) async {
    // The bar paints **two** layers per item — every cell in its selected state
    // under the pill and every cell unselected outside it (`NavBarIconRow` with
    // `forceSelected` / `forceUnselected`) — so each label exists twice; the
    // layer that is tapped is irrelevant, both sit over the same full-height
    // tap cell. That cell, not the label, is the hit target (the glass layers
    // are painted above the text), hence `warnIfMissed: false`: a genuinely
    // missed tap still fails the `tabIndex` assertion that follows every call.
    await tester.tap(
      find.descendant(of: nav, matching: find.text(label)).first,
      warnIfMissed: false,
    );
    await settle(tester);
  }

  testWidgets('底部导航是四个 tab：首页 / 照片 / 设备 / 我的', (tester) async {
    await tester.pumpWidget(home());
    await settle(tester);

    expect(nav, findsOneWidget);
    // 「我的」是后加的第四个：账号原先挂在设备页底部的一个角落，那是个临时位置。
    for (final label in ['首页', '照片', '设备', '我的']) {
      expect(
        find.descendant(of: nav, matching: find.text(label)),
        findsNWidgets(2),
        reason: '导航栏里应当有「$label」这一个 tab（选中/未选中两层各绘制一次）',
      );
    }
    // The removed playback tab must not come back.
    expect(find.descendant(of: nav, matching: find.text('播放')), findsNothing);
  });

  testWidgets('默认进入首页，首页显示照片卡片', (tester) async {
    await tester.pumpWidget(home());
    await settle(tester);

    expect(tabIndex(tester), 0);
    // The device switcher and the read-only mode label belong to 首页.
    expect(find.byKey(const ValueKey('bloom-device-switcher')), findsOneWidget);
    expect(find.text('推荐模式'), findsOneWidget);
    // Neither header action is back: 刷新 was removed earlier (it duplicated
    // 下一张) and 下一张 itself was removed by the user.
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
    // The letter card is still there, with its caption and its 720x1200 ratio.
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AspectRatio && widget.aspectRatio == 720 / 1200,
      ),
      findsOneWidget,
    );
    expect(find.text('「测试照片」'), findsOneWidget);
    expect(find.text('2024.01.02'), findsOneWidget);
  });

  testWidgets('点「照片」→ 占位页，不是旧播放页', (tester) async {
    await tester.pumpWidget(home());
    await settle(tester);

    await tapTab(tester, '照片');

    expect(tabIndex(tester), 1);
    expect(find.text('照片库即将上线'), findsOneWidget);
    // Nothing from the deleted playback page may be reachable again.
    expect(find.text('播放'), findsNothing);
    expect(find.text('调整时间与频率'), findsNothing);
    expect(find.text('立即下一张'), findsNothing);
  });

  testWidgets('点「设备」→ 设备列表', (tester) async {
    await tester.pumpWidget(home());
    await settle(tester);

    await tapTab(tester, '设备');

    expect(tabIndex(tester), 2);
    expect(find.text('E-Ink'), findsOneWidget);
    // Each device is a tile: a small top line (type · state) over a large name.
    // See bloom_device_pages_test.
    // type == name, so the tile's meta line is only the live state
    expect(find.text('离线'), findsOneWidget);
    // 添加设备 is a bare ＋ in the header corner now, not a word in the list.
    expect(find.text('添加设备'), findsNothing);
    expect(find.byKey(const ValueKey('bloom-add-device')), findsOneWidget);
  });

  testWidgets('切回首页，照片卡片还在', (tester) async {
    await tester.pumpWidget(home());
    await settle(tester);

    await tapTab(tester, '照片');
    await tapTab(tester, '设备');
    await tapTab(tester, '首页');

    expect(tabIndex(tester), 0);
    expect(find.text('「测试照片」'), findsOneWidget);
  });

  testWidgets('首页模式只报短标签，长文案不再出现（推荐 / 轮播两种都要对）', (tester) async {
    // The mirror says 推荐; the server's own row (shown and edited on the
    // device detail page) can legitimately say something else. The home page
    // must only ever claim what the phone widget is really doing — and it now
    // says it as one short label instead of a second header row.
    Future<void> pumpWithMode(BloomDisplayMode mode) => tester.pumpWidget(
      MaterialApp(
        home: _Harness(
          initialTab: 0,
          onTabChanged: (_) {},
          photoPath: photoPath,
          credentials: credentials,
          mode: mode,
        ),
      ),
    );

    await pumpWithMode(BloomDisplayMode.recommendation);
    await settle(tester);

    expect(find.text('推荐模式'), findsOneWidget);
    expect(find.text('轮播模式'), findsNothing);
    // 推荐 has no "next photo", so the carousel action stays away.
    expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
    // The removed narration must not come back in any wording.
    expect(find.textContaining('本机小组件当前'), findsNothing);
    expect(find.text('在「设备」里可改'), findsNothing);
    expect(find.text('今日推荐'), findsNothing);
    expect(find.text('随机轮播'), findsNothing);

    await pumpWithMode(BloomDisplayMode.carousel);
    await settle(tester);

    expect(find.text('轮播模式'), findsOneWidget);
    expect(find.text('推荐模式'), findsNothing);
    // 下一张 is gone from the header at the user's request — in *both* modes,
    // because it was only ever rendered in 轮播 (and the phone's own widget is
    // normally in 推荐). `onNext` is still wired; nothing draws it.
    expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
  });

  testWidgets('头部行的缩进跟着信纸卡的真实宽度走（左右边缘都必须齐平）', (tester) async {
    // The user's own complaint: the mode label and the switcher stuck out past
    // the card below them.
    //
    // The subtlety this pins down is that the card is an `AspectRatio(720/1200)`
    // box, so on a **short** screen it is the height that runs out first and the
    // card ends up narrower than the column and centred. A row pinned to the
    // page inset (16) would then hang ~34px wider on each side. The viewport
    // below is deliberately short so that this is the case being tested.
    tester.view.physicalSize = const Size(1179, 2100);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(home());
    await settle(tester);

    final card = tester.getRect(find.byKey(const ValueKey('bloom-letter-card')));
    // The whole label block (glyph included), not the bare text: the glyph is
    // what the eye reads as its left edge.
    final mode = tester.getRect(find.byKey(const ValueKey('bloom-mode-tag')));
    final switcher = tester.getRect(
      find.byKey(const ValueKey('bloom-device-switcher')),
    );

    // Guard the test itself: if the card filled the column, the assertions
    // below would pass without proving anything.
    expect(
      card.left,
      greaterThan(BloomSurface.pageInset + 8),
      reason: '这个视口要能触发“高度先卡住、卡片比内容列窄”的情况',
    );
    expect(
      (mode.left - card.left).abs(),
      lessThan(0.6),
      reason: '模式标签的左边缘必须和卡片左边缘齐平',
    );
    expect(
      (switcher.right - card.right).abs(),
      lessThan(0.6),
      reason: '设备切换的右边缘必须和卡片右边缘齐平',
    );
  });

  testWidgets('顶部提示条必须避开状态栏和挖孔摄像头', (tester) async {
    // The reported bug: on a Xiaomi 14 the "扫码配对即将支持" toast sat *under the
    // front camera*. The cause is structural — the glass scaffold offsets its
    // nav bar by the system insets but lets its `lenses` span the whole window,
    // so a toast pinned at `top: 12` lands inside the status bar.
    const inset = 120.0; // logical px, a punch-hole phone
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: inset * 3);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(home(message: '扫码配对即将支持'));
    await settle(tester);

    // The toast's own box (the `_GlassMessage` padding just inside the glass),
    // not the text: the padding is what must clear the camera.
    final toast = tester.getRect(
      find
          .ancestor(
            of: find.text('扫码配对即将支持'),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(
      toast.top,
      greaterThanOrEqualTo(inset + 10),
      reason: '提示条必须落在状态栏/挖孔摄像头下方，而不是压在里面',
    );
  });

  testWidgets('首页头部一行两端：模式在左，设备切换在右', (tester) async {
    // The user asked for the one tappable control to sit where a right hand
    // already is, with the read-only label opposite it. Order is what carries
    // that, so it is asserted on real geometry rather than on the widget tree.
    await tester.pumpWidget(home());
    await settle(tester);

    final mode = tester.getRect(find.byKey(const ValueKey('bloom-mode-tag')));
    final switcher = tester.getRect(
      find.byKey(const ValueKey('bloom-device-switcher')),
    );
    expect(
      mode.center.dx,
      lessThan(switcher.center.dx),
      reason: '模式标签必须在左侧，设备切换必须在右侧',
    );
    // One row, one centre line. The control on the right is a *bare* glyph in a
    // 34px tap box, so aligning the boxes (as a first attempt did) left the
    // reading sitting ~10px below the arrow and looking unaligned — the user
    // caught exactly that: "切换按钮还是正方形的，所以没有和推荐模式对齐".
    expect(
      (mode.center.dy - switcher.center.dy).abs(),
      lessThan(1.5),
      reason: '模式标签必须和右侧切换图标在同一条中心线上',
    );
  });
  testWidgets('换图之后卡片只能剩一张（旧的必须真的退场）', (tester) async {
    // **真机上出现过：白色纸面上中文标题画了两遍。** 上面一层是大字（两行），
    // 下面一层是正常字号加英文和日期，中间一条接缝 —— 而且它**不会再自己
    // 消失**（用户原话："之前还能自动消失 现在不能了"）。
    //
    // 卡片外面套着 `AnimatedSwitcher` 做交叉淡出，它的自定义 `layoutBuilder`
    // 把上一张卡保留在 `Stack` 里。设计上假设"旧卡 480ms 后自己淡出消失"，
    // 只要这个假设不成立，两层就一直在。
    //
    // 这条用例把"树里有几张卡"变成可断言的数字，不再靠肉眼看截图。
    Widget withItem(int id) => MaterialApp(
      home: _Harness(
        initialTab: 0,
        onTabChanged: (_) {},
        photoPath: photoPath,
        credentials: credentials,
        recommendationId: id,
      ),
    );

    await tester.pumpWidget(withItem(3));
    await settle(tester);
    expect(find.text('「测试照片」'), findsOneWidget, reason: '一开始就该只有一张卡');

    // 换一张图 —— 这正是真机上发生的事：先显示缓存里那张，加载完再换成
    // 同步来的那一张。
    await tester.pumpWidget(withItem(4));
    await settle(tester);
    expect(
      find.text('「测试照片」'),
      findsOneWidget,
      reason: '换图之后旧卡片必须已经退场，否则纸面上会叠出两层标题',
    );
  });
}

/// Owns the selected tab so a tap on the nav bar really swaps pages.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.initialTab,
    required this.onTabChanged,
    required this.photoPath,
    required this.credentials,
    this.mode = BloomDisplayMode.recommendation,
    this.message,
    this.recommendationId = 3,
  });

  final int initialTab;
  final ValueChanged<int> onTabChanged;
  final String photoPath;
  final DeviceCredentials credentials;
  final BloomDisplayMode mode;
  final String? message;

  /// 让用例能换一张"当前展示的照片" —— 卡片的 key 跟着它走，所以换它就是
  /// 触发一次换图动画。
  final int recommendationId;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late int _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) => BloomGlassHome(
    message: widget.message,
    loading: false,
    nextLoading: false,
    selectedTab: _tab,
    credentials: widget.credentials,
    portrait: CachedWidgetImage(
      path: widget.photoPath,
      orientation: 'portrait',
      date: '2026-08-13',
      recommendationId: widget.recommendationId,
    ),
    originalPhotoPath: widget.photoPath,
    content: DailyContent(
      date: '2026-08-13',
      recommendationId: widget.recommendationId,
      captionZh: '测试照片',
      capturedDateText: '2024.01.02',
      locationText: '天津',
    ),
    date: '2026-08-13',
    settings: BloomDisplaySettings(mode: widget.mode),
    devices: bloomDevices(
      credentials: widget.credentials,
      localOnline: true,
    ),
    selectedDeviceId: widget.credentials.deviceId,
    onTabChanged: (index) {
      setState(() => _tab = index);
      widget.onTabChanged(index);
    },
    onRefresh: () async {},
    onNext: () {},
    onDeviceChanged: (_) {},
    onOpenDevice: (_) {},
    onAddDevice: () {},
    onCopyDeviceId: () {},
    account: fakeAccount(),
  );
}
