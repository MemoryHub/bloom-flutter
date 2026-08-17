import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../core/models/device_models.dart';
import '../core/storage/display_preferences.dart';

Widget _buildPlaybackNavGlyph(BuildContext context, LiquidGlassGlyph glyph) {
  if (!glyph.selected) {
    return Icon(Icons.tune_rounded, size: glyph.size, color: glyph.color);
  }
  return _SelectedNavGlyph(icon: Icons.play_arrow_rounded, glyph: glyph);
}

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
    child: Icon(icon, size: glyph.size * .68, color: const Color(0xffF7F4EE)),
  );
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
    required this.onTabChanged,
    required this.onRefresh,
    required this.onModeChanged,
    required this.onNext,
    required this.onOpenCarouselSettings,
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
  final BloomDisplaySettings settings;
  final ValueChanged<int> onTabChanged;
  final Future<void> Function() onRefresh;
  final ValueChanged<BloomDisplayMode> onModeChanged;
  final VoidCallback onNext;
  final VoidCallback onOpenCarouselSettings;
  final VoidCallback onRefreshPairingCode;
  final VoidCallback onCopyDeviceId;
  final VoidCallback onCopyPairingCode;

  static const _panelStyle = LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: 30,
      borderWidth: 1.15,
      lightIntensity: 1.3,
      borderType: OpticalBorder(
        borderSaturation: .88,
        ambientIntensity: .9,
        borderSolidity: .14,
      ),
    ),
    appearance: LiquidGlassAppearance(
      color: Color(0x04FFFFFF),
      blur: LiquidGlassBlur(sigmaX: .24, sigmaY: .24),
      saturation: 1.04,
      enableInnerRadiusTransparent: true,
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

  static const _navStyle = LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: 36,
      borderWidth: 1.2,
      lightIntensity: 1.34,
      borderType: OpticalBorder(
        borderSaturation: .9,
        ambientIntensity: .94,
        borderSolidity: .15,
      ),
    ),
    appearance: LiquidGlassAppearance(
      color: Color(0x04FFFFFF),
      blur: LiquidGlassBlur(sigmaX: .2, sigmaY: .2),
      saturation: 1.05,
      enableInnerRadiusTransparent: true,
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

  static const _buttonStyle = LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: 26,
      borderWidth: 1.1,
      lightIntensity: 1.28,
      borderType: OpticalBorder(
        borderSaturation: .84,
        ambientIntensity: .88,
        borderSolidity: .13,
      ),
    ),
    appearance: LiquidGlassAppearance(
      color: Color(0x05FFFFFF),
      blur: LiquidGlassBlur(sigmaX: .22, sigmaY: .22),
      saturation: 1.035,
      enableInnerRadiusTransparent: true,
    ),
    refraction: LiquidGlassRefraction(
      refractionType: OpticalRefraction(
        refraction: 1.42,
        refractionWidth: 20,
        depth: .3,
      ),
      chromaticAberration: .00035,
      magnification: 1.006,
    ),
  );

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
    final pages = [
      _PhotoPage(
        loading: loading,
        originalPhotoPath: originalPhotoPath,
        content: content,
        date: date,
        mode: settings.mode,
        onRefresh: onRefresh,
      ),
      _PlaybackPage(
        settings: settings,
        loading: loading,
        onModeChanged: onModeChanged,
        onOpenCarouselSettings: onOpenCarouselSettings,
        onNext: onNext,
        nextLoading: nextLoading,
      ),
      _DevicePage(
        credentials: credentials,
        pairing: pairing,
        pairingRefreshing: pairingRefreshing,
        onRefreshPairingCode: onRefreshPairingCode,
        onCopyDeviceId: onCopyDeviceId,
        onCopyPairingCode: onCopyPairingCode,
      ),
    ];

    return LiquidGlassScaffold(
      useImpellerBackdrop: Platform.isIOS ? false : null,
      safeArea: true,
      backgroundColor: const Color(0xffF5F2EB),
      body: _PhotoBackdrop(
        imagePath: originalPhotoPath,
        revision: content?.recommendationId,
      ),
      lenses: [
        Positioned.fill(
          child: IndexedStack(index: selectedTab, children: pages),
        ),
        if (message != null)
          Positioned(
            top: 12,
            left: 24,
            right: 24,
            child: _GlassMessage(message: message!),
          ),
      ],
      bottomNavigationBar: LiquidGlassBottomNavBar(
        items: const [
          LiquidGlassTabBarItem(
            icon: Icons.photo_outlined,
            selectedIcon: Icons.photo,
            label: '照片',
          ),
          LiquidGlassTabBarItem.custom(
            iconBuilder: _buildPlaybackNavGlyph,
            label: '播放',
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
          selectedColor: Color(0xff25312F),
          unselectedColor: Color(0xff75807D),
          iconSize: 23,
          labelFontSize: 11,
          iconLabelGap: 2.5,
          selectedFontWeight: FontWeight.w700,
          unselectedFontWeight: FontWeight.w500,
        ),
        pillStyle: const LiquidGlassNavPillStyle(
          mode: LiquidGlassPillMode.impellerOnly,
          animated: true,
          color: Color(0x0AFFFFFF),
          growHeight: 8,
          distortion: .055,
          distortionWidth: 22,
          magnification: 1.014,
          enableInnerRadiusTransparent: true,
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
                borderSolidity: .15,
              ),
            ),
            appearance: LiquidGlassAppearance(
              color: Color(0x06FFFFFF),
              blur: LiquidGlassBlur(sigmaX: .18, sigmaY: .18),
              saturation: 1.05,
              enableInnerRadiusTransparent: true,
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
              color: Color(0x08FFFFFF),
              enableInnerRadiusTransparent: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoBackdrop extends StatelessWidget {
  const _PhotoBackdrop({required this.imagePath, required this.revision});

  final String? imagePath;
  final int? revision;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    return Stack(
      fit: StackFit.expand,
      children: [
        const _DarkAtmosphere(),
        if (path != null)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            switchInCurve: Curves.easeOutCubic,
            child: Opacity(
              key: ValueKey('$path:$revision'),
              opacity: .14,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
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
              colors: [Color(0x4DF8F5EF), Color(0x36EEF2EF), Color(0xB8F6F2EA)],
            ),
          ),
        ),
      ],
    );
  }
}

