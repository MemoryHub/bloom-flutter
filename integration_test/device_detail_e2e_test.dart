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
  Future<void> openPhoneDetail(WidgetTester tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 4));

    // `.last` because the glass nav keeps two copies of every tab label (a 45%
    // rest copy and a 100% selected copy) for its cross-fade — the selected one
    // is the later of the two in paint order.
    await tester.tap(find.text('设备').last);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The phone's tile, not the frame's.
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
    expect(find.textContaining('每天一张'), findsWidgets);
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
