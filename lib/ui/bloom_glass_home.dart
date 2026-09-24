import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../core/models/device_models.dart';
import '../core/storage/display_preferences.dart';
import 'bloom_device_pages.dart';

Widget _buildDeviceNavGlyph(BuildContext context, LiquidGlassGlyph glyph) {
  if (!glyph.selected) {
    return Icon(Icons.devices_outlined, size: glyph.size, color: glyph.color);
  }
  return _SelectedNavGlyph(icon: Icons.devices_rounded, glyph: glyph);
}

class _SelectedNavGlyph extends StatelessWidget {
  const _SelectedNavGlyph({required this.icon, required this.glyph});

  final IconData icon;
  final LiquidGlassGlyph glyph;

  @override
  Widget build(BuildContext context) => Container(
    width: glyph.size,
    height: glyph.size,
    decoration: BoxDecoration(
      color: glyph.color,
      borderRadius: BorderRadius.circular(glyph.size * .23),
    ),
    alignment: Alignment.center,
    child: Icon(icon, size: glyph.size * .68, color: BloomInk.inverseInk),
  );
}

/// The soft lift drawn *under* a glass surface.
///
/// The liquid-glass shader lights its own border but never casts a shadow, so
/// the "floating above the page" part has to come from the widget tree: this
/// paints a rounded drop shadow exactly behind the surface it wraps. The
/// shadow's radius must match the wrapped glass shape's corner radius.
///
/// Only the two surfaces that stay glass are wrapped in it now: the bottom nav
/// bar and the message toast. Paper cards lift with [BloomInk.lift]
/// / [BloomInk.lift] instead, which are warmer and much smaller.
class BloomGlassShadow extends StatelessWidget {
  const BloomGlassShadow({
    super.key,
    required this.child,
    this.cornerRadius = 30,
  });

  final Widget child;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(cornerRadius),
      // Black at 8%, blurred 14, dropped 3px: light enough not to look like a
      // Material elevation, strong enough to separate glass from paper.
      boxShadow: const [
        BoxShadow(
          color: Color(0x14000000),
          blurRadius: 14,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: child,
  );
}

/// The app's two display modes, as **one icon and one label each**.
///
/// One place, because they had already drifted: the home page's tag drew 轮播 as
/// `shuffle` while the settings page drew the same mode as `slideshow`, so one
/// idea had two glyphs on two screens. Everything that shows a mode — the home
/// tag, the settings choice, the frame's read-only row — reads from here.
IconData bloomModeIcon(BloomDisplayMode mode) =>
    mode == BloomDisplayMode.carousel
        ? Icons.slideshow_rounded
        : Icons.auto_awesome_rounded;

String bloomModeLabel(BloomDisplayMode mode) =>
    mode == BloomDisplayMode.carousel ? '轮播模式' : '推荐模式';

/// The same two modes in one word, for a row with no space for the suffix.
String bloomModeShortLabel(BloomDisplayMode mode) =>
    mode == BloomDisplayMode.carousel ? '轮播' : '推荐';

/// A hand-built switch.
///
/// Material's `Switch` is the most recognisable Android control there is, and the
/// user's note about this page — "太过安卓原始了，一点儿也没有那个艺术气息" —
/// applies to it at least as much as to the segmented control it replaced. This
/// is the same idea in this app's language: a capsule that fills with the theme
/// colour when it is on, a knob that travels, no border, no ripple ring.
class BloomSwitch extends StatelessWidget {
  const BloomSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.onLabel,
    this.offLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  /// Optional state word carried **inside** the track, opposite the knob.
  ///
  /// The switch on the device page used to be an unlabelled toggle, and the
  /// user's note was blunt: "没人知道这是干嘛的". A switch whose state has a
  /// name should say the name where the empty half of the track already is.
  final String? onLabel;
  final String? offLabel;

  static const _width = 44.0;
  static const _labelledWidth = 62.0;
  static const _height = 26.0;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final onLabel = this.onLabel;
    final offLabel = this.offLabel;
    final labelled = onLabel != null && offLabel != null;
    final trackWidth = labelled ? _labelledWidth : _width;
    return Semantics(
      label: semanticLabel,
      toggled: value,
      child: Opacity(
        opacity: onChanged == null ? .4 : 1,
        child: GestureDetector(
          onTap: onChanged == null ? null : () => onChanged(!value),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            // The capsule stays small; the tap box does not.
            width: trackWidth + 8,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: trackWidth,
                height: _height,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: value ? BloomInk.accentDeep : BloomInk.recess,
                  borderRadius: BorderRadius.circular(_height / 2),
                ),
                child: Stack(
                  children: [
                    // The word sits in whichever half the knob has vacated.
                    AnimatedAlign(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      // Centred in the half the knob has vacated, not pinned to
                      // the track's edge: "在线" was touching the far left.
                      alignment:
                          value
                              ? const Alignment(-.42, 0)
                              : const Alignment(.42, 0),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: Text(
                          value ? onLabel! : offLabel!,
                          key: ValueKey(value),
                          style: BloomType.label.copyWith(
                            fontSize: 11,
                            letterSpacing: .6,
                            color: value ? BloomInk.text : BloomInk.textMuted,
                          ),
                        ),
                      ),
                    ),
                    AnimatedAlign(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment:
                          value ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        width: _height - 6,
                        height: _height - 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: value ? BloomInk.accent : BloomInk.textFaint,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class BloomGlassHome extends StatelessWidget {
  const BloomGlassHome({
    super.key,
    required this.loading,
    required this.paired,
    required this.pairingRefreshing,
    required this.nextLoading,
    required this.selectedTab,
    required this.settings,
    required this.devices,
    this.widgetEnabled = true,
    this.onWidgetEnabledChanged,
    required this.onTabChanged,
    required this.onRefresh,
    required this.onNext,
    required this.onDeviceChanged,
    required this.onOpenDevice,
    required this.onAddDevice,
    required this.onRefreshPairingCode,
    required this.onCopyDeviceId,
    required this.onCopyPairingCode,
    this.credentials,
    this.pairing,
    this.portrait,
    this.originalPhotoPath,
    this.content,
    this.date,
    this.message,
    this.selectedDeviceId,
    this.nextSlotAt,
  });

  final bool loading;

  final bool paired;
  final bool pairingRefreshing;
  final bool nextLoading;
  final int selectedTab;
  final DeviceCredentials? credentials;
  final PairingInfo? pairing;
  final CachedWidgetImage? portrait;
  final String? originalPhotoPath;
  final DailyContent? content;
  final String? date;
  final String? message;

  /// When the next carousel slot is due, as epoch milliseconds
  /// (`next_slot_at_ms` in the daily mirror). `null` outside carousel mode or
  /// before the first sync.
  final int? nextSlotAt;

  final BloomDisplaySettings settings;

  /// "下次更新 今天 14:15" — the phone's own next carousel slot, in the reader's
  /// own words.
  ///
  /// **The persisted stamp is only as fresh as the last sync that landed.** When
  /// that sync was blocked (the background task held the lock, the phone was
  /// offline, the switch was off) the stamp sits in the past while the clock
  /// moves on: the user saw "今天 12:15" at 14:11. The window and the interval are
  /// enough to answer locally — slots are `start + k * interval`, so the next one
  /// is the first grid point after now, and once the window is done it is
  /// tomorrow's start.
  static String? nextSlotText(BloomDisplaySettings settings, int? stampMillis) {
    final now = DateTime.now();
    final stamp =
        (stampMillis == null || stampMillis < 1)
            ? null
            : DateTime.fromMillisecondsSinceEpoch(stampMillis);
    // **Only the plan's own stamp — never a guess from the phone's settings.**
    // The grid fallback that used to stand here read the *local* window, which on
    // this phone did not match the plan the server is actually running, so at
    // 15:00 it announced "明天 06:00"; a settings state is not a schedule. If the
    // stamp is missing or already past, the honest answer is to say nothing.
    if (stamp == null || !stamp.isAfter(now)) return null;
    final at = stamp;
    final days =
        DateTime(
          at.year,
          at.month,
          at.day,
        ).difference(DateTime(now.year, now.month, now.day)).inDays;
    final day = switch (days) {
      0 => '今天',
      1 => '明天',
      _ => '${at.month}月${at.day}日',
    };
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return '下次更新 $day $hh:$mm';
  }



  /// Devices the switcher and the "设备" tab list. Hardcoded for now (F3):
  /// this phone plus the frame. See `bloom_device_pages.dart`.
  final List<BloomDevice> devices;

  /// The master switch, for the same reason as the device page's own switch:
  /// one fact, one owner.
  final bool widgetEnabled;
  final ValueChanged<bool>? onWidgetEnabledChanged;

  /// Device whose photos the photo page shows. `null` means "this phone".
  final String? selectedDeviceId;
  final ValueChanged<int> onTabChanged;

  /// Reloads this phone's photos. **Kept, but no longer used by the page**: the
  /// header's 刷新 button was removed because it only ever did what 下一张 does
  /// (and was disabled outright while a remote device was selected). The
  /// parameter stays so `main.dart` — which still passes `_load` — keeps
  /// compiling; nothing on the page consumes it.
  final Future<void> Function() onRefresh;

  /// Advances the carousel by one. **Kept, but nothing renders it any more**:
  /// the user removed the 下一张 button from the home header (it only ever
  /// appeared in 轮播 mode). The parameter and its [nextLoading] twin stay so
  /// `main.dart` — which still passes the real carousel action — keeps
  /// compiling, and so re-adding the control is a one-widget change.
  final VoidCallback onNext;

  final ValueChanged<String> onDeviceChanged;
  final ValueChanged<BloomDevice> onOpenDevice;
  final VoidCallback onAddDevice;
  final VoidCallback onRefreshPairingCode;
  final VoidCallback onCopyDeviceId;
  final VoidCallback onCopyPairingCode;

  /// The flat colour behind everything: the top stop of [backgroundGradient], so
  /// a transparent app bar never shows a seam where the gradient starts.
  static const backgroundColor = BloomInk.page;

  /// The app-wide wall: a warm near-black that deepens towards the bottom.
  ///
  /// A gradient rather than a flat fill for one reason: the letter card and
  /// every panel are a single step *lighter* than the page, so the page has to
  /// be its own darkest reference. Falling off towards the bottom also gives the
  /// glass nav something to sit in. [BloomAtmosphere] adds the tooth on top.
  static const backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [BloomInk.page, Color(0xff161C1E), BloomInk.pageBottom],
    stops: [0, .55, 1],
  );

  /// The home header's vertical rhythm.
  ///
  /// The gap above the switcher row (now measured from the 首页 title) and the
  /// gap between that row and the photo card must be the same value (the user
  /// asked for exactly that), so both use this constant and neither is written
  /// by hand. Both were 10 (plus a since-removed status line) before.
  ///
  /// It is no longer the page's *horizontal* padding: the title band moved the
  /// page onto the 18px inset the 设备 and 照片 pages already use, see
  /// [BloomSurface.pageInset].
  /// Title → the mode/switch row, and the row → the card. **Both 0.**
  ///
  /// The row is a 34px tap box around a 14px label, so 10px of invisible padding
  /// sits on each side of it: with both gaps at zero the label is the same
  /// distance below the title as it is above the card, which is what the user
  /// asked for ("把卡片和轮播模式那一行之间的间距也提上来… 和首页和轮播模式那一行
  /// 中间的间距保持一致"). The first attempt used 0/20 and read as lopsided.
  static const headerGap = 0.0;
  // Matched to the 设备 page by measuring *it*, not by taste: `BloomPageTitle`
  // puts the subtitle 6 under the title and callers leave `contentGap` (20)
  // before the first block. This row is a 34px tap box around a 14px label, so
  // it already carries 10px of invisible padding top and bottom — 0 above keeps
  // the label 10 under the title (the closest a 34px target can come to 6), and
  // 10 below makes it 20 to the card, exactly the 设备 page's subtitle → list gap.
  static const cardGap = 10.0;

  // Glass fills.
  //
  // Kept for exactly two surfaces, both of which really do float above a
  // photograph: the bottom nav bar (its own [_navStyle] and pill styles below)
  // and the message toast ([panelStyle]) — which is why they are the dark-glass
  // twins of these. Everything else in the app is ink on a dark wall; see
  // [BloomInk], [BloomPanel], [BloomSurface] and [BloomType]. The panels,
  // buttons, skeleton and both pre-pairing screens used to be lenses too; over
  // a near-white wash a lens has nothing behind it to refract, so a translucent
  // fill was the only thing keeping it visible, and a translucent fill is
  // exactly what made a control hard to tell from the page.
  static const panelStyle = LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: 30,
      borderWidth: 1.05,
      lightIntensity: 1.34,
      borderType: OpticalBorder(
        borderSaturation: .9,
        ambientIntensity: 1,
        borderSolidity: .4,
      ),
    ),
    appearance: LiquidGlassAppearance(
      // Ink at 70%: the toast floats over a dark page, so it is a smoked sheet,
      // not a frosted white one.
      color: Color(0xB31A1816),
      blur: LiquidGlassBlur(sigmaX: 12, sigmaY: 12),
      saturation: 1.06,
      enableInnerRadiusTransparent: false,
    ),
    refraction: LiquidGlassRefraction(
      refractionType: OpticalRefraction(
        refraction: 1.52,
        refractionWidth: 30,
        depth: .55,
      ),
      chromaticAberration: .0007,
      magnification: 1.014,
    ),
  );

  /// The bar's own lens. The selected pill's moving fill is [_navStyle]'s
  /// sibling further down, next to the item style.
  static const _navStyle = LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: 36,
      borderWidth: 1,
      lightIntensity: 1.34,
      borderType: OpticalBorder(
        borderSaturation: .9,
        ambientIntensity: 1,
        borderSolidity: .38,
      ),
    ),
    appearance: LiquidGlassAppearance(
      // Ink at 76%: the bar has to float *above* a near-black page, which on a
      // dark UI means it must be lighter than what is behind it — so it is a
      // smoked lens with a lit rim, not an opaque bar. The refraction is what
      // keeps it a piece of glass rather than a grey rectangle.
      color: Color(0xC21A1816),
      blur: LiquidGlassBlur(sigmaX: 16, sigmaY: 16),
      saturation: 1.05,
      enableInnerRadiusTransparent: false,
    ),
    refraction: LiquidGlassRefraction(
      refractionType: OpticalRefraction(
        refraction: 1.56,
        refractionWidth: 34,
        depth: .64,
      ),
      chromaticAberration: .00075,
      magnification: 1.018,
    ),
  );

