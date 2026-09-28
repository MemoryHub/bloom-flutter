import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../background_sync.dart';
import '../core/api/bloom_api_client.dart';
import '../core/models/device_models.dart';
import '../core/storage/display_preferences.dart';
import 'bloom_glass_home.dart';
import 'bloom_keep_alive_card.dart';

/// One row of the F3 device list.
///
/// The list is **hardcoded** for now: `BloomApiClient.listMyDevices()` needs a
/// user session (F1) and throws [UnsupportedError] without one, so nothing
/// here calls it.
class BloomDevice {
  const BloomDevice({
    required this.deviceId,
    required this.name,
    required this.type,
    this.isLocal = false,
    this.isOnline,
  });

  final String deviceId;
  final String name;

  /// Either `eink` (the frame) or `mobile` (this phone's home-screen widget).
  final String type;

  /// True for the device whose token this app actually holds. Only that device
  /// gives the app access to photos.
  final bool isLocal;

  /// `null` when the app cannot learn the state: there is no `last_seen_at`
  /// for the frame without a user session. Rendered as `—`, never guessed.
  final bool? isOnline;

  bool get isFrame => type == BloomApiClient.settingsTargetEink;

  /// The small line that sits **above** the name (the tile) and under it (the
  /// app bar): `type · state`, or just the state when the device's name already
  /// *is* its type.
  ///
  /// The whole product calls the frame `e-ink` and the phone's widget 手机小组件,
  /// so the name and the type now coincide and the pair would read "e-ink · —"
  /// over "e-ink". One place computes the line, and both surfaces use it.
  String get metaLabel =>
      typeLabel == name ? presenceLabel : '$typeLabel · $presenceLabel';

  /// Status text for the row. An unknown state is `—`, not a fake `离线`.
  String get presenceLabel =>
      isOnline == null ? '离线' : (isOnline! ? '在线' : '离线');

  String get typeLabel => isFrame ? 'E-Ink' : '手机小组件';

  /// Server settings record this device reads and writes: the frame owns the
  /// `eink` record, the phone's widget owns the `mobile` one.
  String get settingsTarget =>
      isFrame
          ? BloomApiClient.settingsTargetEink
          : BloomApiClient.settingsTargetMobile;
}

/// The frame this build ships with. Hardcoded until F1/F4 can list the
/// signed-in user's devices.
const bloomBundledFrame = BloomDevice(
  deviceId: 'bloom-eink-68ee8f606594',
  name: 'E-Ink',
  type: BloomApiClient.settingsTargetEink,
);

/// The devices the UI shows: this phone first (the only device whose photos
/// the app can load), then the frame.
///
/// **Hard-coded, and it is the biggest known gap in the product.** The server
/// can list a signed-in user's devices, but that call needs a user session (F1)
/// which the app does not have yet — so this list is a constant, and the
/// presence of the frame is `null` (rendered `—`, never guessed).
List<BloomDevice> bloomDevices({
  required DeviceCredentials? credentials,
  bool? localOnline,
}) => [
  if (credentials != null)
    BloomDevice(
      deviceId: credentials.deviceId,
      name: '手机小组件',
      type: BloomApiClient.settingsTargetMobile,
      isLocal: true,
      isOnline: localOnline,
    ),
  bloomBundledFrame,
];

/// The F3 "设备" tab.
///
/// **Cards, and a yin/yang pair of depths.** The user's note on the flat version
/// was that it had become "too simple" and wanted containers with a sense of
/// positive and negative space, so the page now states each depth explicitly:
///
/// * **yang** — every device is a raised sheet ([BloomPanel]): lighter than the
///   wall, lit along its top edge, with a shadow under it.
/// * **yin** — inside it, the device's glyph sits in a *hollow* (a recessed
///   tile), and below the cards the 添加设备 action is a hollow row of its own.
///
/// The two depths carry different meanings, which is what keeps it from being
/// decoration: raised is *a device that exists*, hollow is *a place a device
/// could go*.
class BloomDeviceListPage extends StatelessWidget {
  const BloomDeviceListPage({
    super.key,
    required this.devices,
    required this.onOpenDevice,
    required this.onAddDevice,
    this.widgetEnabled = true,
    this.onWidgetEnabledChanged,
  });

  final List<BloomDevice> devices;
  final ValueChanged<BloomDevice> onOpenDevice;
  final VoidCallback onAddDevice;

  /// False while the master switch is off: the phone's tile must say 离线 even
  /// though the server still remembers it as reachable.
  final bool widgetEnabled;
  final ValueChanged<bool>? onWidgetEnabledChanged;


  @override
  Widget build(BuildContext context) => SafeArea(
    minimum: const EdgeInsets.fromLTRB(
      BloomSurface.pageInset,
      BloomSurface.pageInset,
      BloomSurface.pageInset,
      0,
    ),
    child: ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 112),
      children: [
        BloomPageTitle(
          title: '设备',
          subtitle: '管理相框和手机小组件',
          // Both actions, bare, in the corner the user asked for. 扫码 is the
          // camera path and ＋ is the plain one — today they open the same
          // "coming soon" notice, so this is a **placeholder pairing**: when the
          // real flow lands, ＋ should start a manual add and 扫码 should only
          // read a QR.
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BloomIconButton(
                icon: Icons.qr_code_scanner_rounded,
                loading: false,
                onTap: onAddDevice,
              ),
              const SizedBox(width: 2),
              BloomIconButton(
                key: const ValueKey('bloom-add-device'),
                icon: Icons.add_rounded,
                loading: false,
                onTap: onAddDevice,
              ),
            ],
          ),
        ),
        const SizedBox(height: BloomPageTitle.contentGap),
        // An empty list is a designed state, not an absence: one glyph, one
        // sentence, one button, centred in the space the tiles would have used.
        if (devices.isEmpty) ...[
          const SizedBox(height: 96),
          const Icon(
            Icons.photo_size_select_actual_outlined,
            size: 34,
            color: BloomInk.textFaint,
          ),
          const SizedBox(height: 14),
          Text(
            '还没有添加设备',
            textAlign: TextAlign.center,
            style: BloomType.body.copyWith(color: BloomInk.textMuted),
          ),
          const SizedBox(height: 22),
          Center(
            child: SizedBox(
              width: 168,
              child: BloomPrimaryButton(
                key: const ValueKey('bloom-empty-add-device'),
                label: '添加设备',
                onPressed: onAddDevice,
              ),
            ),
          ),
        ] else
          for (var index = 0; index < devices.length; index++) ...[
            // Tiles are 112 tall now, so the seam between two of them is a real
            // gap in a list rather than a 9px shim.
            if (index > 0) const SizedBox(height: 12),
            _DeviceCard(
              device: devices[index],
              // The switch's verdict for this phone outranks the server: with
              // the widget off, its tile is 离线 wherever the server thinks it
              // is.
              onlineOverride:
                  devices[index].isLocal && !widgetEnabled ? false : null,
              onTap: () => onOpenDevice(devices[index]),
            ),
          ],
      ],
    ),
  );
}

