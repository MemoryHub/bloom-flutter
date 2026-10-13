import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/device_models.dart';
import 'country_flag_assets.dart';

class GalleryTextRun {
  GalleryTextRun(
    this.painter,
    this.position, {
    this.card = 'label',
    this.role = '',
  });
  final TextPainter painter;
  final Offset position;
  final String card;
  final String role;
  Rect get bounds => position & painter.size;
}

class GalleryFlag {
  GalleryFlag(this.country, this.bounds);
  final String country;
  final Rect bounds;
}

class GalleryLabelLayout {
  GalleryLabelLayout(
    this.card,
    this.runs,
    this.scale, {
    this.noteCard,
    this.flags = const [],
  });
  final Rect card;
  final List<GalleryTextRun> runs;
  final double scale;
  final Rect? noteCard;
  final List<GalleryFlag> flags;
  List<Rect> get cards => [card, if (noteCard != null) noteCard!];
  void dispose() {
    for (final run in runs) {
      run.painter.dispose();
    }
  }
}

/// Original artwork is rendered locally; widgets never decode the frame RAW.
class MobileArtworkRenderer {
  static const template = 'bloom-mobile-gallery-v8-server-country-assets';
  static const sizes = {
    'portrait': Size(720, 1200),
    'square': Size(720, 720),
    'largeSquare': Size(1200, 1200),
  };

  static String cleanText(dynamic value) {
    if (value is! String && value is! int) return '';
    final text = '$value'
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    return ['none', 'null', 'undefined'].contains(text.toLowerCase())
        ? ''
        : text;
  }

  static String artistLifespan(Map<String, dynamic> metadata) {
    String valid(dynamic value) {
      final text = cleanText(value);
      return RegExp(r'^(?:c\.\s*)?[1-9]\d{2,3}(?:/\d{1,4})?$').hasMatch(text)
          ? text
          : '';
    }

    final birth = valid(metadata['artist_birth_year']),
        death = valid(metadata['artist_death_year']);
    if (birth.isNotEmpty && death.isNotEmpty) {
      int year(String s) => int.parse(RegExp(r'\d+').firstMatch(s)![0]!);
      return year(birth) > year(death) ? '' : '$birth–$death';
    }
    if (birth.isNotEmpty) return 'b. $birth';
    if (death.isNotEmpty) return 'd. $death';
    return '';
  }

  static String shortCaption(Map<String, dynamic> metadata) {
    final explicit = cleanText(metadata['label_caption']);
    final text =
        explicit.isNotEmpty
            ? explicit
            : cleanText(metadata['short_description']);
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final result =
        explicit.isNotEmpty ? sentences.take(2).join(' ') : sentences.first;
    final words = result.split(' ');
    if (result.length <= 110 && words.length <= 20) return result;
    var fitted = '';
    for (final word in words.take(20)) {
      final candidate = '$fitted $word'.trim();
      if (candidate.length > 107) break;
      fitted = candidate;
    }
    return fitted.isEmpty
        ? ''
        : '${fitted.replaceFirst(RegExp(r'[.,;:]+$'), '')}…';
  }

  static String countryCode(Map<String, dynamic> metadata) {
    final code = cleanText(metadata['artist_country_code']).toUpperCase();
    return RegExp(r'^[A-Z]{2}$').hasMatch(code) &&
            (supportedCountries.containsKey(code) || hasFlagAsset(metadata))
        ? code
        : '';
  }

  static bool hasFlagAsset(Map<String, dynamic> metadata) =>
      CountryFlagAssets.bytes(metadata) != null;

  static double artworkFocus(
    Map<String, dynamic> metadata,
    String axis,
    double fallback,
  ) {
    final focus = metadata['artwork_focus'];
    final value = focus is Map ? focus[axis] : null;
    return value is num && value.isFinite && value >= 0 && value <= 1
        ? value.toDouble()
        : fallback;
  }

  static const supportedCountries = {
    'JP': '日本',
    'NL': '荷兰',
    'FR': '法国',
    'AT': '奥地利',
    'IT': '意大利',
    'GB': '英国',
    'US': '美国',
    'DE': '德国',
    'ES': '西班牙',
    'UA': '乌克兰',
    'BE': '比利时',
    'IE': '爱尔兰',
    'CA': '加拿大',
    'AU': '澳大利亚',
    'CZ': '捷克',
    'RU': '俄罗斯',
    'PL': '波兰',
    'TW': '中国台湾',
  };

