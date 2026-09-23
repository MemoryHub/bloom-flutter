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
  if (Platform.isAndroid) {
    await initializeBackgroundSync();
  }
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
  DeviceCredentials? _credentials;
  PairingInfo? _pairing;
  CachedWidgetImage? _portrait;
  DailyContent? _content;
  String? _originalPhotoPath;
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
    _slotWatch = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || _loading || !_widgetEnabled) return;
      _load(showSpinner: false);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slotWatch?.cancel();
    _pairingPoll?.cancel();
    _messageTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner && mounted) setState(() => _loading = true);
    try {
      final storedCredentials = await _identity.read();
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
      DeviceStatus? status;
      PairingInfo? pairing;
      if (storedCredentials == null) {
        pairing = await _api.register(credentials, name: 'Bloom 手机');
        status = await _api.status(credentials);
      } else {
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
      }

      CachedWidgetImage? portrait;
      DailyContent? content;
      String? originalPhotoPath;
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
            content =
                displaySettings.mode == BloomDisplayMode.carousel
                    ? await repository.syncCarousel(
                      credentials,
                      displaySettings,
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
          final nativePhoto =
              native == null
                  ? null
                  : (native.originalPhotoPath ?? native.portraitPath);
          final nativePhotoExists =
              nativePhoto != null && await File(nativePhoto).exists();
          final expectedMode =
              displaySettings.mode == BloomDisplayMode.carousel
                  ? 'carousel'
                  : 'recommendation';
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
          // Flutter cache. Otherwise use the normal repository paths.
          originalPhotoPath ??= await repository.originalPhotoPath();
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
              originalPhotoPath: originalPhotoPath,
              captionZh: content?.captionZh,
              captionEn: content?.captionEn,
              capturedDateText: content?.capturedDateText,
              locationText: content?.locationText,
              mode:
                  displaySettings.mode == BloomDisplayMode.carousel
                      ? 'carousel'
                      : 'recommendation',
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
      setState(() {
        _credentials = credentials;
        _pairing = pairing ?? _pairing;
        _paired = pairedNow;
        _portrait = portrait ?? _portrait;
        _content = content ?? _content;
        _originalPhotoPath = originalPhotoPath ?? _originalPhotoPath;
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
    }
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
      final content = await repository.syncCarousel(
        credentials,
        _displaySettings,
        next: true,
      );
      final portrait = await repository.cached('portrait');
      final square = await repository.cached('square');
      final largeSquare = await repository.cached('largeSquare');
      final originalPhotoPath = await repository.originalPhotoPath();
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
