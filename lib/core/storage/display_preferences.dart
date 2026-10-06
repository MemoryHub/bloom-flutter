import 'dart:io';

import 'package:bloom_widget_bridge/bloom_widget_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/bloom_api_client.dart';
import '../models/device_models.dart';

enum BloomDisplayMode { recommendation, carousel }

/// 照片【来源】。与 `mode` 正交：sources 决定"从哪些池子里取候选"，
/// mode 决定"怎么给候选排序"。两者是独立的两件事，任意组合都合法。
///
/// ⚠️ wire 值必须与服务器的 `carousel.SUPPORTED_SOURCES` 完全一致 ——
/// 那是最权威的一份名单。服务器现在【登记了四个】但只实现了 personal：
/// 登记不等于能取到片。
enum BloomPhotoSource {
  /// 用户自己上传 / Immich 图库里的照片。目前唯一真正实现的来源。
  personal('personal', '我的照片'),

  /// 名画 / 油画。服务器已登记，取片能力待实现。
  art('art', '名画'),

  /// 新闻图片。服务器已登记，取片能力待实现。
  news('news', '新闻'),

  /// 小组件生成的内容（天气 / 股票 / 自创）。注意它是【内容来源】，
  /// 不是设备类型 —— 设备类型是 target，两者不要混。
  widget('widget', '小组件');

  const BloomPhotoSource(this.wire, this.label);

  /// 协议值（小写，永不翻译，永远不要改）。
  final String wire;

  /// 界面显示名。可以随时改，不影响协议。
  final String label;

  /// 服务器【真正能取到照片】的来源。UI 只应该给出这些选项 ——
  /// 给出还没实现的来源，用户设完之后相框毫无变化，就是"设了没反应"。
  static const implemented = <BloomPhotoSource>[BloomPhotoSource.personal];

  /// 从协议值解析；认不出来返回 null（调用方当作"保持现状"）。
  static BloomPhotoSource? fromWire(String? value) {
    for (final source in BloomPhotoSource.values) {
      if (source.wire == value) return source;
    }
    return null;
  }
}

/// 把选中的来源转成服务器的 wire 形状。
///
/// 服务器同时接受纯字符串与 `{name, weight}` 两种写法，这里一律发对象 ——
/// 权重现在恒为 1，但形状先站住，将来做混合权重时客户端不用再改协议。
///
/// ⚠️ 空列表【不发送】而不是发 `[]`：服务器的语义是"没送 = 别动已存的值"
///    （与 mode 一字不差的同一规矩）。发 `[]` 会被 normalize_sources 当成
///    "什么都没说"而回退到 personal，等于把用户的选择悄悄改掉。
List<Map<String, Object?>> bloomSourcesToWire(
  Iterable<BloomPhotoSource> sources,
) => <Map<String, Object?>>[
  for (final source in sources)
    <String, Object?>{'name': source.wire, 'weight': 1},
];

/// 解析服务器回显的 `sources` 字段。
///
/// 服务器同时回 `sources_key`（规范串）与 `sources`（列表），这里用列表，
/// 因为它不用再解析格式。认不出来的名字直接跳过 —— 服务器加了新来源而
/// 这个 App 版本还不认识时，不该因此崩掉或清空用户的选择。
List<BloomPhotoSource> bloomSourcesFromWire(Object? value) {
  if (value is! List) return const <BloomPhotoSource>[];
  final out = <BloomPhotoSource>[];
  for (final entry in value) {
    final String? name = switch (entry) {
      String raw => raw,
      Map raw => (raw['name'] ?? raw['id']) as String?,
      _ => null,
    };
    final parsed = BloomPhotoSource.fromWire(name);
    if (parsed != null && !out.contains(parsed)) out.add(parsed);
  }
  return out;
}

/// 协议里登记的全部来源（= 服务器 `SUPPORTED_SOURCES`）。
///
/// 单独列出来是为了让"客户端认识的名单"和"服务器登记的名单"有一个
/// 可断言的对照点；加了新来源时两处一起改，测试会提醒。
const List<String> bloomSourceWireValues = <String>[
  'personal',
  'art',
  'news',
  'widget',
];