  static String editorialNote(Map<String, dynamic> metadata) {
    final value = metadata['bloom_note_zh'];
    if (value is! String) return '';
    return value
        .split('\n')
        .map(cleanText)
        .where((s) => s.isNotEmpty)
        .join('\n');
  }

  static GalleryLabelLayout layoutLabel(Map<String, dynamic> meta, Size size) {
    final unit = math.min(size.width, size.height) / 720;
    final compact = size.width == size.height;
    final width = (compact ? 340 : 336) * unit;
    final pad = 18 * unit;
    final inset = (compact ? 56 : 52) * unit;
    final textWidth = width - 2 * pad;
    final maximum = (compact ? 180 : 228) * unit;
    TextPainter text(
      String value,
      double fontSize,
      FontWeight weight,
      int maxLines,
      double maxWidth,
      Color color, {
      bool chinese = false,
    }) => TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: chinese ? 'BloomHandwriting' : 'BloomGallery',
          fontSize: fontSize * unit,
          fontWeight: weight,
          fontVariations:
              chinese
                  ? null
                  : [ui.FontVariation('wght', (weight.index + 1) * 100.0)],
          color: color,
          height: chinese ? 1.4 : 1.17,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    const ink = Color(0xff1d1d1c),
        secondary = Color(0xff52524c),
        dates = Color(0xff686860);
    final titleText = cleanText(meta['title']);
    var titleSize = compact ? 32.0 : 34.0;
    var title = text(
      titleText.isEmpty ? 'Artwork' : titleText,
      titleSize,
      FontWeight.w400,
      2,
      textWidth,
      ink,
    );
    while (title.didExceedMaxLines && titleSize > (compact ? 28 : 30)) {
      title.dispose();
      titleSize -= 1;
      title = text(
        titleText.isEmpty ? 'Artwork' : titleText,
        titleSize,
        FontWeight.w400,
        2,
        textWidth,
        ink,
      );
    }
    final fullAuthor = cleanText(meta['artist']);
    final displayName = cleanText(meta['artist_display_name']);
    final artistText =
        fullAuthor.isEmpty
            ? ''
            : (displayName.isEmpty ? fullAuthor : displayName);
    final life = fullAuthor.isEmpty ? '' : artistLifespan(meta);
    final flag = fullAuthor.isEmpty ? '' : countryCode(meta);
    TextPainter? lifePainter =
        life.isEmpty
            ? null
            : text(
              life,
              compact ? 14 : 16,
              FontWeight.w400,
              1,
              textWidth,
              dates,
            );
    if (lifePainter != null && lifePainter.width > 145 * unit) {
      lifePainter.dispose();
      lifePainter = null;
    }
    final trailing =
        (lifePainter == null ? 0.0 : lifePainter.width + 10 * unit) +
        (flag.isEmpty ? 0.0 : 26 * unit);
    // One line only. Do not guess away compound surnames; optional display names
    // are curated metadata, while the full name stays available in the App.
    final author =
        artistText.isEmpty
            ? null
            : text(
              artistText,
              22,
              FontWeight.w700,
              1,
              textWidth - trailing,
              const Color(0xff242422),
            );
    final yearText = cleanText(meta['year']);
    final year =
        yearText.isEmpty
            ? null
            : text(
              yearText,
              20,
              FontWeight.w400,
              1,
              textWidth,
              const Color(0xff3e3e3a),
            );
    final header = <(TextPainter, double, String)>[
      (title, (compact ? 8 : 10) * unit, 'title'),
      if (author != null) (author, 6 * unit, 'author'),
      if (year != null) (year, 12 * unit, 'year'),
    ];
    final caption = compact ? '' : shortCaption(meta);
    final fixed = 2 * pad + header.fold<double>(0, (h, r) => h + r.$1.height);
    final gaps = header
        .take(header.length - 1)
        .fold<double>(0, (h, r) => h + r.$2);
    final bodyGap = header.last.$2;
    final available = maximum - fixed - gaps - bodyGap;
    final bodyLines = math.min(
      2,
      math.max(0, (available / (20 * unit * 1.17)).floor()),
    );
    final body =
        caption.isEmpty || bodyLines == 0
            ? null
            : text(
              caption,
              20,
              FontWeight.w400,
              bodyLines,
              textWidth,
              secondary,
            );
    final height = fixed + gaps + (body == null ? 0 : bodyGap + body.height);
    final card = Rect.fromLTWH(
      size.width - inset - width,
      size.height - inset - height,
      width,
      height,
    );
    final runs = <GalleryTextRun>[], flags = <GalleryFlag>[];
    var cursor = card.top + pad;
    for (var i = 0; i < header.length; i++) {
      final painter = header[i].$1;
      runs.add(
        GalleryTextRun(
          painter,
          Offset(card.left + pad, cursor),
          role: header[i].$3,
        ),
      );
      if (painter == author) {
        var nextX = card.left + pad + painter.width;
        if (lifePainter != null) {
          nextX += 10 * unit;
          runs.add(
            GalleryTextRun(
              lifePainter,
              Offset(
                nextX,
                cursor +
                    painter.computeLineMetrics().first.baseline -
                    lifePainter.computeLineMetrics().first.baseline,
              ),
              role: 'lifespan',
            ),
          );
          nextX += lifePainter.width;
        }
        if (flag.isNotEmpty) {
          nextX += 10 * unit;
          flags.add(
            GalleryFlag(
              flag,
              Rect.fromLTWH(
                nextX,
                cursor +
                    painter.computeLineMetrics().first.baseline -
                    10 * unit,
                16 * unit,
                10 * unit,
              ),
            ),
          );
        }
      }
      cursor += painter.height;
      if (i < header.length - 1 || body != null) cursor += header[i].$2;
    }
    if (body != null) {
      runs.add(
        GalleryTextRun(body, Offset(card.left + pad, cursor), role: 'body'),
      );
    }
    final note = editorialNote(meta);
    Rect? noteCard;
    if (note.isNotEmpty) {
      final painter = text(
        note,
        compact ? 22 : 24,
        FontWeight.w400,
        4,
        textWidth,
        const Color(0xff2d2d28),
        chinese: true,
      );
      final notePadding = (compact ? 12 : 16) * unit;
      final noteHeight = painter.height + 2 * notePadding;
      noteCard = Rect.fromLTWH(
        card.left,
        card.top - (compact ? 8 : 9) * unit - noteHeight,
        width,
        noteHeight,
      );
      runs.add(
        GalleryTextRun(
          painter,
          Offset(card.left + pad, noteCard.top + notePadding),
          card: 'note',
          role: 'note',
        ),
      );
    }
    return GalleryLabelLayout(
      card,
      runs,
      unit,
      noteCard: noteCard,
      flags: flags,
    );
  }

