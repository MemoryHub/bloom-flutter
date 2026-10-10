import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'background_sync.dart';
import 'core/api/bloom_api_client.dart';
import 'core/auth/auth_repository.dart';
import 'core/models/auth_models.dart';
import 'core/models/device_models.dart';
import 'core/storage/daily_content_repository.dart';
import 'core/storage/device_identity_repository.dart';
import 'core/storage/display_preferences.dart';
import 'core/storage/content_sync_epoch.dart';
import 'platform/widget_bridge.dart';
import 'ui/bloom_auth_pages.dart';
import 'ui/bloom_device_pages.dart';
import 'ui/bloom_photo_library_page.dart';
import 'ui/bloom_device_sharing_page.dart';
import 'ui/bloom_confirmation_dialog.dart';
import 'package:bloom_widget_bridge/bloom_widget_bridge.dart';
import 'ui/bloom_glass_home.dart';
import 'ui/bloom_discover_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  // The Impeller shader path used by liquid_glass_easy triggers a Metal BIF0
  // page fault on the tested iPhone 12 Pro / iOS 18.4.1.  Do not hold the
  // first Flutter frame behind shader compilation on iOS; LiquidGlassView
  // loads its Skia programs asynchronously and keeps the normal UI visible.
  if (!Platform.isIOS) {
    await LiquidGlassShaders.ensureLoaded();
  }
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  // **两端都要初始化后台任务。** iOS 上这一步同时承担两件事：写进
  // workmanager 的 Dart 回调句柄（没有它，系统就算唤醒了也跑不到我们的代码），
  // 以及（配合 `configureBackgroundSync`）真正向 BGTaskScheduler **提交**一次
  // 周期请求。历史上这里只对安卓调用，于是 iOS 侧"声明了标识符、注册了
  // handler，却永远没有请求被提交"——小组件的补货因此只存在于 App 还活着的时候。
  await initializeBackgroundSync();
  runApp(const BloomApp());
}

class BloomApp extends StatelessWidget {
  const BloomApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Bloom',
    debugShowCheckedModeBanner: false,
    // Dark, top to bottom — including every stock Material surface the app still
    // opens: the time picker, a snack bar, the device sheet, text-selection
    // handles, the dropdown's own menu. Without this the rebuilt pages would pop
    // bright white dialogs, which is the one seam that would give the redesign
    // away. Both slots carry the same theme so the system's light/dark setting
    // cannot flip half the app back.
    themeMode: ThemeMode.dark,
    theme: _bloomDarkTheme,
    darkTheme: _bloomDarkTheme,
    home: const BloomHomePage(),
  );
}

/// The Material shell under the app's own ink-and-paper system.
///
/// Only the pieces the app does not draw itself are configured here; everything
/// visible in a Bloom screen comes from [BloomInk] / [BloomType].
final _bloomDarkTheme = ThemeData(
  brightness: Brightness.dark,
  colorScheme: const ColorScheme.dark(
    primary: BloomInk.text,
    onPrimary: BloomInk.inverseInk,
    secondary: BloomInk.accent,
    surface: BloomInk.panel,
    onSurface: BloomInk.text,
  ),
  scaffoldBackgroundColor: BloomInk.page,
  canvasColor: BloomInk.panel,
  splashFactory: InkRipple.splashFactory,
  useMaterial3: true,
);

class BloomHomePage extends StatefulWidget {
  const BloomHomePage({
    super.key,
    this.identity,
    this.api,
    this.displayPreferences,
    this.auth,
  });

  /// Test seams. Production passes nothing and the state builds the real
  /// collaborators; the widget tests inject a stub identity and a stubbed
  /// `http.Client` so `_load()` can be observed (in particular the requests it
  /// must *not* make).
  final DeviceIdentityRepository? identity;
  final BloomApiClient? api;
  final DisplayPreferences? displayPreferences;

  /// 账号会话（F1）。生产不传，由状态自己建。
  final AuthRepository? auth;

  @override
  State<BloomHomePage> createState() => _BloomHomePageState();
}