/// The value the server stores for [mode] in `frame_device_settings.mode`.
///
/// **This is now the same spelling everywhere**: the wire protocol, the local
/// mirror the native widgets read, and the Kotlin/Swift sides all say
/// `carousel` / `recommend`. There used to be a second spelling
/// (`recommendation`) for the local mirror alone; it was removed because one
/// concept with two names is how a cross-language contract drifts.
///
/// These two functions stay even though they are near-identity now: they are
/// the single place a mode crosses between "what we store" and "what we send",
/// so any future rename has exactly one edit to make.
String bloomModeToWire(BloomDisplayMode mode) =>
    mode == BloomDisplayMode.carousel
        ? DeviceCarouselSettings.modeCarousel
        : DeviceCarouselSettings.modeRecommend;

/// Parses a `mode` from the server or from the local mirror.
///
/// Accepts the retired `recommendation` spelling on the way in: an install that
/// last wrote its mirror before the rename still has that string on disk, and
/// refusing it would silently flip such a user back to carousel. `null` is
/// returned for a missing or unrecognised value, which callers treat as "leave
/// the current setting alone".
BloomDisplayMode? bloomModeFromWire(String? value) {
  if (value == DeviceCarouselSettings.modeCarousel) {
    return BloomDisplayMode.carousel;
  }
  if (value == DeviceCarouselSettings.modeRecommend ||
      value == DeviceCarouselSettings.modeRecommendLegacy) {
    return BloomDisplayMode.recommendation;
  }
  return null;
}

/// Human readable label for a carousel refresh interval in minutes.
String intervalLabel(int minutes) => _intervalLabelText(minutes);

String _intervalLabelText(int minutes) {
  if (minutes <= 0) return '未设置';
  if (minutes == 1440) return '每天一次';
  if (minutes == 720) return '半天一次';
  if (minutes % 60 == 0) return '每${minutes ~/ 60}小时';
  return '每$minutes分钟';
}

/// 推荐模式的固定作息：开始 / 结束 / 间隔。
///
/// ⚠️ 这三个值必须【真的写进请求】。服务器对四个参数零特例 —— 它不会
/// "因为在推荐模式就忽略间隔"，所以 App 必须自己把值填好，而不是指望
/// 服务器替它兜底。
///
/// 06:00–22:00 配 12 小时，一天醒两次（photosPerDay == 2），正好覆盖推荐
/// 算法打分的那一批照片；夜里 22:00–06:00 不唤醒，省电也不打扰。
///
/// 放在这里而不是 UI 文件里：它是一份【协议约定】，和 720 这个档位同级，
/// 不是排版细节 —— 测试与界面都从这里取，避免两处各写一份而漂移。
const String recommendActiveStart = '06:00';
const String recommendActiveEnd = '22:00';
const int recommendIntervalMinutes = 720;

class BloomDisplaySettings {
  const BloomDisplaySettings({
    this.mode = BloomDisplayMode.recommendation,
    // 默认只有一个来源 —— personal 是目前唯一真正取得出照片的来源，
    // 与服务器 carousel.SUPPORTED_SOURCES / IMPLEMENTED_SOURCES 保持一致。
    this.sources = const <BloomPhotoSource>[BloomPhotoSource.personal],
    this.intervalMinutes = 1440,
    this.activeStart = '06:00',
    this.activeEnd = '22:00',
    this.timezone = DeviceCarouselSettings.defaultTimezone,
    this.dailySlotCount,
    this.allowedIntervalMinutes,
  });

  /// The six tiers the carousel settings sheet offers.
  ///
  /// This is a **UI choice**, not a validation whitelist. Values from the
  /// server outside this list (for example 45) are legal and must survive; see
  /// [isValidIntervalMinutes].
  ///
  /// The menu is therefore built defensively: the device-detail sheet renders
  /// `{...allowedIntervals, current}` sorted, so a stored value outside the six
  /// tiers still has a matching entry. `DropdownButtonFormField` asserts in
  /// debug (and shows a blank field in release) when its `value` is missing
  /// from `items`, which is exactly what a server-sent 45 would otherwise do.
  static const allowedIntervals = <int>[15, 30, 60, 120, 720, 1440];

  /// 把 wire 上的来源名字翻成枚举。
  ///
  /// 认不出来的名字【跳过】而不是崩掉：服务器加了新来源而 App 还没跟上时，
  /// 界面少显示一项，但用户的其余选择原样保留 —— 丢掉会让用户觉得
  /// "我选的来源没了"。
  static List<BloomPhotoSource> sourcesFromWire(Iterable<String> names) {
    final out =
        names
            .map(BloomPhotoSource.fromWire)
            .whereType<BloomPhotoSource>()
            .toList();
    return out.isEmpty
        ? const <BloomPhotoSource>[BloomPhotoSource.personal]
        : out;
  }