  static void drawFlag(Canvas canvas, GalleryFlag flag) {
    final box = flag.bounds;
    canvas.drawRect(box, Paint()..color = Colors.white);
    const red = Color(0xffae2b23), blue = Color(0xff28538b);
    void rect(double x, double y, double w, double h, Color color) =>
        canvas.drawRect(
          Rect.fromLTWH(
            box.left + x * box.width,
            box.top + y * box.height,
            w * box.width,
            h * box.height,
          ),
          Paint()..color = color,
        );
    void stripes(List<Color> colors, {bool vertical = false}) {
      for (var i = 0; i < colors.length; i++) {
        if (vertical) {
          rect(i / colors.length, 0, 1 / colors.length, 1, colors[i]);
        } else {
          rect(0, i / colors.length, 1, 1 / colors.length, colors[i]);
        }
      }
    }

    void polygon(List<(double, double)> points, Color color) {
      final path =
          Path()..moveTo(
            box.left + points.first.$1 * box.width,
            box.top + points.first.$2 * box.height,
          );
      for (final point in points.skip(1)) {
        path.lineTo(
          box.left + point.$1 * box.width,
          box.top + point.$2 * box.height,
        );
      }
      path.close();
      canvas.drawPath(path, Paint()..color = color);
    }

    void star(double x, double y, double radius, int points) {
      polygon(
        List.generate(points * 2, (n) {
          final angle = n * math.pi / points - math.pi / 2;
          final r = radius * (n.isEven ? 1 : .45);
          return (
            x + math.cos(angle) * r * box.height / box.width,
            y + math.sin(angle) * r,
          );
        }),
        Colors.white,
      );
    }

    switch (flag.country) {
      case 'JP':
        canvas.drawCircle(box.center, box.height * .3, Paint()..color = red);
      case 'NL':
        stripes([red, Colors.white, blue]);
      case 'FR':
        stripes([blue, Colors.white, red], vertical: true);
      case 'IT':
        stripes([const Color(0xff227543), Colors.white, red], vertical: true);
      case 'BE':
        stripes([
          const Color(0xff1e1e1e),
          const Color(0xffe9c33d),
          red,
        ], vertical: true);
      case 'IE':
        stripes([
          const Color(0xff227543),
          Colors.white,
          const Color(0xffe7892f),
        ], vertical: true);
      case 'RU':
        stripes([Colors.white, blue, red]);
      case 'PL':
        stripes([Colors.white, red]);
      case 'CZ':
        stripes([Colors.white, red]);
        polygon([(0.0, 0.0), (.5, .5), (0.0, 1.0)], blue);
      case 'CA':
        rect(0, 0, .25, 1, red);
        rect(.75, 0, .25, 1, red);
        polygon([
          (.5, .17),
          (.55, .34),
          (.61, .29),
          (.60, .46),
          (.69, .40),
          (.65, .58),
          (.57, .64),
          (.58, .71),
          (.52, .70),
          (.52, .84),
          (.48, .84),
          (.48, .70),
          (.42, .71),
          (.43, .64),
          (.35, .58),
          (.31, .40),
          (.40, .46),
          (.39, .29),
          (.45, .34),
        ], red);
      case 'TW':
        rect(0, 0, 1, 1, red);
        rect(0, 0, .5, .5, blue);
        star(.25, .25, .16, 12);
      case 'AU':
        rect(0, 0, 1, 1, blue);
        canvas.save();
        canvas.clipRect(
          Rect.fromLTWH(box.left, box.top, box.width * .5, box.height * .5),
        );
        drawFlag(
          canvas,
          GalleryFlag(
            'GB',
            Rect.fromLTWH(box.left, box.top, box.width * .5, box.height * .5),
          ),
        );
        canvas.restore();
        star(.25, .76, .12, 7);
        star(.76, .20, .07, 7);
        star(.63, .46, .07, 7);
        star(.90, .42, .07, 7);
        star(.76, .82, .07, 7);
        star(.82, .58, .035, 5);
      case 'AT':
        stripes([red, Colors.white, red]);
      case 'DE':
        stripes([const Color(0xff1e1e1e), red, const Color(0xffdeb52f)]);
      case 'UA':
        stripes([blue, const Color(0xffe9c33d)]);
      case 'ES':
        rect(0, 0, 1, 1, red);
        rect(0, .25, 1, .5, const Color(0xffe9c33d));
        rect(.27, .38, .09, .27, red);
      case 'US':
        stripes(List.generate(13, (i) => i.isEven ? red : Colors.white));
        rect(0, 0, .42, 7 / 13, blue);
        for (var row = 0; row < 5; row++) {
          for (var col = 0; col < 6; col++) {
            canvas.drawCircle(
              Offset(
                box.left + box.width * (.035 + col * .066),
                box.top + box.height * (.045 + row * .105),
              ),
              box.height * .012,
              Paint()..color = Colors.white,
            );
          }
        }
      case 'GB':
        rect(0, 0, 1, 1, blue);
        for (final line in [
          (box.topLeft, box.bottomRight),
          (box.bottomLeft, box.topRight),
        ]) {
          canvas.drawLine(
            line.$1,
            line.$2,
            Paint()
              ..color = Colors.white
              ..strokeWidth = box.height * .24,
          );
          canvas.drawLine(
            line.$1,
            line.$2,
            Paint()
              ..color = red
              ..strokeWidth = box.height * .10,
          );
        }
        rect(.39, 0, .22, 1, Colors.white);
        rect(0, .32, 1, .36, Colors.white);
        rect(.45, 0, .10, 1, red);
        rect(0, .41, 1, .18, red);
    }
    canvas.drawRect(
      box,
      Paint()
        ..color = const Color(0xffa0a098)
        ..style = PaintingStyle.stroke
        ..strokeWidth = box.height / 14,
    );
  }

