import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'background_sync.dart';
import 'core/api/bloom_api_client.dart';
import 'core/models/device_models.dart';
import 'core/storage/daily_content_repository.dart';
import 'core/storage/device_identity_repository.dart';
import 'core/storage/display_preferences.dart';
import 'platform/widget_bridge.dart';
import 'ui/bloom_device_pages.dart';
import 'ui/bloom_glass_home.dart';

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
  });

  /// Test seams. Production passes nothing and the state builds the real
  /// collaborators; the widget tests inject a stub identity and a stubbed
  /// `http.Client` so `_load()` can be observed (in particular the requests it
  /// must *not* make).
  final DeviceIdentityRepository? identity;
  final BloomApiClient? api;
  final DisplayPreferences? displayPreferences;

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

  Timer? _pairingPoll;
  Timer? _messageTimer;
  /// Turns the page when its slot arrives while the app is open.
  Timer? _slotWatch;
  /// Fires exactly when the next slot begins.
  Timer? _slotWake;
  Timer? _followNative;
  DeviceCredentials? _credentials;
  PairingInfo? _pairing;
  CachedWidgetImage? _portrait;
  DailyContent? _content;
  String? _originalPhotoPath;
  int? _nextSlotAt;
  bool _loadInFlight = false;
  DateTime? _loadStartedAt;
  DateTime? _pausedAt;
  String? _date;
  String? _message;

  /// The master switch, mirrored from the device page: off means the widget is
  /// not running and this page must not fetch anything.
  bool _widgetEnabled = true;
  bool _paired = false;
  bool _loading = true;
  bool _pairingRefreshing = false;
  bool _nextLoading = false;
  int _selectedTab = 0;

  /// Device whose photos the photo page shows. `null` = this phone (the only
  /// device whose photos the app can load).
  String? _photoDeviceId;
  BloomDisplaySettings _displaySettings = const BloomDisplaySettings();

  @override
  void initState() {
    super.initState();
    // **Follow the widget continuously.** The app read the native current item only
    // while it ran a sync, so between syncs the widget could advance while the card
    // stayed behind — the "widget and app show different photos" symptom. Re-reading
    // it every 20 s while the page is alive removes the gap by construction.
    _followNative = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!mounted || _loading) return;
      final repository = DailyContentRepository(api: _api);
      await repository.drainWidgetTimelineLog();
      final native = await repository.nativeContent();
      if (!mounted || native == null) return;
      if (native.recommendationId == _content?.recommendationId) return;
      // ⚠️ **照片要跟着动，不能只换文案。** 原来这里只 setState 了 `_content`
      //    （文案），照片仍是上一张 —— 而 [Repository.photoPathFor] 按 id 取
      //    路径这件事本来就是为「照片与文案同源」做的。只换文案正好把这条
      //    保证拆掉：卡片会显示 A 的图配 B 的字。
      //    冷启动时这个定时器以前被 `_loading` 挡着（一轮 sync 要 60 秒），
      //    现在本机那张会先被画上去，`_loading` 提前转 false，它就会真的跑 ——
      //    所以这里必须把路径一起换掉。
      final path =
          await repository.photoPathFor(native.recommendationId) ??
          await repository.originalPhotoPath();
      if (!mounted) return;
      setState(() {
        _content = native;
        if (path != null) _originalPhotoPath = path;
      });
    });
    WidgetsBinding.instance.addObserver(this);
    _load();
    _startSlotWatch();
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
    // ⚠️ 推荐的下一格**不在** `next_slot_at_ms` 里（那是轮播的戳，推荐路径不写）。
    //    在推荐模式下读它只会拿到上一轮轮播留下的过期值，于是这次唤醒要么永远
    //    不响、要么在错误的时刻响。两边用同一个来源：推荐按固定作息算。
    final at = _displaySettings.mode == BloomDisplayMode.recommendation
        ? _nextRecommendSlotMs(_displaySettings)
        : await DailyContentRepository(api: _api).nextSlotAtMillis();
    if (!mounted || at == null) return;
    final delay = at - DateTime.now().millisecondsSinceEpoch;
    if (delay <= 0) return;
    _slotWake?.cancel();
    _slotWake = Timer(Duration(milliseconds: delay + 1500), () async {
      if (!mounted || !_widgetEnabled) return;
      await _load(showSpinner: false);
      await _armNextSlotWake();
    });
  }

  /// 推荐模式的下一次更新时间。
  ///
  /// 推荐【没有服务端计划戳】—— 那是轮播的概念。它的节奏由固定作息给出:
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
    final start = DateTime(now.year, now.month, now.day, startHour, startMinute);
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
    _followNative?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _slotWake?.cancel();
    _slotWatch?.cancel();
    _pairingPoll?.cancel();
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
    final repository = DailyContentRepository(api: _api);
    CachedWidgetImage? portrait;
    DailyContent? content;
    String? photoPath;
    try {
      final native = await WidgetBridge().readCurrentState();
      if (native != null) {
        final path =
            await repository.photoPathFor(native.recommendationId) ??
            native.originalPhotoPath ??
            native.portraitPath;
        if (path != null && await File(path).exists()) {
          photoPath = path;
          content = DailyContent(
            date: native.date ?? '',
            recommendationId: native.recommendationId,
            captionZh: native.captionZh,
            captionEn: native.captionEn,
            capturedDateText: native.capturedDateText,
            locationText: native.locationText,
          );
          portrait = CachedWidgetImage(
            path: path,
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
        final path =
            await repository.photoPathFor(cached?.recommendationId) ??
            await repository.originalPhotoPath();
        if (cached != null && path != null) {
          photoPath = path;
          content = cached;
          portrait = await repository.cached('portrait');
        }
      } catch (_) {
        // 什么都没有（第一次安装 / 缓存被清）：交给下面正常的联网路径。
      }
    }
    if (photoPath == null || !mounted) return;
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
      _loading = false;
    });
  }

  Future<void> _load({bool showSpinner = true}) async {
    // **One load at a time.** Resume, the slot timer and the 30 s fallback can
    // all ask within the same second, and a second sync would only race the
    // first for the same files (and double the refill's network cost).
    if (_loadInFlight) {
      final started = _loadStartedAt;
      if (started != null &&
          DateTime.now().difference(started) < const Duration(seconds: 60)) {
        return;
      }
      // **A stuck load must not freeze every later refresh.** A download can
      // outlive its own timeout, and the guard is only there to stop two *live*
      // syncs racing for the same files — so once the holder is this old, let the
      // new one through.
    }
    _loadInFlight = true;
    _loadStartedAt = DateTime.now();
    if (showSpinner && mounted) setState(() => _loading = true);
    try {
      final credentials = await _identity.initialize();
      // Device identity is local state and must remain visible even when the
      // following server/status/photo request fails.
      if (mounted) {
        setState(() => _credentials = credentials);
      }
      // Local-only, and deliberately *not* `read()`: the mirror
      // (`bloom.display_mode` + the three `bloom.carousel_*` keys) is the phone
      // widget's own record, and a server read here would (a) write the frame's
      // `eink` schedule into it, changing the phone widget's cadence, and
      // (b) put a network round trip in front of the first frame even though
      // the photo page shows no settings at all. `readLocal()` touches neither
      // the network nor the mirror and still gives the photo page the phone's
      // own mode, which picks the carousel/recommendation sync path.
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
      if (localSettings.mode == BloomDisplayMode.recommendation && mounted) {
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
      DeviceStatus? status;
      PairingInfo? pairing;
      // **Always probe the server first, regardless of local cache state.**
      // `storedCredentials == null` used to gate straight to `register()`,
      // treating "no local cache" as "server has never seen this device".
      // That is only true on iOS. On Android, `initialize()` re-derives a
      // deterministic id from `ANDROID_ID` when the local cache is missing
      // (a fresh install, or the app's data being cleared), so the server
      // may already recognize this exact device — calling `register()`
      // unconditionally in that case can reset an already-paired device back
      // to unpaired, which is exactly the "stuck on the pairing screen even
      // though the device is bound server-side" symptom. `status()` is the
      // only call that can tell the two cases apart; `register()` must stay
      // reserved for the case the server actually says it doesn't know this
      // device (401 device_authentication_required).
      try {
        status = await _api.status(credentials);
      } on BloomApiException catch (error) {
        if (error.statusCode == 401 &&
            error.code == 'device_authentication_required') {
          pairing = await _api.register(credentials, name: 'Bloom 手机');
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
      var displaySettings = await displaySettingsFuture;
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
      final serverMode = bloomModeFromWire(status?.mode);
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
      if (status?.paired == true) {
        _pairingPoll?.cancel();
        // Pairing is a server-authentication state, not an image-refresh
        // state. Enter the photo experience immediately and never fall back
        // to the pairing screen merely because a download/render fails.
        if (mounted && !_paired) {
          setState(() => _paired = true);
        }
        if (status?.hasAssets == true) {
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
            final cachedOriginal = await repository.originalPhotoPath();
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
              _originalPhotoPath = cachedOriginal ?? _originalPhotoPath;
              _date = cachedBeforeSync.date;
              _displaySettings = displaySettings;
              _loading = false;
              _message = null;
            });
          }
          // A widget alarm can advance the shared native cache while the
          // carousel plan is still being downloaded. Seed the photo page from
          // that newer native item immediately, instead of briefly showing
          // the older daily.json image until the network/render pass finishes.
          final nativeBeforeSync = await WidgetBridge().readCurrentState();
          final nativeBeforePortrait = nativeBeforeSync?.portraitPath;
          final nativeBeforeIsCurrent =
              nativeBeforeSync != null &&
              nativeBeforeSync.mode == 'carousel' &&
              nativeBeforePortrait != null &&
              await File(nativeBeforePortrait).exists() &&
              (cachedBeforeSync == null ||
                  nativeBeforeSync.recommendationId >=
                      cachedBeforeSync.recommendationId);
          if (nativeBeforeIsCurrent && mounted) {
            final nativeBefore = nativeBeforeSync;
            setState(() {
              _portrait = CachedWidgetImage(
                path: nativeBeforePortrait,
                orientation: 'portrait',
                date: nativeBefore.date,
                recommendationId: nativeBefore.recommendationId,
              );
              _content = DailyContent(
                date: nativeBefore.date ?? '',
                recommendationId: nativeBefore.recommendationId,
                captionZh: nativeBefore.captionZh,
                captionEn: nativeBefore.captionEn,
                capturedDateText: nativeBefore.capturedDateText,
                locationText: nativeBefore.locationText,
              );
              _originalPhotoPath =
                  nativeBefore.originalPhotoPath ?? _originalPhotoPath;
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
            if (displaySettings.mode == BloomDisplayMode.carousel) {
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
            // ⚠️ 推荐走它自己的算法路径，不与轮播共用引擎（见
            //    background_sync.dart 的说明）。
            content =
                displaySettings.mode == BloomDisplayMode.carousel
                    ? await repository.syncCarousel(
                      credentials,
                      displaySettings,
                      foreground: true,
                    )
                    : await repository.sync(credentials);
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
                  : (await repository.photoPathFor(native.recommendationId) ??
                      native.originalPhotoPath ??
                      native.portraitPath);
          final nativePhotoExists =
              nativePhoto != null && await File(nativePhoto).exists();
          final expectedMode =
              displaySettings.mode == BloomDisplayMode.carousel
                  ? 'carousel'
                  : 'recommend';
          final networkId = content?.recommendationId ?? 0;
          if (native != null &&
              nativePhotoExists &&
              (native.mode == null || native.mode == expectedMode) &&
              native.recommendationId >= networkId) {
            content = DailyContent(
              date: native.date ?? content?.date ?? '',
              recommendationId: native.recommendationId,
              captionZh: native.captionZh,
              captionEn: native.captionEn,
              capturedDateText: native.capturedDateText,
              locationText: native.locationText,
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
          originalPhotoPath ??=
              await repository.photoPathFor(content?.recommendationId) ??
              await repository.originalPhotoPath();
          // Read the slot stamp the same sync just wrote, so the label under the
          // card always belongs to the plan that is on screen.
          //
          // ⚠️ **推荐模式没有这个戳。** `next_slot_at_ms` 是轮播的概念（由引擎在
          //    计划落盘时写进 daily.json），推荐路径从不写它，所以这里原来在推荐
          //    模式下永远是 null —— 首页那行「下次更新」只在【保存过一次设置】
          //    之后才出现（那条路会把 `_nextRecommendSlotMs` 塞进 `_nextSlotAt`）。
          //    推荐的节奏由固定作息唯一决定（06:00–22:00 / 12 小时 → 06:00、18:00），
          //    所以这里直接按作息算，冷启动和保存后走同一个来源。
          nextSlotAt = displaySettings.mode == BloomDisplayMode.recommendation
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
          if (portrait != null) {
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
                  displaySettings.mode == BloomDisplayMode.carousel
                      ? 'carousel'
                      : 'recommend',
            );
          }
        } else {
          message = '已经绑定，照片准备好后会自动显示。';
        }
      } else {
        _startPairingPoll();
      }

      if (!mounted) return;
      await _evictPreviewImages([portrait]);
      if (!mounted) return;
      final pairedNow = status?.paired ?? false;
      final pairingJustCompleted =
          !_paired && pairedNow && _credentials != null;
      await _precacheIncoming(originalPhotoPath);
      setState(() {
        _credentials = credentials;
        _pairing = pairing ?? _pairing;
        _paired = pairedNow;
        _portrait = portrait ?? _portrait;
        _content = content ?? _content;
        _originalPhotoPath = originalPhotoPath ?? _originalPhotoPath;
        _nextSlotAt = nextSlotAt ?? _nextSlotAt;
        _date = date ?? _date;
        _message = message;
        _displaySettings = displaySettings;
        _loading = false;
      });
      if (pairingJustCompleted) {
        await HapticFeedback.mediumImpact();
        _notify('设备配对成功。');
      } else if (message != null) {
        _scheduleMessageClear();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message =
            error is BloomApiException
                ? '服务器请求失败（${error.statusCode}），已有照片会继续保留。'
                : '暂时无法连接服务器，已有照片会继续保留。';
        _loading = false;
      });
      _scheduleMessageClear();
    } finally {
      _loadInFlight = false;
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
    final away = _pausedAt == null ? null : DateTime.now().difference(_pausedAt!);
    _pausedAt = null;
    // `null` means this is the resume that every cold start produces (the first
    // `_load` is already running), and a blink shorter than this is the
    // notification shade, not a return.
    if (away == null || away < const Duration(seconds: 5)) return;
    unawaited(_load(showSpinner: false));
  }

  void _startPairingPoll() {
    _pairingPoll ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => _pollPairing(),
    );
  }

  Future<void> _pollPairing() async {
    final credentials = _credentials;
    if (credentials == null) return;
    try {
      final status = await _api.status(credentials);
      if (status.paired) await _load(showSpinner: false);
    } catch (_) {}
  }

  Future<void> _newPairingCode() async {
    final credentials = _credentials;
    if (credentials == null || _pairingRefreshing) return;
    await HapticFeedback.lightImpact();
    if (mounted) setState(() => _pairingRefreshing = true);
    try {
      final pairing = await _api.refreshPairingCode(credentials);
      if (!mounted) return;
      setState(() => _pairing = pairing);
      _notify('新的激活码已生成。');
    } catch (_) {
      _notify('绑定码获取失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _pairingRefreshing = false);
    }
  }

  /// Devices the photo page switcher and the "设备" tab list.
  ///
  /// Hardcoded on purpose: `listMyDevices()` is a user-session endpoint and
  /// throws [UnsupportedError] without a login (F1), so nothing here calls it.
  List<BloomDevice> get _devices => bloomDevices(
    credentials: _credentials,
    localOnline: _credentials == null ? null : _paired,
  );

  /// The device whose photos the photo page shows; falls back to this phone.
  BloomDevice? get _photoDevice {
    final devices = _devices;
    final selected = _photoDeviceId;
    if (selected != null) {
      for (final device in devices) {
        if (device.deviceId == selected) return device;
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

  void _showAddDeviceNotice() {
    HapticFeedback.lightImpact();
    _notify('扫码配对即将支持');
  }

  Future<void> _openDeviceDetail(BloomDevice device) async {
    final credentials = _credentials;
    await BloomDeviceDetailPage.open(
      context,
      device: device,
      preferences: _displayPreferences,
      settings: _displaySettings,
      credentials: credentials,
      // The app writes with the token it holds, so the caller is the app's own
      // device (not the frame it is configuring).
      callerDeviceId: credentials?.deviceId,
      // The page paints the same photo the home page does, so its glass has
      // something to refract.
      photoPath: _originalPhotoPath,
      pairing: _pairing,
      onModeChanged: (settings) => _applyModeChange(device, settings),
      onSaved: (settings) => _applySavedSettings(device, settings),
      // **The link that was missing.** The detail page has always called this
      // callback when the switch moves; nobody was listening, because this route
      // was opened without it.
      onWidgetEnabledChanged:
          (enabled) => setState(() => _widgetEnabled = enabled),
      onRefreshPairingCode: _newPairingCode,
      onCopyPairingCode: _copyPairingCode,
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
    // ⭐ 保存之后必须让取图链路【重跑一次】。
    //
    // 为什么: 服务器的 mode 与作息改完之后，「下一次更新时间」和「小组件该
    // 显示哪张」都变了，但这两个东西【只在下一次 syncCarousel 落地时才更新】。
    // 原来这里只 setState 了 _displaySettings —— 于是首页的「下次更新」文案、
    // Android/iOS 小组件读到的共享状态，全都停在上一份计划上，
    // 用户要【杀死 App 重进】才会好。这正是那个症状的根因。
    unawaited(_resyncCarouselAfterSave(settings));
  }

  /// 保存设置后立刻重跑一次 carousel 同步，并刷新首页的「下次更新」。
  ///
  /// 失败不能影响保存结果 —— 设置已经写进服务器了，重同步只是让界面和
  /// 小组件跟上；拉不到就等下一次后台同步，不该弹错误。
  Future<void> _resyncCarouselAfterSave(BloomDisplaySettings settings) async {
    final credentials = _credentials;
    if (credentials == null) return;
    final repository = DailyContentRepository(api: _api);
    try {
      if (settings.mode == BloomDisplayMode.carousel) {
        await repository.syncCarousel(
          credentials,
          settings,
          // foreground: 用前台写入者身份，这样后台任务拿到的是最新计划，
          // 也能顺带把 iOS 小组件要读的共享状态重写一遍。
          foreground: true,
        );
        final at = await repository.nextSlotAtMillis();
        if (!mounted) return;
        setState(() => _nextSlotAt = at);
        debugPrint('[BloomUI] resynced (carousel) after save: next=${at ?? 'none'}');
      } else {
        await repository.sync(credentials);
        if (!mounted) return;
        setState(() => _nextSlotAt = _nextRecommendSlotMs(settings));
        debugPrint('[BloomUI] resynced (recommend) after save');
      }
      // ⭐ 最后一步：让原生小组件【立刻重载】。
      //
      // 少了这一步就会出现用户报的那个现象: App 里的文案已经换成新的了，
      // 照片却还是上一张（桌面小组件也还是上一张）—— 因为 App 的照片取自
      // 原生小组件状态，而那个状态要等小组件自己按时间线刷新才更新，
      // 推荐模式下那是【按天】的，所以会一直停在旧图上。
      // 文案来自 Flutter 缓存、照片来自原生状态，两个源不同步，就"对不上"了。
      await WidgetBridge().refresh();
    } catch (error) {
      debugPrint('[BloomUI] resync after save failed (ignored): $error');
    }
  }


  /// A mode change made **on a device's own detail page**.
  ///
  /// This is the bug the user kept reporting: it used to take no device and
  /// carry no guard, so changing the mode on the **frame's** page adopted the
  /// frame's `eink` record into this phone's shared slot — the phone's home page
  /// then said 推荐 while the phone's own page said 轮播, and switching the
  /// device picker back to 手机小组件 showed the frame's mode. Its sibling
  /// [_applySavedSettings] has had exactly this guard (and the comment above it)
  /// all along; this one was simply missed.
  Future<void> _applyModeChange(
    BloomDevice device,
    BloomDisplaySettings settings,
  ) async {
    if (!mounted || !device.isLocal) return;
    // **Probes for the "I pressed 保存 and nothing happened" chain.**
    //
    // A save is supposed to end with a fresh sync, which is what re-arms the
    // native alarm chain for the new window. When that did not visibly happen
    // there was no way to tell *which* link broke: the save handler, the reload,
    // or the sync inside it. These three lines name each link.
    debugPrint(
      '[BloomSave] saved: mode=${settings.mode.name} '
      'window=${settings.activeStart}-${settings.activeEnd} '
      'interval=${settings.intervalMinutes}',
    );
    setState(() => _displaySettings = settings);
    // Re-run the load so the photo page shows the newly selected mode's photo.
    await _load(showSpinner: false);
    debugPrint('[BloomSave] reload finished (alarms should be re-armed)');
  }

  Future<void> _nextCarouselPhoto() async {
    final credentials = _credentials;
    if (credentials == null || _loading || _nextLoading) {
      return;
    }
    await HapticFeedback.lightImpact();
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
        _displaySettings,
        next: true,
      );
      final portrait = await repository.cached('portrait');
      final square = await repository.cached('square');
      final largeSquare = await repository.cached('largeSquare');
      final originalPhotoPath =
          await repository.photoPathFor(content.recommendationId) ??
          await repository.originalPhotoPath();
      await _evictOriginalPhoto(originalPhotoPath);
      await _evictPreviewImages([portrait, square, largeSquare]);
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
      if (!mounted) return;
      setState(() {
        _portrait = portrait ?? _portrait;
        _content = content;
        _originalPhotoPath = originalPhotoPath ?? _originalPhotoPath;
        _date = content.date;
      });
      await HapticFeedback.mediumImpact();
      _notify('已切换到下一张。');
    } catch (_) {
      _notify('下一张获取失败，请稍后重试。');
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

  Future<void> _copyPairingCode() async {
    final value = _pairing?.code;
    if (value == null) return;
    await Clipboard.setData(ClipboardData(text: value));
    await HapticFeedback.lightImpact();
    _notify('激活码已复制。');
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
    for (var i = 0; i < 100 && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final at = await repository.nextSlotAtMillis();
      if (!mounted || at == null || at == _nextSlotAt) continue;
      setState(() => _nextSlotAt = at);
    }
  }

  @override
  Widget build(BuildContext context) => BloomGlassHome(
    loading: _loading,
    paired: _paired,
    pairingRefreshing: _pairingRefreshing,
    nextLoading: _nextLoading,
    selectedTab: _selectedTab,
    credentials: _credentials,
    pairing: _pairing,
    portrait: _portrait,
    originalPhotoPath: _originalPhotoPath,
    content: _content,
    date: _date,
    message: _message,
    settings: _displaySettings,
    devices: _devices,
    nextSlotAt: _nextSlotAt,
    widgetEnabled: _widgetEnabled,
    onWidgetEnabledChanged: (enabled) => setState(() => _widgetEnabled = enabled),
    selectedDeviceId: _photoDevice?.deviceId,
    onTabChanged: _changeTab,
    onRefresh: _load,
    onNext: _nextCarouselPhoto,
    onDeviceChanged: _changePhotoDevice,
    onOpenDevice: _openDeviceDetail,
    onAddDevice: _showAddDeviceNotice,
    onRefreshPairingCode: _newPairingCode,
    onCopyDeviceId: _copyDeviceId,
    onCopyPairingCode: _copyPairingCode,
  );
}