  /// Whether [value] can describe a schedule at all.
  ///
  /// The server owns the authoritative tier list
  /// (`allowed_interval_minutes`, surfaced through [allowedIntervalMinutes]).
  /// This guard only rejects values that would break the local arithmetic
  /// (zero or negative) — it deliberately does not consult
  /// [allowedIntervals], which used to rewrite every unknown value to 1440.
  static bool isValidIntervalMinutes(int value) => value > 0;

  final BloomDisplayMode mode;
  final int intervalMinutes;

  /// 这台设备的内容来源。
  ///
  /// 与 mode 正交：sources 决定"从哪些池子里取候选"，mode 决定"怎么排序"。
  /// 服务器对四个参数零特例，任何组合都合法。
  final List<BloomPhotoSource> sources;
  final String activeStart;
  final String activeEnd;

  /// Timezone reported by the server. Kept so a save can send the server its
  /// own value back instead of overwriting it with a hardcoded default.
  final String timezone;

  /// Server-computed `daily_slot_count`; `null` for settings that only came
  /// from the local mirror.
  final int? dailySlotCount;

  /// Server's authoritative `allowed_interval_minutes`; `null` when the
  /// settings only came from the local mirror.
  final List<int>? allowedIntervalMinutes;

  BloomDisplaySettings copyWith({
    BloomDisplayMode? mode,
    int? intervalMinutes,
    List<BloomPhotoSource>? sources,
    String? activeStart,
    String? activeEnd,
    String? timezone,
    int? dailySlotCount,
    List<int>? allowedIntervalMinutes,
  }) {
    final scheduleEdited =
        intervalMinutes != null || activeStart != null || activeEnd != null;
    return BloomDisplaySettings(
      mode: mode ?? this.mode,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      sources: sources ?? this.sources,
      activeStart: activeStart ?? this.activeStart,
      activeEnd: activeEnd ?? this.activeEnd,
      timezone: timezone ?? this.timezone,
      // A locally edited window invalidates the server-computed slot count;
      // keeping it would make the settings sheet show the estimate of the
      // previous schedule.
      dailySlotCount:
          dailySlotCount ?? (scheduleEdited ? null : this.dailySlotCount),
      allowedIntervalMinutes:
          allowedIntervalMinutes ?? this.allowedIntervalMinutes,
    );
  }

  String get intervalLabel => _intervalLabelText(intervalMinutes);

  /// Photos the schedule plays per day.
  ///
  /// Prefers the server-computed [dailySlotCount]. The local formula below is
  /// only a fallback for settings read from the local mirror, and it is
  /// intentionally kept as-is even though it disagrees with the server by ±1
  /// for the same window (06:00–22:00 at 15 minutes yields 64 here and 65 on
  /// the server).
  int get expectedDailyItems {
    final fromServer = dailySlotCount;
    if (fromServer != null && fromServer > 0) return fromServer;
    if (intervalMinutes <= 0) return 0;
    if (intervalMinutes == 1440) return 1;
    final start = _minutes(activeStart);
    final end = _minutes(activeEnd);
    if (start == null || end == null || end <= start) return 0;
    return ((end - start - 1) ~/ intervalMinutes) + 1;
  }

  static int? _minutes(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      return null;
    }
    return hour * 60 + minute;
  }
}

/// Stores the carousel display settings.
///
/// The server is now the source of truth (F2); the four `bloom.carousel_*` /
/// `bloom.display_mode` preferences remain a **local mirror** that the Android
/// and iOS home-screen widgets read directly from native code.
///
/// [read] is server-first and never throws. [saveRemote] writes the server and
/// [cacheLocal] writes the mirror; they are separate on purpose so a rejected
/// server write cannot leave the mirror ahead of the server.
///
/// Wiring note for the F2 UI phase: `main.dart` currently calls the legacy
/// [write] (mirror only) and does not pass credentials to [read]. Passing
/// credentials without also routing the settings sheet through [saveRemote]
/// would make the `_load()` that follows a save re-read the server's old value
/// and silently revert the user's edit, so the wiring belongs in the same
/// change as the UI.
class DisplayPreferences {
  Future<String> frameOrientation({
    required DeviceCredentials credentials,
    required String frameDeviceId,
    String? mode,
  }) => _api.frameOrientation(
    credentials,
    frameDeviceId: frameDeviceId,
    mode: mode,
  );