  /// The **top bar's** lens: the nav bar's stock, one notch tighter and lighter.
  ///
  /// The bar carries the back button, the device name, the mode switch and the
  /// widget switch — controls, not a thumb rest — so it is inset from the screen
  /// edges and rounded on all four corners, exactly like the bar at the bottom.
  /// The two ends of the app are then the same piece of glass.
  static const barStyle = LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: 24,
      borderWidth: 1,
      lightIntensity: 1.3,
      borderType: OpticalBorder(
        borderSaturation: .9,
        ambientIntensity: 1,
        borderSolidity: .38,
      ),
    ),
    appearance: LiquidGlassAppearance(
      // Ink at 42%, down from 68%: over a near-black page a dark lens at 68%
      // reads as a *grey bar with a lit rim* — the user's exact words ("完全没有
      // 透明的感觉呀… 只是视觉上两边有白色的描边儿"). Glass is only glass when you
      // can see through it, so the ink comes down and the blur goes up to keep
      // the text legible.
      color: Color(0x3A2C3230),
      blur: LiquidGlassBlur(sigmaX: 24, sigmaY: 24),
      saturation: 1.12,
      enableInnerRadiusTransparent: false,
    ),
    refraction: LiquidGlassRefraction(
      // **A thin lens.** 46/0.78 sampled content from well outside the bar,
      // which is what read as "折射的角度非常大": the glass was bending the page
      // from far away instead of the strip it covers. A control-height lens
      // bends only its own edge.
      refractionType: OpticalRefraction(
        refraction: 1.2,
        refractionWidth: 12,
        depth: .26,
      ),
      chromaticAberration: .0003,
      magnification: 1.004,
    ),
  );

  /// The mode switcher's track: a small frosted capsule inside [barStyle].
  static const modePillStyle = LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: 19,
      borderWidth: .9,
      lightIntensity: 1.26,
      borderType: OpticalBorder(
        borderSaturation: .9,
        ambientIntensity: 1,
        borderSolidity: .34,
      ),
    ),
    appearance: LiquidGlassAppearance(
      color: Color(0x8C0F0E0D),
      blur: LiquidGlassBlur(sigmaX: 10, sigmaY: 10),
      saturation: 1.04,
      enableInnerRadiusTransparent: false,
    ),
    refraction: LiquidGlassRefraction(
      refractionType: OpticalRefraction(
        refraction: 1.16,
        refractionWidth: 8,
        depth: .2,
      ),
      chromaticAberration: .0003,
      magnification: 1.003,
    ),
  );

  /// The primary action as glass: the app's green as the *tint* of a smoked
  /// lens rather than as a flat fill, so the save button belongs to the same
  /// material as the bar above it.
  static const accentGlassStyle = LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: 26,
      borderWidth: 1,
      lightIntensity: 1.34,
      borderType: OpticalBorder(
        borderSaturation: .9,
        ambientIntensity: 1,
        borderSolidity: .4,
      ),
    ),
    appearance: LiquidGlassAppearance(
      // The action is glass too: 55% green, so the page shows through it the
      // way it shows through the bar.
      color: Color(0x5C5E8574),
      blur: LiquidGlassBlur(sigmaX: 22, sigmaY: 22),
      saturation: 1.14,
      enableInnerRadiusTransparent: false,
    ),
    refraction: LiquidGlassRefraction(
      refractionType: OpticalRefraction(
        refraction: 1.18,
        refractionWidth: 10,
        depth: .22,
      ),
      chromaticAberration: .0003,
      magnification: 1.003,
    ),
  );

  /// The selected nav pill's fill: a lift of light on the smoked bar, 14% while
  /// it travels and 8% at rest.
  ///
  /// Deliberately **not** [BloomInk.accent]: the rust is reserved for live
  /// state (the online dot, the current segment). A coloured nav pill would be
  /// the loudest thing on a page whose whole point is the photograph.
  static const navPillColor = Color(0x24EDF2EF);
  static const navPillRestColor = Color(0x14EDF2EF);

  @override
  Widget build(BuildContext context) {
    if (!paired && loading) {
      return const _BindingCheckExperience();
    }
    if (!paired) {
      return _PairingExperience(
        loading: loading,
        pairingRefreshing: pairingRefreshing,
        credentials: credentials,
        pairing: pairing,
        message: message,
        onRefreshPairingCode: onRefreshPairingCode,
        onCopyDeviceId: onCopyDeviceId,
        onCopyPairingCode: onCopyPairingCode,
      );
    }
    return _buildBound(context);
  }

  Widget _buildBound(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final navWidth = (width - 36).clamp(280.0, 330.0);
    // Tab order is the nav's order: 首页 (the photo the widget is showing) →
    // 照片 (the future photo library, an empty placeholder today) → 设备.
    final pages = [
      _PhotoPage(
        // The switch being off freezes this phone's card, so a "下次更新" under it
        // would be a promise the app is not keeping; and the label describes this
        // phone's own plan, so it goes away with it.
        nextSlotText:
            widgetEnabled && settings.mode == BloomDisplayMode.carousel
                ? nextSlotText(settings, nextSlotAt)
                : null,
        originalPhotoPath: originalPhotoPath,
        content: content,
        date: date,
        mode: settings.mode,
        devices: devices,
        selectedDeviceId: selectedDeviceId,
        onDeviceChanged: onDeviceChanged,
      ),
      const _PhotoLibraryPlaceholderPage(),
      BloomDeviceListPage(
        devices: devices,
        widgetEnabled: widgetEnabled,
        onWidgetEnabledChanged: onWidgetEnabledChanged,
        onOpenDevice: onOpenDevice,
        onAddDevice: onAddDevice,
      ),
    ];

    return LiquidGlassScaffold(
      useImpellerBackdrop: Platform.isIOS ? false : null,
      safeArea: true,
      backgroundColor: backgroundColor,
      body: BloomPhotoBackdrop(
        imagePath: originalPhotoPath,
        revision: content?.recommendationId,
      ),
      lenses: [
        Positioned.fill(
          child: IndexedStack(index: selectedTab, children: pages),
        ),
        if (message != null)
          Positioned(
            // **The safe area is this widget's job, not the scaffold's.** The
            // glass scaffold shifts its nav bar and its outer slots by the
            // system insets but lets `lenses` span the whole window, so a toast
            // pinned at `top: 12` landed *inside* the status bar — on a Xiaomi 14
            // the front camera sat on top of it. Reading the window padding here
            // keeps it clear of the status bar, of any punch-hole or notch, and
            // of the side cutouts in landscape, on every device.
            // The floating notice lives in the **lower half** everywhere in the
            // app. It used to clear the punch-hole camera at the top; the user's
            // call was for one place, consistently, so it now clears the nav bar
            // at the bottom instead.
            bottom: 118,
            left: 24,
            right: 24,
            child: BloomMessage(message: message!),
          ),
      ],
      bottomNavigationBar: BloomGlassShadow(
        cornerRadius: 36,
        child: LiquidGlassBottomNavBar(
          items: const [
            LiquidGlassTabBarItem(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home_rounded,
              label: '首页',
            ),
            LiquidGlassTabBarItem(
              icon: Icons.photo_outlined,
              selectedIcon: Icons.photo,
              label: '照片',
            ),
            LiquidGlassTabBarItem.custom(
              iconBuilder: _buildDeviceNavGlyph,
              label: '设备',
            ),
          ],
          selectedIndex: selectedTab,
          onChanged: onTabChanged,
          width: navWidth,
          height: 72,
          margin: const EdgeInsets.only(bottom: 14),
          alignment: Alignment.bottomCenter,
          itemPadding: 5,
          style: _navStyle,
          itemStyle: const LiquidGlassNavItemStyle(
            selectedColor: BloomInk.text,
            unselectedColor: Color(0x73EDF2EF),
            iconSize: 23,
            labelFontSize: 11,
            iconLabelGap: 2.5,
            selectedFontWeight: FontWeight.w700,
            unselectedFontWeight: FontWeight.w500,
          ),
          pillStyle: const LiquidGlassNavPillStyle(
            mode: LiquidGlassPillMode.impellerOnly,
            animated: true,
            color: BloomGlassHome.navPillColor,
            growHeight: 8,
            distortion: .055,
            distortionWidth: 22,
            magnification: 1.014,
            enableInnerRadiusTransparent: false,
            travelStiffness: 240,
            travelDamping: 29.5,
            jelly: LiquidGlassJellyConfig(
              style: LiquidGlassJellyStyle.squashStretch,
              stiffness: 270,
              damping: 20,
              maxVelocity: 6,
              velocityClamp: 60,
              stretchWidth: 20,
              squashHeight: 5.5,
              anchorBias: -.55,
              recoilScale: 1.15,
              recoilAnchor: .72,
              directionTau: .24,
            ),
            glassStyle: LiquidGlassStyle(
              shape: LiquidGlassShape.continuousRoundedRectangle(
                cornerRadius: 34,
                borderWidth: 1.15,
                lightIntensity: 1.38,
                borderType: OpticalBorder(
                  borderSaturation: .92,
                  ambientIntensity: .96,
                  borderSolidity: .3,
                ),
              ),
              appearance: LiquidGlassAppearance(
                color: BloomGlassHome.navPillColor,
                blur: LiquidGlassBlur(sigmaX: 6, sigmaY: 6),
                saturation: 1.05,
                enableInnerRadiusTransparent: false,
              ),
              refraction: LiquidGlassRefraction(
                refractionType: OpticalRefraction(
                  refraction: 1.58,
                  refractionWidth: 24,
                  depth: .54,
                ),
                chromaticAberration: .00075,
                magnification: 1.014,
              ),
            ),
            rest: LiquidGlassStyle(
              shape: LiquidGlassShape.continuousRoundedRectangle(
                cornerRadius: 34,
              ),
              appearance: LiquidGlassAppearance(
                color: BloomGlassHome.navPillRestColor,
                enableInnerRadiusTransparent: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's one page background: the wall's gradient, the atmosphere pools, the
/// current photo bled in at 30%, and the paper grain painted last so every page
/// shares one texture.
///
/// Public because the **device detail page needs it too**. That page is a route
/// above the shell, so it used to show the bare gradient — which is why its
/// glass looked like a grey bar with a lit rim: a lens over a flat gradient has
/// nothing to refract. With the photo and the grain behind it, the same lens
/// finally has something to bend.
class BloomPhotoBackdrop extends StatelessWidget {
  const BloomPhotoBackdrop({
    super.key,
    required this.imagePath,
    required this.revision,
    this.child,
  });

  final String? imagePath;
  final int? revision;

  /// Page content, drawn **on top of** the backdrop. Optional: the shell keeps
  /// its own Stack, which is why this stayed a background-only widget until the
  /// detail page needed both halves in one call.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    return Stack(
      fit: StackFit.expand,
      children: [
        // The grain is deliberately not here: it goes on last, below.
        const BloomAtmosphere(grain: false),
        // **Always mounted, on purpose.**
        //
        // This switcher is stateful: it keeps the outgoing child so it can
        // cross-fade. Mounting it conditionally (`if (path != null) ...`) threw
        // that state away — a rebuild where the path was momentarily null
        // unmounted the whole switcher, and when it came back it saw a "first"
        // child and faded in from nothing, which is exactly the once-per-refresh
        // flash of the *same* photo. Keying by path was not enough on its own:
        // the keys matched, but the widget holding them had been destroyed.
        // A placeholder child keeps it mounted through the gap.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOutCubic,
          // **This is what made the photo a band instead of a backdrop.**
          // AnimatedSwitcher lays its children out in a Stack, and a Stack
          // hands non-positioned children *loose* constraints — so the
          // `BoxFit.cover` below never had a box to cover and the image fell
          // back to its own aspect: a portrait photo became a tall strip with
          // black above and below, a landscape one a strip across the middle.
          // Expanding the layout gives the photo the whole screen to cover.
          layoutBuilder:
              (currentChild, previousChildren) => Stack(
                fit: StackFit.expand,
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              ),
          child:
              path == null
                  ? const SizedBox.shrink(key: ValueKey('bloom-no-photo'))
                  : Opacity(
                    // **The path alone identifies the photo.** It already carries the
                    // item id (`mobile-local-portrait-3197.png`), so a re-read that
                    // finds the same photo now yields the same key and the switcher
                    // stays still. Including `revision` made the key flap whenever that
                    // number came from a different source between two loads, which
                    // replayed the fade every time the page refreshed — the flicker.
                    // **Keyed by the item, not the path.** Probes on the device show
                    // the same photo arriving under two different spellings —
                    // `carousel-original-3263.photo` from the per-item cache and
                    // `original.photo` from the current-photo mirror — while the
                    // revision stays 3263 for both. Keying by path therefore animated
                    // the same picture, which is exactly the "it blinks but the photo
                    // did not change" report. The item id is the identity; the path is
                    // an implementation detail that flaps.
                    key: ValueKey(revision),
                    opacity: .36,
                    child: ImageFiltered(
                      // Less blur than before: at 20 the photo was a colour wash.
                      imageFilter: ui.ImageFilter.blur(sigmaX: 19, sigmaY: 19),
                      child: Transform.scale(
                        scale: 1.12,
                        child: Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          alignment: const Alignment(0, -.12),
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // A scrim, not a veil: on the dark page the blurred photo is
              // pushed *down* (heavy at the top where the type sits, heaviest at
              // the bottom under the glass nav) so the letter card stays the
              // brightest object on the screen while the nav still has real
              // colour to refract.
              colors: [Color(0x731D2427), Color(0x8C161C1E), Color(0xB30F1412)],
            ),
          ),
        ),
        // **Last, over the scrim.** This is what makes the home page and the
        // device list feel like the device page: same paper, same tooth, on top
        // of the photo instead of buried under it.
        const RepaintBoundary(
          child: CustomPaint(painter: _PaperGrainPainter()),
        ),
        // Page content last, so it sits above the photo and the grain.
        if (child != null) child!,
      ],
    );
  }
}

/// The app-wide page background: the wall from
/// [BloomGlassHome.backgroundGradient], the two faint pools of light from
/// [_AtmospherePainter] and the fixed tooth of [_PaperGrainPainter].
///
/// Shared by every page (the home backdrop, the device list inside it and the
/// pushed device-detail page) so the wall looks the same wherever it appears.
/// Optional [child] is painted on top of the texture.
class BloomAtmosphere extends StatelessWidget {
  const BloomAtmosphere({super.key, this.child, this.grain = true});

  final Widget? child;

  /// Whether to paint the paper grain here.
  ///
  /// **False is for the one background that has to paint it last.** On the home
  /// page the atmosphere sits *under* a blurred photo and a 60–80% scrim, and
  /// that scrim was swallowing the grain whole: the device page (which paints
  /// the atmosphere directly) had visible tooth while the home page and the
  /// device list — which sit on this same backdrop — looked like flat black.
  /// The user's report, and they were right. So the backdrop now paints its
  /// gradient and pools here and drops the grain on top of everything instead,
  /// which puts the same tooth on all three screens.
  final bool grain;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: BloomGlassHome.backgroundGradient,
    ),
    child: Stack(
      fit: StackFit.expand,
      children: [
        // Each texture layer sits in its own repaint boundary: the grain is
        // ~20k points built once, and it must not be redrawn every time the
        // page content (a scrolling list, the photo cross-fade) repaints its
        // own layer.
        const RepaintBoundary(
          child: CustomPaint(painter: _AtmospherePainter()),
        ),
        if (grain)
          const RepaintBoundary(
            child: CustomPaint(painter: _PaperGrainPainter()),
          ),
        if (child != null) child!,
      ],
    ),
  );
}

class _AtmospherePainter extends CustomPainter {
  const _AtmospherePainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Two very wide, very faint warm pools. On the light page these were colour
    // ribbons; on the dark wall any band with an edge reads as a stain, so what
    // is left is light *falling* on the page, not shapes drawn on it.
    final top =
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(size.width * .18, size.height * .04),
            size.width * 1.3,
            // The reference's own move: one broad pool of pale green light in a
            // top corner, falling away into the black. It is what turns a flat
            // fill into a *gradient with a direction*.
            const [Color(0x338FA99C), Color(0x008FA99C)],
          );
    final bottom =
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(size.width * .88, size.height * .96),
            size.width * 1.05,
            const [Color(0x1F6F8C7E), Color(0x006F8C7E)],
          );
    canvas.drawRect(Offset.zero & size, top);
    canvas.drawRect(Offset.zero & size, bottom);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// One fibre of the paper: a very short, almost horizontal hair.
typedef _Fibre = ({Offset from, Offset to});

/// The cached dot/fibre field. Built once per surface size and reused for every
/// frame afterwards.
class _PaperField {
  const _PaperField({
    required this.size,
    required this.ink,
    required this.tooth,
    required this.fibres,
  });

  final Size size;
  final List<Offset> ink;
  final List<Offset> tooth;
  final List<_Fibre> fibres;
}

/// The page's tooth: a fixed field of sub-pixel light specks plus a few short
/// fibres, so the dark wall has the texture of a real surface instead of the
/// flatness of a flat fill. (Under the light theme these were dark ink specks;
/// on the dark wall only the light ones survive, which is why both are still
/// generated and the ink pass is now almost invisible.)
///
/// Everything here is deterministic and static. One `math.Random` with a
/// constant seed builds the field **once per surface size** and the result is
/// cached, so no frame re-randomises a point — and every launch shows the same
/// paper. No image asset, no new dependency, no animation.
class _PaperGrainPainter extends CustomPainter {
  const _PaperGrainPainter();

  /// Two independent streams, so the ink and the raised tooth do not fall into
  /// one lattice and start reading as a pattern.
  static const _inkSeed = 20240613;
  static const _toothSeed = 19700101;

  /// Fine and even: one dot per ~10 logical px², i.e. ~36k dots on a 400x900
  /// screen, drawn in two `drawPoints` calls over the cached list.
  ///
  /// This was 1/16 (and much fainter) while the page was near-white, where a
  /// little grain was all the surface needed. On a dark wall the user's
  /// complaint was that it read as **flat black, with no material at all** —
  /// so the field is denser and brighter, and it is the light specks that carry
  /// it now (see [paint]).
  static const _dotsPerPx = 1 / 10;

  /// Ceiling for large windows (tablet/desktop) so the field stays one cheap
  /// pass whatever the surface.
  static const _maxDots = 40000;

  /// The hairs of the sheet. Enough of them to give the light something to catch
  /// at arm's length: this is the layer that reads as *paper* rather than as
  /// sensor noise, and it is the one the user was missing.
  static const _fibreCount = 190;

  /// The last field. Rebuilt only when the surface size changes (rotation or a
  /// window resize) — never per frame.
  static _PaperField? _field;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final field = _fieldFor(size);
    // Pass one — "ink": the shadow side of the grain, a *darker* speck. On the
    // dark wall it is almost invisible and that is correct: it only keeps the
    // field from being a uniform brightening.
    canvas.drawPoints(
      ui.PointMode.points,
      field.ink,
      Paint()
        ..color = const Color(0x1FEDF2EF)
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round,
    );
    // Pass two — "tooth": the raised fibres of a laid sheet, which is what makes
    // a surface feel soft rather than merely speckled. Six in a hundred, a touch
    // wider, and the brightest of the three layers.
    canvas.drawPoints(
      ui.PointMode.points,
      field.tooth,
      Paint()
        ..color = const Color(0x29EDF2EF)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
    // Pass three — the hairs. Long enough to catch the eye at a glance, faint
    // enough to never resolve into a pattern.
    final fibrePaint =
        Paint()
          ..color = const Color(0x1FEDF2EF)
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round;
    for (final fibre in field.fibres) {
      canvas.drawLine(fibre.from, fibre.to, fibrePaint);
    }
  }

  static _PaperField _fieldFor(Size size) {
    final cached = _field;
    if (cached != null && cached.size == size) return cached;

    final total = math.min(
      _maxDots,
      math.max(1, (size.width * size.height * _dotsPerPx).round()),
    );
    final inkRandom = math.Random(_inkSeed);
    final ink = List<Offset>.generate(
      total,
      (_) => Offset(
        inkRandom.nextDouble() * size.width,
        inkRandom.nextDouble() * size.height,
      ),
      growable: false,
    );
    final toothRandom = math.Random(_toothSeed);
    final tooth = List<Offset>.generate(
      total ~/ 6,
      (_) => Offset(
        toothRandom.nextDouble() * size.width,
        toothRandom.nextDouble() * size.height,
      ),
      growable: false,
    );
    // Fibres lie along the sheet: ±0.4 rad around horizontal, and they scale
    // gently with the surface so a tablet does not look like a phone's paper
    // blown up.
    final fibreRandom = math.Random(_inkSeed ^ _toothSeed);
    final scale = (size.shortestSide / 800).clamp(.6, 1.6);
    final fibres = List<_Fibre>.generate(_fibreCount, (_) {
      final from = Offset(
        fibreRandom.nextDouble() * size.width,
        fibreRandom.nextDouble() * size.height,
      );
      final angle = (fibreRandom.nextDouble() - .5) * .8;
      final reach = (4 + fibreRandom.nextDouble() * 14) * scale;
      return (
        from: from,
        to: from + Offset(math.cos(angle) * reach, math.sin(angle) * reach),
      );
    }, growable: false);

    return _field = _PaperField(
      size: size,
      ink: ink,
      tooth: tooth,
      fibres: fibres,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PhotoPage extends StatelessWidget {
  const _PhotoPage({
    required this.nextSlotText,
    required this.originalPhotoPath,
    required this.content,
    required this.date,
    required this.mode,
    required this.devices,
    required this.selectedDeviceId,
    required this.onDeviceChanged,
  });

  final String? nextSlotText;

  final String? originalPhotoPath;
  final DailyContent? content;
  final String? date;
  final BloomDisplayMode mode;
  final List<BloomDevice> devices;
  final String? selectedDeviceId;
  final ValueChanged<String> onDeviceChanged;

  /// The device whose photos this page shows. Falls back to this phone when
  /// nothing (or something unknown) is selected.
  BloomDevice? get _selected {
    for (final device in devices) {
      if (device.deviceId == selectedDeviceId) return device;
    }
    for (final device in devices) {
      if (device.isLocal) return device;
    }
    return null;
  }

  Future<void> _pickDevice(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      // The sheet is bottom-anchored, but a tall one (or a landscape cutout) can
      // still reach the top insets — let the framework keep it clear.
      useSafeArea: true,
      backgroundColor: BloomInk.panel,
      barrierColor: const Color(0x99000000),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(BloomSurface.radius),
        ),
      ),
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Text(
                    '选择设备',
                    style: TextStyle(
                      color: BloomInk.text,
                      fontSize: 22,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      fontFamily: BloomType.serifFamily,
                      fontFamilyFallback: BloomType.serifFallback,
                    ),
                  ),
                ),
                for (final device in devices)
                  ListTile(
                    key: ValueKey('bloom-device-option-${device.deviceId}'),
                    leading: Icon(
                      device.isFrame
                          ? Icons.devices_rounded
                          : Icons.phone_iphone_rounded,
                      size: 19,
                      color: BloomInk.textMuted,
                    ),
                    title: Text(device.name, style: BloomType.rowTitle),
                    subtitle: Text(
                      '${device.typeLabel} · ${device.presenceLabel}',
                      style: BloomType.meta,
                    ),
                    trailing:
                        device.deviceId == selectedDeviceId
                            ? const Icon(
                              Icons.check_rounded,
                              color: BloomInk.accent,
                            )
                            : null,
                    onTap: () => Navigator.pop(context, device.deviceId),
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
    );
    if (choice != null) onDeviceChanged(choice);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    // This app only holds its own device token, so it cannot load the frame's
    // photos (`/carousel/plan` needs a token belonging to that device). Show
    // the placeholder instead of pretending, and never touch the auth path.
    final remoteSelected = selected != null && !selected.isLocal;
    final hasPhoto = originalPhotoPath != null && !remoteSelected;
    final carousel = mode == BloomDisplayMode.carousel;
    return SafeArea(
      // [BloomSurface.pageInset] on the sides and on top: the same inset the
      // 设备 list page uses, and the one the page title below reads.
      minimum: const EdgeInsets.fromLTRB(
        BloomSurface.pageInset,
        BloomSurface.pageInset,
        BloomSurface.pageInset,
        0,
      ),
      child: Padding(
        // Clears the floating nav bar (72 + 14 margin) with a little slack.
        padding: const EdgeInsets.only(bottom: 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 首页, in the same type as 设备 and 照片: one shared component, so
            // the three titles cannot drift apart.
            const BloomPageTitle(title: '首页'),
            const SizedBox(height: BloomGlassHome.headerGap),
            // One row, two ends, and only one material per end.
            //
            // Left: what this page is showing — a read-only label, the plainest
            // thing on the screen. Right: the only control, held where a right
            // hand already is.
            //
            // The 下一张 button that used to sit here is gone at the user's
            // request: it was visible only in 轮播 mode (a mode the phone's own
            // widget is not usually in), and the carousel advances on its own
            // schedule anyway. [BloomGlassHome.onNext] is still wired for when
            // it comes back; nothing on this page calls it.
            Expanded(
              // **The alignment rule of this page lives here.**
              //
              // The letter card is an `AspectRatio(720/1200)` box, and on a tall
              // phone it is the *height* that runs out first — so the card comes
              // out narrower than the column and is centred, leaving a few px of
              // slack on each side. A header row pinned to the page inset would
              // therefore hang wider than the card under it, which is precisely
              // what the user could see. So the row's inset is derived from the
              // card's **real** width here, and both edges are guaranteed to
              // touch on any screen, any safe area and any aspect ratio.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const rowHeight = BloomInk.controlSize;
                  // The "next update" line sits under the card, inside the same
                  // width, so its height comes out of the card's budget — reserve
                  // it here or the column overflows on a short screen.
                  final nextSlot = remoteSelected ? null : nextSlotText;
                  const nextSlotGap = 8.0;
                  const nextSlotHeight = 15.0;
                  final cardBox = math.max(
                    0.0,
                    constraints.maxHeight -
                        rowHeight -
                        BloomGlassHome.cardGap -
                        (nextSlot == null ? 0.0 : nextSlotGap + nextSlotHeight),
                  );
                  // Same formula as `AspectRatio` itself: fill the width unless
                  // the height says otherwise (the card is portrait, 720x1200).
                  final cardWidth =
                      hasPhoto
                          ? math.min(
                            constraints.maxWidth,
                            cardBox * _LetterPhotoCard.aspectRatio,
                          )
                          : constraints.maxWidth;
                  final side = math.max(
                    0.0,
                    (constraints.maxWidth - cardWidth) / 2,
                  );
                  // The card is `AspectRatio`-locked, so on a screen where the
                  // width runs out first it is *shorter* than the box it is
                  // handed. Hanging the label off that box would then leave a
                  // stray gap; measure the card itself so the label sits exactly
                  // [nextSlotGap] under its bottom edge on every screen.
                  final cardHeight =
                      hasPhoto
                          ? math.min(
                            cardBox,
                            cardWidth / _LetterPhotoCard.aspectRatio,
                          )
                          : cardBox;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: rowHeight,
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: side),
                          child: Row(
                            // **Centred on the glyph, which is what the eye
                            // reads.** The control on the right is a bare icon
                            // in a 34px tap box, so bottom-aligning the two
                            // *boxes* left the reading sitting ~10px below the
                            // arrow and looking unaligned — the user caught it:
                            // "切换按钮还是正方形的，所以没有和推荐模式对齐". There is
                            // no visible box to align to any more, so the two
                            // glyphs share one centre line.
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // The label describes *this phone's* home-screen
                              // widget, so it is hidden while the dial points at
                              // another device: the local mirror says nothing
                              // about a frame.
                              if (!remoteSelected)
                                _ModeTag(
                                  key: const ValueKey('bloom-mode-tag'),
                                  carousel: carousel,
                                ),
                              const Spacer(),
                              BloomDeviceSwitch(
                                key: const ValueKey('bloom-device-switcher'),
                                deviceName: selected?.name ?? '手机小组件',
                                label: remoteSelected ? 'E-Ink' : '小组件',
                                onTap:
                                    devices.length > 1
                                        ? () => _pickDevice(context)
                                        : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Half of [headerGap]: see [cardGap].
                      const SizedBox(height: BloomGlassHome.cardGap),
                      SizedBox(
                        height: cardHeight,
                        // **Top, not centre.** The card's height comes from
                        // whichever of width/height runs out first; when the
                        // width does, the leftover height used to be split
                        // evenly above and below the card, so the gap under the
                        // mode row read as twice what it is. Pinned to the top,
                        // the gap is exactly [cardGap] on every screen — which
                        // is what the user was asking for twice.
                        child: Align(
                          alignment: Alignment.topCenter,
                          // **Top, not centre.** The card is aspect-locked to
                          // its width, so on a tall phone it comes out *shorter*
                          // than the box it is handed; a centred card therefore
                          // leaves half of the leftover height above it, and that
                          // is the "gap under the mode row" the user reported
                          // three times. My previous attempt wrapped an
                          // `Align(topCenter)` around this very `Center`, which
                          // re-centred the card and changed nothing at all.
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              width: cardWidth,
                              child:
                                  remoteSelected
                                      ? _RemoteDeviceCard(
                                        deviceName: selected.name,
                                      )
                                      : !hasPhoto
                                      ? const _PhotoLoadingCard()
                                      : _LetterPhotoCard(
                                        key: const ValueKey(
                                          'bloom-letter-card',
                                        ),
                                        imagePath: originalPhotoPath!,
                                        revision:
                                            '${mode.name}:${content?.recommendationId}:${content?.photo?.url}',
                                        content: content,
                                        fallbackDate: date,
                                      ),
                            ),
                          ),
                        ),
                      ),
                      if (nextSlot != null) ...[
                        const SizedBox(height: nextSlotGap),
                        SizedBox(
                          height: nextSlotHeight,
                          // Right-aligned to the **card**, not to the page: the
                          // card is centred with `side` px of slack on each edge,
                          // so the label carries the same inset.
                          child: Padding(
                            padding: EdgeInsets.only(right: side),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: nextSlot == null
                                  ? const SizedBox.shrink()
                                  : Text(
                                      nextSlot,
                                      key: const ValueKey('bloom-next-slot'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: BloomType.meta,
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The home page's read-only mode label: 推荐模式 / 轮播模式 and nothing else.
///
/// This replaces the old `_ModeStatusLine`, which had grown into a full second
/// header row ("手机小组件当前 · …" plus "在「设备」里可改"). The value is still
/// the one the phone's own home-screen widget uses — the local mirror
/// `bloom.display_mode`, *not* the server's record, which is what the device
/// detail page shows and edits — but the screen now states it as one short
/// label. The old widget's only logic was turning the mode into a glyph and a
/// colour, which is what is left here; the "pointed at another device" case is
/// handled by the caller hiding the tag (the mirror does not describe the
/// frame).
///
/// The user asked for its slip (a filled chip with a hairline) to go: what is
/// left is bare text on the wall, one step fainter than everything else. No
/// fill, no border, no lift — nothing that could be mistaken for a control,
/// which is also why there is no ripple and no touch target. That contrast is
/// what makes the row legible: this end is the only thing on it that is *not* a
/// control.
/// The small glyph keeps 推荐 (sparkle) apart from 轮播 (shuffle) at a glance and
/// anchors the left end of the row; it is decorative, so it sits a step back.
class _ModeTag extends StatelessWidget {
  const _ModeTag({super.key, required this.carousel});

  final bool carousel;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        bloomModeIcon(
          carousel
              ? BloomDisplayMode.carousel
              : BloomDisplayMode.recommendation,
        ),
        size: 14,
        color: BloomInk.textMuted,
      ),
      const SizedBox(width: 5),
      Text(
        bloomModeLabel(
          carousel
              ? BloomDisplayMode.carousel
              : BloomDisplayMode.recommendation,
        ),
        maxLines: 1,
        // The tracked meta step ([BloomType.labelStrong]): the label now anchors
        // the *left* end of the row, so it has to read as a label rather than
        // as the beginning of a sentence.
        style: BloomType.labelStrong,
      ),
    ],
  );
}

/// The 照片 tab until the photo library lands: an empty state and nothing else.
/// It intentionally carries none of the removed playback features.
///
/// The structure is the competitor's (a line-art object, a title, one line of
/// explanation, no card around any of it): an empty page is a **designed**
/// page, and a glass panel with an icon in it reads as a placeholder for
/// something that failed to load.
class _PhotoLibraryPlaceholderPage extends StatelessWidget {
  const _PhotoLibraryPlaceholderPage();

  @override
  Widget build(BuildContext context) => SafeArea(
    // Same inset as the 设备 list page, and the title is the same component.
    minimum: const EdgeInsets.fromLTRB(
      BloomSurface.pageInset,
      BloomSurface.pageInset,
      BloomSurface.pageInset,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const BloomPageTitle(title: '照片'),
        // The 设备 page's own title→content gap, so the two list-style pages
        // breathe identically.
        const SizedBox(height: BloomPageTitle.contentGap),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 96),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A sheet of paper inside a frame: the same object the home
                  // card is, drawn empty. Two hairlines instead of an icon in a
                  // box is the whole "illustration".
                  Container(
                    width: 96,
                    height: 118,
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: BloomInk.panel,
                      borderRadius: BorderRadius.circular(
                        BloomSurface.innerRadius,
                      ),
                      // The one place a line is right: this is a drawing of a
                      // picture frame, not a card.
                      border: Border.all(
                        color: BloomInk.textMuted.withValues(alpha: .5),
                        width: 1.5,
                      ),
                      boxShadow: BloomInk.lift,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: BloomInk.recess,
                        borderRadius: BorderRadius.circular(
                          BloomSurface.innerRadius,
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.photo_outlined,
                          size: 26,
                          color: BloomInk.textFaint,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text('照片库即将上线', style: BloomType.rowTitle),
                  const SizedBox(height: 8),
                  const Text(
                    '以后可以在这里回看每天推荐过的照片。',
                    textAlign: TextAlign.center,
                    style: BloomType.body,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Shown when the switcher points at the frame: the app has no frame token, so
/// its photos need a user session (F1) that does not exist yet.
class _RemoteDeviceCard extends StatelessWidget {
  const _RemoteDeviceCard({required this.deviceName});

  final String deviceName;

  @override
  Widget build(BuildContext context) => Center(
    child: BloomPanel(
      lifted: true,
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.lock_outline_rounded,
            size: 28,
            color: BloomInk.textMuted,
          ),
          const SizedBox(height: 12),
          const Text(
            '登录后可查看此设备的照片',
            textAlign: TextAlign.center,
            style: BloomType.rowTitle,
          ),
          const SizedBox(height: 8),
          Text(
            '“$deviceName”拍下的照片需要账号登录后才能查看（后续版本支持）。'
            '手机小组件仍会按照当前节奏正常更新。',
            textAlign: TextAlign.center,
            style: BloomType.body,
          ),
        ],
      ),
    ),
  );
}

class _LetterPhotoCard extends StatelessWidget {
  const _LetterPhotoCard({
    super.key,
    required this.imagePath,
    required this.revision,
    required this.content,
    required this.fallbackDate,
  });

  final String imagePath;
  final Object revision;
  final DailyContent? content;
  final String? fallbackDate;

  /// The card's own proportions: a 720x1200 poster.
  ///
  /// Exposed so the page can derive the card's width — and from it the header
  /// row's inset — from the very number the card is laid out with. One source,
  /// two callers, which is what keeps the two edges aligned.
  static const aspectRatio = 720 / 1200;

  @override
  Widget build(BuildContext context) {
    final fx = (content?.photo?.focusX ?? .5).clamp(0.0, 1.0);
    final fy = (content?.photo?.focusY ?? .45).clamp(0.0, 1.0);
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(27),
          boxShadow: const [
            BoxShadow(
              color: Color(0x78000000),
              blurRadius: 30,
              spreadRadius: 1,
              offset: Offset(0, 14),
            ),
            BoxShadow(
              color: Color(0x243E5B54),
              blurRadius: 26,
              offset: Offset(0, -3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(27),
          child: AnimatedSwitcher(
            // **A cross-fade, not a blink.** The old photo used to be swapped for
            // the new one in a single frame — and because the new file still had
            // to be decoded, what the eye caught was a flash of nothing. Letting
            // the two overlap removes both the blink and the empty frame.
            duration: const Duration(milliseconds: 480),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder:
                (currentChild, previousChildren) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                ),
            // **Keyed by the item, so the fade runs only when the picture really
            // changes** — a rebuild that re-renders the same item (a sync
            // landing, the label ticking, the backdrop updating) must not
            // animate it again. And the *whole* card fades, photo and words
            // together: the two can never be seen from different items.
            child: Column(
              key: ValueKey(content?.recommendationId ?? imagePath),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: Image.file(
                    File(imagePath),
                    fit: BoxFit.cover,
                    alignment: Alignment(fx * 2 - 1, fy * 2 - 1),
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => const _LetterPhotoFallback(),
                  ),
                ),
                Expanded(
                  child: _LetterPaper(
                    content: content,
                    fallbackDate: fallbackDate,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LetterPaper extends StatelessWidget {
  const _LetterPaper({required this.content, required this.fallbackDate});

  final DailyContent? content;
  final String? fallbackDate;

  @override
  Widget build(BuildContext context) {
    final rawZh = content?.captionZh?.trim() ?? '';
    final zh =
        '「${(rawZh.isEmpty ? '今天，也值得看一眼。' : rawZh).replaceAll(RegExp(r'^[「」]|[「」]$'), '')}」';
    final rawEn = content?.captionEn?.trim() ?? '';
    final en = rawEn.replaceFirst(RegExp(r'^[—–-]\s*'), '');
    final date = content?.capturedDateText?.trim();
    final location = content?.locationText?.trim();
    final showEnglish = en.isNotEmpty && zh.runes.length <= 19;
    return CustomPaint(
      painter: const _PaperTexturePainter(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 132;
          final horizontal = constraints.maxWidth * .072;
          final gap = compact ? 5.0 : 7.0;
          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontal,
              constraints.maxHeight * .075,
              horizontal,
              constraints.maxHeight * .06,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  zh,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: const Color(0xff292929),
                    fontSize: compact ? 17 : 19,
                    height: 1.05,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'BloomHandwriting',
                  ),
                ),
                if (showEnglish) ...[
                  SizedBox(height: gap),
                  Text(
                    '— $en',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xff4A4A4A),
                      fontSize: compact ? 10.5 : 11.5,
                      height: 1,
                      fontFamily: 'BloomHandwriting',
                    ),
                  ),
                ],
                SizedBox(height: gap),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        (date == null || date.isEmpty)
                            ? (fallbackDate ?? '')
                            : date,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xff74706A),
                          fontSize: compact ? 10 : 11,
                          height: 1,
                          fontFamily: 'BloomHandwriting',
                        ),
                      ),
                    ),
                    if (location != null && location.isNotEmpty)
                      Expanded(
                        child: Text(
                          location,
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: const Color(0xff74706A),
                            fontSize: compact ? 10 : 11,
                            height: 1,
                            fontFamily: 'BloomHandwriting',
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PaperTexturePainter extends CustomPainter {
  const _PaperTexturePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, const [
          Color(0xffFAF7EF),
          Color(0xffF1ECE0),
        ]),
    );
    final random = math.Random(
      1701 + size.width.round() * 7 + size.height.round(),
    );
    final cloud =
        Paint()
          ..color = const Color(0x0D7C705F)
          ..maskFilter = ui.MaskFilter.blur(
            ui.BlurStyle.normal,
            size.height * .025,
          );
    for (var i = 0; i < 14; i++) {
      final center = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: center,
          width: size.width * (.08 + random.nextDouble() * .16),
          height: size.height * (.06 + random.nextDouble() * .14),
        ),
        cloud,
      );
    }
    final grain = Paint()..color = const Color(0x181B1711);
    final fiber =
        Paint()
          ..color = const Color(0x185F574B)
          ..strokeWidth = .65;
    final count = (size.width * size.height / 520).round().clamp(90, 260);
    for (var i = 0; i < count; i++) {
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        .25 + random.nextDouble() * .55,
        grain,
      );
    }
    for (var i = 0; i < 30; i++) {
      final y = random.nextDouble() * size.height;
      final x = random.nextDouble() * size.width * .82;
      final length = 9 + random.nextDouble() * 34;
      canvas.drawLine(Offset(x, y), Offset(x + length, y + .3), fiber);
    }
    final seamHeight = math.max(6.0, size.height * .045);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, seamHeight),
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          Offset(rect.center.dx, seamHeight),
          const [Color(0x290D0B08), Color(0x000D0B08)],
        ),
    );
    canvas.drawLine(
      Offset.zero,
      Offset(size.width, 0),
      Paint()
        ..color = const Color(0x70FFFDF8)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LetterPhotoFallback extends StatelessWidget {
  const _LetterPhotoFallback();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xffD8D2C7),
    child: Center(
      child: Icon(Icons.photo_outlined, color: Color(0xff817A70), size: 36),
    ),
  );
}

class _BindingCheckExperience extends StatelessWidget {
  const _BindingCheckExperience();

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: BloomAtmosphere(
      child: SafeArea(
        minimum: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The wordmark is the only serif on a splash, and the only place
              // the app shouts: everything below it is a label.
              const Text(
                'Bloom',
                style: TextStyle(
                  color: BloomInk.text,
                  fontSize: 34,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  fontFamily: BloomType.serifFamily,
                  fontFamilyFallback: BloomType.serifFallback,
                ),
              ),
              const SizedBox(height: 9),
              const Text('把记忆留在每天看得见的地方', style: BloomType.body),
              const SizedBox(height: 30),
              BloomPanel(
                lifted: true,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: const SizedBox(
                  width: 286,
                  height: 108,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 27,
                        height: 27,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: BloomInk.accent,
                        ),
                      ),
                      SizedBox(width: 17),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('正在连接 Bloom', style: BloomType.rowTitle),
                            SizedBox(height: 7),
                            Text('正在确认设备绑定状态…', style: BloomType.meta),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PairingExperience extends StatelessWidget {
  const _PairingExperience({
    required this.loading,
    required this.pairingRefreshing,
    required this.credentials,
    required this.pairing,
    required this.message,
    required this.onRefreshPairingCode,
    required this.onCopyDeviceId,
    required this.onCopyPairingCode,
  });

  final bool loading;
  final bool pairingRefreshing;
  final DeviceCredentials? credentials;
  final PairingInfo? pairing;
  final String? message;
  final VoidCallback onRefreshPairingCode;
  final VoidCallback onCopyDeviceId;
  final VoidCallback onCopyPairingCode;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: BloomAtmosphere(
      child: SafeArea(
        minimum: const EdgeInsets.all(20),
        child: Center(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  const Text(
                    'Bloom',
                    style: TextStyle(
                      color: BloomInk.text,
                      fontSize: 34,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      fontFamily: BloomType.serifFamily,
                      fontFamilyFallback: BloomType.serifFallback,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('把记忆留在每天看得见的地方', style: BloomType.body),
                  const SizedBox(height: 28),
                  BloomPanel(
                    lifted: true,
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('连接 Bloom', style: BloomType.rowTitle),
                        const SizedBox(height: 8),
                        const Text(
                          '打开 bloom.jihu.top，在“设备管理”中输入设备 ID 和绑定码。',
                          style: TextStyle(
                            color: BloomInk.textMuted,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 22),
                        _PairingValue(
                          label: '设备 ID',
                          value:
                              credentials?.deviceId ??
                              (loading ? '正在准备设备标识…' : '暂时不可用'),
                          onCopy: credentials == null ? null : onCopyDeviceId,
                        ),
                        const SizedBox(height: 18),
                        _PairingValue(
                          label: '绑定码',
                          value:
                              pairing?.code ?? (loading ? '正在获取…' : '点击下方重新生成'),
                          emphasized: pairing != null,
                          onCopy: pairing == null ? null : onCopyPairingCode,
                        ),
                        const SizedBox(height: 20),
                        // The only action on this screen, so it carries the
                        // app's single accent.
                        BloomPrimaryButton(
                          label: '重新生成绑定码',
                          icon: Icons.refresh_rounded,
                          loadingLabel: '正在生成绑定码…',
                          loading: pairingRefreshing,
                          onPressed:
                              pairingRefreshing ? null : onRefreshPairingCode,
                        ),
                      ],
                    ),
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 14),
                    BloomMessage(message: message!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PairingValue extends StatelessWidget {
  const _PairingValue({
    required this.label,
    required this.value,
    this.emphasized = false,
    this.onCopy,
  });

  final String label;
  final String value;
  final bool emphasized;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: BloomType.meta),
      const SizedBox(height: 7),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: BloomInk.text,
                fontSize: emphasized ? 30 : 14,
                letterSpacing: emphasized ? 5 : 0,
                fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
          if (onCopy != null)
            _PlainIconButton(icon: Icons.copy_rounded, onTap: onCopy),
        ],
      ),
    ],
  );
}

/// The app's ink: warm white type on a warm-black wall.
///
/// The name is historical — the app's material used to be paper. It is now
/// **ink on a dark wall**, and the only sheet of paper left in the product is
/// the letter card on the home page (which is deliberately untouched: it has to
/// match the home-screen widget). Every colour in the app comes from here; a
/// screen that invents its own grey is what made the palette drift.
abstract final class BloomInk {
  /// The page. A **grey-green** near-black — the hue the reference's own
  /// background is built from — and never `#000`: pure black reads as a hole on
  /// OLED, and the user's complaint about the first dark build was exactly that
  /// it had "no material, just black". A wall with a hue can catch light; a
  /// hole cannot.
  static const page = Color(0xFF1D2427);
  static const pageBottom = Color(0xFF0C1012);

  /// The card: **soft black** — the wall's own hue, taken a step *down*.
  ///
  /// It went white (paper), then pure black (`#000000`, the reference's own
  /// move), and that was one step too far: against a wall which is itself a
  /// gradient, a void-black card reads as a hole rather than as a sheet, and the
  /// user felt it immediately ("这个背景色的黑实在是太黑了，有点儿没那么协调").
  ///
  /// This is the wall's cool green-black (#1D2427 → #0C1012) darkened and
  /// desaturated just enough to sit below it at the top of the screen and above
  /// it at the bottom, so the card's silhouette comes from the lit top edge and
  /// the shadow rather than from raw contrast. The brightest surface in the app
  /// is still unique: the home page's letter card.
  static const panel = Color(0xFF15191B);

  /// A **recess**: a trough, a slot, an input — anything that should read as
  /// hollow instead of raised. The yin to [panel]'s yang, and the app's second
  /// depth cue after the lit top edge.
  /// A **trough cut into a card**, or a group sitting on the wall.
  ///
  /// On a black card nothing can be darker, so a well is a step *up* from the
  /// card instead — the one place in this app where "inset" is lighter than its
  /// container. It is the only way a form field can be visible inside black.
  static const recess = Color(0xFF191C1E);

  /// The hairline between two rows. On a dark page this is the only kind of
  /// "border" the app draws, and it is always a separator, never a frame.
  static const divider = Color(0xFF333B3D);

  /// Primary text: an almost-neutral white with the faintest cool cast, matched
  /// to the wall's green rather than to the letter card's warmth — that
  /// difference is what separates "the interface" from "the photograph".
  /// Never `#FFF`: pure white on near-black glares and cheapens the page.
  static const text = Color(0xFFEDF2EF);

  /// Secondary text: the same warm white at 62%.
  static const textMuted = Color(0x9EEDF2EF);

  /// Tertiary: group labels, chevrons, hints — 38%.
  static const textFaint = Color(0x61EDF2EF);

  /// The ink that goes **on** [accent]: the primary button's label. The sage is
  /// a light colour, so its text is near-black rather than near-white.
  static const inverseInk = Color(0xFF121614);

  /// The app's one chroma: a **muted grey-green** (鼠尾草绿), taken from the
  /// reference the user pointed at. It is deliberately low-saturation — a bright
  /// green would be a toy, a grey one is an instrument — and it is used in
  /// exactly two places: live state (the online dot) and the current selection
  /// (the lit dot on the device dial, the selected segment).
  static const accent = Color(0xFF8FA99C);

  /// The app's only red: a *closed* presence dot. Deliberately rust rather than
  /// a signal red — it means "asleep", not "broken" — and it never appears
  /// anywhere except next to a device that is off.
  static const offline = Color(0xFFA6604F);

  /// The same green, taken down to a *fill*: a selected tab, a tinted slot. The
  /// accent itself is too light to sit under white text.
  static const accentDeep = Color(0xFF2C3A34);

  /// A control that needs an edge on a dark page gets a hairline of light rather
  /// than a filled box: `rgba(242,238,230,.24)`.
  static const controlEdge = Color(0x3DEDF2EF);

  /// The shadow under anything raised. **Two layers**, always: a tight contact
  /// shadow and a wide diffuse one. On a near-black wall a shadow can only be
  /// seen if the wall itself has some light in it — which is the real reason the
  /// first dark build's cards looked flat ("整体显得 low"): the wall was
  /// `#0A0C0B` and the shadow simply had nowhere to fall.
  static const lift = <BoxShadow>[
    BoxShadow(color: Color(0x59000000), blurRadius: 4, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x73000000), blurRadius: 20, offset: Offset(0, 7)),
  ];

  /// Every header control is this square: the device dial, the 扫码 action. One
  /// number, so the two ends of a header row cannot disagree about its height.
  static const controlSize = 34.0;
}

/// The geometry the app is allowed to use.
abstract final class BloomSurface {
  /// **5px, everywhere.** The app is right-angled rectangles with a hint of a
  /// corner. Two exceptions, both deliberate: the letter card (27 — it is a
  /// photograph and must match the home-screen widget) and the nav bar's pill.
  static const radius = 5.0;

  /// A block inside a row (an icon tile).
  static const innerRadius = 3.0;

  /// A control: the device switcher, a button, a chip.
  static const controlRadius = 5.0;

  /// A list row's minimum height, so the type always has air around it.
  static const rowHeight = 56.0;

  /// The page's horizontal inset — and the **single source** of the home page's
  /// alignment: the header row and the letter card both read it, which is what
  /// stops the row from hanging 6px wider than the card under it.
  static const pageInset = 16.0;

  /// Grouped rows are separated by a hairline that starts where the text does:
  /// the row's 16 padding + its 28px glyph + the 12 gap.
  static const rowDividerIndent = 56.0;
}

/// The type scale.
///
/// Three rules, all taken from the reference app:
/// 1. **Two families.** Serif for display; the system sans for everything else.
/// 2. **Almost nothing is bold.** Body and rows are regular; only a display
///    title, a button and a read-out value take weight. The old build wrote
///    w600/w700 on nearly every line, and that — not the sizes — is what made
///    the app look heavy and unrefined.
/// 3. **Small text is tracked, not bolded.** Labels are 11px with 1.1 of
///    letter spacing; Latin labels are written in caps at the call site.
abstract final class BloomType {
  /// **The whole app is one serif.** Not just the display text any more: the
  /// user's note was that the sans ladder did not match the app's tone ("这个
  /// 字体不太符合咱们的调性… 你找一个艺术气息比较重、比较符合的"), and an ink/paper
  /// frame app has no business setting its captions in Roboto.
  ///
  /// No font file is bundled: iOS ships 宋体 (Songti SC) and Android ships a
  /// Noto Serif CJK on most builds, so the family is requested by name and the
  /// fallback list keeps the text rendering (in the platform's default face)
  /// when a build has none. Bundling a subset later — EB Garamond for the Latin
  /// and 思源宋体 for the CJK — means editing the two constants below and nothing
  /// else, which is exactly why the ladder goes through them.
  /// **霞鹜文楷 (LXGW WenKai)**, bundled at `assets/fonts/`.
  ///
  /// The request was for something with an artist's hand — "艺术气息比较重" — and
  /// explicitly *not* 思源宋体. WenKai is a kai (楷) face: brush-derived strokes,
  /// a calligraphic tilt, and — the reason it wins over pairing two fonts — its
  /// own Latin and numerals come from the same pen (Fontworks Klee), so the
  /// digits and the Chinese finally belong to one another.
  ///
  /// Requesting system families by name did not work on the user's phone: iOS
  /// and macOS know 宋体 by name, Android does not, so the Chinese silently fell
  /// back to the default sans while the Latin turned serif. A bundled file
  /// removes the guesswork on every platform.
  static const serifFamily = 'BloomSerif';
  static const serifFallback = <String>[
    'BloomSerif',
    'LXGW WenKai',
    'Songti SC',
    'serif',
  ];

  /// 首页 / 照片 / 设备. 30 → **26** with the serif: the reference app's titles
  /// are large but light, never large and heavy.
  static const pageTitle = TextStyle(
    color: BloomInk.text,
    fontSize: 26,
    height: 1.3,
    fontWeight: FontWeight.w600,
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
  );

  /// A row's own name (a device, a section). Regular weight: a row is identified
  /// by its position and its label, not by shouting.
  static const rowTitle = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.text,
    fontSize: 15,
    height: 1.25,
    fontWeight: FontWeight.w500,
    letterSpacing: .1,
  );

  /// A **tile's** own name (a device card).
  ///
  /// The one place a row-level item is allowed to be display-sized, and it comes
  /// straight from the reference the user pointed at: a filled tile puts a tiny
  /// meta line at the top and the name in large type at the bottom. The contrast
  /// between this and [meta] is what makes a tile read as a tile instead of as a
  /// list row.
  static const tileTitle = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.text,
    fontSize: 24,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -.2,
  );

  /// The title of the page's one primary sheet (刷新节奏).
  ///
  /// The top rung of the in-page ladder: 18 (this) · 16 [value] · 15 [rowTitle]
  /// · 13.5 [body] · 11.5 [meta] / 11 [label]. Every screen belongs to one
  /// subject, and this is how the subject announces itself.
  static const sectionTitle = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.text,
    fontSize: 18,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -.2,
  );

  /// A form field's own label, sitting **above** its control.
  static const fieldLabel = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.textFaint,
    fontSize: 11,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.2,
  );

  /// The tracked label step: a group header, the mode reading, a section name.
  /// Latin belongs in caps at the call site.
  static const label = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.textFaint,
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
  );

  /// The same step, one notch brighter, for a label that carries a value.
  static const labelStrong = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.textMuted,
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
  );

  /// A row's second line: a type, a state, a date.
  static const meta = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.textMuted,
    fontSize: 11.5,
    height: 1.25,
    fontWeight: FontWeight.w400,
    letterSpacing: .3,
  );

  /// Running text: an explanation under a panel, an error, a hint.
  static const body = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.textMuted,
    fontSize: 13.5,
    height: 1.55,
    fontWeight: FontWeight.w400,
  );

  /// A read-out the user came for (a time, a value).
  static const value = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.text,
    fontSize: 16,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  /// A code the user has to read out loud (a device id, a pairing code).
  static const code = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    color: BloomInk.text,
    fontSize: 24,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 3,
  );

  /// A button's label.
  static const button = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    fontSize: 15,
    height: 1,
    fontWeight: FontWeight.w600,
    letterSpacing: .3,
  );
}

/// A panel's surface: a warm-black sheet on the dark page.
///
/// The dark-page twin of the letter's [_PaperTexturePainter]: a barely-there
/// vertical fall (lighter at the top), a whisper of *light* grain, and the same
/// 1px lit edge along the top that a real sheet catches from above. On a dark
/// page the grain has to be light rather than dark, which is why this is its own
/// painter instead of a parameter on the other one.
class _PanelPainter extends CustomPainter {
  const _PanelPainter({required this.fill, required this.lit});

  /// The surface's own colour. Anything other than [BloomInk.panel] (a trough, a
  /// group, an alert) is painted flat: those are *wells* and *tints*, not cards.
  final Color fill;

  /// Whether this surface is **raised** — a card. Only a card gets the lit top
  /// edge and the shaded lower lip; a well is the same material with no edges at
  /// all. That pair of 1px lines is now the entire difference between the two,
  /// which is why the page can be all-black cards and still have a subject.
  final bool lit;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = fill);

    // Only a **card** carries the tooth; a trough inside one does not (two
    // grains stacked is a moiré, not a material).
    if (fill != BloomInk.panel) return;

    // **Flat**, and no gradient: the user asked for pure black cards, and a card
    // that fades is a card that was never black. Its material is the tooth below
    // plus the two edges, not a wash.
    final random = math.Random(
      901 + size.width.round() * 13 + size.height.round(),
    );
    final speck = Paint()..color = const Color(0x14EDF2EF);
    final count = (size.width * size.height / 2200).round().clamp(30, 110);
    for (var i = 0; i < count; i++) {
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        .2 + random.nextDouble() * .4,
        speck,
      );
    }
    final fibre =
        Paint()
          ..color = const Color(0x12EDF2EF)
          ..strokeWidth = .6;
    for (var i = 0; i < 10; i++) {
      final y = random.nextDouble() * size.height;
      final x = random.nextDouble() * size.width * .82;
      canvas.drawLine(
        Offset(x, y),
        Offset(x + 9 + random.nextDouble() * 24, y + .3),
        fibre,
      );
    }

    if (!lit) return;

    // The lit top edge: on a black card this single 1px line is what makes it
    // read as a surface catching the light rather than as a hole in the wall.
    canvas.drawLine(
      Offset.zero,
      Offset(size.width, 0),
      Paint()
        ..color = const Color(0x33EDF2EF)
        ..strokeWidth = 1,
    );
    // ...and a shaded bottom edge. Light comes from above, so the sheet's lower
    // lip is the one that turns away from it — the pair is what gives the panel
    // a thickness instead of a fill.
    canvas.drawLine(
      Offset(0, size.height - .5),
      Offset(size.width, size.height - .5),
      Paint()
        ..color = const Color(0x4D000000)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _PanelPainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.lit != lit;
}

