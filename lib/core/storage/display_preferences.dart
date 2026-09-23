import 'dart:io';

import 'package:bloom_widget_bridge/bloom_widget_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/bloom_api_client.dart';
import '../models/device_models.dart';

enum BloomDisplayMode { recommendation, carousel }

/// The value the server stores for [mode] in `frame_device_settings.mode`.
///
/// The server only accepts `carousel` / `recommend` (a 422 otherwise), while
/// the local mirror the native widgets read spells the second value
/// `recommendation`. The two spellings are a cross-language contract on both
/// sides, so they stay separate and are converted here, in one place.
String bloomModeToWire(BloomDisplayMode mode) =>
    mode == BloomDisplayMode.carousel
        ? DeviceCarouselSettings.modeCarousel
        : DeviceCarouselSettings.modeRecommend;

/// Parses the server's `mode`; `null` for a missing or unrecognised value.
BloomDisplayMode? bloomModeFromWire(String? value) {
  if (value == DeviceCarouselSettings.modeCarousel) {
    return BloomDisplayMode.carousel;
  }
  if (value == DeviceCarouselSettings.modeRecommend) {
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

class BloomDisplaySettings {
  const BloomDisplaySettings({
    this.mode = BloomDisplayMode.recommendation,
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
  }) => (api ?? _api).setDeviceSettings(
    credentials,
    target: target,
    timezone: timezone ?? settings.timezone,
    activeStart: settings.activeStart,
    activeEnd: settings.activeEnd,
    intervalMinutes: settings.intervalMinutes,
    callerDeviceId: callerDeviceId,
    mode: mode == null ? null : bloomModeToWire(mode),
  );

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
                : 'recommendation',
        intervalMinutes: settings.intervalMinutes,
        activeStart: settings.activeStart,
        activeEnd: settings.activeEnd,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      modeKey,
      settings.mode == BloomDisplayMode.carousel
          ? 'carousel'
          : 'recommendation',
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
  /// `recommendation` is written — the same value the Kotlin (`mode !=
  /// "carousel"`) and Swift (`?? "recommendation"`) sides already fall back to
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