/// One device, as a **black card** — the reference's own material.
///
/// Layout from their reference: a small glyph in a rounded slot with a line of
/// tiny meta beside it, the name in large type below, a chevron in the
/// bottom-right corner. Material also from the reference, at the user's request:
/// **flat pure black**, white type, a lit top edge where the light lands, and a
/// shadow underneath.
///
/// It was white paper for one build. Black is the better answer here, for the
/// reason the user gave: the wall is no longer flat black either, so a black card
/// has a grey ground to be black *against* — and that contrast is the effect.
/// The brightest surface in the product is therefore still unique: the home
/// page's letter card.
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.onTap,
    this.onlineOverride,
  });

  final BloomDevice device;
  final VoidCallback onTap;

  /// The master switch's verdict for **this phone**, which the server knows
  /// nothing about: with the widget off there is nothing to be online *about*.
  /// Null means "ask the device record".
  final bool? onlineOverride;

  @override
  Widget build(BuildContext context) {
    final online = onlineOverride ?? device.isOnline;
    return BloomPanel(
    // The card, raised: pure black with the tooth and the two 1px edges.
    lifted: true,
    padding: EdgeInsets.zero,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: const Color(0x14EDF2EF),
        highlightColor: const Color(0x0AEDF2EF),
        child: Stack(
          children: [
            // **A live card carries its own light.**
            //
            // The reference the user sent is a smart-home tile that glows from a
            // corner while its lamp is on and goes flat when it is off; the ask
            // was to give this app the same signal — from the *bottom-right*, so
            // it reads as light spilling in rather than a lamp burning — in the
            // theme's green. Online gets the glow, offline gets the plain card,
            // and the only chroma in the list is the one that means something.
            if (online == true)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(.98, 1.08),
                        // Radius is a fraction of the *short* side (the card is
                        // ~104 tall, ~350 wide), so 1.8 puts the falloff about
                        // half way across the item: the user wanted the spill to
                        // reach roughly half the card and to be brighter.
                        radius: 1.8,
                        stops: const [0, .45, 1],
                        colors: [
                          BloomInk.accent.withValues(alpha: .52),
                          BloomInk.accent.withValues(alpha: .20),
                          BloomInk.accent.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            SizedBox(
              // 104 rather than 112: the user's eye read the gap between the glyph
              // band and the name as "一段很大的距离", and the name itself is now
              // bigger, so the card gets shorter *and* louder instead of taller.
              height: 104,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Band one: the glyph slot and the tiny meta line, exactly where
                    // the reference puts its "There are N tasks to do".
                    Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: BloomInk.recess,
                            borderRadius: BorderRadius.circular(
                              BloomSurface.innerRadius,
                            ),
                          ),
                          child: Icon(
                            device.isFrame
                                ? Icons.devices_rounded
                                : Icons.phone_iphone_rounded,
                            size: 16,
                            color: BloomInk.textMuted,
                          ),
                        ),
                        const SizedBox(width: 10),
                        _PresenceDot(isOnline: online),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            // The phone is only "online" while its master
                            // switch is on; the frame's state stays the
                            // server's answer.
                            onlineOverride == null
                                ? device.metaLabel
                                : (device.typeLabel == device.name
                                    ? (online == true ? '在线' : '离线')
                                    : '${device.typeLabel} · '
                                        '${online == true ? '在线' : '离线'}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BloomType.meta,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    // Band two: the name, with the chevron on its own baseline.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BloomType.tileTitle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4),
                          child: Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: BloomInk.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  }
}

/// The app's only use of the accent outside a selection: a 6px dot.
///
/// Live state is the one thing on this page that changes without the user doing
/// anything, so it is the one thing allowed to carry the chroma. An unknown
/// state is a hollow ring, not a grey dot — "we do not know" is not "offline".
class _PresenceDot extends StatelessWidget {
  const _PresenceDot({required this.isOnline});

  final bool? isOnline;

  @override
  Widget build(BuildContext context) {
    final online = isOnline;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Three states, three readings: online is the theme's green, offline is
        // the one red in the app (a closed eye — the user asked for exactly
        // this: "离线的状态，前头那个项目光标要红色的"), unknown is hollow.
        // The dot follows the **word**, not the raw field: an unknown state is
        // rendered as 离线, so it is drawn as 离线. The frame is always unknown
        // (the server does not report it), which is why its dot stayed hollow.
        color: online == true ? BloomInk.accent : BloomInk.offline,
      ),
    );
  }
}

/// The F3 core screen: refresh cadence, display mode, device info and the
/// local widget section for one device.
///
/// Save order is the data layer's contract and must not be reordered:
/// `saveRemote` (server) → `cacheLocal` (the mirror the native widgets read) →
/// `configureBackgroundSync`. A failed server write therefore never leaves the
/// mirror — or the home-screen widget — ahead of the server.
///
/// Two rules make the two `target`s behave differently, and they are the whole
/// point of this screen:
/// - the frame (`eink`) is **read-only** for the display mode: its firmware
///   cannot read the server's `mode` yet, and a save omits `mode` entirely (the
///   server keeps the stored value) and never writes the local mirror;
/// - this phone (`mobile`) owns the local mirror, so only its saves call
///   `cacheLocal`, and only its request carries `mode`.
class BloomDeviceDetailPage extends StatefulWidget {
  const BloomDeviceDetailPage({
    super.key,
    required this.device,
    required this.preferences,
    required this.settings,
    this.credentials,
    this.callerDeviceId,
    this.pairing,
    this.onModeChanged,
    this.onSaved,
    this.onMirrored,
    this.photoPath,
    this.onWidgetEnabledChanged,
    this.onRefreshPairingCode,
    this.onCopyPairingCode,
  });

  final BloomDevice device;
  final DisplayPreferences preferences;

  /// The values the page renders until its own server read answers, and the
  /// fallback when that read fails (offline, 403, malformed payload).
  ///
  /// The read itself happens in `initState` and is scoped to this device's own
  /// `target`; it never writes the local mirror.
  final BloomDisplaySettings settings;

  /// The credentials this app holds. The frame's `eink` record is read and
  /// written through them; the app has no frame token and must not pretend to.
  final DeviceCredentials? credentials;

  /// The app's own device id, sent as `caller_device_id`.
  final String? callerDeviceId;
  final PairingInfo? pairing;

  /// Fired after a save that changed the display mode, so the home page can
  /// refresh the photo it shows.
  final ValueChanged<BloomDisplaySettings>? onModeChanged;

  /// Fired after a settings save reached the server and the mirror.
  final ValueChanged<BloomDisplaySettings>? onSaved;

  /// The step that runs *after* the local mirror was written, in the order this
  /// screen guarantees: `saveRemote` → `cacheLocal` → this.
  ///
  /// Defaults to [configureBackgroundSync] behind the Android guard. It is
  /// injectable because `flutter test` runs on macOS, where `Platform.isAndroid`
  /// is false and the real WorkManager call is a silent no-op: without a seam
  /// the ordering contract (mirror first, scheduler second) could not be
  /// observed at all.
  final Future<void> Function(BloomDisplaySettings settings)? onMirrored;

  /// Fired when the master switch flips, so the home page can stop (or resume)
  /// the photo it keeps up to date.
  final ValueChanged<bool>? onWidgetEnabledChanged;
  /// The photo the home page is currently showing, painted under this page for
  /// the same reason it is painted under the tabs.
  final String? photoPath;
  final VoidCallback? onRefreshPairingCode;
  final VoidCallback? onCopyPairingCode;

  /// Pushes the detail page. Kept in one place so the production route and the
  /// widget tests exercise the same navigation.
  static Future<void> open(
    BuildContext context, {
    required BloomDevice device,
    required DisplayPreferences preferences,
    required BloomDisplaySettings settings,
    DeviceCredentials? credentials,
    String? callerDeviceId,
    PairingInfo? pairing,
    ValueChanged<BloomDisplaySettings>? onModeChanged,
    ValueChanged<BloomDisplaySettings>? onSaved,
    Future<void> Function(BloomDisplaySettings settings)? onMirrored,
    String? photoPath,
    ValueChanged<bool>? onWidgetEnabledChanged,
    VoidCallback? onRefreshPairingCode,
    VoidCallback? onCopyPairingCode,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder:
          (_) => BloomDeviceDetailPage(
            device: device,
            preferences: preferences,
            settings: settings,
            credentials: credentials,
            callerDeviceId: callerDeviceId,
            pairing: pairing,
            onModeChanged: onModeChanged,
            onSaved: onSaved,
            onMirrored: onMirrored,
            photoPath: photoPath,
          onWidgetEnabledChanged: onWidgetEnabledChanged,
            onRefreshPairingCode: onRefreshPairingCode,
            onCopyPairingCode: onCopyPairingCode,
          ),
    ),
  );

  @override
  State<BloomDeviceDetailPage> createState() => _BloomDeviceDetailPageState();
}

class _BloomDeviceDetailPageState extends State<BloomDeviceDetailPage> {
  /// What the page is editing (may contain unsaved cadence and mode edits).
  late BloomDisplaySettings _draft = widget.settings;

  /// The display mode the server reported for this device, once a read
  /// succeeded. `null` means "not known": the read is still in flight or it
  /// failed, and the frame's read-only line falls back to the opened value.
  BloomDisplayMode? _serverMode;

  /// What this phone's home-screen widget **actually** uses right now
  /// (`bloom.display_mode`). Only read for the `mobile` target — the frame has
  /// no mirror of its own — and never written on open.
  ///
  /// It can legitimately differ from [_serverMode]: the server's `mode` column
  /// was seeded with its default for the devices that already existed, and the
  /// phone's local value was never pushed up. The panel no longer narrates that
  /// difference (the user removed the long copy), but the value still decides
  /// what a save hands to the Android scheduler while the user has not picked a
  /// mode on this page: see [_save].
  BloomDisplayMode? _mirrorMode;

  /// True once the user actually picked 轮播/推荐 on this page.
  ///
  /// Both the request and the mirror write follow it: a mode the user never
  /// mentioned is a field this save must not touch on either side — the request
  /// omits `mode` (the server keeps its stored value) and the mirror keeps its
  /// own `bloom.display_mode`.
  bool _modeTouched = false;

  bool _saving = false;

  /// Set by any unsaved edit, and by a completed save: an in-flight server read
  /// must never overwrite a decision the user already made on this page.
  bool _edited = false;
  bool _savedOnce = false;

  /// The floating result message, and the timer that takes it away.
  ///
  /// Held in the state (rather than an `OverlayEntry` + a bare `Timer`) so it is
  /// cancelled by [dispose]: a message that outlives its page is a leak, and a
  /// dangling timer is a test failure.
  String? _toast;
  bool _toastIsError = false;
  Timer? _toastTimer;

  /// The master switch: whether the home-screen widget runs at all.
  ///
  /// It is not a setting *of* the widget's content — it is the thing that decides
  /// whether any of the content below it exists. Off means this page's settings
  /// do not apply, the app stops asking the server for anything, and the
  /// background refresh is disarmed; the user's words were "完全凌驾于下边这些
  /// 所有东西之上".
  bool _widgetEnabled = true;

  /// The server record this device reads and writes: the frame owns `eink`,
  /// this phone owns `mobile`.
  String get _target => widget.device.settingsTarget;

  /// True only for this phone's own record.
  ///
  /// The local mirror (`bloom.display_mode` + the three `bloom.carousel_*`
  /// keys) is read directly by the Android/iOS widgets and belongs to this
  /// phone, so the `eink` record must neither be written to it nor have its
  /// display mode changed from here.
  bool get _ownsLocalMirror => _target == BloomApiClient.settingsTargetMobile;

  /// The mode the server is known to hold, for telling "selected but not saved
  /// yet" apart from "already stored".
  BloomDisplayMode get _modeOnServer => _serverMode ?? widget.settings.mode;

  /// Mode shown in the frame's read-only row.
  BloomDisplayMode get _displayMode => _serverMode ?? _draft.mode;

  /// Menu entries: the six tiers plus whatever the settings currently hold, so
  /// a server value outside the tiers (45, for example) still opens. Without
  /// this, `DropdownButtonFormField` would assert on a `value` that has no
  /// matching item — and the old `main.dart` sheet would have crashed outright.
  List<int> get _intervalOptions {
    final values = <int>{...BloomDisplaySettings.allowedIntervals};
    if (BloomDisplaySettings.isValidIntervalMinutes(_draft.intervalMinutes)) {
      values.add(_draft.intervalMinutes);
    }
    return values.toList()..sort();
  }

  @override
  void initState() {
    super.initState();
    // Not awaited: the page must render immediately and stay usable if the
    // server never answers.
    unawaited(_readWidgetEnabled());
    unawaited(_loadServerSettings());
  }

  Future<void> _readWidgetEnabled() async {
    final enabled = await widget.preferences.readWidgetEnabled();
    if (!mounted || enabled == _widgetEnabled) return;
    setState(() => _widgetEnabled = enabled);
  }

  /// Flips the master switch.
  ///
  /// Persist first, then act: **off** disarms everything this app does on the
  /// widget's behalf (the Android scheduler and the carousel alarm chain, which
  /// is why the bridge's `clearCarouselSchedule` is called rather than just
  /// skipping the next schedule), and **on** re-arms it from the values the page
  /// is showing. The parent is told either way, so the home page can stop
  /// showing a photo that is no longer being kept up to date.
  Future<void> _setWidgetEnabled(bool enabled) async {
    if (_saving) return;
    setState(() {
      _widgetEnabled = enabled;
      _toast = null;
    });
    await widget.preferences.writeWidgetEnabled(enabled);
    unawaited(HapticFeedback.selectionClick());
    try {
      if (enabled) {
        await _afterMirror(_draft);
      } else {
        // Two mechanisms, both disarmed: the carousel's alarm chain...
        await widget.preferences.clearRemoteSchedule();
        // ...and the periodic worker.
        await disableBackgroundSync();
      }
    } catch (_) {
      // The switch is on the phone, not on the server: a failing native call
      // must not flip the switch back and lie about it.
    }
    if (!mounted) return;
    widget.onWidgetEnabledChanged?.call(enabled);
    _showToast(enabled ? '手机小组件已开启，下面的设置开始生效。' : '手机小组件已关闭，不再读取线上数据。');
  }

  /// Reads this device's own server record once, on open.
  ///
  /// Neither read writes the local mirror: for this phone the mirror's mode is
  /// only *read*, so the save path can leave a mode the user never mentioned
  /// alone. Any failure — offline, 403, 5xx, malformed payload — is
  /// deliberately silent: the page keeps rendering the values it was opened
  /// with instead of an error or a spinner.
  Future<void> _loadServerSettings() async {
    final credentials = widget.credentials;
    if (credentials == null) return;
    if (_ownsLocalMirror) {
      // The phone's own record: what the widget is really doing right now.
      final local = await widget.preferences.readLocal();
      if (mounted) setState(() => _mirrorMode = local.mode);
    }
    final remote = await widget.preferences.readServer(
      credentials: credentials,
      target: _target,
    );
    if (!mounted || remote == null) return;
    setState(() {
      _serverMode = remote.mode;
      if (_edited || _savedOnce) return;
      _draft = remote;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final credentials = widget.credentials;
    final callerDeviceId = widget.callerDeviceId;
    if (credentials == null || callerDeviceId == null) {
      _showToast('设备身份还没有准备好，暂时无法保存。', isError: true);
      return;
    }
    final draft = _draft;
    if (draft.intervalMinutes < 1440 && draft.expectedDailyItems < 1) {
      _showToast('结束时间必须晚于开始时间。', isError: true);
      return;
    }
    final previousMode = _modeOnServer;
    _toastTimer?.cancel();
    setState(() {
      _saving = true;
      _toast = null;
    });
    try {
      // 1. Server first. A rejection throws and nothing local changes.
      //
      // The mode travels in the same request as the cadence — but only when the
      // user actually picked one. A mode nobody mentioned is left alone: the
      // request omits `mode` and the server keeps the value it already stores.
      final result = await widget.preferences.saveRemote(
        draft,
        credentials: credentials,
        callerDeviceId: callerDeviceId,
        target: _target,
        mode: _ownsLocalMirror && _modeTouched ? draft.mode : null,
      );
      final saved = _fromServer(result.settings, draft);
      // 2. Only after the server accepted, and only for the record the mirror
      //    actually belongs to: caching the frame's schedule here is what used
      //    to change the home-screen widget's cadence.
      if (_ownsLocalMirror) {
        // The mirror's mode follows the same rule as the request: written only
        // when the user chose it, otherwise left at the value the widget is
        // already using. Silently pulling the phone's mode onto the server's
        // value is exactly what this guards against.
        if (_modeTouched) {
          try {
            await widget.preferences.cacheLocal(saved);
          } catch (_) {
            // The server already has the new schedule; a failing local mirror
            // must not be reported as a failed save.
          }
        } else {
          try {
            await widget.preferences.cacheLocalKeepingMode(saved);
          } catch (_) {}
          _mirrorMode ??= (await widget.preferences.readLocal()).mode;
        }
        // 3. After the mirror, because the Android scheduler is driven by the
        //    phone's own mode — and the mode it must see is whatever the mirror
        //    now holds, which is `saved.mode` only when the user picked one.
        //    A frame save changes neither, so it must not reach this call: the
        //    frame's mode is not the phone's.
        try {
          await _afterMirror(
            _modeTouched ? saved : saved.copyWith(mode: _mirrorMode),
          );
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _draft = saved;
        _serverMode = saved.mode;
        if (_modeTouched) _mirrorMode = saved.mode;
        _edited = false;
        _savedOnce = true;
        // The mode the user picked has just been committed (either by the tap
        // that picked it or by 保存). Clearing this keeps a later 保存 a
        // cadence-only request, which is the same "only send a mode somebody
        // chose" rule the save path has always had.
        _modeTouched = false;
      });
      _showToast(_successMessage(result));
      unawaited(HapticFeedback.mediumImpact());
      widget.onSaved?.call(saved);
      if (saved.mode != previousMode) widget.onModeChanged?.call(saved);
    } on BloomApiException catch (error) {
      if (mounted) _showToast(_describeApiError(error), isError: true);
    } catch (_) {
      if (mounted) _showToast('保存失败，请稍后重试。', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The step that runs after the mirror was written: the Android background
  /// configuration, or whatever the tests injected in its place.
  Future<void> _afterMirror(BloomDisplaySettings settings) {
    final hook = widget.onMirrored;
    if (hook != null) return hook(settings);
    if (!Platform.isAndroid) return Future<void>.value();
    return configureBackgroundSync(settings);
  }

  static BloomDisplaySettings _fromServer(
    DeviceCarouselSettings remote,
    BloomDisplaySettings fallback,
  ) => fallback.copyWith(
    // The server echoes the mode it stored: for `mobile` the value just sent,
    // for `eink` the untouched stored value. A payload without a mode keeps the
    // fallback (`copyWith` treats `null` as "leave it").
    mode: bloomModeFromWire(remote.mode),
    intervalMinutes: remote.intervalMinutes,
    activeStart: remote.activeStart,
    activeEnd: remote.activeEnd,
    timezone: remote.timezone,
    dailySlotCount: remote.dailySlotCount,
  );

  static String _describeApiError(BloomApiException error) {
    switch (error.statusCode) {
      case 403:
        return '没有权限：${error.message}';
      case 422:
        return error.message;
      default:
        return '服务器拒绝了这次保存（${error.statusCode}）：${error.message}';
    }
  }

  String _successMessage(DeviceSettingsUpdateResult result) {
    final label = intervalLabel(result.settings.intervalMinutes);
    final mode = bloomModeFromWire(result.settings.mode);
    final buffer = StringBuffer(
      widget.device.isFrame
          ? '设置已保存，相框会在下次联网时换成新节奏。当前$label'
          : '设置已保存，手机小组件会按新节奏刷新。当前$label'
              '${mode == null ? '' : ' · ${mode == BloomDisplayMode.carousel ? '轮播' : '推荐'}'}',
    );
    final next = result.nextCheckAt;
    if (next != null) {
      final minutes = next.toLocal().difference(DateTime.now()).inMinutes;
      if (minutes >= 0) {
        buffer.write('，预计 $minutes 分钟后轮到它。');
        return buffer.toString();
      }
    }
    buffer.write('。');
    return buffer.toString();
  }

  /// Picks a display mode **and saves it**, in one tap.
  ///
  /// It used to only move the draft and wait for 保存. The user's report was
  /// blunt: "点击推荐和轮播按钮也不走接口". A segmented control is a *switch* —
  /// one that needs a second press somewhere else to take effect is not a
  /// switch — so the tap now runs the same path as the button: server →
  /// local mirror → background sync. 保存 stays for the cadence fields, which
  /// are genuinely a form (two times and an interval that only make sense
  /// together).
  ///
  /// [_modeTouched] is still what tells the save to include `mode` in the
  /// request; a cadence-only save still omits it and leaves the phone's own
  /// value alone.
  void _selectMode(BloomDisplayMode mode) {
    if (_saving || _draft.mode == mode) return;
    setState(() {
      _edited = true;
      _modeTouched = true;
      _draft = _draft.copyWith(mode: mode);
    });
    unawaited(HapticFeedback.selectionClick());
    unawaited(_save());
  }

  /// Shows [message] in the app's own glass slip, over this page.
  ///
  /// One message component for every result on this screen — a copy, a save, a
  /// rejection. It used to be a SnackBar for copies and an inline box for saves,
  /// which is two different languages for the same sentence.
  void _showToast(String message, {bool isError = false}) {
    _toastTimer?.cancel();
    setState(() {
      _toast = message;
      _toastIsError = isError;
    });
    _toastTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    unawaited(HapticFeedback.lightImpact());
    if (!mounted) return;
    _showToast(message);
  }

  /// **A window is one decision, not two.**
  ///
  /// It used to be two fields with two system time pickers, which let a user
  /// choose 03:47 and then an end before the start — a state the server rejects
  /// outright (`active_start >= active_end` → 422) and that the page then had to
  /// explain. The original design was a handful of options; the user asked for
  /// exactly that: one 生效时间 field, five windows and 全天.
  ///
  /// **全天 is 00:00–23:59, not 00:00–00:00**: the server's rule is a strict
  /// `start < end`, so a zero-length window is not expressible. 23:59 is also a
  /// real slot in the plan (the server treats `active_end` as the closing photo
  /// of the day), which makes it the correct end for "all day" rather than a
  /// fudge.
  ///
  /// **What a window is for.** The user's explanation, and it is the whole
  /// design: the window exists to *save power and to stay quiet*. Nobody looks at
  /// a photo frame while they are asleep, so the frame does not refresh then —
  /// it wakes up when you do and goes to sleep when you do.
  ///
  /// That makes the options a *sleep schedule*, not a duration: the start is your
  /// wake-up time and the end is your bedtime, and both move together. The first
  /// build got this wrong — 07:00–21:00, 08:00–20:00, 09:00–18:00 shortened the
  /// day as it "got later", which is backwards: the later you wake, the later you
  /// go to bed, so the window has to *shift*, not shrink.
  ///
  /// The wire format is unchanged: the chosen pair is split back into
  /// `active_start` / `active_end`, two fields, exactly as the API stores them.
  static const _windows = <(String, String)>[
    ('05:00', '21:00'), // 早睡早起
    ('06:00', '22:00'), // 标准
    ('07:00', '23:00'), // 晚起晚睡
    ('08:00', '23:59'), // 更晚
    ('08:00', '18:00'), // 只在白天
    ('00:00', '23:59'), // 全天
  ];

  /// Most windows are their own label; the two special ones get a word.
  static String _windowLabel((String, String) window) {
    if (window.$1 == '00:00' && window.$2 == '23:59') return '全天';
    if (window.$1 == '08:00' && window.$2 == '18:00') return '只在白天';
    return '${window.$1} – ${window.$2}';
  }

  /// The作息 behind each窗口, so the choice can be made by lifestyle rather than
  /// by arithmetic. Shown as the row's second line in the sheet.
  static String _windowHint((String, String) window) {
    if (window.$1 == '00:00' && window.$2 == '23:59') return '全天都在换，最费电';
    if (window.$1 == '08:00' && window.$2 == '18:00') return '白天有人时才换';
    if (window.$1 == '05:00') return '早睡早起';
    if (window.$1 == '06:00') return '标准作息';
    if (window.$1 == '07:00') return '晚起晚睡';
    return '睡得很晚';
  }

  /// One choice, as a sheet: the same interaction for the interval and for both
  /// times, so the whole form behaves one way.
  Future<void> _pickOption<T>({
    required String title,
    required List<T> options,
    required T selected,
    required String Function(T value) label,
    required ValueChanged<T> onPick,
    String? note,
    String Function(T value)? hint,
  }) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      // Anchored to the lower part of the screen: a sheet that sizes itself can
      // start anywhere, and the user read that as "奇怪".
      constraints: BoxConstraints(
        // Half the screen: the sheet's *top edge* then lands on the middle
        // line, which is what "中下位置" means. 62% put its top above the
        // middle and the user saw no change at all.
        maxHeight: MediaQuery.sizeOf(context).height * .5,
      ),
      // Scroll-controlled and internally scrollable: seven 52px rows plus a
      // title is taller than a short phone's sheet allowance, and a bottom sheet
      // that overflows is a bottom sheet whose last option cannot be reached.
      isScrollControlled: true,
      backgroundColor: BloomInk.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(BloomSurface.radius),
        ),
      ),
      builder:
          (context) => SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: BloomType.sectionTitle.copyWith(
                          fontFamily: BloomType.pageTitle.fontFamily,
                        ),
                      ),
                      if (note != null) ...[
                        const SizedBox(height: 8),
                        Text(note, style: BloomType.body),
                      ],
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final option in options)
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => Navigator.of(context).pop(option),
                            splashColor: const Color(0x14EDF2EF),
                            highlightColor: const Color(0x0AEDF2EF),
                            child: SizedBox(
                              height: 52,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            label(option),
                                            style:
                                                option == selected
                                                    ? BloomType.value
                                                    : BloomType.rowTitle,
                                          ),
                                          if (hint != null) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              hint(option),
                                              style: BloomType.meta,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    if (option == selected)
                                      const Icon(
                                        Icons.check_rounded,
                                        size: 18,
                                        color: BloomInk.accent,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
    );
    if (picked == null || !mounted) return;
    onPick(picked);
  }

  /// The interval, as a sheet of tiers.
  Future<void> _pickInterval() => _pickOption<int>(
    title: '更换频率',
    options: _intervalOptions,
    selected: _draft.intervalMinutes,
    label: intervalLabel,
    onPick: (value) {
      setState(() {
        _edited = true;
        _draft = _draft.copyWith(intervalMinutes: value);
      });
    },
  );

  /// Flips a draft field without touching the server: this is the form the 保存
  /// button belongs to.
  void _editDraft(BloomDisplaySettings next) {
    setState(() {
      _edited = true;
      _draft = next;
    });
  }

  Future<void> _pickWindow() async {
    final current = (_draft.activeStart, _draft.activeEnd);
    // A server value outside the presets is shown as its own extra choice, so an
    // existing odd window can still be seen (and kept) instead of silently
    // snapping to the nearest preset.
    final options =
        _windows.contains(current)
            ? _windows
            : <(String, String)>[..._windows, current];
    await _pickOption<(String, String)>(
      title: '生效时间',
      note:
          '生效时间内才换照片：你睡着的时候它也跟着睡，省电，也不打扰。'
          '选一个贴近你作息的时段就行。',
      options: options,
      selected: current,
      label: _windowLabel,
      hint: _windowHint,
      onPick:
          (value) => _editDraft(
            _draft.copyWith(activeStart: value.$1, activeEnd: value.$2),
          ),
    );
  }

  @override
  @override
  @override
  @override
  Widget build(BuildContext context) {
    // The frame's mode is a server read-out (its firmware ignores it), so it
    // shows what the server holds; the phone's is the live edit.
    final carousel =
        (widget.device.isFrame ? _displayMode : _draft.mode) ==
        BloomDisplayMode.carousel;
    final topInset = MediaQuery.paddingOf(context).top;
    // The floating bar is 56 tall and 6 below the status bar; the body has to
    // start under it.
    final barHeight = topInset + 68.0;
    // The floating save belongs to the carousel form only: in 推荐 there is
    // nothing on this page to save, so a save button would be a button that does
    // nothing. It also disappears with the master switch.
    final showSave = _widgetEnabled && carousel;
    final toast = _toast;
    return Scaffold(
      // The bar is glass, so the content has to run *under* it: that is what the
      // lens has to refract, and it is why this is not a solid AppBar any more.
      extendBodyBehindAppBar: true,
      backgroundColor: BloomGlassHome.backgroundColor,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(barHeight),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, topInset + 6, 12, 0),
          child: SizedBox(height: 56, child: _topBar(carousel)),
        ),
      ),
      body: BloomPhotoBackdrop(
        imagePath: widget.photoPath,
        revision: 0,
        child: Stack(
          children: [
            ListView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                BloomSurface.pageInset,
                barHeight + 8,
                BloomSurface.pageInset,
                showSave ? 108 : 40,
              ),
              children: [
                if (!_widgetEnabled)
                  _OffCard(onEnable: () => _setWidgetEnabled(true))
                else ...[
                  // No section headings and no descriptions anywhere on this
                  // page: the mode is the switch in the bar, and the rest is a
                  // form. The user deleted every line of explanation here
                  // ("这些文字完全不要了"), so what is left is only what can be
                  // changed or read.
                  if (carousel) _cadenceCard() else _RecommendationCard(),
                  // 后台保活自检：**这台手机自己的事**，所以只在本机（手机小组件）
                  // 的详情页出现，相框上没有。iOS 上原生返回空列表，卡片整个不渲染。
                  if (widget.device.isLocal) const BloomKeepAliveCard(),
                ],
                const SizedBox(height: 28),
                _deviceInfo(),
              ],
            ),
            if (showSave)
              Positioned(
                left: BloomSurface.pageInset,
                right: BloomSurface.pageInset,
                bottom: 78,
                child: _GlassAction(
                  label: '保存',
                  loadingLabel: '正在保存…',
                  loading: _saving,
                  onPressed: _saving ? null : _save,
                ),
              ),
            // **Lower-middle, not the top.** The message used to sit just under
            // the bar — a spot chosen to clear the Xiaomi 14's punch-hole camera
            // — and the user read it as "弹窗还在上面" no matter what I did to the
            // option sheets. It now floats above the action, in the half of the
            // screen a thumb and an eye are already in.
            if (toast != null)
              Positioned(
                bottom: showSave ? 146 : 88,
                left: 20,
                right: 20,
                child: BloomMessage(message: toast, isError: _toastIsError),
              ),
          ],
        ),
      ),
    );
  }

  /// The **floating glass bar**: the same material as the nav bar at the other
  /// end of the app, carrying everything that is above the page's content.
  ///
  /// Left: back and the device's own name, sharing the back button's line — the
  /// user asked for "小组件" to be vertically centred with the arrow. Centre: the
  /// mode switcher, borrowed from the reference they sent (a two-segment capsule
  /// with a travelling tab). Right: the master switch, which now names its own
  /// state ("在线" / "离线") because an unlabelled toggle told nobody anything.
  Widget _topBar(bool carousel) {
    final switchable = _widgetEnabled;
    return LiquidGlassLens(
      style: BloomGlassHome.barStyle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Stack(
          // Centre, because a Stack pins its non-positioned children to
          // `topStart` by default — which is exactly why the back button, the
          // name and the switch all sat high in a 56px bar.
          alignment: Alignment.center,
          children: [
            // The mode switcher is centred on the **bar**, not on what is left
            // over between the title and the switch: on the frame there is no
            // switch, and "between two Spacers" put the pill right of centre.
            if (switchable)
              Center(
                child: _ModePill(
                  carousel: carousel,
                  onChanged:
                      _saving || widget.device.isFrame ? null : _selectMode,
                ),
              ),
            Row(
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      size: 20,
                      color: BloomInk.text,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  widget.device.isLocal ? '小组件' : widget.device.name,
                  style: BloomType.rowTitle,
                ),
                const Spacer(),
                // The master switch belongs to **this phone's widget** and nothing
                // else. On the frame it is absent: the frame's online state is the
                // device's own business (it is whether the ESP32 is awake), which the
                // app reads from the server and cannot toggle.
                if (widget.device.isLocal)
                  BloomSwitch(
                    key: const ValueKey('bloom-widget-switch'),
                    value: switchable,
                    semanticLabel: '小组件',
                    onLabel: '在线',
                    offLabel: '离线',
                    onChanged: _saving ? null : _setWidgetEnabled,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The cadence form: two fields, no heading.
  Widget _cadenceCard() => BloomPanel(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Field(
          key: const ValueKey('bloom-interval-dropdown'),
          label: '更换频率',
          value: intervalLabel(_draft.intervalMinutes),
          onTap: _saving ? null : _pickInterval,
        ),
        const SizedBox(height: 16),
        _Field(
          key: const ValueKey('bloom-window-field'),
          label: '生效时间',
          value: _windowLabel((_draft.activeStart, _draft.activeEnd)),
          onTap: _saving ? null : _pickWindow,
        ),
        const SizedBox(height: 14),
        // Inside the card, flush with the two labels above it, and as small as
        // the type ladder goes: it is a footnote, not a field ("这个只是一个辅助
        // 的说明"). Its second clause ("只在你选的时段里换") is gone.
        Text('预计每天更新 ${_draft.expectedDailyItems} 张', style: BloomType.meta),
      ],
    ),
  );

  /// Identifiers, last and quiet: a label and a value per row, with bare glyphs
  /// on the value's own line. No heading, no description, no note under it — the
  /// user deleted all three.
  Widget _deviceInfo() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // The heading the user missed ("设备的那个标题和左侧有一个指纹的那个 icon，
      // 那个要保留"): the identifiers are the only block on this page that is
      // neither a form nor a switch, so it keeps the small label + glyph that
      // says which kind of thing it is.
      Padding(
        padding: const EdgeInsets.only(left: 16, bottom: 10),
        child: Row(
          children: [
            const Icon(
              Icons.fingerprint_rounded,
              size: 15,
              color: BloomInk.textFaint,
            ),
            const SizedBox(width: 7),
            Text(
              '设备信息',
              style: BloomType.label.copyWith(color: BloomInk.textMuted),
            ),
          ],
        ),
      ),
      Padding(
        // Lined up with the **card's content**, not with the card's edge: the form's
        // labels sit 16 inside the panel, so the identifiers need the same 16 to land
        // on one vertical line with them. The user caught exactly this ("它比卡片的
        // 间距更窄").
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InfoRow(
              label: '设备号',
              value: widget.device.deviceId,
              onCopy: () => _copy(widget.device.deviceId, '设备号已复制。'),
            ),
            const BloomRowDivider(indent: 0),
            _InfoRow(
              label: '配对码',
              value: widget.pairing?.code ?? '尚未生成',
              onCopy:
                  widget.pairing == null
                      ? null
                      : () => widget.onCopyPairingCode?.call(),
              onRefresh:
                  widget.device.isLocal ? widget.onRefreshPairingCode : null,
            ),
          ],
        ),
      ),
    ],
  );
}