  DisplayPreferences({BloomApiClient? api}) : _injectedApi = api;

  /// Lazily built so a local-only read (the background isolate's path) does not
  /// allocate an HTTP client it will never use.
  late final BloomApiClient _api = _injectedApi ?? BloomApiClient();

  /// SharedPreferences keys read by native code. This is a cross-language
  /// contract: Android reads them as `flutter.bloom.*`
  /// (`BloomWidgetBridgePlugin.kt`, `BloomWidgetRefresh.kt`) and the iOS widget
  /// reads them from the app group (`BloomWidgets.swift`). Renaming one breaks
  /// the home-screen widget without any Dart error.
  static const modeKey = 'bloom.display_mode';
  static const intervalKey = 'bloom.carousel_interval_minutes';
  static const startKey = 'bloom.carousel_active_start';
  // 用户自己的轮播作息，切到「推荐」之前存一份。
  //
  // 为什么必须【持久化】而不是放在页面内存里：服务器的 mode 与作息正交，
  // 切到推荐会把固定值（06:00/22:00/12h）写进同一个存储位，覆盖掉用户的。
  // 而用户切走之后常常会返回首页再回来 —— 页面 State 被销毁重建，内存里的
  // 那一份就没了，切回轮播时还原不回去。这几个 key 是 Dart 私有的，
  // 小组件不读它们，所以新增不会影响原生侧。
  //
  // ⚠️ **必须按 target 分开存。** 手机和相框是两条独立的服务器记录、两份独立的
  //    作息，而这一份是"用户自己的那一份"。用同一组全局 key 会互相覆盖：
  //    先给相框切一次推荐（存下相框的作息），再给手机切推荐（把相框那份盖掉），
  //    然后手机的详情页切回轮播，还回去的就是**相框的作息**。
  static String carouselStashIntervalKey(String target) =>
      'bloom.carousel_stash_interval_$target';
  static String carouselStashStartKey(String target) =>
      'bloom.carousel_stash_start_$target';
  static String carouselStashEndKey(String target) =>
      'bloom.carousel_stash_end_$target';
  static const endKey = 'bloom.carousel_active_end';

  /// Marks that the local mirror has been taken over from the server once.
  ///
  /// Dart-only bookkeeping (the widget bridge has no flag API), so it is not
  /// part of the native key contract above.
  static const migratedKey = 'bloom.carousel_settings_migrated_v1';

  final BloomApiClient? _injectedApi;

  /// Reads the current settings.
  ///
  /// When [credentials] are supplied the settings stored on the server are
  /// authoritative and a successful read also refreshes the local mirror. Any
  /// failure — timeout, offline, server error, malformed payload, or even a
  /// failing local read — falls back to the local mirror and is swallowed:
  /// this method must not throw, otherwise a settings hiccup would turn the
  /// whole home page into "无法连接服务器".
  ///
  /// Local settings the server does not know about are simply kept as they
  /// are; nothing is pushed back to the server from here, so a first launch
  /// can never overwrite stored server values with stale local ones.
  ///
  /// [target] selects which stored settings to read. The default is `eink`
  /// (the frame); the mobile widget keeps its own `mobile` record.
  ///
  /// **Use [readServer] instead when reading the frame's `eink` record.** This
  /// method refreshes the local mirror with whatever it read, and the mirror is
  /// the *phone widget's* record: reading the frame here would put the frame's
  /// schedule into the phone widget. The device detail page therefore uses
  /// [readServer], and `main.dart` reads the mirror only ([readLocal]).
  Future<BloomDisplaySettings> read({
    DeviceCredentials? credentials,
    BloomApiClient? api,
    String target = BloomApiClient.settingsTargetEink,
  }) async {
    BloomDisplaySettings local;
    try {
      local = await _readLocal();
    } catch (_) {
      // A failing local store must not stop the app from starting.
      local = const BloomDisplaySettings();
    }
    if (credentials == null) return local;
    final DeviceCarouselSettingsEnvelope envelope;
    try {
      envelope = await (api ?? _api).getDeviceSettings(
        credentials,
        target: target,
      );
    } catch (_) {
      // Timeout, offline, server error or a malformed payload: keep the
      // mirror and keep the app usable.
      return local;
    }
    final remote = envelope.settings;
    final merged = BloomDisplaySettings(
      // The display mode is the phone's own value: `bloom.display_mode` is what
      // the native widgets read, and the server's `mode` column is not merged
      // into the mirror by this method (see [readServer] for a server read that
      // reports the server's mode without touching the mirror).
      mode: local.mode,
      intervalMinutes: remote.intervalMinutes,
      sources: BloomDisplaySettings.sourcesFromWire(remote.sources),
      activeStart: remote.activeStart,
      activeEnd: remote.activeEnd,
      timezone: remote.timezone,
      dailySlotCount: remote.dailySlotCount,
      allowedIntervalMinutes:
          envelope.allowedIntervalMinutes.isEmpty
              ? null
              : envelope.allowedIntervalMinutes,
    );
    try {
      await cacheLocal(merged);
      await _markMigrated();
    } catch (_) {
      // The caller still gets the server values for this run; the mirror will
      // catch up on the next successful read.
    }
    return merged;
  }