/// A panel: one warm-black sheet lying on the dark page.
///
/// **[lifted] is the only decision a caller makes.** It is reserved for the one
/// block that owns its screen (刷新节奏, the pairing card); a panel that is
/// merely a section takes no shadow at all, because on a dark page a shadow
/// reads as a smudge and the sheet's lit top edge (painted by [_PanelPainter])
/// already does the separating.
///
/// There is no border parameter on purpose: on this page a line is only ever a
/// *separator between rows* ([BloomRowDivider]), never a frame.
class BloomPanel extends StatelessWidget {
  const BloomPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = BloomSurface.radius,
    this.lifted = false,
    this.color = BloomInk.panel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool lifted;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final corners = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        boxShadow: lifted ? BloomInk.lift : null,
      ),
      child: ClipRRect(
        borderRadius: corners,
        // The fill is the painter's job, not a `ColoredBox` behind it: a solid
        // box would paint over the grain and leave the panel flat again.
        child: CustomPaint(
          painter: _PanelPainter(fill: color, lit: lifted),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// The hairline between two rows. The app's only line.
///
/// It starts where the row's *text* starts (not at the panel edge), which is
/// what makes a list read as a list instead of as a table.
class BloomRowDivider extends StatelessWidget {
  const BloomRowDivider({
    super.key,
    this.indent = BloomSurface.rowDividerIndent,
  });

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: indent),
    child: const Divider(height: 1, thickness: 1, color: BloomInk.divider),
  );
}