/// The mode switcher, in the reference's shape: **one capsule, two segments, a
/// travelling tab**.
///
/// It replaces a pair of radio rows with a paragraph each. The user's notes
/// shaped both halves of that: the descriptions are gone ("这些文字完全不要了"),
/// and the control is now the two-segment switch from the screenshot they sent —
/// no "模式" suffix either, just 轮播 and 推荐, with the mode's own glyph kept.
///
/// Glass, not a filled Material segment: it lives inside the glass bar, so its
/// track is the same frosted stock and the tab is the app's green.
class _ModePill extends StatelessWidget {
  const _ModePill({required this.carousel, required this.onChanged});

  final bool carousel;

  /// Null while saving, and null for the frame (whose firmware cannot read the
  /// server's `mode` yet, so the pill is a read-out rather than a control there).
  final ValueChanged<BloomDisplayMode>? onChanged;

  @override
  Widget build(BuildContext context) => LiquidGlassLens(
    style: BloomGlassHome.modePillStyle,
    child: SizedBox(
      // Fixed, because the travelling tab is sized as a fraction of the track:
      // a Stack cannot measure itself from a fraction, so the track states its
      // width (two 69px segments) instead.
      width: 138,
      height: 38,
      child: Stack(
        children: [
          // The travelling tab. It slides between the two halves on a change,
          // which is the whole interaction the reference is selling.
          AnimatedAlign(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            // 轮播 is the **left** segment, so that is where its tab goes; the
            // two were swapped, which is why the lit tab sat under the mode that
            // was not selected.
            alignment: carousel ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: .5,
              heightFactor: 1,
              child: Container(
                margin: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: BloomInk.accentDeep,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Row(
            children: [
              _ModeSegment(
                key: const ValueKey('bloom-mode-carousel'),
                mode: BloomDisplayMode.carousel,
                selected: carousel,
                onTap: onChanged,
              ),
              _ModeSegment(
                key: const ValueKey('bloom-mode-recommend'),
                mode: BloomDisplayMode.recommendation,
                selected: !carousel,
                onTap: onChanged,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({
    super.key,
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final BloomDisplayMode mode;
  final bool selected;
  final ValueChanged<BloomDisplayMode>? onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: GestureDetector(
      onTap: onTap == null ? null : () => onTap!(mode),
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: BloomType.label.copyWith(
            fontSize: 12,
            letterSpacing: .8,
            color: selected ? BloomInk.text : BloomInk.textMuted,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                bloomModeIcon(mode),
                size: 14,
                color: selected ? BloomInk.text : BloomInk.textMuted,
              ),
              const SizedBox(width: 5),
              Text(bloomModeShortLabel(mode)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The primary action as a piece of glass.
///
/// The user's note: "把这个也做成液态玻璃风格的，这个颜色可以保留，但是要透明度
/// 和液态玻璃要保持和咱的保持一致". So the green stays, as the *tint* of a smoked
/// lens instead of a flat fill — the same material as the bar above it, which is
/// what makes the page feel like one object.
class _GlassAction extends StatelessWidget {
  const _GlassAction({
    required this.label,
    required this.loadingLabel,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final String loadingLabel;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return Opacity(
      opacity: enabled || loading ? 1 : .45,
      child: LiquidGlassLens(
        style: BloomGlassHome.accentGlassStyle,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            splashColor: const Color(0x1FEDF2EF),
            highlightColor: const Color(0x14EDF2EF),
            child: SizedBox(
              height: 54,
              width: double.infinity,
              child: Center(
                child:
                    loading
                        ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                color: Color(0xCCEDF2EF),
                              ),
                            ),
                            const SizedBox(width: 9),
                            Text(
                              loadingLabel,
                              style: BloomType.button.copyWith(
                                color: const Color(0xCCEDF2EF),
                              ),
                            ),
                          ],
                        )
                        : Text(label, style: BloomType.button),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What 推荐 actually does, in the user's terms.
///
/// The mode's *description* in the switcher is gone, so this card is the only
/// place the promise is stated — and it was an explicit earlier request ("站在
/// 产品的角度，给观众看的角度"). The server picks one photo a day
/// (`frame_daily_recommendation` is keyed by date); the app merely checks
/// whether it changed.
class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard();

  @override
  Widget build(BuildContext context) => BloomPanel(
    lifted: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              bloomModeIcon(BloomDisplayMode.recommendation),
              size: 20,
              color: BloomInk.accent,
            ),
            const SizedBox(width: 10),
            Text('推荐', style: BloomType.sectionTitle),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          '每天一张。把你带回那年今天，你当时也在场的那个瞬间。',
          style: TextStyle(
            color: BloomInk.text,
            fontSize: 16,
            height: 1.45,
            fontFamily: BloomType.serifFamily,
            fontFamilyFallback: BloomType.serifFallback,
          ),
        ),
      ],
    ),
  );
}

/// The whole page, switched off.
///
/// Not a greyed-out copy of the settings: with the master switch off there is
/// nothing to grey out, because none of those settings reach anything. One
/// sentence explaining what is not happening, and one way back.
class _OffCard extends StatelessWidget {
  const _OffCard({required this.onEnable});

  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) => BloomPanel(
    lifted: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.do_not_disturb_on_outlined,
              size: 20,
              color: BloomInk.textMuted,
            ),
            const SizedBox(width: 10),
            Text('小组件已关闭', style: BloomType.sectionTitle),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          '桌面小组件不会再换照片，App 也不会去读线上的数据 —— 不联网、不刷新、不耗电。'
          '重新打开就恢复。',
          style: BloomType.body,
        ),
        const SizedBox(height: 18),
        // The same glass action as 保存: the page has exactly one primary
        // action in it, and it should look like the same thing in both states.
        _GlassAction(
          label: '重新开启',
          loadingLabel: '正在开启…',
          loading: false,
          onPressed: onEnable,
        ),
      ],
    ),
  );
}

/// One labelled field: a small tracked label **above** a recessed trough.
///
/// The label used to be a Material *floating* label inside the dropdown, and
/// that is exactly the collision the user saw — 「更换频率压在了下边那个下拉菜单
/// 上」: at rest Flutter draws it straddling the field's top edge, over the line
/// the menu draws for itself. A label above its control cannot collide with
/// anything, and the pair (11px tracked over a 16px value) is the hierarchy this
/// form was missing.
///
/// The trough is a **hole in the sheet**, not an outlined box: the page owns one
/// line style (dividers), and a form field is not a border.
class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: BloomType.fieldLabel),
      const SizedBox(height: 7),
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(BloomSurface.controlRadius),
          splashColor: const Color(0x14EDF2EF),
          highlightColor: const Color(0x0AEDF2EF),
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: BloomInk.recess,
              borderRadius: BorderRadius.circular(BloomSurface.controlRadius),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BloomType.value,
                  ),
                ),
                const Icon(
                  Icons.expand_more_rounded,
                  size: 20,
                  color: BloomInk.textFaint,
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// One identifier: a label, a value, and bare glyphs on the value's own line.
///
/// Small on purpose: 设备信息 is the least important thing on this page now, and
/// the user asked for it to read that way ("作为小字部分不那么起眼儿").
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.onCopy,
    this.onRefresh,
  });

  final String label;
  final String value;

  /// Copy the value. A bare glyph, no border and no square box.
  final VoidCallback? onCopy;

  /// Regenerate the value — only the pairing code has one.
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: BloomType.fieldLabel),
        const SizedBox(height: 5),
        Row(
          // **Baseline**, not centre: the user asked for the glyph to line up with
          // the text it belongs to, and a 19px icon centred on a 16px line of
          // type sits a pixel or two high.
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: SelectableText(
                value,
                maxLines: 1,
                style: BloomType.body.copyWith(color: BloomInk.text),
              ),
            ),
            if (onCopy != null) ...[
              const SizedBox(width: 10),
              _BareGlyph(
                icon: Icons.content_copy_rounded,
                semanticLabel: '复制$label',
                onTap: onCopy,
              ),
            ],
            if (onRefresh != null) ...[
              const SizedBox(width: 2),
              _BareGlyph(
                icon: Icons.refresh_rounded,
                semanticLabel: '重新生成$label',
                onTap: onRefresh,
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

/// A glyph with no box around it, sized to sit on a line of body text.
///
/// The last stock Material control on this page was a bordered square
/// `IconButton`; the user's note was "不要有边框，不要是正方形". Its 32px tap target
/// is invisible but real, so the bare look costs nothing in reachability.
class _BareGlyph extends StatelessWidget {
  const _BareGlyph({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticLabel,
    child: InkResponse(
      onTap: onTap,
      radius: 18,
      splashColor: const Color(0x1FEDF2EF),
      highlightColor: const Color(0x14EDF2EF),
      child: SizedBox(
        width: 32,
        height: 26,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Icon(icon, size: 18, color: BloomInk.textMuted),
        ),
      ),
    ),
  );
}
