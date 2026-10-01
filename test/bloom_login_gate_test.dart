import 'dart:convert';
import 'dart:io';

import 'package:bloom/core/models/auth_models.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/auth/auth_repository.dart';
import 'package:bloom/core/storage/device_identity_repository.dart';
import 'package:bloom/main.dart';
import 'package:bloom/ui/bloom_auth_pages.dart';
import 'package:bloom/ui/bloom_device_pages.dart';
import 'package:bloom/ui/bloom_glass_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_account.dart';

/// 每个页面在**未登录**时的表现。
///
/// 这一组测试守的是一条产品决定：**不做开屏强制登录，但四个页面各自挡住** ——
/// 首页 / 照片 / 设备 / 我的，没登录时都只显示一段各自措辞的说明加一个登录
/// 按钮，而不是显示一份假内容或一个空页面。
///
/// 之所以值得单独一组测试：这个行为靠"每个页面自己记得 gate"来实现，将来加
/// 第五个页面、或有人图省事把某页的 gate 去掉，界面不会报错、只会静静地漏出
/// 内容 —— 那种回归没人会注意到。
void main() {
  final credentials = DeviceCredentials(
    deviceId: 'bloom-mobile-test',
    deviceToken: 'a' * 64,
  );

  // 首页的卡片是 `Image.file`，路径必须真实存在，否则会退化成占位图，
  // "看到内容"的断言就失去意义了。
  late final String photoPath;
  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('bloom-login-gate-test');
    final file = File('${dir.path}/photo.png');
    file.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ),
    );
    photoPath = file.path;
  });

  /// 玻璃动画不会真正 settle，按帧推完即可。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    required AccountInfo? account,
    int tab = 0,
    VoidCallback? onSignIn,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _GateHarness(
          initialTab: tab,
          credentials: credentials,
          photoPath: photoPath,
          account: account,
          onSignIn: onSignIn,
        ),
      ),
    );
    await settle(tester);
  }

  /// 切到某个 tab 并等动画结束。
  ///
  /// 必须把查找范围限定在导航栏内：页面自己的标题也叫「照片」「设备」，
  /// 而 `IndexedStack` 会把四个页面全部建出来，全局查找会命中好几处。
  Future<void> goToTab(WidgetTester tester, String label) async {
    await tester.tap(
      find
          .descendant(
            of: find.byType(LiquidGlassBottomNavBar),
            matching: find.text(label),
          )
          .first,
      warnIfMissed: false,
    );
    await settle(tester);
  }

  group('手机号打码', () {
    // 服务端存的是 E.164。曾经的实现直接取前 3 位，于是界面上显示
    // `861****7800` —— 国码被当成了号码开头。"我的"页会把它当作最显眼的
    // 身份信息放在昵称下面，所以这条不是小事。
    test('E.164 号码剥掉国码后再打码', () {
      expect(fakeAccount(phone: '+8618611137800').maskedPhone, '186****7800');
    });

    test('不带国码的号码照常打码', () {
      expect(fakeAccount(phone: '18611137800').maskedPhone, '186****7800');
    });

    test('过短的号码原样返回，不越界', () {
      expect(fakeAccount(phone: '12345').maskedPhone, '12345');
    });
  });

  group('未登录', () {
    for (final entry in const [
      (tab: 0, label: '首页', key: 'bloom-home-signed-out'),
      (tab: 1, label: '照片', key: 'bloom-photos-signed-out'),
      (tab: 2, label: '设备', key: 'bloom-devices-signed-out'),
      (tab: 3, label: '我的', key: 'bloom-profile-signed-out'),
    ]) {
      testWidgets('「${entry.label}」页给出登录提示与登录按钮', (tester) async {
        await pump(tester, account: null, tab: entry.tab);
        expect(
          find.byKey(ValueKey(entry.key)),
          findsOneWidget,
          reason: '${entry.label}页在未登录时必须显示登录提示',
        );
        // 提示里必须真的有一个能点的登录按钮，否则这段文字就是死路。
        expect(find.widgetWithText(BloomPrimaryButton, '登录'), findsOneWidget);
      });
    }

    testWidgets('四个 tab 都能切换，各自显示自己的登录提示', (tester) async {
      await pump(tester, account: null);
      // 未登录时导航栏**必须还在**：把关卡套在整个 scaffold 外面虽然更省事，
      // 但那样连 tab 都没了，用户连"这是哪一页"都看不出来。
      expect(find.byKey(const ValueKey('bloom-home-signed-out')), findsOneWidget);

      await goToTab(tester, '照片');
      expect(find.byKey(const ValueKey('bloom-photos-signed-out')), findsOneWidget);
      await goToTab(tester, '设备');
      expect(find.byKey(const ValueKey('bloom-devices-signed-out')), findsOneWidget);
      await goToTab(tester, '我的');
      expect(find.byKey(const ValueKey('bloom-profile-signed-out')), findsOneWidget);
      await goToTab(tester, '首页');
      expect(find.byKey(const ValueKey('bloom-home-signed-out')), findsOneWidget);
    });

    testWidgets('点登录按钮会触发登录入口', (tester) async {
      var tapped = 0;
      await pump(tester, account: null, onSignIn: () => tapped++);
      await tester.tap(find.widgetWithText(BloomPrimaryButton, '登录'));
      await settle(tester);
      expect(tapped, 1);
    });

    testWidgets('照片页保留原来的插画与文案，只是多了一个登录按钮', (tester) async {
      await pump(tester, account: null, tab: 1);
      // 用户明确要求"中间是个图标、下面字不变"：这两句不能被提示语替换掉。
      expect(find.text('照片库即将上线'), findsOneWidget);
      expect(find.text('以后可以在这里回看每天推荐过的照片。'), findsOneWidget);
      expect(find.widgetWithText(BloomPrimaryButton, '登录'), findsOneWidget);
    });

    testWidgets('设备页不显示任何设备（没有账号就没有设备列表）', (tester) async {
      await pump(tester, account: null, tab: 2);
      // 兜底硬编码相框不能漏出来：那会显示一台用户并没有的设备。
      expect(find.text('E-Ink'), findsNothing);
      expect(find.byKey(ValueKey(bloomBundledFrame.deviceId)), findsNothing);
    });

    testWidgets('「我的」页不显示退出登录（没有账号可退）', (tester) async {
      await pump(tester, account: null, tab: 3);
      expect(find.text('退出登录'), findsNothing);
    });
  });

  group('已登录', () {
    testWidgets('「我的」页显示昵称、打码手机号与退出登录', (tester) async {
      await pump(
        tester,
        account: fakeAccount(nickname: 'Alex', phone: '+8618611137800'),
        tab: 3,
      );
      expect(find.byKey(const ValueKey('bloom-profile-signed-out')), findsNothing);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('186****7800'), findsOneWidget);
      expect(find.byKey(const ValueKey('bloom-profile-sign-out')), findsOneWidget);
    });

    testWidgets('「我的」页未就绪时说明正在准备相册', (tester) async {
      await pump(tester, account: fakeProvisioningAccount(), tab: 3);
      expect(find.textContaining('正在准备你的相册'), findsOneWidget);
    });

    testWidgets('首页显示内容而不是登录提示', (tester) async {
      await pump(tester, account: fakeAccount());
      expect(find.byKey(const ValueKey('bloom-home-signed-out')), findsNothing);
      expect(find.text('首页'), findsWidgets);
    });

    testWidgets('照片页仍是即将上线（登录后也一样，上传还没做）', (tester) async {
      await pump(tester, account: fakeAccount(), tab: 1);
      expect(find.text('照片库即将上线'), findsOneWidget);
      expect(find.byKey(const ValueKey('bloom-photos-signed-out')), findsNothing);
    });
  });

  testWidgets('四个 tab 在窄屏上不溢出（3 个变 4 个最容易挤爆）', (tester) async {
    // 360×800 逻辑像素：比这台小米 14 还窄，用来兜住中文标签在窄屏上
    // 把导航栏撑爆的情况。Flutter 的溢出在测试里会变成异常，所以断言
    // "没有异常"就够。
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await pump(tester, account: fakeAccount());
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录前后切换：提示消失、内容出现', (tester) async {
    await pump(tester, account: null, tab: 3);
    expect(find.byKey(const ValueKey('bloom-profile-signed-out')), findsOneWidget);

    // 同一个页面重新 pump 成已登录，等价于登录成功后 UI 重建。
    await pump(tester, account: fakeAccount(nickname: 'Alex'), tab: 3);
    expect(find.byKey(const ValueKey('bloom-profile-signed-out')), findsNothing);
    expect(find.text('Alex'), findsOneWidget);
  });

  /// **登录成功之后必须自己去取一次图。**
  ///
  /// 这条守的是一个真实发生过的故障：`_load()` 改成"未登录就什么都不做"之后，
  /// 启动时那一次（还没有会话）变成空跑，而登录成功之后没有任何地方会重来一次 ——
  /// 页面于是停在空态、永远不换图。服务端日志里除了那次 `claim` 之外，看不到
  /// 该设备的任何 `/status` 请求，这就是当时的现场。
  ///
  /// 之所以不能只靠"四个页面各自挡住"那组用例：那些用例验的是**渲染**，
  /// 而这里漏掉的是**取数**。渲染全对、就是不联网，界面上看不出区别。
  testWidgets('登录成功后会自动请求本机状态（不会停在空态）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <String>[];
    final secure = <String, String>{};

    // ⚠️ 必须带 charset：`http.Response(body, 200)` 默认按 latin-1 编码，
    //    body 里只要有中文就抛 ArgumentError（看起来像"网络异常"）。
    const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

    Future<http.Response> handler(http.Request request) async {
      final path = request.url.path;
      requests.add('${request.method} $path');
      if (path.endsWith('/auth/login')) {
        return http.Response(
          jsonEncode({
            'token': 'session-token',
            'expires_at': '2030-01-01T00:00:00Z',
            'account': {
              'id': 'acc-1',
              'phone': '+8613800138000',
              'nickname': '测试',
              'provision_status': 'ready',
              'immich_ready': true,
            },
            // 相册已就绪的账号，登录响应里直接带着设备令牌。
            'device': {'device_id': 'bloom-mobile-test', 'device_token': 'd' * 64},
          }),
          200,
          headers: jsonHeaders,
        );
      }
      if (path.endsWith('/status')) {
        return http.Response(
          jsonEncode({'paired': true, 'has_assets': false, 'mode': 'recommend'}),
          200,
          headers: jsonHeaders,
        );
      }
      return http.Response('{}', 404);
    }

    final client = MockClient(handler);
    final identity = DeviceIdentityRepository(
      readToken: (key) async => secure[key],
      writeToken: (key, value) async => secure[key] = value,
      mirrorToWidget: (_, _) async {},
    );
    final api = BloomApiClient(
      baseUrl: 'https://bloom.jihu.top',
      client: client,
    );
    final auth = AuthRepository(
      api: BloomApiClient(baseUrl: 'https://bloom.jihu.top', client: client),
      readValue: (_) async => null,
      writeValue: (_, _) async {},
      deleteValue: (_) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BloomHomePage(
          identity: identity,
          api: api,
          displayPreferences: DisplayPreferences(api: api),
          auth: auth,
        ),
      ),
    );
    await settle(tester);

    expect(
      requests.where((r) => r.contains('/devices/')),
      isEmpty,
      reason: '未登录时一个设备请求都不该发出去',
    );

    // 走完整的登录流程：点登录入口 → 填手机号与验证码 → 提交。
    await tester.tap(find.widgetWithText(BloomPrimaryButton, '登录').first);
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), '13800138000');
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(BloomAuthPage),
        matching: find.widgetWithText(BloomPrimaryButton, '登录'),
      ),
    );
    // 登录 → 认领设备 → 列设备 → 取图，中间有多次 await，多推几帧。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      requests.any((r) => r.contains('/devices/') && r.endsWith('/status')),
      isTrue,
      reason: '登录成功后必须自己去取一次图，否则页面停在空态、永远不换图。'
          '实际发出的请求：$requests；'
          '登录页还在吗：${find.byType(BloomAuthPage).evaluate().isNotEmpty}；'
          '屏幕上的文字：${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).where((t) => t != null).toList()}',
    );
  });
}