/// The one primary action on a screen: a warm-white bar with ink on it.
///
/// On a dark wall an inverted bar is the strongest shape available — stronger
/// than any colour — which is why the app needs no coloured button at all. It
/// is the reference app's `Add Canvas`, inverted for ink.
class BloomPrimaryButton extends StatelessWidget {
  const BloomPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.loadingLabel,
    this.loading = false,
    this.onPressed,
  });

  final String label;

  /// Optional leading glyph. A label alone is the default: an icon on a button
  /// whose meaning is already a verb only repeats it.
  final IconData? icon;
  final String? loadingLabel;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final corners = BorderRadius.circular(BloomSurface.controlRadius);
    final icon = this.icon;
    return Opacity(
      opacity: enabled || loading ? 1 : .4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // **The theme colour is the action colour.** The user picked the sage
          // out of the mode selector's selected tab and asked for it to be the
          // app's colour; a filled bar is the strongest statement the app can
          // make, so this is where it belongs. It also settles the old
          // inconsistency they called out: 保存 was a filled bar while 生成新的
          // 激活码 was a hairline outline, so two actions of the same kind looked
          // like two different kinds of thing.
          color: BloomInk.accent,
          borderRadius: corners,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: corners,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: corners,
            splashColor: const Color(0x14000000),
            highlightColor: const Color(0x0A000000),
            child: SizedBox(
              height: 52,
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
                                color: Color(0x99121614),
                              ),
                            ),
                            const SizedBox(width: 9),
                            Text(
                              loadingLabel ?? '正在处理…',
                              style: BloomType.button.copyWith(
                                color: const Color(0x99121614),
                              ),
                            ),
                          ],
                        )
                        : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (icon != null) ...[
                              Icon(icon, size: 18, color: BloomInk.inverseInk),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              label,
                              style: BloomType.button.copyWith(
                                color: BloomInk.inverseInk,
                              ),
                            ),
                          ],
                        ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shared shell of a control on the dark wall: optional fill, optional
