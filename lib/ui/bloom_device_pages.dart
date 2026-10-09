import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../background_sync.dart';
import '../core/api/bloom_api_client.dart';
import '../core/models/auth_models.dart';
import '../core/models/device_models.dart';
import '../core/storage/display_preferences.dart';
import 'bloom_glass_home.dart';
import 'bloom_keep_alive_card.dart';
import 'bloom_sign_in_prompt.dart';
import 'bloom_discover_page.dart';

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
/// 未登录时的兜底相框（F3 之前）。
///
/// ⚠️ 这个 ID **必须跟着现役相框走**。2026-09-30 旧开发板
/// `bloom-eink-68ee8f606594` 已从服务端彻底删除，此处若仍指向它，
/// 未登录的用户会看到一台不存在的相框，点进去必然报错 —— 而这看起来
/// 像是"登录功能坏了"。
///
/// 之所以还留着硬编码：[bloomDevices] 是登录态拿不到服务端设备列表时的
/// 兜底，而这份兜底里唯一有用的信息就是"当前这台相框"。真正的解法是
/// 让设备列表全部来自服务端（F1 已经做到），并给未登录态一个空状态。
const bloomBundledFrame = BloomDevice(
  deviceId: 'bloom-eink-94a990f4e394-b',
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
///
/// F1 之后它退居为**未登录时的兜底**：登录了就改用
/// [bloomDevicesFromRemote] 返回的真实绑定关系。
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

/// 把服务端的设备记录转成界面用的 [BloomDevice]。
///
/// [localDeviceId] 是这台手机自己的设备 ID（来自设备令牌）。只有与它相等的
/// 那一行是 `isLocal` —— 因为只有那台设备的照片这个 App 取得到，
/// 别的设备（含相框）都只能用用户会话读设置，读不到照片。
List<BloomDevice> bloomDevicesFromRemote(
  List<UserDevice> remote, {
  String? localDeviceId,
  bool? localOnline,
}) => [
  for (final device in remote)
    () {
      final isLocal = localDeviceId != null && device.deviceId == localDeviceId;
      return BloomDevice(
        deviceId: device.deviceId,
        name:
            (device.name?.trim().isNotEmpty ?? false)
                ? device.name!.trim()
                : (device.isFrame ? 'E-Ink' : '手机小组件'),
        type: device.deviceType,
        isLocal: isLocal,
        // 本机小组件的开关状态只对本机有效。家庭里另一台手机也是
        // device_type=mobile，套用本机的开关会把它显示成错误的离线。
        isOnline:
            isLocal && localOnline != null ? localOnline : _onlineFrom(device),
      );
    }(),
];

/// 由 `last_seen_at` 推断在线状态。
///
/// 窗口取该设备自己刷新间隔的两倍（下限 30 分钟）：相框大部分时间在深度睡眠，
/// 用固定窗口会把一台完全正常的相框常年显示成"离线"，而这个提示一旦长期
/// 不准，用户就再也不看它了。间隔本身来自服务端内联的 settings，
/// 所以不需要额外请求。
///
/// 服务端从未上报过 `last_seen_at` 时返回 null —— 界面渲染成"离线"，
/// 而不是编一个状态出来。
bool? _onlineFrom(UserDevice device) {
  final seen = device.lastSeenAt;
  if (seen == null) return null;
  final interval = device.settings?.intervalMinutes ?? 60;
  // clamp 返回 num，Duration 要 int。
  final windowMinutes = (interval * 2).clamp(30, 24 * 60).toInt();
  return DateTime.now().difference(seen) < Duration(minutes: windowMinutes);
}

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
    this.account,
    this.onAccountTap,
    this.accountBusy = false,
  });

  final List<BloomDevice> devices;
  final ValueChanged<BloomDevice> onOpenDevice;
  final VoidCallback onAddDevice;

  /// False while the master switch is off: the phone's tile must say 离线 even
  /// though the server still remembers it as reachable.
  final bool widgetEnabled;
  final ValueChanged<bool>? onWidgetEnabledChanged;

  /// 当前登录的账号。null 表示未登录 —— 页面底部据此显示登录入口。
  final AccountInfo? account;

  /// 打开登录页。未登录时的入口。
  final VoidCallback? onAccountTap;

  /// 登录态正在变化（例如正在取设备列表），期间禁用账号操作，避免重复点击。
  final bool accountBusy;

  @override
  Widget build(BuildContext context) {
    // 未登录：整页换成登录提示。
    //
    // 设备列表**本来就是账号数据** —— 服务端按账号返回绑定关系
    // （`list_user_devices` 走 immich_user_id），没有账号就无从列起。
    // 之前用硬编码兜底假装有设备，那才是错的：它会显示一台你并没有的设备。
    //
    // ⚠️ 代价：本机小组件的详情页（里面有"小组件开关"和刷新节奏）也进不去了。
    // 那些设置其实只要设备令牌、不需要账号。如果希望未登录时仍能改本机小组件，
    // 就把本机那一张 tile 留在提示上方。
    if (account == null) {
      return SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          BloomSurface.pageInset,
          BloomSurface.pageInset,
          BloomSurface.pageInset,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const BloomPageTitle(title: '设备', subtitle: '管理相框和手机小组件'),
            const SizedBox(height: BloomPageTitle.contentGap),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 96),
                child: BloomSignInPrompt(
                  key: const ValueKey('bloom-devices-signed-out'),
                  title: '登录后管理你的设备',
                  message: '相框和手机小组件都绑在账号下，登录后这里会列出它们。',
                  onSignIn: onAccountTap,
                  busy: accountBusy,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return SafeArea(
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
/// - the frame (`eink`) **can** now pick its display mode: the server selects
///   the ordering from `frame_device_settings.mode` and the firmware merely
///   follows it, so switching modes needs no reflash. A frame save therefore
///   carries `mode`, exactly like a phone save — but it still never writes the
///   local mirror, which belongs to this phone's home-screen widget;
/// - this phone (`mobile`) owns the local mirror, so only its saves call
///   `cacheLocal`.
class BloomDeviceDetailPage extends StatefulWidget {
  const BloomDeviceDetailPage({
    super.key,
    required this.device,
    required this.preferences,
    required this.settings,
    this.credentials,
    this.userToken,
    this.callerDeviceId,
    this.onModeChanged,
    this.onSaved,
    this.onMirrored,
    this.photoPath,
    this.onWidgetEnabledChanged,
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
  final String? userToken;
  final String? callerDeviceId;

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

  /// Pushes the detail page. Kept in one place so the production route and the
  /// widget tests exercise the same navigation.
  static Future<void> open(
    BuildContext context, {
    required BloomDevice device,
    required DisplayPreferences preferences,
    required BloomDisplaySettings settings,
    DeviceCredentials? credentials,
    String? callerDeviceId,
    String? userToken,
    ValueChanged<BloomDisplaySettings>? onModeChanged,
    ValueChanged<BloomDisplaySettings>? onSaved,
    Future<void> Function(BloomDisplaySettings settings)? onMirrored,
    String? photoPath,
    ValueChanged<bool>? onWidgetEnabledChanged,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder:
          (_) => BloomDeviceDetailPage(
            device: device,
            preferences: preferences,
            settings: settings,
            credentials: credentials,
            callerDeviceId: callerDeviceId,
            userToken: userToken,
            onModeChanged: onModeChanged,
            onSaved: onSaved,
            onMirrored: onMirrored,
            photoPath: photoPath,
            onWidgetEnabledChanged: onWidgetEnabledChanged,
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

  /// 这台设备当前生效的来源。null 表示"还不知道"，用打开页面时的值兜底。
  /// 服务器回显后会被覆盖 —— 与 _serverMode 同一个套路。
  List<BloomPhotoSource>? _sources;

  /// 用户这次会话里动过来源没有。与 _modeTouched 一字不差的同一规矩：
  /// 没动过就不发送这个键，服务器保持已存的值。
  bool _sourcesTouched = false;
  String? _orientationMode;
  bool _orientationSaving = false;
  int _orientationRevision = 0;

  /// 用户自己的轮播作息，在切到「推荐」之前记下来。
  ///
  /// 服务器的 mode 与作息是【正交】的：四个字段只有一个存储位，切到推荐时
  /// 必须把固定作息（06:00/22:00/12h）写进去，否则推荐会用一个不相干的作息
  /// 去跑。代价是【用户原来的轮播作息被覆盖】。所以切过去之前先记一份，
  /// 切回来时原样还回去 —— 否则用户只是去看了一眼推荐，回来发现自己的
  /// 作息没了。
  BloomDisplaySettings? _carouselSchedule;

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
    if (widget.device.isFrame) unawaited(_loadOrientation());
  }

  Future<void> _loadOrientation() async {
    final credentials = widget.credentials;
    if (credentials == null) return;
    final revision = _orientationRevision;
    try {
      final mode = await widget.preferences.frameOrientation(
        credentials: credentials,
        frameDeviceId: widget.device.deviceId,
      );
      if (mounted && !_orientationSaving && revision == _orientationRevision) {
        setState(() => _orientationMode = mode);
      }
    } catch (_) {
      // 老服务端、离线或未绑定时不伪造朝向设置。
    }
  }

  Future<void> _pickOrientation() async {
    if (_orientationSaving || _saving || widget.credentials == null) return;
    await _pickOption<String>(
      title: '照片朝向',
      note: '改变摆放方向后，照片会在放稳后自动调整。墨水屏更新需要片刻。',
      options: const ['auto', 'locked'],
      selected: _orientationMode ?? 'auto',
      label: (mode) => mode == 'auto' ? '自动转向' : '锁定当前朝向',
      hint: (mode) => mode == 'auto' ? '放稳后调整' : '保持朝向，仍按计划更换照片',
      onPick: (mode) {
        unawaited(_saveOrientation(mode));
      },
    );
  }

  Future<void> _saveOrientation(String mode) async {
    final credentials = widget.credentials;
    if (credentials == null || _orientationSaving) return;
    setState(() {
      _orientationSaving = true;
      _orientationRevision++;
    });
    try {
      final saved = await widget.preferences.frameOrientation(
        credentials: credentials,
        frameDeviceId: widget.device.deviceId,
        mode: mode,
      );
      if (!mounted) return;
      setState(() => _orientationMode = saved);
      _showToast('设置已保存。相框下次唤醒时生效，轻按中键可立即同步。');
    } catch (_) {
      if (mounted) _showToast('朝向设置未保存，请稍后重试。', isError: true);
    } finally {
      if (mounted) setState(() => _orientationSaving = false);
    }
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
      deviceId: widget.device.deviceId,
      target: _target,
    );
    if (!mounted || remote == null) return;
    // 取回用户自己的轮播作息（在 setState 之外 await —— 回调不是 async）。
    // 持久化的，所以【返回首页再进来也还在】；内存版会在页面被销毁时丢掉，
    // 用户第二次切换就还原不回去了。**按 target 分开取**：手机与相框各有各的。
    final stashedCarouselSchedule = await widget.preferences
        .recallCarouselSchedule(target: _target);
    if (!mounted) return;
    setState(() {
      _serverMode = remote.mode;
      // ⚠️ 用户已经动过来源就不要被这次（可能更早发出的）读回覆盖 —— 与
      //    `_edited` 挡住 `_draft` 是同一条规矩。否则用户勾完来源、服务器读
      //    刚好返回，勾选会被悄悄抹掉。
      if (!_sourcesTouched) _sources = remote.sources;
      _carouselSchedule = stashedCarouselSchedule;
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
        deviceId: widget.device.deviceId,
        target: _target,
        // 带不带 mode 只看用户有没有动过它，与 target 无关 —— 相框同样需要
        // 把自己的选择发给服务器。（本地镜像是另一回事，见下面
        // _ownsLocalMirror 的分支：只有手机才写镜像。）
        mode: _modeTouched ? draft.mode : null,
        // 与 mode 同一规矩：没碰过就不带这个键，服务器保持已存的值。
        // 空列表也不能发 —— 见 _toggleSource 的注释。
        sources:
            _sourcesTouched && _displaySources.isNotEmpty
                ? _displaySources
                : null,
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
        _sources = saved.sources;
        // 用户自己在轮播上调过之后，那份"自己的作息"要跟着更新，
        // 否则下次切推荐会把旧值记下来、切回来还原成过期的设置。
        if (saved.mode == BloomDisplayMode.carousel) {
          _carouselSchedule = saved;
          unawaited(
            widget.preferences.rememberCarouselSchedule(saved, target: _target),
          );
        }
        if (_modeTouched) _mirrorMode = saved.mode;
        _edited = false;
        _savedOnce = true;
        // The mode the user picked has just been committed (either by the tap
        // that picked it or by 保存). Clearing this keeps a later 保存 a
        // cadence-only request, which is the same "only send a mode somebody
        // chose" rule the save path has always had.
        _modeTouched = false;
        // 来源同一条规矩：这次已经送出去了，就回到"用户没碰过"。
        // 不清掉的话，推荐模式下「保存」按钮会因为 `_sourcesTouched` 永远亮着。
        _sourcesTouched = false;
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
    sources: BloomDisplaySettings.sourcesFromWire(remote.sources),
    sourceWeights: remote.sourceWeights,
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
  /// 打开页面时该显示的来源：服务器回显优先，否则用打开时的值。
  List<BloomPhotoSource> get _displaySources =>
      _sources ?? widget.settings.sources;

  void _toggleSource(BloomPhotoSource source) {
    // 只放出已实现来源；新闻和动态组件仍然预留。
    if (!BloomPhotoSource.implemented.contains(source)) return;
    final next = List<BloomPhotoSource>.from(_displaySources);
    if (next.contains(source)) {
      // 至少留一个：全不选等于没有来源，相框就没有候选照片可取了。
      // 服务器的空列表语义是"回落到 personal"，那会让这次点击看起来
      // 什么都没发生 —— 不如直接不允许取消最后一个。
      if (next.length <= 1) return;
      next.remove(source);
    } else {
      next.add(source);
    }
    setState(() {
      _sourcesTouched = true;
      _sources = next;
      // 「保存」按钮的显示条件里有 `_sourcesTouched`：**推荐模式下也必须有办法
      // 提交来源**。推荐模式没有作息表单，原来那个按钮是 carousel-only，于是
      // 在推荐模式里点来源只改草稿、永远送不出去 —— 就是"点了没反应"。
      _edited = true;
    });
    // 只改草稿，不提交 —— 与「更换频率」「生效时间」一样，等页面底部
    // 那个统一的「保存」按钮。mode 是开关所以立刻提交，来源不是。
    unawaited(HapticFeedback.selectionClick());
  }

  void _selectMode(BloomDisplayMode mode) {
    if (_saving || _draft.mode == mode) return;
    setState(() {
      _edited = true;
      _modeTouched = true;
      if (mode == BloomDisplayMode.recommendation) {
        // 先把用户自己的轮播作息记下来（内存 + 磁盘），再填固定值。
        // ⚠️ 按 target 记：手机和相框各有各的作息，共用一组 key 会互相覆盖。
        _carouselSchedule = _draft;
        unawaited(
          widget.preferences.rememberCarouselSchedule(_draft, target: _target),
        );
        // 推荐模式的作息是固定的：把三个值【真的填进草稿】，随这次保存一起
        // 提交。服务器对四个参数零特例，不会"因为推荐就忽略间隔"，
        // 所以不填就等于用一个不相干的作息去跑推荐。
        _draft = _draft.copyWith(
          mode: mode,
          activeStart: recommendActiveStart,
          activeEnd: recommendActiveEnd,
          intervalMinutes: recommendIntervalMinutes,
        );
      } else {
        // 切回轮播：把用户自己那份作息原样还回去，而不是留着推荐的固定值。
        // 只改 mode 的话，用户会看到自己的设置被"看一眼推荐"这件事改掉了。
        final own = _carouselSchedule;
        _draft =
            own == null
                ? _draft.copyWith(mode: mode)
                : _draft.copyWith(
                  mode: mode,
                  activeStart: own.activeStart,
                  activeEnd: own.activeEnd,
                  intervalMinutes: own.intervalMinutes,
                );
      }
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
    // The floating save belongs to the forms on this page, and those differ by mode:
    // 轮播 has the cadence form, 推荐 has none — but **both** have the「照片来源」
    // card, which is a form too. Gating this on `carousel` alone is what made 来源
    // impossible to save in 推荐：点一下只改草稿，而页面上根本没有提交它的按钮。
    //
    // 推荐模式下没动过任何东西时仍然不显示按钮（那才是"一个什么都不做的按钮"）；
    // 碰过来源它就会出现。它也随总开关一起消失。
    final showSave = _widgetEnabled && (carousel || _sourcesTouched);
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
                  if (widget.device.isFrame && _orientationMode != null)
                    BloomPanel(
                      padding: const EdgeInsets.all(16),
                      child: _Field(
                        key: const ValueKey('bloom-orientation-field'),
                        label: '照片朝向',
                        value:
                            _orientationSaving
                                ? '保存中…'
                                : _orientationMode == 'auto'
                                ? '自动转向'
                                : '锁定当前朝向',
                        onTap:
                            _orientationSaving || _saving
                                ? null
                                : _pickOrientation,
                      ),
                    ),
                  _SourcesCard(
                    allowArt: true,
                    selected: _displaySources,
                    onToggle: _saving ? null : _toggleSource,
                  ),
                  if (widget.userToken != null)
                    BloomPanel(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('展示内容', style: BloomType.rowTitle),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap:
                            () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder:
                                    (_) => BloomContentManagerPage(
                                      api: BloomApiClient(),
                                      token: widget.userToken!,
                                      frame: GalleryFrame(
                                        widget.device.deviceId,
                                        widget.device.name,
                                        isMobile: !widget.device.isFrame,
                                      ),
                                    ),
                              ),
                            ),
                      ),
                    ),
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
                  // 相框现在也能改模式：服务器按 frame_device_settings.mode
                  // 选排序方式，固件只是照做，改模式不需要重烧固件。
                  onChanged: _saving ? null : _selectMode,
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
            // 「配对码」这一行已经删掉了。
            //
            // 它是激活码机制的产物：用户要把六位码抄进 Immich 后台来证明"这台
            // 设备归我"。现在归属由登录证明（登录时上报设备号，服务端把它挂到
            // 账号下），所以这一行既没有东西可显示，留着还会让人以为仍然需要
            // 去后台配对。
            //
            // 「设备号」保留：它仍然有用 —— 服务端的设备记录、报障时对号都用它。
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

  /// Null while saving. It is a real control for both targets now: the frame's
  /// mode used to be a read-out because its firmware could not read the server's
  /// `mode`, which is no longer true.
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
/// 推荐模式一天醒来几次 —— 由固定作息算出，供文案使用。
///
/// 单独放一个 getter 而不是在文案里写死数字：数字和作息必须永远一致，
/// 否则改了间隔而忘了改文案，界面就会给出错的一天几张。
int get recommendPhotosPerDay =>
    BloomDisplaySettings(
      intervalMinutes: recommendIntervalMinutes,
      activeStart: recommendActiveStart,
      activeEnd: recommendActiveEnd,
    ).expectedDailyItems;

/// 照片来源。
///
/// 相框和手机小组件共用个人照片与艺术来源；两者各自保留作息。
class _SourcesCard extends StatelessWidget {
  const _SourcesCard({
    required this.selected,
    required this.onToggle,
    this.allowArt = false,
  });

  final bool allowArt;

  final List<BloomPhotoSource> selected;

  /// Null while saving.
  final ValueChanged<BloomPhotoSource>? onToggle;

  @override
  Widget build(BuildContext context) => BloomPanel(
    lifted: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('照片来源', style: BloomType.sectionTitle),
        const SizedBox(height: 4),
        for (final source in BloomPhotoSource.implemented.where(
          (s) => allowArt || s == BloomPhotoSource.personal,
        ))
          _SourceRow(
            key: ValueKey('bloom-source-${source.wire}'),
            source: source,
            checked: selected.contains(source),
            // 只剩这一个时不能再取消 —— 全不选就没有来源了。
            // 把 onTap 置空，行会呈现为不可点，比"点了没反应"清楚。
            onTap:
                onToggle == null ||
                        (selected.length <= 1 && selected.contains(source))
                    ? null
                    : () => onToggle!(source),
          ),
      ],
    ),
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.source,
    required this.checked,
    required this.onTap,
  });

  final BloomPhotoSource source;
  final bool checked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          // 用方框而不是圆圈：这是一个【多选】，圆圈看起来像单选。
          // 颜色用 accent（#8FA99C）而不是 accentDeep（#2C3A34）——
          // 后者和底色几乎一样，选中态看上去像被禁用了。
          Icon(
            checked
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            size: 22,
            color: checked ? BloomInk.accent : BloomInk.textFaint,
          ),
          const SizedBox(width: 12),
          Text(
            source.label,
            style: TextStyle(
              // 未选中的文字压暗，选中/未选中的区别不只靠一个小图标。
              color: checked ? BloomInk.text : BloomInk.textFaint,
              fontSize: 16,
            ),
          ),
        ],
      ),
    ),
  );
}

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
        // 张数从固定作息【算出来】，不写死：卡片说"每天一张"而作息是 12 小时
        // 的话，界面就在骗人。改 recommendIntervalMinutes 时这里会跟着变。
        Text(
          '一天$recommendPhotosPerDay张。把你带回那年今天，你当时也在场的那个瞬间。',
          style: const TextStyle(
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
  const _InfoRow({required this.label, required this.value, this.onCopy});

  final String label;
  final String value;

  /// Copy the value. A bare glyph, no border and no square box.
  final VoidCallback? onCopy;

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