  /// Reads the server's record for [target] and returns it.
  ///
  /// Unlike [read] this is a **pure read of the server**: it never writes the
  /// local mirror, and it never throws. `null` means "the server could not be
  /// asked, or answered with something unusable" — the caller then keeps
  /// whatever fallback it already has.
  ///
  /// The mirror is the *phone widget's* own record (`bloom.display_mode` and
  /// the three `bloom.carousel_*` keys, read directly by the Android/iOS
  /// widgets). Reading the frame's `eink` record must therefore never write it,
  /// otherwise the frame's schedule silently replaces the phone widget's.
  ///
  /// `mode` has its own fallback because it is legitimately absent from some
  /// payloads: the server's value wins, and only for the `mobile` target — the
  /// one record the mirror actually owns — does a missing server value fall
  /// back to the phone-local `bloom.display_mode`.
  Future<BloomDisplaySettings?> readServer({
    required DeviceCredentials credentials,
    required String target,
    BloomApiClient? api,
  }) async {
    final DeviceCarouselSettingsEnvelope envelope;
    try {
      envelope = await (api ?? _api).getDeviceSettings(
        credentials,
        target: target,
      );
    } catch (_) {
      // Timeout, offline, 403/422/5xx or a malformed payload: the caller keeps
      // its fallback and the page stays usable.
      return null;
    }
    final remote = envelope.settings;
    var mode = bloomModeFromWire(remote.mode);
    if (mode == null && target == BloomApiClient.settingsTargetMobile) {
      try {
        mode = (await _readLocal()).mode;
      } catch (_) {
        // A failing local store only costs us the fallback.
      }
    }
    return BloomDisplaySettings(
      // Last resort: the app-wide default, never a guess about the device.
      mode: mode ?? const BloomDisplaySettings().mode,
      // ⚠️ 这一行原来漏了，于是详情页的「照片来源」永远读回默认的 [personal]：
      //    服务器上真存了什么，界面根本看不到 —— 用户勾了别的来源再进来，
      //    卡片显示的仍是 personal，看起来就像"设了没反应"。
      //    与 [read] 走同一个转换（认不出来的名字跳过，不崩、不清空）。
      sources: BloomDisplaySettings.sourcesFromWire(remote.sources),
      intervalMinutes: remote.intervalMinutes,
      activeStart: remote.activeStart,
      activeEnd: remote.activeEnd,
      timezone: remote.timezone,
      dailySlotCount: remote.dailySlotCount,
      allowedIntervalMinutes:
          envelope.allowedIntervalMinutes.isEmpty
              ? null
              : envelope.allowedIntervalMinutes,
    );
  }