/// hairline of light, and an ink ripple that stays inside the slip.
class _Slip extends StatelessWidget {
  const _Slip({
    required this.child,
    required this.height,
    this.width,
    this.onTap,
    this.edge = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  final Widget child;
  final double height;
  final double? width;
  final VoidCallback? onTap;

  /// The 1px hairline of light. Off for the header controls, which the user
  /// wanted reduced to *just a glyph* on the bare wall — see [BloomDeviceSwitch]
  /// and [BloomIconButton].
  final bool edge;
  final EdgeInsetsGeometry padding;

  /// A ripple of *light*, because everything it runs over is dark.
  static const splash = Color(0x14EDF2EF);
  static const highlight = Color(0x0AEDF2EF);

  @override
  Widget build(BuildContext context) {
    final corners = BorderRadius.circular(BloomSurface.controlRadius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        border: edge ? Border.all(color: BloomInk.controlEdge) : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: corners,
        child: InkWell(
          onTap: onTap,
          borderRadius: corners,
          splashColor: splash,
          highlightColor: highlight,
          child: Container(
            height: height,
            width: width,
            padding: padding,
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The device switch: the header's only control, reduced to one bare glyph.
///
/// **No box, no border.** The user's note after living with the previous two
/// versions — a labelled chip, then a bordered dial — was that the control was
/// still too loud for what it does, and asked for "just an icon, the kind used
/// for switching". So this is the most conventional glyph there is for the job,
/// at full ink, with nothing drawn around it.
///
/// It stays findable as a control by position (it is alone in the top-right
/// corner of a page), by the ripple under the finger, and by the tooltip and
/// accessibility label, which is also where the selected device's name lives
/// now that no text is drawn.
class BloomDeviceSwitch extends StatelessWidget {
  const BloomDeviceSwitch({
    super.key,
    required this.deviceName,
    required this.label,
    this.onTap,
  });

  /// The device this control currently points at. Not drawn: the name is the
  /// tooltip and the accessibility label, and it is spelled out in full on every
  /// row of the sheet that opens.
  final String deviceName;

  /// **The word on the control itself**: `小组件` while it points at this phone,
  /// `E-Ink` while it points at the frame. An icon alone left the reader guessing
  /// what the two arrows were switching between.
  final String label;

  final VoidCallback? onTap;

  /// Both arrows, opposite directions: "move between the things in this set".
  /// Not a phone, not a monitor, not a chevron — nothing that could be mistaken
  /// for a picture of the hardware or for "open a menu".
  static const glyph = Icons.swap_horiz_rounded;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: deviceName,
    decoration: BoxDecoration(
      color: BloomInk.panel,
      borderRadius: BorderRadius.circular(BloomSurface.controlRadius),
      border: Border.all(color: BloomInk.controlEdge),
    ),
    textStyle: BloomType.meta.copyWith(color: BloomInk.text),
    child: Semantics(
      button: true,
      label: '切换设备，当前 $deviceName',
      child: _Slip(
        height: BloomInk.controlSize,
        edge: false,
        onTap: onTap,
        // The whole slip is the target, word and glyph together — the row sizes
        // itself around them instead of the old fixed 34px square.
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, maxLines: 1, style: BloomType.labelStrong),
            const SizedBox(width: 6),
            const Icon(glyph, size: 20, color: BloomInk.text),
          ],
        ),
      ),
    ),
  );
}

/// An icon-only control of the same shape as the switcher.
class BloomIconButton extends StatelessWidget {
  const BloomIconButton({
    super.key,
    required this.icon,
    required this.loading,
    required this.onTap,
    this.edge = false,
  });

  final IconData icon;
  final bool loading;
  final VoidCallback? onTap;

  /// `false` (the default) leaves the bare glyph, which is what the 设备 page's
  /// header actions are.
  final bool edge;

  @override
  Widget build(BuildContext context) => _Slip(
    height: BloomInk.controlSize,
    width: BloomInk.controlSize,
    edge: edge,
    onTap: onTap,
    padding: EdgeInsets.zero,
    child: Center(
      child:
          loading
              ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.7,
                  color: BloomInk.accent,
                ),
              )
              : Icon(icon, size: 17, color: BloomInk.text),
    ),
  );
}

class _PhotoLoadingCard extends StatefulWidget {
  const _PhotoLoadingCard();