class _BloomHomePageState extends State<BloomHomePage>
    with WidgetsBindingObserver {
  late final DeviceIdentityRepository _identity =
      widget.identity ?? DeviceIdentityRepository();
  late final BloomApiClient _api = widget.api ?? BloomApiClient();
  late final DisplayPreferences _displayPreferences =
      widget.displayPreferences ?? DisplayPreferences();
  late final AuthRepository _auth = widget.auth ?? AuthRepository();

  Timer? _messageTimer;

  /// Turns the page when its slot arrives while the app is open.
  Timer? _slotWatch;

  /// Fires exactly when the next slot begins.
  Timer? _slotWake;
  Timer? _followNative;
  Timer? _deviceListWatch;
  Timer? _accountReadyRetry;
  int _accountRetryAttempt = 0;
  bool _accountRefreshInFlight = false;
  bool? _hasAssets;
  String? _contentError;
  DeviceCredentials? _credentials;
  CachedWidgetImage? _portrait;
  DailyContent? _content;
  String? _originalPhotoPath;
  int? _nextSlotAt;
  bool _loadInFlight = false;
  bool _loadPending = false;
  int _settingsRevision = 0;
  DateTime? _pausedAt;
  String? _date;
  String? _message;

  /// The master switch, mirrored from the device page: off means the widget is
  /// not running and this page must not fetch anything.
  bool _widgetEnabled = true;
  bool _paired = false;
  bool _loading = true;
  bool _nextLoading = false;
  int _selectedTab = 0;

  /// Device whose photos the photo page shows. `null` = this phone (the only
  /// device whose photos the app can load).
  String? _photoDeviceId;
  BloomDisplaySettings _displaySettings = const BloomDisplaySettings();

  /// F1 账号状态。
  ///
  /// [_account] 为 null 表示未登录；退出会清除取图凭据，
  /// 首页不发内容请求，小组件清除旧账号画面和预存时间线。
  AccountInfo? _account;

  /// 登录后从服务端取回的设备归属关系。相册成员不进入这个列表；
  /// 请求尚未返回时，仅用本机作为占位。
  List<UserDevice> _remoteDevices = const [];
  String? _devicesLoadingToken;
  int _devicesRequestGeneration = 0;

  bool _accountBusy = false;
  bool _signOutConfirming = false;

  @override
  void initState() {
    super.initState();
    _deviceListWatch = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _pausedAt == null && _selectedTab == 3) {
        unawaited(_loadRemoteDevices());
      }
    });
    // **Follow the widget continuously.** The app read the native current item only
    // while it ran a sync, so between syncs the widget could advance while the card
    // stayed behind — the "widget and app show different photos" symptom. Re-reading
    // it every 20 s while the page is alive removes the gap by construction.
    _followNative = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!mounted || _loading || !_auth.isSignedIn) return;
      final revision = _settingsRevision;
      final repository = DailyContentRepository(api: _api);
      await repository.drainWidgetTimelineLog();
      if (!mounted || revision != _settingsRevision) return;
      final nextAt =
          _displaySettings.mode == BloomDisplayMode.carousel
              ? await repository.nextSlotAtMillis()
              : _nextRecommendSlotMs(_displaySettings);
      if (!mounted || revision != _settingsRevision) return;
      if (nextAt != null && nextAt != _nextSlotAt) {
        setState(() => _nextSlotAt = nextAt);
        unawaited(_armNextSlotWake());
      }
      final expectedMode =
          _displaySettings.usesScheduledPlan ? 'carousel' : 'recommend';
      final native = await repository.nativeContent(expectedMode: expectedMode);
      if (!mounted || native == null) return;
      if (native.recommendationId == _content?.recommendationId &&
          _hasAssets != false &&
          _contentError == null) {
        return;
      }
      // ⚠️ **照片要跟着动，不能只换文案。** 原来这里只 setState 了 `_content`
      //    （文案），照片仍是上一张 —— 而 [Repository.photoPathFor] 按 id 取
      //    路径这件事本来就是为「照片与文案同源」做的。只换文案正好把这条
      //    保证拆掉：卡片会显示 A 的图配 B 的字。
      //    冷启动时这个定时器以前被 `_loading` 挡着（一轮 sync 要 60 秒），
      //    现在本机那张会先被画上去，`_loading` 提前转 false，它就会真的跑 ——
      //    所以这里必须把路径一起换掉。
      final path = await repository.photoPathFor(
        native.recommendationId,
        mode: expectedMode,
      );
      if (!mounted || revision != _settingsRevision || path == null) return;
      final portrait = await repository.cached('portrait');
      setState(() {
        _content = native;
        // Background sync can receive a contributor's first photo while the
        // foreground still remembers the device's earlier empty-library status.
        // Adopt readiness with the verified local image, not only its pixels.
        _hasAssets = true;
        _paired = true;
        _contentError = null;
        _originalPhotoPath = path;
        _portrait =
            portrait?.recommendationId == native.recommendationId
                ? portrait
                : null;
      });
      unawaited(_armNextSlotWake());
    });
    WidgetsBinding.instance.addObserver(this);
    _startSlotWatch();
    // **先恢复登录态，再跑 `_load`（在 `_restoreAuth` 里）。**
    //
    // `_load()` 现在的第一步是"未登录就什么都不做"，所以顺序反过来的话，它会
    // 在一份还没恢复出会话的状态下跑完，登录用户的首屏就永远停在骨架屏上。
    // 恢复会话只是一次本地读，代价可以忽略。
    unawaited(_restoreAuth());
  }

  /// **The page turns itself, like the widget does.**
  ///
  /// This is the feature that was rolled back by mistake: it *did* advance the
  /// home page on its own, and it was removed together with the flash it caused
  /// instead of the flash being fixed. Both flash causes are now closed — the
  /// switcher stays mounted (so its state, and the outgoing photo, survive) and
  /// it is keyed by the item id rather than the path (which flapped between
  /// `carousel-original-<id>.photo` and `original.photo` for the same picture).
  /// With those in place a re-read no longer repaints anything unless the photo
  /// really changed.
  ///
  /// The precise version of this — wake once, exactly at `next_slot_at_ms`, now
  /// written next to the photo — is a refinement; this interval already turns the
  /// page within half a minute of its slot.
  void _startSlotWatch() {
    _slotWatch?.cancel();
    _slotWatch = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!mounted || _loading || !_widgetEnabled) return;
      // A new device has no grid to be behind. While it is open, recheck an
      // empty library so another account's first contribution becomes visible
      // without requiring the owner to restart the app.
      if (_hasAssets == false &&
          _pausedAt == null &&
          _auth.isSignedIn &&
          _account?.immichReady == true) {
        await _load(showSpinner: false);
        return;
      }
      // **Only the fallback it was always described as.** The one-shot timer
      // above wakes exactly at `next_slot_at_ms`; polling on top of it made the
      // app re-sync every 30 seconds for as long as the page was on screen, and
      // every pass fetched the next page — which the bounded pool then trimmed,
      // while the trimming deleted the very files the pool still pointed at.
      // **判据必须是「落后了吗」，不能是「下一格还在未来吗」。**
      //
      // 后者按定义恒为真——`nextSlotAtMillis()` 返回的永远是未来的一格，
      // `at > now - 5000` 没有例外——于是这个兜底此前**一次都没有执行过**。
      // 页面一旦错过上面那次一次性唤醒，就再无补救（实测：21:15 该换的图
      // 拖到 21:17 才换）。
      //
      // 现在改成问「此刻应有的那一格，比状态里记的当前格更新吗」。只有真落后
      // 才补一次 sync，没落后就安静地跳过——30 秒一轮，代价可以忽略。
      final repository = DailyContentRepository(api: _api);
      if (!await repository.isBehind()) return;
      if (!mounted || _loading) return;
      await _load(showSpinner: false);
    });
    _armNextSlotWake();
  }

  /// **One wake-up per slot, at the slot's own moment.**
  ///
  /// `next_slot_at_ms` is written by every sync with the same number the native
  /// alarm chain arms itself with, so waking on it means the page and the widget
  /// turn at the same instant. The interval above stays only as a fallback for
  /// when the file is missing, the slot is in the past, or the write raced the
  /// read — it is no longer the mechanism.
  Future<void> _armNextSlotWake() async {
    _slotWake?.cancel();
    // ⚠️ 推荐的下一格**不在** `next_slot_at_ms` 里（那是轮播的戳，推荐路径不写）。
    //    在推荐模式下读它只会拿到上一轮轮播留下的过期值，于是这次唤醒要么永远
    //    不响、要么在错误的时刻响。两边用同一个来源：推荐按固定作息算。
    final at =
        _displaySettings.mode != BloomDisplayMode.carousel
            ? _nextRecommendSlotMs(_displaySettings)
            : await DailyContentRepository(api: _api).nextSlotAtMillis();
    if (!mounted || at == null) return;
    final delay = at - DateTime.now().millisecondsSinceEpoch;
    if (delay <= 0) return;
    _slotWake = Timer(Duration(milliseconds: delay + 1500), () async {
      if (!mounted || !_widgetEnabled) return;
      // Advance the label from the local grid before a network/photo sync.
      final nextAt =
          _displaySettings.mode == BloomDisplayMode.carousel
              ? await DailyContentRepository(api: _api).nextSlotAtMillis()
              : _nextRecommendSlotMs(_displaySettings);
      if (mounted && nextAt != null) setState(() => _nextSlotAt = nextAt);
      await _load(showSpinner: false);
      await _armNextSlotWake();
    });
  }

  /// 推荐模式的下一次更新时间。
  ///
  /// 推荐也使用共享计划，但首页的下一时点按推荐作息计算，避免沿用旧轮播戳。
  /// 在 06:00–22:00 之间每 12 小时落一格，所以是 06:00 与 18:00，窗口结束
  /// 之后就是明天 06:00。这样推荐模式下首页也有「下次更新」。
  static int? _nextRecommendSlotMs(BloomDisplaySettings settings) {
    (int, int) parseClock(String raw, int fallbackHour, int fallbackMinute) {
      final bits = raw.split(':');
      return (
        int.tryParse(bits.first) ?? fallbackHour,
        bits.length > 1
            ? (int.tryParse(bits.last) ?? fallbackMinute)
            : fallbackMinute,
      );
    }

    final now = DateTime.now();
    final (startHour, startMinute) = parseClock(settings.activeStart, 6, 0);
    final (endHour, endMinute) = parseClock(settings.activeEnd, 22, 0);
    final start = DateTime(
      now.year,
      now.month,
      now.day,
      startHour,
      startMinute,
    );
    final end = DateTime(now.year, now.month, now.day, endHour, endMinute);
    final step = Duration(minutes: settings.intervalMinutes);
    if (step.inMinutes <= 0) return null;
    var at = start;
    for (var i = 0; i < 2000 && !at.isAfter(now); i++) {
      at = at.add(step);
    }
    if (at.isAfter(end)) {
      return start.add(const Duration(days: 1)).millisecondsSinceEpoch;
    }
    return at.millisecondsSinceEpoch;
  }

  @override
  void dispose() {
    _accountReadyRetry?.cancel();
    _deviceListWatch?.cancel();
    _followNative?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _slotWake?.cancel();
    _slotWatch?.cancel();
    _messageTimer?.cancel();
    super.dispose();
  }

  /// **先把本机已经有的那张画上去，再谈联网。**
  ///
  /// 冷启动时首页原来要等 `/status` 回来、再等整轮 sync（下载 + 渲染）走完才
  /// 拿到 `_originalPhotoPath`，所以卡片一直停在骨架屏 —— 而那张照片**早就在
  /// 本机了**。两个来源，按可信度排序：
  ///
  /// 1. 原生共享状态（`carousel-state.json` / `bloom_widget` 偏好）：后台同步或
  ///    闹钟可能已经把当前项推进到下一格，它比 Flutter 自己的缓存新；
  /// 2. Flutter 的 `daily.json` + 版本化图片。
  ///
  /// ⚠️ **照片路径必须走 [DailyContentRepository.photoPathFor]（按 id 取），
  ///    不能用 [DailyContentRepository.originalPhotoPath]。** 后者是推荐模式的
  ///    可变文件 `original.photo`；轮播模式写的是
  ///    `carousel-original-<id>.photo`，于是它在轮播下返回 null。下面那条
  ///    "先显示缓存"的老路正是这么写的，所以在轮播模式下**等于没有**：
  ///    实测 15:07:03 启动、15:07:06 计划就回来了，`[BloomUI] show` 却拖到
  ///    15:08:12 —— 69 秒全花在下载与渲染上，只为显示一张本机已有的照片。
  ///
  /// 画完就把 `_loading` 转 false 并置 `_paired`：前者让页面离开骨架屏，后者
  /// 让它离开"正在准备设备标识…"。两个都只是"我们已经证明过自己在显示照片"
  /// 的推论 —— 随后真实的 `/status` 仍然可以把它们改回去（未配对、无素材）。
  Future<void> _paintLocalContent() async {
    final revision = _settingsRevision;
    final repository = DailyContentRepository(api: _api);
    CachedWidgetImage? portrait;
    DailyContent? content;
    String? photoPath;
    try {
      final native = await WidgetBridge().readCurrentState();
      final expectedMode =
          _displaySettings.usesScheduledPlan ? 'carousel' : 'recommend';
      if (native != null &&
          (native.mode == null || native.mode == expectedMode)) {
        final path = await repository.photoPathFor(
          native.recommendationId,
          mode: native.mode,
        );
        if (path != null && await File(path).exists()) {
          photoPath = path;
          content = await repository.contentForNative(native);
          portrait = CachedWidgetImage(
            path: native.portraitPath ?? path,
            orientation: 'portrait',
            date: native.date,
            recommendationId: native.recommendationId,
          );
        }
      }
    } catch (_) {
      // 原生桥不可用（widget 测试、或平台还没挂上）：继续看 Flutter 缓存。
    }
    if (photoPath == null) {
      try {
        final cached = await repository.cachedContent();
        final path = await repository.photoPathFor(cached?.recommendationId);
        if (cached != null && path != null) {
          photoPath = path;
          content = cached;
          portrait = await repository.cached('portrait');
        }
      } catch (_) {
        // 什么都没有（第一次安装 / 缓存被清）：交给下面正常的联网路径。
      }
    }
    if (photoPath == null || !mounted || revision != _settingsRevision) return;
    final nextAt =
        _displaySettings.mode == BloomDisplayMode.carousel
            ? await repository.nextSlotAtMillis()
            : _nextRecommendSlotMs(_displaySettings);
    if (!mounted || revision != _settingsRevision) return;
    debugPrint(
      '[BloomUI] local-first show id=${content?.recommendationId} '
      'photo=$photoPath',
    );
    setState(() {
      _paired = true;
      _originalPhotoPath = photoPath;
      _content = content;
      _portrait = portrait ?? _portrait;
      _date = content?.date ?? _date;
      _nextSlotAt = nextAt ?? _nextSlotAt;
      _loading = false;
    });
  }

  Future<void> _load({bool showSpinner = true}) async {
    // **One load at a time.** Resume, the slot timer and the 30 s fallback can
    // all ask within the same second, and a second sync would only race the
    // first for the same files (and double the refill's network cost).
    if (_loadInFlight) {
      _loadPending = true;
      return;
    }
    _loadInFlight = true;
    final settingsRevision = _settingsRevision;
    if (showSpinner && mounted) setState(() => _loading = true);
    try {
      // **未登录：不 initialize、不请求、不落任何东西。**
      //
      // 设备令牌现在由服务端在登录/认领设备时下发，所以未登录时本机根本没有
      // 能取图的凭证 —— 继续往下走只会拿到 401，然后在页面上显示成"服务器
      // 请求失败"。而正确的结果是"请先登录"，四个页面自己已经挡住了。
      //
      // 这也是"登出即冻结"的另一半：本地令牌已被清掉，这里再把照片从内存里
      // 撤走，首页那张图与背景图都不会留在屏幕上。
      if (!_auth.isSignedIn) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _message = null;
          _content = null;
          _portrait = null;
          _originalPhotoPath = null;
          _date = null;
        });
        return;
      }
      if (_account?.immichReady != true || !await _identity.hasServerToken()) {
        await _refreshAccount();
        if (!mounted || settingsRevision != _settingsRevision) return;
        if (_account?.immichReady != true ||
            !await _identity.hasServerToken()) {
          setState(() => _loading = false);
          _scheduleAccountReadyRetry();
          return;
        }
      }
      if (mounted) setState(() => _contentError = null);
      // 可重新赋值：服务端认领设备后会下发新令牌，401 分支要用新令牌重试。
      var credentials = await _identity.initialize();
      // Device identity is local state and must remain visible even when the
      // following server/status/photo request fails.
      if (mounted) {
        setState(() => _credentials = credentials);
      }
      // Paint using this phone's local mirror first; then read its complete
      // mobile settings. Never use the selected physical frame's eink schedule.
      final displaySettingsFuture = _displayPreferences.readLocal();
      // **The master switch, ahead of every request.** With the widget switched
      // off the app must not read a single byte from the server — the user's
      // words were "也不会去走接口，它就不读取线上的数据了". So the gate is here,
      // before the registration and status calls, and the page falls back to
      // whatever is already on disk (nothing is downloaded, nothing is written).
      final widgetEnabled = await _displayPreferences.readWidgetEnabled();
      if (!widgetEnabled) {
        final repository = DailyContentRepository(api: _api);
        final cached = await repository.cachedContent();
        final cachedPortrait = await repository.cached('portrait');
        final local = await displaySettingsFuture;
        if (!mounted) return;
        setState(() {
          _widgetEnabled = false;
          _displaySettings = local;
          _content = cached;
          _portrait = cachedPortrait;
          _date = cached?.date;
          _paired = true;
          _loading = false;
          _message = null;
        });
        return;
      }
      if (mounted && !_widgetEnabled) setState(() => _widgetEnabled = true);
      // ⭐ **推荐模式的「下次更新」一帧都不要等网络。**
      //
      // 它的节奏由固定作息唯一决定（06:00–22:00 / 12 小时 → 06:00、18:00），
      // 本机就能算；而轮播那一份要等计划落盘才有 `next_slot_at_ms`。
      // 放在 `/status` 之前算，冷启动和"保存过一次设置"两条路就都走同一个来源。
      //
      // ⚠️ 原来这个值只在 `_resyncCarouselAfterSave` 里算 —— 于是推荐模式下的
      //    「下次更新」**只有保存过设置之后才会出现**，冷启动永远没有那一行。
      //    下面同步路径里那一处赋值只是复核（设置可能刚被改过），不是唯一来源。
      final localSettings = await displaySettingsFuture;
      if (!mounted || settingsRevision != _settingsRevision) return;
      setState(() => _displaySettings = localSettings);
      if (localSettings.mode != BloomDisplayMode.carousel && mounted) {
        setState(() => _nextSlotAt = _nextRecommendSlotMs(localSettings));
      }
      // ⭐ **本机已有的那张，先画上去 —— 在任何网络请求之前。**
      //
      // 这一段原来是缺的：下面那条"先显示缓存"的路在轮播模式下取不到路径
      // （原因见 [_paintLocalContent]），于是冷启动要等整轮 sync 走完才有照片。
      // 实测：15:07:03 启动，`/status` + `/plan` 在 15:07:06 就回来了，但
      // `[BloomUI] show` 直到 15:08:12 —— 69 秒，全花在下载与渲染上，
      // 而屏幕上的照片其实早就在本机。
      //
      // ⚠️ **必须有界。** 这是一次平台通道调用 + 几次本机文件读，正常在毫秒级；
      //    但通道没人应答时（widget 测试里就是这样，真机上一个卡住的平台调用
      //    同理）它会永远不返回，而它一旦不返回，`_load` 就永远走不到 `/status`
      //    —— 首屏反而更慢。600ms 足够，超时就当"本机没有"，照常往下走。
      await _paintLocalContent().timeout(
        const Duration(milliseconds: 600),
        onTimeout: () => debugPrint('[BloomUI] local-first paint timed out'),
      );
      // Read this phone's complete settings after painting its local photo.
      // Mode alone cannot detect a changed window, cadence or art selection.
      var displaySettings =
          await _displayPreferences.readServer(
            credentials: credentials,
            target: BloomApiClient.settingsTargetMobile,
            api: _api,
          ) ??
          localSettings;
      if (!mounted || settingsRevision != _settingsRevision) return;
      await _displayPreferences.cacheLocal(displaySettings);
      if (!mounted || settingsRevision != _settingsRevision) return;
      setState(() {
        _displaySettings = displaySettings;
        if (ContentSyncEpoch.settingsKey(displaySettings) !=
            ContentSyncEpoch.settingsKey(localSettings)) {
          _nextSlotAt =
              displaySettings.mode == BloomDisplayMode.carousel
                  ? null
                  : _nextRecommendSlotMs(displaySettings);
        }
      });
      await configureBackgroundSync(displaySettings);
      DeviceStatus? status;
      // **不再走 `register()`。** 那是账号出现之前的机制：它靠激活码授权，
      // 建出来的是一台"未配对"设备，于是 App 又把用户送回"设备 ID + 激活码"
      // 那一页 —— 那正是要拆掉的东西。
      //
      // 现在的路径是：登录时/登录后由 `_ensureDeviceClaimed()` 让服务端把本机
      // 认领到账号下，服务端同时下发设备令牌。所以 401 只意味着"认领还没完成"，
      // 补一次再用新令牌重试即可。
      try {
        status = await _api.status(credentials);
      } on BloomApiException catch (error) {
        if (error.statusCode == 401 &&
            (error.code == 'device_authentication_required' ||
                error.code == 'invalid_device_token')) {
          if (!await _ensureDeviceClaimed(forceRefresh: true)) rethrow;
          final refreshed = await _identity.read();
          if (refreshed == null) rethrow;
          credentials = refreshed;
          if (mounted) setState(() => _credentials = refreshed);
          status = await _api.status(refreshed);
          displaySettings =
              await _displayPreferences.readServer(
                credentials: refreshed,
                target: BloomApiClient.settingsTargetMobile,
                api: _api,
              ) ??
              displaySettings;
          if (!mounted || settingsRevision != _settingsRevision) return;
          await _displayPreferences.cacheLocal(displaySettings);
          await configureBackgroundSync(displaySettings);
        } else {
          rethrow;
        }
      }

      CachedWidgetImage? portrait;
      DailyContent? content;
      String? originalPhotoPath;
      int? nextSlotAt;
      String? date;
      String? message;
      WidgetCurrentState? nativeState;
      var nativeStateApplied = false;
      if (!mounted || settingsRevision != _settingsRevision) return;
      // **The server's own answer wins, and the mirror is made to agree.**
      //
      // `/status` carries the mode the server wants this device in on every
      // launch. The app used to ignore it and read the *local mirror* instead,
      // and the user's report was exactly the symptom: 推荐模式 on the home page
      // and 轮播模式 on the very same phone's device page. The mirror is only
      // ever written by this app, so anything set anywhere else (the web UI)
      // never reached it — the mirror is the stale one, not the server.
      //
      // Reconciling here also re-points the home-screen widget, which reads that
      // same mirror, so the server, the app and the widget end up telling one
      // story. For the device whose token we hold this is always our own
      // `mobile` record, so there is no way to pull a frame's schedule in here.
      final serverMode = bloomModeFromWire(status.mode);
      if (serverMode != null && serverMode != displaySettings.mode) {
        displaySettings = displaySettings.copyWith(mode: serverMode);
        try {
          await _displayPreferences.write(displaySettings);
          await configureBackgroundSync(displaySettings);
        } catch (_) {
          // A failing mirror write must not stop the app from launching; the
          // next launch will try again.
        }
      }
      if (status.paired == true) {
        // Pairing is a server-authentication state, not an image-refresh
        // state. Enter the photo experience immediately and never fall back
        // to the pairing screen merely because a download/render fails.
        if (mounted && !_paired) {
          setState(() => _paired = true);
        }
        if (status.hasAssets == true) {
          final repository = DailyContentRepository(api: _api);
          // Show the last complete local render immediately. A carousel
          // refresh may download and render up to four originals before it
          // completes; the photo page should not remain behind a spinner
          // during that network/CPU work.
          final cachedBeforeSync = await repository.cachedContent();
          final cachedPortraitBeforeSync = await repository.cached('portrait');
          if (cachedBeforeSync != null &&
              cachedPortraitBeforeSync != null &&
              mounted) {
            final cachedOriginal = await repository.photoPathFor(
              cachedBeforeSync.recommendationId,
            );
            if (cachedOriginal != null) {
              setState(() {
                _paired = true;
                _portrait = cachedPortraitBeforeSync;
                _content = cachedBeforeSync;
                // A cache read that comes back empty must not *erase* a photo
                // that is already on screen: the file is being renamed into place
                // at exactly the wrong moment during every background refill, and
                // the null it returns then used to blank the card — permanently,
                // once anything re-read the cache periodically. Lines 433/623
                // already merge this way; these two were the odd ones out.
                _originalPhotoPath = cachedOriginal;
                _date = cachedBeforeSync.date;
                _displaySettings = displaySettings;
                _loading = false;
                _message = null;
              });
            }
          }
          // A widget alarm can advance the shared native cache while the
          // carousel plan is still being downloaded. Seed the photo page from
          // that newer native item immediately, instead of briefly showing
          // the older daily.json image until the network/render pass finishes.
          final nativeBeforeSync = await WidgetBridge().readCurrentState();
          final nativeBeforePortrait = nativeBeforeSync?.portraitPath;
          final nativeBeforeIsCurrent =
              nativeBeforeSync != null &&
              displaySettings.usesScheduledPlan &&
              nativeBeforeSync.mode == 'carousel' &&
              nativeBeforePortrait != null &&
              await File(nativeBeforePortrait).exists() &&
              nativeBeforeSync.mode == 'carousel';
          final nativeBeforeOriginal = await repository.photoPathFor(
            nativeBeforeSync?.recommendationId,
          );
          if (nativeBeforeIsCurrent &&
              nativeBeforeOriginal != null &&
              mounted) {
            final nativeBefore = nativeBeforeSync;
            final nativeContent = await repository.contentForNative(
              nativeBefore,
              fallback: cachedBeforeSync,
            );
            if (!mounted) return;
            setState(() {
              _portrait = CachedWidgetImage(
                path: nativeBeforePortrait,
                orientation: 'portrait',
                date: nativeBefore.date,
                recommendationId: nativeBefore.recommendationId,
              );
              _content = nativeContent;
              _originalPhotoPath = nativeBeforeOriginal;
              _date = nativeBefore.date;
              _displaySettings = displaySettings;
              _loading = false;
            });
          }
          try {
            debugPrint(
              '[BloomSave] _load is syncing now '
              '(mode=${displaySettings.mode.name} '
              'window=${displaySettings.activeStart}-${displaySettings.activeEnd})',
            );
            if (displaySettings.usesScheduledPlan) {
              // **This path needed the same catch-up as the manual "下一张"
              // button.** `_watchNextSlot` was wired only to that button, so
              // "下次更新" appeared within ~1 s after a manual advance but sat
              // blank for up to a minute on cold start, the 30 s fallback and
              // resume-from-background — every route that lands here instead.
              // The label is written moments after the plan response, well
              // before the batch's downloads finish; start the same poll here
              // so this path catches it just as early.
              unawaited(_watchNextSlot(repository));
            }
            content = await repository.syncCarousel(
              credentials,
              displaySettings,
              foreground: true,
            );
          } catch (error, stack) {
            // **Never swallow this silently again.** The user-visible notice
            // ("正在显示上一张") is the *only* thing this catch produced, so a
            // failing sync left no evidence anywhere — no log, no reason, just a
            // stale photo. Whatever throws here is the answer to "why is the
            // photo old", so it goes to logcat in full.
            debugPrint('[BloomSync] foreground sync failed: $error');
            debugPrint('[BloomSync] $stack');
            content = await repository.cachedContent();
            message = '新照片暂时刷新失败，正在显示上一张。';
          }
          // Android alarms and the iOS Widget extension can advance either
          // mode while Flutter is not running. Read their shared current item
          // before presenting the page so the app never rolls back to its
          // older daily.json snapshot.
          if (!mounted || settingsRevision != _settingsRevision) return;
          final native = await WidgetBridge().readCurrentState();
          nativeState = native;
          // **The item's own immutable copy wins over the path the native state
          // carries.** `original.photo` is rewritten in place by every sync,
          // while the native id and captions can advance on their own (an alarm
          // applies the stored plan), so that file can still hold the previous
          // item's bytes at the very moment its own id is current — the card
          // then shows one item's picture under another item's words.
          final nativePhoto =
              native == null
                  ? null
                  : await repository.photoPathFor(
                    native.recommendationId,
                    mode: native.mode,
                  );
          final nativePhotoExists =
              nativePhoto != null && await File(nativePhoto).exists();
          final expectedMode =
              displaySettings.usesScheduledPlan ? 'carousel' : 'recommend';
          if (native != null &&
              nativePhotoExists &&
              (native.mode == null || native.mode == expectedMode)) {
            content = await repository.contentForNative(
              native,
              fallback: content,
            );
            originalPhotoPath = nativePhoto;
            portrait =
                native.portraitPath == null
                    ? portrait
                    : CachedWidgetImage(
                      path: native.portraitPath!,
                      orientation: 'portrait',
                      date: native.date,
                      recommendationId: native.recommendationId,
                    );
            nativeStateApplied = true;
          }
          if (!nativeStateApplied) {
            portrait = await repository.cached('portrait');
          }
          // Keep the native item selected above when it is newer than the
          // Flutter cache. Otherwise use the item's own immutable path — never
          // the one mutable `original.photo`, whose bytes the next background
          // sync overwrites in place (that is what made the photo change while
          // the caption stayed behind).
          originalPhotoPath ??= await repository.photoPathFor(
            content?.recommendationId,
          );
          // Read the slot stamp the same sync just wrote, so the label under the
          // card always belongs to the plan that is on screen.
          //
          // ⚠️ **推荐模式没有这个戳。** `next_slot_at_ms` 是轮播的概念（由引擎在
          //    计划落盘时写进 daily.json），推荐路径从不写它，所以这里原来在推荐
          //    模式下永远是 null —— 首页那行「下次更新」只在【保存过一次设置】
          //    之后才出现（那条路会把 `_nextRecommendSlotMs` 塞进 `_nextSlotAt`）。
          //    推荐的节奏由固定作息唯一决定（06:00–22:00 / 12 小时 → 06:00、18:00），
          //    所以这里直接按作息算，冷启动和保存后走同一个来源。
          nextSlotAt =
              displaySettings.mode != BloomDisplayMode.carousel
                  ? _nextRecommendSlotMs(displaySettings)
                  : await repository.nextSlotAtMillis();
          debugPrint(
            '[BloomUI] show id=${content?.recommendationId} '
            'photo=${originalPhotoPath ?? 'none'} '
            'caption=${(content?.captionZh ?? '').trim()} '
            'next=${nextSlotAt ?? 'none'} '
            'source=${nativeStateApplied ? 'native' : 'cache'}',
          );
          final square =
              nativeStateApplied && nativeState?.squarePath != null
                  ? CachedWidgetImage(
                    path: nativeState!.squarePath!,
                    orientation: 'square',
                    date: nativeState.date,
                    recommendationId: nativeState.recommendationId,
                  )
                  : await repository.cached('square');
          final largeSquare =
              nativeStateApplied && nativeState?.largeSquarePath != null
                  ? CachedWidgetImage(
                    path: nativeState!.largeSquarePath!,
                    orientation: 'largeSquare',
                    date: nativeState.date,
                    recommendationId: nativeState.recommendationId,
                  )
                  : await repository.cached('largeSquare');
          date = content?.date;
          await _evictOriginalPhoto(originalPhotoPath);
          if (!mounted || settingsRevision != _settingsRevision) return;
          if (portrait != null &&
              portrait.recommendationId == content?.recommendationId &&
              originalPhotoPath != null) {
            await WidgetBridge().update(
              portraitPath: portrait.path,
              squarePath: square?.path ?? portrait.path,
              largeSquarePath: largeSquare?.path ?? portrait.path,
              date: content?.date ?? portrait.date ?? '',
              recommendationId:
                  content?.recommendationId ?? portrait.recommendationId ?? 0,
              // Never hand the native state the one mutable file: the widget
              // and the app both read this back, and the next sync overwrites it
              // in place. The item's versioned copy is stable for as long as the
              // item is.
              originalPhotoPath:
                  await repository.photoPathFor(content?.recommendationId) ??
                  originalPhotoPath,
              captionZh: content?.captionZh,
              captionEn: content?.captionEn,
              capturedDateText: content?.capturedDateText,
              locationText: content?.locationText,
              mode:
                  displaySettings.usesScheduledPlan ? 'carousel' : 'recommend',
            );
          }
        } else {
          message = null;
        }
      } else {
        // 设备还没挂到账号的 Immich 用户名下 —— 注册之后 provisioning 还没跑完
        // 是最常见的原因。
        //
        // **不再启动配对轮询**：归属现在由登录决定，没有需要用户参与的"配对"
        // 这回事了。每 5 秒问一次服务器只是白耗电；下一次 `_load`（回到前台、
        // 或用户下拉刷新）自然会重试。
        message = '正在准备你的图库，稍后就能看到照片。';
      }

      if (!mounted) return;
      if (settingsRevision != _settingsRevision) return;
      await _evictPreviewImages([portrait]);
      if (!mounted) return;
      await _precacheIncoming(originalPhotoPath);
      if (!mounted || settingsRevision != _settingsRevision) return;
      // 提到闭包外面：`status` 在 try/catch 里会被重新赋值，所以在闭包里读它
      // 拿不到流分析的类型收窄（会报"接收者可能是 null"）。
      final isPaired = status.paired;
      setState(() {
        _credentials = credentials;
        _paired = isPaired;
        if (content != null && originalPhotoPath != null) {
          _portrait =
              portrait?.recommendationId == content.recommendationId
                  ? portrait
                  : null;
          _content = content;
          _originalPhotoPath = originalPhotoPath;
        }
        _hasAssets = status!.hasAssets;
        _nextSlotAt = _hasAssets == false ? null : nextSlotAt ?? _nextSlotAt;
        _date = date ?? _date;
        _message = message;
        _displaySettings = displaySettings;
        _loading = false;
      });
      if (message != null) {
        _scheduleMessageClear();
      }
    } catch (error) {
      if (!mounted || settingsRevision != _settingsRevision) return;
      setState(() {
        _contentError = '暂时无法获取照片，请检查网络后重试。';
        _message =
            error is BloomApiException
                ? '服务器请求失败（${error.statusCode}），已有照片会继续保留。'
                : '暂时无法连接服务器，已有照片会继续保留。';
        _loading = false;
      });
      _scheduleMessageClear();
    } finally {
      _loadInFlight = false;
      if (mounted) {
        await _armNextSlotWake();
        if (_loadPending) {
          _loadPending = false;
          unawaited(_load(showSpinner: false));
        }
      }
    }
  }

  /// **Coming back to the foreground is a moment the plan can have moved on.**
  /// Android freezes a cached process, so the slot timer does not fire while the
  /// app is away — the page would still be showing the photo that was due when it
  /// left, with a "下次更新" time already in the past. Re-read on the way in: the
  /// pool normally already holds the due item, so this is a local read plus one
  /// short request, and both the card and the label come back in step.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final away =
        _pausedAt == null ? null : DateTime.now().difference(_pausedAt!);
    _pausedAt = null;
    // `null` means this is the resume that every cold start produces (the first
    // `_load` is already running), and a blink shorter than this is the
    // notification shade, not a return.
    if (away == null || away < const Duration(seconds: 5)) return;
    unawaited(_loadRemoteDevices());
    unawaited(_load(showSpinner: false));
  }

  /// Devices the photo page switcher and the "设备" tab list.
  ///
  /// 服务端按设备归属返回列表。请求尚未完成时仅回退到本机，
  /// 不推断相框归属，也不把相册成员的手机显示为自己的设备。
  List<BloomDevice> get _devices {
    if (_remoteDevices.isNotEmpty) {
      return bloomDevicesFromRemote(
        _remoteDevices,
        localDeviceId: _credentials?.deviceId,
        localOnline: _credentials == null ? null : _paired,
      );
    }
    return bloomDevices(
      credentials: _credentials,
      localOnline: _credentials == null ? null : _paired,
    );
  }

  // ---------- F1 账号 ----------

  /// 启动时恢复本地会话，并向服务端确认它还有效。
  ///
  /// 两步分开是刻意的：本地恢复不发网络请求，所以登录状态在离线时也立刻可用；
  /// 确认失败（非 401）只保留旧状态，不会把用户登出 —— 见 [AuthRepository.refresh]。
  Future<void> _restoreAuth() async {
    await _auth.load();
    if (!mounted) return;
    setState(() => _account = _auth.account);
    if (_account != null) await _prepareAccountCache(_account!.id);
    if (_account?.immichReady == true && await _identity.hasServerToken()) {
      final revision = _settingsRevision;
      final local = await _displayPreferences.readLocal();
      if (!mounted || revision != _settingsRevision) return;
      setState(() => _displaySettings = local);
      await _paintLocalContent().timeout(
        const Duration(milliseconds: 600),
        onTimeout: () {},
      );
    }
    if (_auth.isSignedIn) {
      await _refreshAccount();
    }
    if (mounted) unawaited(_load(showSpinner: false));
  }

  void _scheduleAccountReadyRetry() {
    if (_accountReadyRetry?.isActive == true || _accountRetryAttempt >= 5) {
      return;
    }
    final token = _auth.token;
    final delay = [2, 4, 8, 16, 30][_accountRetryAttempt++];
    _accountReadyRetry = Timer(Duration(seconds: delay), () async {
      if (!mounted || token != _auth.token || _pausedAt != null) return;
      await _refreshAccount();
      if (mounted && token == _auth.token) await _load(showSpinner: false);
    });
  }

  Future<void> _refreshAccount() async {
    if (_accountRefreshInFlight) return;
    _accountRefreshInFlight = true;
    final token = _auth.token;
    try {
      final account = await _auth.refresh();
      if (!mounted || (token != _auth.token && _auth.token != null)) return;
      setState(() => _account = account);
      if (account == null) {
        if (token != null && _auth.token == null) await _clearAccountContent();
        return;
      }
      if (account.immichReady && await _ensureDeviceClaimed()) {
        _accountReadyRetry?.cancel();
        _accountRetryAttempt = 0;
        await _loadRemoteDevices();
      } else {
        _scheduleAccountReadyRetry();
      }
    } finally {
      _accountRefreshInFlight = false;
    }
  }

  /// 本机上报给服务端的设备描述。
  ///
  /// 名字用**平台**而不是机型：拿机型要加依赖或写原生代码，而服务端的
  /// `claim_device_for_account` 只在**首次插入**时采用这个名字（之后在库里
  /// 改过的名字不会被重新登录覆盖），所以它的作用仅仅是让新设备不至于无名。
  Future<DeviceClaim> _claimFor(DeviceCredentials credentials) async =>
      DeviceClaim(
        deviceId: credentials.deviceId,
        name: Platform.isIOS ? 'iPhone' : 'Android 手机',
        claimSecret: await _identity.installClaimSecret(),
        previousDeviceToken: credentials.deviceToken,
      );

  /// 确保这台设备已经在服务端认领过，并保存服务端下发的设备令牌。
  ///
  /// 登录响应里通常已经带着设备令牌，但**注册那一刻必然没有** —— 服务端还在
  /// 异步建 Immich 用户（没有 immich_user_id 就绑不了设备）。所以这里要能
  /// 反复调：账号一变成 ready 就补一次。
  ///
  /// 认领失败一律不阻断登录：相册还在准备中是 409，属于"等一会儿再来"，
  /// 不是错误。
  Future<bool> _ensureDeviceClaimed({bool forceRefresh = false}) async {
    if (!_auth.isSignedIn || _account?.immichReady != true) return false;
    final session = _auth.token;
    // ⚠️ 不能直接用 `_credentials`：**登出会把它一起清掉**，所以"登出→再登录"
    //    这条路上它一定是 null，而那样这个函数会在第一行就返回，设备永远认领
    //    不上（表现为登录成功但设备列表里没有本机）。
    //    本机身份是谁并不重要 —— 随机生成一个新的也行，认领的是"这台机器"。
    final credentials = _credentials ?? await _identity.initialize();
    if (!mounted || session != _auth.token) return false;
    if (_credentials == null) {
      setState(() => _credentials = credentials);
    }
    try {
      if (!forceRefresh && await _identity.hasServerToken()) {
        if (session != _auth.token) return false;
        try {
          await _api.userRequest(
            _auth.token!,
            'devices/${credentials.deviceId}/confirm-owner',
            method: 'POST',
            deviceToken: credentials.deviceToken,
            body: {'claim_secret': await _identity.installClaimSecret()},
          );
          return session == _auth.token;
        } on BloomApiException catch (error) {
          if (error.statusCode != 401 && error.statusCode != 403) rethrow;
        }
      }

      final claimed = await _auth.claimDevice(await _claimFor(credentials));
      if (session != _auth.token) return false;
      await _identity.saveIssued(
        deviceId: claimed.deviceId,
        deviceToken: claimed.deviceToken,
      );
      if (session != _auth.token) {
        await _identity.clear();
        return false;
      }
      final updated = await _identity.read();
      if (updated != null && mounted) {
        setState(() => _credentials = updated);
      }
      return updated != null && session == _auth.token;
    } on BloomApiException catch (error) {
      debugPrint('[BloomAuth] 设备认领未完成：${error.code ?? error.statusCode}');
    } catch (error) {
      debugPrint('[BloomAuth] 设备认领异常：$error');
    }
    return false;
  }

  /// 取回当前账号绑定的设备。失败时静默保留旧列表 —— 设备列表是展示信息，
  /// 一次网络抖动不该把页面清空。
  Future<void> _loadRemoteDevices() async {
    final token = _auth.token;
    if (token == null) {
      if (mounted) setState(() => _remoteDevices = const []);
      return;
    }
    if (_devicesLoadingToken == token) return;
    _devicesLoadingToken = token;
    final generation = ++_devicesRequestGeneration;
    try {
      final devices = await _api.listMyDevices(token);
      if (!mounted ||
          token != _auth.token ||
          generation != _devicesRequestGeneration) {
        return;
      }
      setState(() => _remoteDevices = devices);
    } catch (_) {
      // 保留既有列表。
    } finally {
      if (generation == _devicesRequestGeneration) _devicesLoadingToken = null;
    }
  }

  Future<void> _prepareAccountCache(
    String accountId, {
    bool signingIn = false,
  }) async {
    final previous = await _identity.cachedAccountOwner();
    if (previous != accountId && (previous != null || signingIn)) {
      await _clearAccountContent();
    }
    await _identity.saveAccountOwner(accountId);
  }

  Future<void> _clearAccountContent() async {
    _accountReadyRetry?.cancel();
    _accountRetryAttempt = 0;
    _settingsRevision++;
    _devicesRequestGeneration++;
    _devicesLoadingToken = null;
    _slotWake?.cancel();
    await _identity.clear();
    await disableBackgroundSync();
    final path = await BloomWidgetBridgePlatform.cacheDirectory();
    if (path != null) await ContentSyncEpoch.resetAccount(Directory(path));
    await BloomWidgetBridgePlatform.resetAccountContent();
    if (mounted) {
      setState(() {
        _content = null;
        _hasAssets = null;
        _contentError = null;
        _portrait = null;
        _originalPhotoPath = null;
        _credentials = null;
        _nextSlotAt = null;
        _remoteDevices = const [];
        _photoDeviceId = null;
      });
    }
  }

  Future<void> _openAuth() async {
    final credentials = _credentials ?? await _identity.initialize();
    final claim = await _claimFor(credentials);
    if (!mounted) return;
    final result = await Navigator.of(context).push<AuthResult>(
      MaterialPageRoute(
        builder:
            (_) => BloomAuthPage(
              auth: _auth,
              // 登录时顺带上报本机，服务端据此把这台手机认领到账号下 ——
              // 这就是"激活码"那套机制的替代品。
              device: claim,
              onCancel: () => Navigator.of(context).pop(),
              onSignedIn: (value) => Navigator.of(context).pop(value),
            ),
      ),
    );
    if (!mounted || result == null) return;
    await _prepareAccountCache(result.account.id, signingIn: true);
    if (!mounted) return;
    setState(() => _account = result.account);
    // 登录响应里可能已经带着服务端下发的设备令牌（相册已就绪的账号）。
    final claimed = result.device;
    if (claimed != null) {
      await _identity.saveIssued(
        deviceId: claimed.deviceId,
        deviceToken: claimed.deviceToken,
      );
      final updated = await _identity.read();
      if (updated != null && mounted) {
        setState(() => _credentials = updated);
      }
    }
    _notify('登录成功');
    // 顺序：**先**认领设备、拿到服务端下发的令牌（`_refreshAccount` 里做），
    // 再取图。反过来的话第一次取图会拿着一个还没被服务端认下的本机令牌去打
    // 一次 401。
    await _refreshAccount();
    if (!mounted) return;
    // **登录成功后必须显式取一次图。**
    //
    // `_load()` 现在的第一步是"未登录就什么都不做"，所以启动时那一次（那时还
    // 没有会话）是空跑的。而登录成功之后**没有任何地方会自动重来**：
    //   - `_startSlotWatch` 的 30 秒兜底会先问 `isBehind()`，而它第一行就是
    //     "本地栅格是空的就返回 false" —— 全新安装时栅格恰好是空的，于是兜底
    //     永远不会触发；
    //   - 剩下的就只有重启 App 或在首页下拉。
    // 漏掉这一句，表现就是"登录成功了，但页面停在空态、永远不换图"，
    // 而且服务端日志里除了那次 `claim` 之外，看不到任何该设备的请求。
    await _load();
  }

  Future<void> _signOut() async {
    if (_accountBusy || _signOutConfirming) return;
    _signOutConfirming = true;
    final confirmed = await confirmBloomAction(
      context,
      title: '退出登录？',
      message: '这台手机的小组件将清除照片并显示请登录。设备归属和播放设置会保留，其他设备继续正常更新。',
      confirmLabel: '退出登录',
    );
    _signOutConfirming = false;
    if (!confirmed || !mounted) return;
    setState(() => _accountBusy = true);
    final credentials = _credentials ?? await _identity.read();
    final logout = _auth.signOut(device: credentials);
    // 退出先停止本机缓存播放及补货，远端退出请求不阻塞隐私清理。
    await _clearAccountContent();
    await logout;
    if (!mounted) return;
    setState(() {
      _account = null;
      _credentials = null;
      _remoteDevices = const [];
      _accountBusy = false;
    });
    _notify('已退出登录');
    // 重开一轮：未登录状态下不该继续显示上一轮的设备与照片。
    unawaited(_load(showSpinner: false));
  }

  /// The device whose photos the photo page shows; falls back to this phone.
  BloomDevice? get _photoDevice {
    final devices = _devices;
    final selected = _photoDeviceId;
    if (selected != null) {
      for (final device in devices) {
        if (device.deviceId == selected &&
            (device.isLocal || device.isFrame && device.canManage)) {
          return device;
        }
      }
    }
    for (final device in devices) {
      if (device.isLocal) return device;
    }
    return null;
  }

  void _changePhotoDevice(String deviceId) {
    if (_photoDeviceId == deviceId) return;
    HapticFeedback.selectionClick();
    setState(() => _photoDeviceId = deviceId);
  }

  Future<void> _showAddDeviceNotice() async {
    if (_auth.token == null) {
      await _openAuth();
      return;
    }
    final paired = await joinBloomDevice(context, _api, _auth.token!);
    if (paired) {
      await _loadRemoteDevices();
      _notify('已向设备提供你的图库');
    }
  }

  Future<void> _deviceContentChanged() async {
    await _loadRemoteDevices();
    if (mounted) unawaited(_load(showSpinner: false));
  }

  Future<void> _openDeviceDetail(BloomDevice device) async {
    if (!device.canManage) {
      final token = _auth.token;
      if (token == null) return;
      final left = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder:
              (_) => BloomJoinedDevicePage(
                api: _api,
                token: token,
                device: device,
              ),
        ),
      );
      if (left == true) await _deviceContentChanged();
      return;
    }
    final credentials = _credentials;
    final accountToken = _auth.token;
    await BloomDeviceDetailPage.open(
      context,
      device: device,
      preferences: _displayPreferences,
      userToken: _auth.token,
      settings: _displaySettings,
      credentials: credentials,
      // The app writes with the token it holds, so the caller is the app's own
      // device (not the frame it is configuring).
      callerDeviceId: credentials?.deviceId,
      // The page paints the same photo the home page does, so its glass has
      // something to refract.
      photoPath: _originalPhotoPath,
      onSaved: (settings) {
        if (_auth.token != accountToken ||
            _credentials?.deviceToken != credentials?.deviceToken) {
          return;
        }
        _applySavedSettings(device, settings);
      },
      onUnbind:
          device.isFrame && _auth.token != null
              ? () async {
                await _api.userRequest(
                  _auth.token!,
                  'devices/${device.deviceId}',
                  method: 'DELETE',
                );
                if (mounted) setState(() => _photoDeviceId = null);
                await _loadRemoteDevices();
              }
              : null,
      onWidgetEnabledChanged:
          (enabled) => setState(() => _widgetEnabled = enabled),
    );
  }

  /// [_displaySettings] models **this phone's** own record: the photo page uses
  /// its mode to pick the carousel/recommendation sync path and its cadence to
  /// drive the carousel, and it is the same record the local mirror holds.
  ///
  /// A save to the frame's `eink` record therefore must not be copied in here:
  /// it belongs to another device, and adopting it would put the frame's mode
  /// and cadence in front of the phone's photo page.
  void _applySavedSettings(BloomDevice device, BloomDisplaySettings settings) {
    if (!mounted || !device.isLocal) return;
    setState(() => _displaySettings = settings);
    _settingsRevision++;
    _slotWake?.cancel();
    setState(
      () =>
          _nextSlotAt =
              settings.mode == BloomDisplayMode.carousel
                  ? null
                  : _nextRecommendSlotMs(settings),
    );
    unawaited(_load(showSpinner: false));
  }

  Future<void> _nextCarouselPhoto() async {
    final credentials = _credentials;
    if (credentials == null || _loading || _nextLoading) {
      return;
    }
    final revision = _settingsRevision;
    final settings = _displaySettings;
    if (!settings.usesScheduledPlan) return;
    await HapticFeedback.lightImpact();
    if (!mounted || revision != _settingsRevision) return;
    setState(() => _nextLoading = true);
    try {
      final repository = DailyContentRepository(api: _api);
      // **Pick the next-slot stamp up while the photos are still downloading.**
      // The repository publishes it the moment the plan request returns, so the
      // page can name the next quarter hour right away instead of waiting for the
      // whole batch to be drawn — which is why "下次更新" used to show up so late.
      unawaited(_watchNextSlot(repository));
      final content = await repository.syncCarousel(
        credentials,
        settings,
        next: true,
      );
      if (!mounted || revision != _settingsRevision) return;
      final portrait = await repository.cached('portrait');
      final square = await repository.cached('square');
      final largeSquare = await repository.cached('largeSquare');
      final originalPhotoPath = await repository.photoPathFor(
        content.recommendationId,
      );
      await _evictOriginalPhoto(originalPhotoPath);
      await _evictPreviewImages([portrait, square, largeSquare]);
      if (!mounted || revision != _settingsRevision) return;
      if (portrait != null) {
        await WidgetBridge().update(
          portraitPath: portrait.path,
          squarePath: square?.path ?? portrait.path,
          largeSquarePath: largeSquare?.path ?? portrait.path,
          date: content.date,
          recommendationId: content.recommendationId,
          originalPhotoPath: originalPhotoPath,
          captionZh: content.captionZh,
          captionEn: content.captionEn,
          capturedDateText: content.capturedDateText,
          locationText: content.locationText,
          mode: 'carousel',
        );
      }
      await _precacheIncoming(originalPhotoPath);
      if (!mounted || revision != _settingsRevision) return;
      setState(() {
        if (originalPhotoPath != null) {
          _portrait =
              portrait?.recommendationId == content.recommendationId
                  ? portrait
                  : null;
          _content = content;
          _originalPhotoPath = originalPhotoPath;
        }
        _date = content.date;
      });
      await HapticFeedback.mediumImpact();
      _notify('已切换到下一张。');
    } catch (_) {
      if (mounted && revision == _settingsRevision) {
        _notify('下一张获取失败，请稍后重试。');
      }
    } finally {
      if (mounted) setState(() => _nextLoading = false);
    }
  }

  Future<void> _evictPreviewImages(Iterable<CachedWidgetImage?> images) async {
    for (final image in images) {
      if (image == null) continue;
      await FileImage(File(image.path)).evict();
    }
  }

  Future<void> _evictOriginalPhoto(String? path) async {
    if (path != null) await FileImage(File(path)).evict();
  }

  /// **Decode the incoming photo before the swap that shows it.**
  ///
  /// The cross-fade is between two widgets, but the incoming one cannot paint
  /// until its file is decoded, so without this the fade passes through a blank
  /// frame — the flash the rebuild probes finally pinned down (the same picture
  /// arrives under two paths, `carousel-original-<id>.photo` and
  /// `original.photo`, and the switcher swaps when the path changes). Decoding
  /// first means the swap has a real frame to fade into.
  ///
  /// Both places that can replace the photo call this: the page load and the
  /// manual "下一张" action. Evicting the file first (the callers do that) keeps
  /// this from being a no-op on a path that was already decoded.
  Future<void> _precacheIncoming(String? incoming) async {
    if (!mounted || incoming == null || incoming == _originalPhotoPath) return;
    try {
      await precacheImage(FileImage(File(incoming)), context);
    } catch (_) {
      // Decoding ahead is an optimisation: a failure only means the older
      // blank-frame fade, never a failed load.
    }
  }

  void _changeTab(int index) {
    if (index == 3) unawaited(_loadRemoteDevices());
    if (_selectedTab == index) return;
    HapticFeedback.selectionClick();
    setState(() => _selectedTab = index);
  }

  Future<void> _copyDeviceId() async {
    final value = _credentials?.deviceId;
    if (value == null) return;
    await Clipboard.setData(ClipboardData(text: value));
    await HapticFeedback.lightImpact();
    _notify('设备 ID 已复制。');
  }

  void _notify(String value) {
    if (!mounted) return;
    _messageTimer?.cancel();
    setState(() => _message = value);
    _scheduleMessageClear();
  }

  void _scheduleMessageClear() {
    _messageTimer?.cancel();
    _messageTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _message = null);
    });
  }

  /// Re-reads the next-slot stamp while a sync is running, so "下次更新" can appear
  /// as soon as the plan is known rather than at the end of the batch.
  Future<void> _watchNextSlot(DailyContentRepository repository) async {
    // **Cover the whole sync, not six seconds of it.** The label is written ~200 ms
    // after the plan response (measured), but a sync can run 13-50 s behind photo
    // downloads; a 15x400 ms window expired long before the value landed, so the label
    // only appeared when the whole load finished. Poll for the length of a slow run.
    final revision = _settingsRevision;
    for (var i = 0; i < 100 && mounted && revision == _settingsRevision; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final at = await repository.nextSlotAtMillis();
      if (!mounted || revision != _settingsRevision) return;
      if (_displaySettings.mode != BloomDisplayMode.carousel ||
          at == null ||
          at == _nextSlotAt) {
        continue;
      }
      setState(() => _nextSlotAt = at);
    }
  }

  Future<void> _galleryContentChanged(String deviceId) async {
    final credentials = _credentials;
    if (credentials == null || credentials.deviceId != deviceId) return;
    final settings = await DisplayPreferences().readServer(
      credentials: credentials,
      target: BloomApiClient.settingsTargetMobile,
      api: _api,
    );
    if (settings == null) return;
    await DisplayPreferences().cacheLocal(settings);
    await configureBackgroundSync(settings);
    if (mounted) setState(() => _displaySettings = settings);
    // Rendering and prefetch are separate from the selection save.
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) => BloomGlassHome(
    loading: _loading,
    hasAssets: _hasAssets,
    contentError: _contentError,
    nextLoading: _nextLoading,
    discoverPage: BloomDiscoverPage(
      api: _api,
      userToken: _auth.token,
      session: GallerySession(
        onContentChanged: _galleryContentChanged,
        token: () => _auth.token,
        frames:
            () => [
              for (final d in bloomDevicesFromRemote(
                _remoteDevices,
              ).where((d) => d.canManage))
                GalleryFrame(d.deviceId, d.name, isMobile: !d.isFrame),
            ],
      ),
      frames: [
        for (final d in bloomDevicesFromRemote(
          _remoteDevices,
        ).where((d) => d.canManage))
          GalleryFrame(d.deviceId, d.name, isMobile: !d.isFrame),
      ],
      onSignIn: _openAuth,
    ),
    photoLibraryPage: BloomPhotoLibraryPage(
      ready: _account?.immichReady == true,
      api: _api,
      token: _auth.token,
      onSignIn: _openAuth,
      onChanged: _deviceContentChanged,
    ),
    selectedTab: _selectedTab,
    credentials: _credentials,
    portrait: _portrait,
    originalPhotoPath: _originalPhotoPath,
    content: _content,
    date: _date,
    message: _message,
    settings: _displaySettings,
    devices: _devices,
    nextSlotAt: _nextSlotAt,
    widgetEnabled: _widgetEnabled,
    onWidgetEnabledChanged:
        (enabled) => setState(() => _widgetEnabled = enabled),
    selectedDeviceId: _photoDevice?.deviceId,
    onTabChanged: _changeTab,
    onRefresh: () async {
      _accountRetryAttempt = 0;
      await _load();
    },
    onNext: _nextCarouselPhoto,
    onDeviceChanged: _changePhotoDevice,
    onOpenDevice: _openDeviceDetail,
    onAddDevice: _showAddDeviceNotice,
    onCopyDeviceId: _copyDeviceId,
    account: _account,
    onAccountTap: _openAuth,
    onSignOut: _signOut,
    accountBusy: _accountBusy,
  );
}