  /// Pushes [settings] to the server for [target].
  ///
  /// [callerDeviceId] must be the device id owning [credentials]; without a
  /// user login the server authorises the write by checking that caller and
  /// target device share an account. Rejections surface:
  /// - 422 — interval not in the server tier list, an inverted window, or a
  ///   `mode` outside `carousel|recommend`;
  /// - 403 — the two devices are not on the same account.
  ///
  /// Both throw a [BloomApiException] carrying the server `detail`. This method
  /// does not touch the local mirror; call [cacheLocal] afterwards when the
  /// write succeeded.
  ///
  /// [mode] is converted to the server's spelling by [bloomModeToWire]. When it
  /// is `null` the request omits `mode` altogether and the server keeps the
  /// value it already stores, so callers that must not change a device's mode
  /// (the frame, whose firmware cannot read the field yet) simply leave it out.
  Future<DeviceSettingsUpdateResult> saveRemote(
    BloomDisplaySettings settings, {
    required DeviceCredentials credentials,
    required String callerDeviceId,
    String target = BloomApiClient.settingsTargetEink,
    String? timezone,
    BloomApiClient? api,
    BloomDisplayMode? mode,
    List<BloomPhotoSource>? sources,
  }) => (api ?? _api).setDeviceSettings(
    credentials,
    target: target,
    timezone: timezone ?? settings.timezone,
    activeStart: settings.activeStart,
    activeEnd: settings.activeEnd,
    intervalMinutes: settings.intervalMinutes,
    callerDeviceId: callerDeviceId,
    mode: mode == null ? null : bloomModeToWire(mode),
    // null = 用户没碰过来源 -> 请求里不带这个键 -> 服务器保持已存的值。
    // 这与 mode 一字不差的同一规矩。
    sources: sources == null ? null : bloomSourcesToWire(sources),
  );