  @override
  State<_PhotoLoadingCard> createState() => _PhotoLoadingCardState();
}

class _PhotoLoadingCardState extends State<_PhotoLoadingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BloomPanel(
    // Stands in for the letter card, which is the one surface on this page that
    // really does float: the page must not change its idea of depth between
    // "loading" and "loaded".
    lifted: true,
    padding: const EdgeInsets.all(20),
    child: AnimatedBuilder(
      animation: _controller,
      builder:
          (context, _) => Opacity(
            opacity: .42 + _controller.value * .28,
            child: const _SkeletonBody(),
          ),
    ),
  );
}

class _SkeletonBody extends StatelessWidget {
  const _SkeletonBody();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SkeletonLine(widthFactor: .78, height: 16),
      SizedBox(height: 12),
      _SkeletonLine(widthFactor: .92, height: 10),
      SizedBox(height: 10),
      _SkeletonLine(widthFactor: .48, height: 10),
    ],
  );
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.widthFactor, required this.height});

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: widthFactor,
    child: Container(
      height: height,
      decoration: BoxDecoration(
        color: const Color(0x14EDF2EF),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// The one page title in the app: 设备, 首页 and 照片 all render this exact
/// widget, so their type ([BloomType.pageTitle]: the serif face, 26, w600, warm
/// white) and their gap to the content cannot drift apart.
///
/// The page owns no padding of its own; the *inset* comes from
/// [BloomSurface.pageInset], which every page — and the letter card — reads, so
/// all three titles start on exactly the same left edge as the content under
/// them. That constant is the fix for the header that used to hang wider than
/// the card below it.
class BloomPageTitle extends StatelessWidget {
  const BloomPageTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;

  /// Optional: 设备 carries one ("管理相框和手机小组件"), 首页 and 照片 state the
  /// tab's name and stop — no copy was invented for them. A missing subtitle
  /// also removes its gap, so a title-only page is not left with a hole.
  final String? subtitle;

  /// An optional action at the title's right end (the 设备 page's 扫码). The
  /// competitor puts one there on every top-level page, and it keeps the body
  /// free of a floating button.
  final Widget? trailing;

  /// Title → first content.
  static const contentGap = 20.0;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final trailing = this.trailing;
    final titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: BloomType.pageTitle),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle, style: BloomType.meta),
        ],
      ],
    );
    if (trailing == null) return titles;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [Expanded(child: titles), const SizedBox(width: 12), trailing],
    );
  }
}

