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
    themeMode: ThemeMode.light,
    theme: ThemeData(
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: Color(0xff506B67),
        secondary: Color(0xff718A85),
        surface: Color(0xffF7F4EE),
      ),
      scaffoldBackgroundColor: const Color(0xffF5F2EB),
      useMaterial3: true,
    ),
    home: const BloomHomePage(),
  );
}

class BloomHomePage extends StatefulWidget {
  const BloomHomePage({super.key});

  @override
  State<BloomHomePage> createState() => _BloomHomePageState();
}

class _BloomHomePageState extends State<BloomHomePage> {
  final _identity = DeviceIdentityRepository();
  final _api = BloomApiClient();
  final _displayPreferences = DisplayPreferences();

  Timer? _pairingPoll;
  Timer? _messageTimer;
  DeviceCredentials? _credentials;
  PairingInfo? _pairing;
  CachedWidgetImage? _portrait;
  DailyContent? _content;
  String? _originalPhotoPath;
  String? _date;
  String? _message;
  bool _paired = false;
  bool _loading = true;
  bool _pairingRefreshing = false;
  bool _nextLoading = false;
  bool _modeSwitching = false;
  int _selectedTab = 0;
  BloomDisplaySettings _displaySettings = const BloomDisplaySettings();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
      final displaySettings = await _displayPreferences.read();
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
              _originalPhotoPath = cachedOriginal;
              _date = cachedBeforeSync.date;
              _displaySettings = displaySettings;
              _loading = false;
              _message = null;
            });
          }
          try {
            content =
                displaySettings.mode == BloomDisplayMode.carousel
                    ? await repository.syncCarousel(
                      credentials,
                      displaySettings,
                    )
                    : await repository.sync(credentials);
          } catch (_) {
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

  Future<void> _setDisplayMode(BloomDisplayMode mode) async {
    if (_displaySettings.mode == mode ||
        _loading ||
        _modeSwitching ||
        _nextLoading) {
      return;
    }
    setState(() => _modeSwitching = true);
    await HapticFeedback.selectionClick();
    try {
      final settings = _displaySettings.copyWith(mode: mode);
      await _displayPreferences.write(settings);
      if (!mounted) return;
      setState(() => _displaySettings = settings);
      await _load();
    } catch (_) {
      _notify('模式切换失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _modeSwitching = false);
    }
  }

  Future<void> _nextCarouselPhoto() async {
    final credentials = _credentials;
    if (credentials == null || _loading || _modeSwitching || _nextLoading) {
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

  Future<void> _showCarouselSettings() async {
    var draft = _displaySettings;
    final result = await showModalBottomSheet<BloomDisplaySettings>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xffF7F4EE),
      barrierColor: const Color(0x520D1716),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setSheetState) => SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      22,
                      18,
                      22,
                      22 + MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 38,
                            height: 4,
                            decoration: BoxDecoration(
                              color: const Color(0x382F3E3B),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          '轮播设置',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 20),
                        DropdownButtonFormField<int>(
                          value: draft.intervalMinutes,
                          decoration: const InputDecoration(
                            labelText: '更换频率',
                            border: OutlineInputBorder(),
                          ),
                          items:
                              BloomDisplaySettings.allowedIntervals
                                  .map(
                                    (value) => DropdownMenuItem(
                                      value: value,
                                      child: Text(
                                        BloomDisplaySettings(
                                          intervalMinutes: value,
                                        ).intervalLabel,
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setSheetState(
                                () =>
                                    draft = draft.copyWith(
                                      intervalMinutes: value,
                                    ),
                              );
                            }
                          },
                        ),
                        const SizedBox(height: 10),
                        _TimeSettingTile(
                          title: '开始时间',
                          value: draft.activeStart,
                          onTap: () async {
                            final selected = await showTimePicker(
                              context: context,
                              initialTime: _parseTime(draft.activeStart),
                            );
                            if (selected != null) {
                              setSheetState(
                                () =>
                                    draft = draft.copyWith(
                                      activeStart: _formatTime(selected),
                                    ),
                              );
                            }
                          },
                        ),
                        if (draft.intervalMinutes < 1440)
                          _TimeSettingTile(
                            title: '结束时间',
                            value: draft.activeEnd,
                            onTap: () async {
                              final selected = await showTimePicker(
                                context: context,
                                initialTime: _parseTime(draft.activeEnd),
                              );
                              if (selected != null) {
                                setSheetState(
                                  () =>
                                      draft = draft.copyWith(
                                        activeEnd: _formatTime(selected),
                                      ),
                                );
                              }
                            },
                          ),
                        const SizedBox(height: 6),
                        Text(
                          draft.intervalMinutes == 1440
                              ? '每天 ${draft.activeStart} 更新一次'
                              : '预计每天更新 ${draft.expectedDailyItems} 张',
                          style: const TextStyle(color: Color(0xff68736F)),
                        ),
                        const SizedBox(height: 22),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, draft),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                            backgroundColor: const Color(0xff526E69),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ),
                ),
          ),
    );
    if (result == null) return;
    if (result.intervalMinutes < 1440 && result.expectedDailyItems < 1) {
      _notify('结束时间必须晚于开始时间。');
      return;
    }
    await _displayPreferences.write(result);
    if (!mounted) return;
    setState(() => _displaySettings = result);
    await HapticFeedback.mediumImpact();
    _notify('轮播设置已保存。');
    await _load(showSpinner: false);
  }

  static TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts.first) ?? 6,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  static String _formatTime(TimeOfDay value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => BloomGlassHome(
    loading: _loading || _modeSwitching,
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
    onTabChanged: _changeTab,
    onRefresh: _load,
    onModeChanged: _setDisplayMode,
    onNext: _nextCarouselPhoto,
    onOpenCarouselSettings: _showCarouselSettings,
    onRefreshPairingCode: _newPairingCode,
    onCopyDeviceId: _copyDeviceId,
    onCopyPairingCode: _copyPairingCode,
  );
}

class _TimeSettingTile extends StatelessWidget {
  const _TimeSettingTile({
    required this.title,
    required this.value,
    required this.onTap,
  });

  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    trailing: Text(
      value,
      style: const TextStyle(
        color: Color(0xff526E69),
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
    onTap: onTap,
  );
}