/// 拥有当前 tab 的宿主，这样点导航栏是真的换页。
class _GateHarness extends StatefulWidget {
  const _GateHarness({
    required this.initialTab,
    required this.credentials,
    required this.photoPath,
    required this.account,
    this.onSignIn,
  });

  final int initialTab;
  final DeviceCredentials credentials;
  final String photoPath;
  final AccountInfo? account;
  final VoidCallback? onSignIn;

  @override
  State<_GateHarness> createState() => _GateHarnessState();
}

class _GateHarnessState extends State<_GateHarness> {
  late int _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) => BloomGlassHome(
    loading: false,
    nextLoading: false,
    selectedTab: _tab,
    credentials: widget.credentials,
    originalPhotoPath: widget.photoPath,
    content: const DailyContent(
      date: '2026-08-13',
      recommendationId: 3,
      captionZh: '测试照片',
      capturedDateText: '2024.01.02',
      locationText: '天津',
    ),
    date: '2026-08-13',
    settings: const BloomDisplaySettings(mode: BloomDisplayMode.recommendation),
    devices: bloomDevices(credentials: widget.credentials, localOnline: true),
    selectedDeviceId: widget.credentials.deviceId,
    onTabChanged: (index) => setState(() => _tab = index),
    onRefresh: () async {},
    onNext: () {},
    onDeviceChanged: (_) {},
    onOpenDevice: (_) {},
    onAddDevice: () {},
    onCopyDeviceId: () {},
    account: widget.account,
    onAccountTap: widget.onSignIn,
  );
}