/// The copy button next to a pairing value: a recess in the panel, not a
/// floating button — it belongs to the value it copies.
class _PlainIconButton extends StatelessWidget {
  const _PlainIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onTap,
    color: BloomInk.text,
    iconSize: 18,
    style: IconButton.styleFrom(
      backgroundColor: BloomInk.recess,
      disabledBackgroundColor: const Color(0x0FEDF2EF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BloomSurface.controlRadius),
      ),
    ),
    icon: Icon(icon),
  );
}

/// The app's one transient message: the glass slip that floats over a page.
///
/// Glass here for the same reason the nav bar is glass — a message is a thing
/// laid *over* the app, not a part of the page it happens to concern.
///
/// It replaced an inline box under the save button, which is what the user saw
/// as "点击保存按钮，然后它不是这个弹窗，它是底下出来一段话": a result is not
/// content, so it must not be pushed into the layout and move it.
class BloomMessage extends StatelessWidget {
  const BloomMessage({super.key, required this.message, this.isError = false});

  final String message;

  /// Errors lean on the app's second chroma (the rust that already carries the
  /// failure tint elsewhere); a confirmation stays neutral.
  final bool isError;

  @override
  Widget build(BuildContext context) => BloomGlassShadow(
    cornerRadius: 18,
    child: LiquidGlassLens(
      style: BloomGlassHome.panelStyle.copyWith(
        shape: const LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: 18,
          borderWidth: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              size: 16,
              color: isError ? const Color(0xFFEFC3B7) : BloomInk.text,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: BloomType.body.copyWith(
                  color: isError ? const Color(0xFFEFC3B7) : BloomInk.text,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