  /// 记下用户自己的轮播作息（切到推荐之前调用）。
  ///
  /// 只写本地，不碰服务器 —— 它记的正是"服务器马上要被覆盖掉的那份"。
  /// [target] 必须传这台设备的记录名（`mobile` / `eink`）：两台设备各有各的
  /// 作息，共用一组 key 会互相覆盖（见 key 定义处的说明）。
  Future<void> rememberCarouselSchedule(
    BloomDisplaySettings settings, {
    required String target,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        carouselStashIntervalKey(target),
        settings.intervalMinutes,
      );
      await prefs.setString(
        carouselStashStartKey(target),
        settings.activeStart,
      );
      await prefs.setString(carouselStashEndKey(target), settings.activeEnd);
    } catch (_) {
      // 记不住不该让切换模式失败：大不了切回来时还原不了。
    }
  }

  /// 取回用户自己的轮播作息；从来没存过则返回 null。
  Future<BloomDisplaySettings?> recallCarouselSchedule({
    required String target,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final interval = prefs.getInt(carouselStashIntervalKey(target));
      final start = prefs.getString(carouselStashStartKey(target));
      final end = prefs.getString(carouselStashEndKey(target));
      if (interval == null || start == null || end == null) return null;
      return BloomDisplaySettings(
        mode: BloomDisplayMode.carousel,
        intervalMinutes: interval,
        activeStart: start,
        activeEnd: end,
      );
    } catch (_) {
      return null;
    }
  }

  /// Reads the local mirror only (no network, no write). Used by [read] as
  /// fallback, by [readServer] for the phone's `mode` and by `main.dart`, which
  /// must not touch the server at all.
  ///
  /// Never throws: a failing local store yields the built-in defaults, exactly
  /// as [read] already treated it, so a broken preference file cannot turn the
  /// home page into an error screen.
  Future<BloomDisplaySettings> readLocal() async {
    try {
      return await _readLocal();
    } catch (_) {
      return const BloomDisplaySettings();
    }
  }

  Future<BloomDisplaySettings> _readLocal() async {
    if (Platform.isIOS) {
      final values =
          await BloomWidgetBridgePlatform.readDisplayPreferences() ?? const {};
      final rawMode = values['mode'] as String?;
      final interval = (values['intervalMinutes'] as num?)?.toInt() ?? 1440;
      return BloomDisplaySettings(
        mode:
            rawMode == 'carousel'
                ? BloomDisplayMode.carousel
                : BloomDisplayMode.recommendation,
        intervalMinutes:
            BloomDisplaySettings.isValidIntervalMinutes(interval)
                ? interval
                : 1440,
        activeStart: values['activeStart'] as String? ?? '06:00',
        activeEnd: values['activeEnd'] as String? ?? '22:00',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final rawMode = prefs.getString(modeKey);
    final interval = prefs.getInt(intervalKey) ?? 1440;
    return BloomDisplaySettings(
      mode:
          rawMode == 'carousel'
              ? BloomDisplayMode.carousel
              : BloomDisplayMode.recommendation,
      intervalMinutes:
          BloomDisplaySettings.isValidIntervalMinutes(interval)
              ? interval
              : 1440,
      activeStart: prefs.getString(startKey) ?? '06:00',
      activeEnd: prefs.getString(endKey) ?? '22:00',
    );
  }

  /// Writes the local mirror: the four preferences the native widgets read.
  ///
  /// iOS goes through the widget bridge (app group), Android through
  /// SharedPreferences — the same branches as before, with the same key names.
  ///
  /// **Only ever call this with the phone's own (`mobile`) settings.** The
  /// mirror is what the home-screen widget reads, so caching the frame's `eink`
  /// record here changes the phone widget's cadence and mode. The device detail
  /// page guards this with `settingsTarget == 'mobile'`; there is no server
  /// target other than `mobile` that owns these keys.
  Future<void> cacheLocal(BloomDisplaySettings settings) async {
    if (Platform.isIOS) {
      await BloomWidgetBridgePlatform.writeDisplayPreferences(
        mode:
            settings.mode == BloomDisplayMode.carousel
                ? 'carousel'
                : 'recommend',
        intervalMinutes: settings.intervalMinutes,
        activeStart: settings.activeStart,
        activeEnd: settings.activeEnd,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      modeKey,
      settings.mode == BloomDisplayMode.carousel ? 'carousel' : 'recommend',
    );
    await prefs.setInt(intervalKey, settings.intervalMinutes);
    await prefs.setString(startKey, settings.activeStart);
    await prefs.setString(endKey, settings.activeEnd);
  }

  /// Writes the cadence to the local mirror and **leaves the display mode
  /// exactly as it already is**.
  ///
  /// This is the write for a save where the user did not touch the mode
  /// selector: the server's `mode` is not part of that request either, so
  /// pushing it into the mirror would silently change what the home-screen
  /// widget shows without the server ever being asked. The mirror keeps its own
  /// `bloom.display_mode`; only the interval and the window move.
  ///
  /// The current value is read back and written unchanged (the iOS bridge
  /// requires a `mode` argument). When the key was absent, the app-wide default
  /// `recommend` is written — the same value the Kotlin (`mode != "carousel"`)
  /// and Swift (`?? "recommend"`) sides already fall back to
  /// for a missing key, so nothing changes for them.
  Future<void> cacheLocalKeepingMode(BloomDisplaySettings settings) async {
    final mode = (await readLocal()).mode;
    await cacheLocal(settings.copyWith(mode: mode));
  }

  /// Whether the home-screen widget is switched on at all.
  ///
  /// The master switch, and the only setting that is not about *what* the widget
  /// shows but *whether* it runs: off means the app stops asking the server for
  /// anything and stops arming the background refresh, so nothing on this phone
  /// reads the frame's data any more. Defaults to **on** — a widget that is
  /// silent until you find a switch is a widget nobody sees.
  static const widgetEnabledKey = 'bloom.widget_enabled';

  /// Android-only for now: the flag lives in the same SharedPreferences the
  /// widgets read, and the iOS bridge's `writeDisplayPreferences` has no
  /// `widgetEnabled` argument yet (the iOS build is blocked on Xcode anyway, so
  /// the Swift side is a deliberate follow-up rather than a guess).
  Future<bool> readWidgetEnabled() async {
    if (Platform.isIOS) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(widgetEnabledKey) ?? true;
  }

  Future<void> writeWidgetEnabled(bool enabled) async {
    if (Platform.isIOS) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(widgetEnabledKey, enabled);
  }

  /// Disarms everything scheduled on this phone's behalf.
  ///
  /// Called when the master switch goes off. Two mechanisms have to stop, not
  /// one: the Android periodic worker (`WorkManager`) and the carousel's own
  /// exact-alarm chain, which is armed through the widget bridge and would
  /// otherwise keep waking the device for a widget the user has switched off.
  Future<void> clearRemoteSchedule() =>
      BloomWidgetBridgePlatform.clearCarouselSchedule();

  /// Legacy entry point kept for the current settings sheet and mode switch:
  /// it writes the local mirror only.
  ///
  /// It intentionally does not call [saveRemote] — see the wiring note on this
  /// class. Use [saveRemote] + [cacheLocal] for anything that must reach the
  /// frame.
  Future<void> write(BloomDisplaySettings settings) => cacheLocal(settings);

  /// True once a server read has replaced the local mirror (the one-time F2
  /// migration of first launch).
  Future<bool> hasMigrated() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(migratedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markMigrated() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(migratedKey, true);
    } catch (_) {
      // The marker is informational; a failed write must not break loading.
    }
  }
}