  /// Paint at the live canvas resolution for the home page; widget exports
  /// share this layout without forcing the home page to upscale a PNG.
  static void paintLabel(
    Canvas canvas,
    Map<String, dynamic> metadata,
    Size size, {
    ui.Image? flagImage,
  }) {
    final label = layoutLabel(metadata, size), unit = label.scale;
    for (final card in label.cards) {
      canvas.drawRect(
        card.shift(Offset(3 * unit, 4 * unit)),
        Paint()
          ..color = const Color.fromARGB(28, 0, 0, 0)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * unit),
      );
      canvas.drawRect(card, Paint()..color = const Color(0xfff7f6f0));
    }
    for (final run in label.runs) {
      final card = run.card == 'note' ? label.noteCard! : label.card;
      canvas.save();
      canvas.clipRect(card);
      run.painter.paint(canvas, run.position);
      canvas.restore();
    }
    for (final flag in label.flags) {
      if (flagImage != null) {
        canvas.drawImageRect(
          flagImage,
          Rect.fromLTWH(
            0,
            0,
            flagImage.width.toDouble(),
            flagImage.height.toDouble(),
          ),
          flag.bounds,
          Paint()..filterQuality = FilterQuality.high,
        );
      } else if (supportedCountries.containsKey(flag.country)) {
        drawFlag(canvas, flag);
      }
    }
    label.dispose();
  }

  static Future<Uint8List> render(
    Uint8List bytes,
    DailyContent content,
    String family,
  ) async {
    final size = sizes[family] ?? sizes['portrait']!;
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth:
          content.photoOrientation == 'landscape' ? null : size.width.toInt(),
      targetHeight:
          content.photoOrientation == 'landscape' ? size.height.toInt() : null,
      allowUpscaling: false,
    );
    final image = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Keep the accepted full-bleed crop and its existing .5/.45 focal point.
    final sourceWidth = image.width.toDouble();
    final sourceHeight = image.height.toDouble();
    final scale = math.max(
      size.width / sourceWidth,
      size.height / sourceHeight,
    );
    final cropWidth = size.width / scale;
    final cropHeight = size.height / scale;
    final left = (sourceWidth * artworkFocus(content.artwork, 'x', .5) -
            cropWidth / 2)
        .clamp(0.0, sourceWidth - cropWidth);
    final top = (sourceHeight * artworkFocus(content.artwork, 'y', .45) -
            cropHeight / 2)
        .clamp(0.0, sourceHeight - cropHeight);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(left, top, cropWidth, cropHeight),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.high,
    );
    final flagImage = await CountryFlagAssets.load(content.artwork);
    paintLabel(canvas, content.artwork, size, flagImage: flagImage);
    final picture = recorder.endRecording();
    final output = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    output.dispose();
    picture.dispose();
    flagImage?.dispose();
    return data!.buffer.asUint8List();
  }
}

/// Home labels load the same server-owned flag as widget exports.
class ServerArtworkLabel extends StatefulWidget {
  const ServerArtworkLabel({super.key, required this.metadata});
  final Map<String, dynamic> metadata;
  @override
  State<ServerArtworkLabel> createState() => _ServerArtworkLabelState();
}

class _ServerArtworkLabelState extends State<ServerArtworkLabel> {
  ui.Image? _image;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ServerArtworkLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (CountryFlagAssets.signature(oldWidget.metadata) !=
        CountryFlagAssets.signature(widget.metadata)) {
      _image?.dispose();
      _image = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final image = await CountryFlagAssets.load(widget.metadata);
    if (!mounted || generation != _generation) {
      image?.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
    });
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _ServerLabelPainter(widget.metadata, _image));
}

class _ServerLabelPainter extends CustomPainter {
  _ServerLabelPainter(this.metadata, this.image);
  final Map<String, dynamic> metadata;
  final ui.Image? image;
  @override
  void paint(Canvas canvas, Size size) => MobileArtworkRenderer.paintLabel(
    canvas,
    metadata,
    size,
    flagImage: image,
  );
  @override
  bool shouldRepaint(_ServerLabelPainter oldDelegate) => true;
}
