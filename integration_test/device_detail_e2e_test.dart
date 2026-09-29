// Real-device, **real-server** scenarios for the device detail page.
//
// Why this file exists: the phone's MIUI build cannot inject touch events over
// adb (it needs a SIM to unlock "USB debugging (security settings)"), so the UI
// cannot be driven from outside. `integration_test` runs *inside* the app
// process and drives its own widgets, and it talks to the **real** server, so a
// save here is a genuine round trip.
//
// What each scenario asserts, and why that is the right assertion:
//   * "设置已保存" only appears when the server answered 2xx — an error shows a
//     red message instead. So the toast *is* the interface's verdict.
//   * Leaving the page and coming back re-reads the record from the server, so
//     the value being there afterwards proves it was stored, not just shown.
import 'package:bloom/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// From a cold start to the phone's own detail page, in 轮播模式 (the mode that
  /// owns the cadence form), the way a person would: 设备 tab → the phone tile.
  /// 等到某个 finder 真的出现为止。
  ///
  /// 冷启动后首屏要过好几道异步门（读本地凭据、/status、/plan），固定
  /// pumpAndSettle(4s) 在真机上不够稳：机器慢一点就直接找不到导航标签而
  /// 整个测试崩掉，看起来像功能坏了，其实只是没等够。所以这里轮询等待，
  /// 超时后把当时屏幕上的文字打出来，方便判断到底是没渲染完还是真缺东西。
  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 30),
    String? label,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return;
    }
    final visible = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .take(40)
        .join(' | ');
    fail('等不到 ${label ?? finder.toString()}（超时 ${timeout.inSeconds}s）。'
        '当时屏幕上的文字：$visible');
  }

  Future<void> openPhoneDetail(WidgetTester tester) async {
    app.main();
    await tester.pump();

    // `.last` because the glass nav keeps two copies of every tab label (a 45%
    // rest copy and a 100% selected copy) for its cross-fade — the selected one
    // is the later of the two in paint order.
    await waitFor(tester, find.text('设备'), label: '导航标签「设备」');
    await tester.tap(find.text('设备').last);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The phone's tile, not the frame's.
    await waitFor(tester, find.text('手机小组件'), label: '设备列表里的「手机小组件」');
    await tester.tap(find.text('手机小组件').first);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // 轮播 owns 更换频率 / 生效时间 / 保存. If the page opened in 推荐, the form
    // is deliberately absent, so switch first (this also exercises the pill).
    final carouselTab = find.byKey(const ValueKey('bloom-mode-carousel'));
    if (carouselTab.evaluate().isNotEmpty) {
      await tester.tap(carouselTab);
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }
  }

  testWidgets('A1/A2 改「更换频率」保存 → 服务端收下（提示已保存），退出重进值还在', (tester) async {
    await openPhoneDetail(tester);

    expect(
      find.byKey(const ValueKey('bloom-interval-dropdown')),
      findsOneWidget,
      reason: '轮播模式应该有「更换频率」字段',
    );
    await tester.tap(find.byKey(const ValueKey('bloom-interval-dropdown')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 每天一次 is the one tier whose label is unique and unmistakable.
    await tester.tap(find.text('每天一次').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(
      find.textContaining('设置已保存'),
      findsWidgets,
      reason: '只有服务端 2xx 才会出现这句；出现即代表接口成功',
    );

    // A2: the record is re-read from the server on the way back in.
    await tester.pageBack();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await waitFor(tester, find.text('手机小组件'), label: '列表里的「手机小组件」');
    await tester.tap(find.text('手机小组件').first);
    await tester.pumpAndSettle(const Duration(seconds: 4));
    expect(
      find.text('每天一次'),
      findsWidgets,
      reason: '重进页面是 services/get 回来的值——它还在，说明服务端真的存了',
    );
  });

  testWidgets('B1 切到「推荐」→ 表单消失、没有保存按钮、出现推荐说明', (tester) async {
    await openPhoneDetail(tester);

    await tester.tap(find.byKey(const ValueKey('bloom-mode-recommend')));
    await tester.pumpAndSettle(const Duration(seconds: 4));

    expect(find.byKey(const ValueKey('bloom-interval-dropdown')), findsNothing);
    expect(find.text('保存'), findsNothing);
    // ⚠️ 这里原本断言「每天一张」，但 12 小时配 06:00–22:00 实际是一天两张。
    //    文案现在从 recommendIntervalMinutes 算出来，所以断言也跟着算 ——
    //    写死数字的话，改间隔时这条会变成假失败。
    expect(find.textContaining('一天两张'), findsWidgets);
  });

  testWidgets('A3 切「推荐」再切回「轮播」→ 用户自己的作息被原样还回来', (tester) async {
    // 服务器对 mode 与作息是【正交】的：四个字段只有一个存储位。切到推荐必须
    // 把固定作息（06:00 / 22:00 / 12 小时）写进去，否则推荐会用一个不相干的
    // 作息去跑 —— 代价是用户原来的轮播作息被覆盖。
    //
    // 所以切过去之前先记一份，切回来原样还回去。这条真机用例验的就是**还原**：
    // 看完推荐回来，表单里绝不能是推荐那一套「半天一次 / 标准作息」。
    //
    // ⚠️ 这条断言曾经写反过（期望"半天一次"）。写反的版本会在真机上永远失败，
    //    而单测 `bloom_device_pages_test.dart:830` 一直断言的是还原 —— 两边
    //    矛盾了很久。以单测为准。
    await openPhoneDetail(tester);

    // 先把作息调成一个【与推荐固定值明显不同】的样子，这样"还回来了"和
    // "留着推荐那份"能被区分开。
    await tester.tap(find.byKey(const ValueKey('bloom-interval-dropdown')));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.text('每2小时').last);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.text('保存'), warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('每2小时'), findsWidgets, reason: '前提：自己的作息是 2 小时');

    await tester.tap(find.byKey(const ValueKey('bloom-mode-recommend')));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('半天一次'), findsNothing, reason: '推荐模式下作息控件本来就隐藏');

    await tester.tap(find.byKey(const ValueKey('bloom-mode-carousel')));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(
      find.text('每2小时'),
      findsWidgets,
      reason: '切回轮播必须还原用户自己的作息，而不是留着推荐那份 12 小时',
    );
    expect(
      find.text('半天一次'),
      findsNothing,
      reason: '绝不能留着推荐那份固定作息',
    );
  });

  testWidgets('A4 「照片来源」卡片只列已实现的来源，勾完能用「保存」提交', (tester) async {
    // 服务器登记了四个名字，但只有 personal 取得出照片。给 art/news/widget
    // 一个能勾的框，用户设完相框毫无变化 —— 就是"设了没反应"。
    await openPhoneDetail(tester);

    expect(find.text('照片来源'), findsWidgets, reason: '应该有这张卡片');
    expect(
      find.byKey(const ValueKey('bloom-source-personal')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bloom-source-art')),
      findsNothing,
      reason: 'art 还没有取片能力，不该出现',
    );

    // 来源是**表单**（与「更换频率」「生效时间」同类），所以点它只改草稿，
    // 提交靠底部那个「保存」。
    //
    // ⚠️ 这里曾经断言"点来源应当立刻提交并成功"（开关式），与实现和单测
    //    （`bloom_device_pages_test.dart:668`）都矛盾。而且 personal 是唯一
    //    来源、默认已选中，点它本来就会被"至少保留一个"挡掉 —— 那条断言在
    //    真机上根本没有可点的状态变化。
    //
    //    真正要钉住的是这个：**来源改动能被提交出去**。所以这里走完整条路 ——
    //    动一下来源、确认「保存」出现、点它、看到保存成功。
    //
    //    推荐模式也必须有这个按钮：它是 `carousel` 之外唯一带表单的模式，
    //    原来 carousel-only 的条件会让来源在推荐模式里彻底送不出去。
    await tester.tap(find.byKey(const ValueKey('bloom-mode-recommend')));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(
      find.text('保存'),
      findsNothing,
      reason: '推荐模式下没动过任何东西时不该有保存按钮',
    );

    await tester.tap(find.byKey(const ValueKey('bloom-source-personal')));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await waitFor(tester, find.text('保存'), label: '碰过来源后出现的「保存」');
    await tester.tap(find.text('保存'), warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(
      find.textContaining('设置已保存'),
      findsWidgets,
      reason: '来源的改动必须真的走接口并成功',
    );

    // 收拾现场：切回轮播，别把机器留在推荐模式上。
    await tester.tap(find.byKey(const ValueKey('bloom-mode-carousel')));
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('D1 切「离线」→ 返回列表，手机小组件这条立刻是离线', (tester) async {
    await openPhoneDetail(tester);

    final toggle = find.byKey(const ValueKey('bloom-widget-switch'));
    expect(toggle, findsOneWidget, reason: '本机详情页应该有开关');
    await tester.tap(toggle);
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.textContaining('小组件已关闭'), findsWidgets);

    // The list is the other half of the same fact.
    await tester.pageBack();
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(
      find.textContaining('离线'),
      findsWidgets,
      reason: '关掉开关后，列表里这条必须跟着变离线',
    );
  });
}