class _DarkAtmosphere extends StatelessWidget {
  const _DarkAtmosphere();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xffF8F4EC), Color(0xffEEF3F0), Color(0xffEEF1F6)],
        stops: [0, .48, 1],
      ),
    ),
    child: CustomPaint(painter: _AtmospherePainter()),
  );
}

class _AtmospherePainter extends CustomPainter {
  const _AtmospherePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cyan =
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(size.width * .82, size.height * .13),
            size.width * .72,
            const [Color(0x6AC9E0DC), Color(0x00D9E7E5)],
          );
    final green =
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(size.width * .08, size.height * .78),
            size.width * .65,
            const [Color(0x5AD0E2D3), Color(0x00DCE8DE)],
          );
    final blue =
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(size.width * .92, size.height * .86),
            size.width * .74,
            const [Color(0x52D5DDEF), Color(0x00E1E4ED)],
          );
    canvas.drawRect(Offset.zero & size, cyan);
    canvas.drawRect(Offset.zero & size, green);
    canvas.drawRect(Offset.zero & size, blue);

    final upperRibbon =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 34
          ..color = const Color(0x2AA7C7BF)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 18);
    final upperPath =
        Path()
          ..moveTo(-size.width * .18, size.height * .22)
          ..cubicTo(
            size.width * .18,
            size.height * .08,
            size.width * .64,
            size.height * .34,
            size.width * 1.16,
            size.height * .16,
          );
    canvas.drawPath(upperPath, upperRibbon);

    final lowerRibbon =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 44
          ..color = const Color(0x28AFB9D0)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 22);
    final lowerPath =
        Path()
          ..moveTo(-size.width * .2, size.height * .78)
          ..cubicTo(
            size.width * .22,
            size.height * .62,
            size.width * .64,
            size.height * .94,
            size.width * 1.2,
            size.height * .72,
          );
    canvas.drawPath(lowerPath, lowerRibbon);

    final contour =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x24506F68);
    for (var i = 0; i < 4; i++) {
      final y = size.height * (.31 + i * .055);
      final path =
          Path()
            ..moveTo(-20, y)
            ..cubicTo(
              size.width * .28,
              y - 24,
              size.width * .7,
              y + 28,
              size.width + 20,
              y - 8,
            );
      canvas.drawPath(path, contour);
    }
    final grain = Paint()..color = const Color(0x0D3E4A46);
    for (var y = 8.0; y < size.height; y += 17) {
      for (var x = 7.0; x < size.width; x += 19) {
        final offset = ((x * 13 + y * 7).toInt() % 11) / 11;
        canvas.drawCircle(Offset(x + offset * 3, y), .45, grain);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PhotoPage extends StatelessWidget {
  const _PhotoPage({
    required this.loading,
    required this.originalPhotoPath,
    required this.content,
    required this.date,
    required this.mode,
    required this.onRefresh,
  });

  final bool loading;
  final String? originalPhotoPath;
  final DailyContent? content;
  final String? date;
  final BloomDisplayMode mode;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = originalPhotoPath != null;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _GlassChip(
                  icon:
                      mode == BloomDisplayMode.carousel
                          ? Icons.shuffle_rounded
                          : Icons.auto_awesome_rounded,
                  label: mode == BloomDisplayMode.carousel ? '随机轮播' : '今日推荐',
                ),
                const Spacer(),
                _GlassIconButton(
                  icon: Icons.refresh_rounded,
                  loading: loading,
                  onTap: loading ? null : onRefresh,
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (!hasPhoto)
              const Expanded(child: _PhotoLoadingCard())
            else
              Expanded(
                child: Center(
                  child: _LetterPhotoCard(
                    imagePath: originalPhotoPath!,
                    revision:
                        '${mode.name}:${content?.recommendationId}:${content?.photo?.url}',
                    content: content,
                    fallbackDate: date,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LetterPhotoCard extends StatelessWidget {
  const _LetterPhotoCard({
    required this.imagePath,
    required this.revision,
    required this.content,
    required this.fallbackDate,
  });

  final String imagePath;
  final Object revision;
  final DailyContent? content;
  final String? fallbackDate;

  @override
  Widget build(BuildContext context) {
    final fx = (content?.photo?.focusX ?? .5).clamp(0.0, 1.0);
    final fy = (content?.photo?.focusY ?? .45).clamp(0.0, 1.0);
    return AspectRatio(
      aspectRatio: 720 / 1200,
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: Image.file(
                  File(imagePath),
                  key: ValueKey('$imagePath:$revision'),
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

class _PlaybackPage extends StatelessWidget {
  const _PlaybackPage({
    required this.settings,
    required this.loading,
    required this.onModeChanged,
    required this.onOpenCarouselSettings,
    required this.onNext,
    required this.nextLoading,
  });

  final BloomDisplaySettings settings;
  final bool loading;
  final ValueChanged<BloomDisplayMode> onModeChanged;
  final VoidCallback onOpenCarouselSettings;
  final VoidCallback onNext;
  final bool nextLoading;

  @override
  Widget build(BuildContext context) => SafeArea(
    minimum: const EdgeInsets.fromLTRB(18, 18, 18, 0),
    child: ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 112),
      children: [
        const _PageTitle(title: '播放', subtitle: '决定 Bloom 如何为你更换照片'),
        const SizedBox(height: 18),
        _ModeGlassSelector(
          settings: settings,
          loading: loading,
          onChanged: onModeChanged,
        ),
        const SizedBox(height: 14),
        LiquidGlassLens(
          style: BloomGlassHome._panelStyle,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      settings.mode == BloomDisplayMode.carousel
                          ? Icons.shuffle_rounded
                          : Icons.auto_awesome_rounded,
                      color: const Color(0xff617D77),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        settings.mode == BloomDisplayMode.carousel
                            ? '随机轮播'
                            : '每日推荐',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  settings.mode == BloomDisplayMode.carousel
                      ? '${settings.intervalLabel} · ${settings.activeStart}–${settings.activeEnd}\n预计每天播放 ${settings.expectedDailyItems} 张照片'
                      : '每天保持一张精选照片，直到第二天推荐更新。',
                  style: const TextStyle(
                    color: Color(0xff66716E),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                if (settings.mode == BloomDisplayMode.carousel) ...[
                  const SizedBox(height: 18),
                  LiquidGlassButton(
                    label: '调整时间与频率',
                    icon: Icons.schedule_rounded,
                    foregroundColor: const Color(0xff34413E),
                    onPressed: loading ? null : onOpenCarouselSettings,
                    width: double.infinity,
                    style: BloomGlassHome._buttonStyle,
                    touch: const LiquidGlassTouch(flex: LiquidGlassFlex()),
                  ),
                  const SizedBox(height: 10),
                  LiquidGlassButton.custom(
                    onPressed: loading || nextLoading ? null : onNext,
                    width: double.infinity,
                    foregroundColor: const Color(0xff34413E),
                    style: BloomGlassHome._buttonStyle,
                    touch: const LiquidGlassTouch(flex: LiquidGlassFlex()),
                    child: _GlassButtonContent(
                      loading: loading || nextLoading,
                      icon: Icons.skip_next_rounded,
                      label: '立即下一张',
                      loadingLabel: loading ? '正在切换模式…' : '正在获取下一张…',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ModeGlassSelector extends StatelessWidget {
  const _ModeGlassSelector({
    required this.settings,
    required this.loading,
    required this.onChanged,
  });

  final BloomDisplaySettings settings;
  final bool loading;
  final ValueChanged<BloomDisplayMode> onChanged;

  @override
  Widget build(BuildContext context) => LiquidGlassLens(
    style: BloomGlassHome._panelStyle,
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          _ModeItem(
            selected: settings.mode == BloomDisplayMode.recommendation,
            loading: loading,
            icon: Icons.auto_awesome_rounded,
            label: '推荐模式',
            onTap:
                loading
                    ? null
                    : () => onChanged(BloomDisplayMode.recommendation),
          ),
          _ModeItem(
            selected: settings.mode == BloomDisplayMode.carousel,
            loading: loading,
            icon: Icons.slideshow_rounded,
            label: '轮播模式',
            onTap: loading ? null : () => onChanged(BloomDisplayMode.carousel),
          ),
        ],
      ),
    ),
  );
}

class _ModeItem extends StatelessWidget {
  const _ModeItem({
    required this.selected,
    required this.loading,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final bool loading;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xA6FFFFFF) : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: selected ? const Color(0xC9FFFFFF) : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (selected && loading)
                const SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: Color(0xff526E69),
                  ),
                )
              else
                Icon(
                  icon,
                  size: 19,
                  color:
                      selected
                          ? const Color(0xff2E3A37)
                          : const Color(0xff78827F),
                ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color:
                      selected
                          ? const Color(0xff2E3A37)
                          : const Color(0xff78827F),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _DevicePage extends StatelessWidget {
  const _DevicePage({
    required this.credentials,
    required this.pairing,
    required this.pairingRefreshing,
    required this.onRefreshPairingCode,
    required this.onCopyDeviceId,
    required this.onCopyPairingCode,
  });

  final DeviceCredentials? credentials;
  final PairingInfo? pairing;
  final bool pairingRefreshing;
  final VoidCallback onRefreshPairingCode;
  final VoidCallback onCopyDeviceId;
  final VoidCallback onCopyPairingCode;

  @override
  Widget build(BuildContext context) {
    final expires = pairing?.expiresAt.toLocal();
    final expiry =
        expires == null
            ? '激活码按需生成，并在到期后刷新。'
            : '有效期至 ${expires.year}.${expires.month.toString().padLeft(2, '0')}.${expires.day.toString().padLeft(2, '0')} ${expires.hour.toString().padLeft(2, '0')}:${expires.minute.toString().padLeft(2, '0')}';
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(18, 18, 18, 0),
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 112),
        children: [
          const _PageTitle(title: '设备', subtitle: '管理设备标识和新的绑定关系'),
          const SizedBox(height: 18),
          _InfoGlassCard(
            label: '设备 ID',
            value: credentials?.deviceId ?? '—',
            icon: Icons.fingerprint_rounded,
            actionIcon: Icons.copy_rounded,
            onAction: credentials == null ? null : onCopyDeviceId,
          ),
          const SizedBox(height: 14),
          LiquidGlassLens(
            style: BloomGlassHome._panelStyle,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.link_rounded, color: Color(0xff617D77)),
                      SizedBox(width: 10),
                      Text(
                        '激活码',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 54,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child:
                                pairing == null
                                    ? const Text(
                                      '尚未生成',
                                      maxLines: 1,
                                      style: TextStyle(
                                        fontSize: 18,
                                        height: 1,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    )
                                    : FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        pairing?.code ?? '',
                                        maxLines: 1,
                                        style: const TextStyle(
                                          fontSize: 29,
                                          height: 1,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 4,
                                        ),
                                      ),
                                    ),
                          ),
                        ),
                        if (pairing != null) ...[
                          const SizedBox(width: 8),
                          _PlainIconButton(
                            icon: Icons.copy_rounded,
                            onTap: onCopyPairingCode,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 38,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        expiry,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xff6D7774),
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LiquidGlassButton.custom(
                    onPressed: pairingRefreshing ? null : onRefreshPairingCode,
                    width: double.infinity,
                    height: 52,
                    foregroundColor: const Color(0xff34413E),
                    style: BloomGlassHome._buttonStyle,
                    touch: const LiquidGlassTouch(flex: LiquidGlassFlex()),
                    child: _GlassButtonContent(
                      loading: pairingRefreshing,
                      icon: Icons.refresh_rounded,
                      label: '生成新的激活码',
                      loadingLabel: '正在生成激活码…',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          const _StatusGlassCard(),
        ],
      ),
    );
  }
}

class _BindingCheckExperience extends StatelessWidget {
  const _BindingCheckExperience();

  @override
  Widget build(BuildContext context) => LiquidGlassView(
    useImpellerBackdrop: Platform.isIOS ? false : null,
    backgroundWidget: const _DarkAtmosphere(),
    child: Material(
      color: Colors.transparent,
      child: SafeArea(
        minimum: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Bloom',
                style: TextStyle(
                  color: Color(0xff2D3936),
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.6,
                ),
              ),
              const SizedBox(height: 9),
              const Text(
                '把记忆留在每天看得见的地方',
                style: TextStyle(color: Color(0xff6D7774), fontSize: 14),
              ),
              const SizedBox(height: 30),
              LiquidGlassLens(
                style: BloomGlassHome._panelStyle.copyWith(
                  shape: const LiquidGlassShape.continuousRoundedRectangle(
                    cornerRadius: 27,
                    borderWidth: 1.45,
                    lightIntensity: 1.42,
                  ),
                ),
                child: const SizedBox(
                  width: 286,
                  height: 108,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 22),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 27,
                          height: 27,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Color(0xff526E69),
                          ),
                        ),
                        SizedBox(width: 17),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '正在连接 Bloom',
                                style: TextStyle(
                                  color: Color(0xff2D3936),
                                  fontSize: 17,
                                  height: 1.1,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 7),
                              Text(
                                '正在确认设备绑定状态…',
                                style: TextStyle(
                                  color: Color(0xff6D7774),
                                  fontSize: 13,
                                  height: 1.1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
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
  Widget build(BuildContext context) => LiquidGlassView(
    useImpellerBackdrop: Platform.isIOS ? false : null,
    backgroundWidget: const _DarkAtmosphere(),
    child: Material(
      color: Colors.transparent,
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
                      color: Color(0xff2D3936),
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '把记忆留在每天看得见的地方',
                    style: TextStyle(color: Color(0xff6D7774), fontSize: 14),
                  ),
                  const SizedBox(height: 28),
                  LiquidGlassLens(
                    style: BloomGlassHome._panelStyle,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            '连接 Bloom',
                            style: TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '打开 bloom.jihu.top，在“设备管理”中输入设备 ID 和绑定码。',
                            style: TextStyle(
                              color: Color(0xff68736F),
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
                                pairing?.code ??
                                (loading ? '正在获取…' : '点击下方重新生成'),
                            emphasized: pairing != null,
                            onCopy: pairing == null ? null : onCopyPairingCode,
                          ),
                          const SizedBox(height: 20),
                          LiquidGlassButton.custom(
                            onPressed:
                                pairingRefreshing ? null : onRefreshPairingCode,
                            width: double.infinity,
                            foregroundColor: const Color(0xff34413E),
                            style: BloomGlassHome._buttonStyle,
                            touch: const LiquidGlassTouch(
                              flex: LiquidGlassFlex(),
                            ),
                            child: _GlassButtonContent(
                              loading: pairingRefreshing,
                              icon: Icons.refresh_rounded,
                              label: '重新生成绑定码',
                              loadingLabel: '正在生成绑定码…',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 14),
                    _GlassMessage(message: message!),
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
      Text(
        label,
        style: const TextStyle(color: Color(0xff77817E), fontSize: 12),
      ),
      const SizedBox(height: 7),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: const Color(0xff2E3936),
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

class _GlassButtonContent extends StatelessWidget {
  const _GlassButtonContent({
    required this.loading,
    required this.icon,
    required this.label,
    this.loadingLabel,
  });

  final bool loading;
  final IconData icon;
  final String label;
  final String? loadingLabel;

  @override
  Widget build(BuildContext context) => Center(
    child:
        loading
            ? Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 19,
                  height: 19,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xff3E4A47),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  loadingLabel ?? '正在处理…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xff56615E),
                    fontSize: 15,
                    height: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
            : Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, size: 21, color: const Color(0xff34413E)),
                const SizedBox(width: 8),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xff34413E),
                    fontSize: 16,
                    height: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
  );
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => LiquidGlassButton(
    label: label,
    icon: icon,
    onPressed: null,
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    foregroundColor: const Color(0xff34413E),
    fontSize: 13,
    fontWeight: FontWeight.w600,
    iconSize: 17,
    style: BloomGlassHome._panelStyle.copyWith(
      shape: const LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: 22,
        borderWidth: 1.35,
        lightIntensity: 1.4,
      ),
    ),
  );
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.icon,
    required this.loading,
    required this.onTap,
  });

  final IconData icon;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => LiquidGlassButton.custom(
    width: 44,
    height: 44,
    padding: EdgeInsets.zero,
    foregroundColor: const Color(0xff34413E),
    onPressed: onTap,
    style: BloomGlassHome._panelStyle.copyWith(
      shape: const LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: 22,
        borderWidth: 1.35,
        lightIntensity: 1.4,
      ),
    ),
    touch: const LiquidGlassTouch(flex: LiquidGlassFlex()),
    child: Center(
      child:
          loading
              ? const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: Color(0xff526E69),
                ),
              )
              : Icon(icon, size: 21, color: const Color(0xff34413E)),
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
  Widget build(BuildContext context) => LiquidGlassLens(
    style: BloomGlassHome._panelStyle,
    child: AnimatedBuilder(
      animation: _controller,
      builder:
          (context, _) => Padding(
            padding: const EdgeInsets.all(20),
            child: Opacity(
              opacity: .42 + _controller.value * .28,
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonLine(widthFactor: .78, height: 18),
                  SizedBox(height: 12),
                  _SkeletonLine(widthFactor: .92, height: 11),
                  SizedBox(height: 10),
                  _SkeletonLine(widthFactor: .48, height: 10),
                ],
              ),
            ),
          ),
    ),
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
        color: const Color(0x2F52615D),
        borderRadius: BorderRadius.circular(height),
      ),
    ),
  );
}

class _PageTitle extends StatelessWidget {
  const _PageTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          color: Color(0xff2D3936),
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -.7,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        subtitle,
        style: const TextStyle(color: Color(0xff68736F), fontSize: 14),
      ),
    ],
  );
}

class _InfoGlassCard extends StatelessWidget {
  const _InfoGlassCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.actionIcon,
    this.onAction,
  });

  final String label;
  final String value;
  final IconData icon;
  final IconData actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => LiquidGlassLens(
    style: BloomGlassHome._panelStyle,
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xff617D77)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xff77817E),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  value,
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
              ],
            ),
          ),
          _PlainIconButton(icon: actionIcon, onTap: onAction),
        ],
      ),
    ),
  );
}

class _StatusGlassCard extends StatelessWidget {
  const _StatusGlassCard();

  @override
  Widget build(BuildContext context) => LiquidGlassLens(
    style: BloomGlassHome._panelStyle,
    child: const Padding(
      padding: EdgeInsets.all(18),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, color: Color(0xff73D6B6)),
          SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '设备已连接',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 3),
                Text(
                  '照片和小组件会按照当前模式自动更新。',
                  style: TextStyle(color: Color(0xff6D7774), fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _PlainIconButton extends StatelessWidget {
  const _PlainIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onTap,
    color: const Color(0xff34413E),
    style: IconButton.styleFrom(
      backgroundColor: const Color(0x70FFFFFF),
      disabledBackgroundColor: const Color(0x35FFFFFF),
    ),
    icon: Icon(icon, size: 19),
  );
}

class _GlassMessage extends StatelessWidget {
  const _GlassMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => LiquidGlassLens(
    style: BloomGlassHome._panelStyle.copyWith(
      shape: const LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: 22,
        borderWidth: 1,
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.info_outline_rounded, size: 17),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    ),
  );
}
