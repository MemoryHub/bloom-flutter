import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/device_models.dart';

/// Renders the same photo + letter composition for the app and all widgets.
class MobileLetterRenderer {
  static const sizes = <String, Size>{
    'portrait': Size(720, 1200),
    'square': Size(720, 720),
    'largeSquare': Size(1200, 1200),
  };

  static Future<Uint8List> render(
    Uint8List bytes,
    DailyContent content,
    String family,
  ) async {
    final size = sizes[family] ?? sizes['portrait']!;
    final photoHeight = size.height * .75;
    // Decode near the actual widget resolution. A phone photo can otherwise
    // occupy well over 100 MB and was previously decoded three times for each
    // carousel item (portrait, small square and large square).
    final isLandscape = content.photoOrientation == 'landscape';
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: isLandscape ? null : size.width.round(),
      targetHeight: isLandscape ? photoHeight.round() : null,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfff8f7f2),
    );
    final letterHeight = size.height * .25;
    _drawCover(
      canvas,
      image,
      Rect.fromLTWH(0, 0, size.width, size.height - letterHeight),
      content,
    );
    _drawLetter(
      canvas,
      content,
      Rect.fromLTWH(0, size.height - letterHeight, size.width, letterHeight),
      family,
    );
    final picture = recorder.endRecording();
    final output = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    output.dispose();
    codec.dispose();
    return data!.buffer.asUint8List();
  }

  static void _drawCover(
    Canvas canvas,
    ui.Image image,
    Rect target,
    DailyContent content,
  ) {
    final scale =
        (target.width / image.width).compareTo(target.height / image.height) > 0
            ? target.width / image.width
            : target.height / image.height;
    final srcW = target.width / scale, srcH = target.height / scale;
    final fx = (content.photo?.focusX ?? .5).clamp(.0, 1.0);
    final fy = (content.photo?.focusY ?? .45).clamp(.0, 1.0);
    final left = (fx * image.width - srcW / 2).clamp(0.0, image.width - srcW);
    final top = (fy * image.height - srcH / 2).clamp(0.0, image.height - srcH);
    final src = Rect.fromLTWH(left, top, srcW, srcH);
    canvas.drawImageRect(
      image,
      src,
      target,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  static void _drawLetter(
    Canvas canvas,
    DailyContent c,
    Rect rect,
    String family,
  ) {
    _drawPaperTexture(canvas, rect);
    // Every line follows the same inset and vertical rhythm. Any unused room
    // stays at the top and bottom instead of opening a random gap above the
    // date/signature row.
    final pad = rect.width * .095;
    final verticalInset = rect.height * .075;
    final rowGap = rect.height * .045;
    final zh = _captionZh(c.captionZh);
    final en = _captionEn(c.captionEn);
    final zhStyle = TextStyle(
      fontFamily: 'BloomHandwriting',
      fontSize: (rect.height * (family == 'square' ? .22 : .20)).clamp(
        30.0,
        86.0,
      ),
      color: const Color(0xff292929),
      height: 1.0,
      fontWeight: FontWeight.w500,
    );
    final maxWidth = rect.width - pad * 2;
    final oneLine = _layoutText(zh, zhStyle, maxWidth, maxLines: 1);
    var captionLines = <String>[zh];
    if ((oneLine?.didExceedMaxLines ?? false) && zh.length >= 12) {
      captionLines = _splitCaption(zh);
    }
    final indentText =
        captionLines.length == 2
            ? captionLines.first.substring(
              0,
              captionLines.first.length.clamp(0, 3),
            )
            : '';
    var fittedZhStyle = zhStyle;
    var indent =
        captionLines.length == 2 ? _measure(indentText, fittedZhStyle) : 0.0;
    while ((fittedZhStyle.fontSize ?? 28) > 24) {
      final first = _layoutText(
        captionLines.first,
        fittedZhStyle,
        maxWidth,
        maxLines: 1,
      );
      final second =
          captionLines.length == 2
              ? _layoutText(
                captionLines[1],
                fittedZhStyle,
                math.max(1, maxWidth - indent),
                maxLines: 1,
              )
              : null;
      if (!(first?.didExceedMaxLines ?? false) &&
          !(second?.didExceedMaxLines ?? false)) {
        break;
      }
      fittedZhStyle = fittedZhStyle.copyWith(
        fontSize: (fittedZhStyle.fontSize ?? 28) - 1,
      );
      indent =
          captionLines.length == 2 ? _measure(indentText, fittedZhStyle) : 0.0;
    }
    final zhPainter = _layoutText(
      captionLines.first,
      fittedZhStyle,
      maxWidth,
      maxLines: 1,
    );
    final secondPainter =
        captionLines.length == 2
            ? _fitText(
              captionLines[1],
              fittedZhStyle,
              math.max(1, maxWidth - indent),
              maxLines: 1,
              minSize: 24,
            )
            : null;
    final enStyle = TextStyle(
      fontFamily: 'BloomHandwriting',
      fontSize: (rect.height * (family == 'square' ? .105 : .10)).clamp(
        24.0,
        44.0,
      ),
      color: const Color(0xff4a4a4a),
      height: 1.08,
    );
    var enPainter = _fitText(
      en,
      enStyle,
      maxWidth,
      maxLines: family == 'square' ? 1 : 2,
      minSize: 21,
    );
    final metadata = _layoutMetadataRow(rect, c, family, pad);

    final zhHeight =
        (zhPainter?.height ?? 0) +
        (secondPainter == null ? 0 : rowGap + secondPainter.height);
    double contentHeight(TextPainter? english) {
      var height = zhHeight;
      if (english != null) height += rowGap + english.height;
      if (metadata.height > 0) height += rowGap + metadata.height;
      return height;
    }

    final availableHeight = rect.height - verticalInset * 2;
    if (enPainter != null && contentHeight(enPainter) > availableHeight) {
      enPainter = null;
    }
    final totalHeight = contentHeight(enPainter);
    var y = rect.top + math.max(verticalInset, (rect.height - totalHeight) / 2);
    if (zhPainter != null) {
      zhPainter.paint(canvas, Offset(rect.left + pad, y));
      y += zhPainter.height;
    }
    if (secondPainter != null) {
      y += rowGap;
      secondPainter.paint(canvas, Offset(rect.left + pad + indent, y));
      y += secondPainter.height;
    }
    if (enPainter != null) {
      y += rowGap;
      enPainter.paint(canvas, Offset(rect.left + pad, y));
      y += enPainter.height;
    }
    if (metadata.height > 0) {
      y += rowGap;
      metadata.paint(canvas, rect, pad, y);
    }
  }

  static _MetadataLayout _layoutMetadataRow(
    Rect rect,
    DailyContent content,
    String family,
    double pad,
  ) {
    final dateText = content.capturedDateText?.trim() ?? '';
    final locationText = content.locationText?.trim() ?? '';
    final available = rect.width - pad * 2;
    final style = TextStyle(
      fontFamily: 'BloomHandwriting',
      fontSize: (rect.height * (family == 'square' ? .105 : .095)).clamp(
        22.0,
        40.0,
      ),
      color: const Color(0xff74706a),
      height: 1.0,
    );
    return _MetadataLayout(
      date: _fitText(
        dateText,
        style,
        available * .42,
        maxLines: 1,
        minSize: 20,
      ),
      location: _fitText(
        locationText,
        style,
        available * .48,
        maxLines: 1,
        minSize: 20,
        align: TextAlign.right,
      ),
    );
  }

  /// A warm stationery surface with broad tonal variation, visible fibres,
  /// and a soft seam where the photo meets the paper. The texture stays
  /// restrained but survives launcher downscaling better than tiny noise.
  static void _drawPaperTexture(Canvas canvas, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, const [
          Color(0xfffaf7ef),
          Color(0xfff1ece0),
        ]),
    );
    final random = math.Random(
      1701 + rect.width.round() * 7 + rect.height.round(),
    );

    final cloud =
        Paint()
          ..color = const Color(0x0d7c705f)
          ..maskFilter = ui.MaskFilter.blur(
            ui.BlurStyle.normal,
            rect.height * .025,
          );
    for (var i = 0; i < 18; i++) {
      final center = Offset(
        rect.left + random.nextDouble() * rect.width,
        rect.top + random.nextDouble() * rect.height,
      );
      final width = rect.width * (.08 + random.nextDouble() * .16);
      final height = rect.height * (.06 + random.nextDouble() * .14);
      canvas.drawOval(
        Rect.fromCenter(center: center, width: width, height: height),
        cloud,
      );
    }

    final grain = Paint()..color = const Color(0x181b1711);
    final fiber =
        Paint()
          ..color = const Color(0x185f574b)
          ..strokeWidth = 1.15;
    final count = (rect.width * rect.height / 2600).round().clamp(140, 900);
    for (var i = 0; i < count; i++) {
      final x = rect.left + random.nextDouble() * rect.width;
      final y = rect.top + random.nextDouble() * rect.height;
      final radius = .45 + random.nextDouble() * 1.05;
      canvas.drawCircle(Offset(x, y), radius, grain);
    }
    for (var i = 0; i < 42; i++) {
      final y = rect.top + random.nextDouble() * rect.height;
      final x = rect.left + random.nextDouble() * rect.width * .82;
      final length = 18 + random.nextDouble() * 68;
      canvas.drawLine(Offset(x, y), Offset(x + length, y + .5), fiber);
    }

    final seamHeight = math.max(8.0, rect.height * .035);
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.top, rect.width, seamHeight),
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          Offset(rect.center.dx, rect.top + seamHeight),
          const [Color(0x250d0b08), Color(0x000d0b08)],
        ),
    );
    canvas.drawLine(
      rect.topLeft,
      rect.topRight,
      Paint()
        ..color = const Color(0x70fffdf8)
        ..strokeWidth = 1.4,
    );

    final edge =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = const Color(0x220b0906);
    canvas.drawRect(rect.deflate(.6), edge);
  }

  static TextPainter? _layoutText(
    String value,
    TextStyle style,
    double width, {
    required int maxLines,
    TextAlign align = TextAlign.left,
  }) {
    if (value.trim().isEmpty) return null;
    final painter = TextPainter(
      text: TextSpan(text: value.trim(), style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: width);
    return painter;
  }

  static TextPainter? _fitText(
    String value,
    TextStyle style,
    double width, {
    required int maxLines,
    required double minSize,
    TextAlign align = TextAlign.left,
  }) {
    if (value.trim().isEmpty) return null;
    var size = style.fontSize ?? 14;
    while (size >= minSize) {
      final painter = _layoutText(
        value,
        style.copyWith(fontSize: size),
        width,
        maxLines: maxLines,
        align: align,
      );
      if (painter != null && !painter.didExceedMaxLines) return painter;
      size -= 1;
    }
    return _layoutText(
      value,
      style.copyWith(fontSize: minSize),
      width,
      maxLines: maxLines,
      align: align,
    );
  }

  static double _measure(String value, TextStyle style) {
    final painter = _layoutText(value, style, double.infinity, maxLines: 1);
    return painter?.width ?? 0;
  }

  static List<String> _splitCaption(String text) {
    final split = text.length ~/ 2;
    const punctuation = '，。！？；、,!?; ';
    var index = split;
    for (var distance = 0; distance < text.length; distance++) {
      final left = split - distance;
      final right = split + distance;
      if (left > 1 && punctuation.contains(text[left - 1])) {
        index = left;
        break;
      }
      if (right < text.length - 1 && punctuation.contains(text[right - 1])) {
        index = right;
        break;
      }
    }
    return [text.substring(0, index), text.substring(index)];
  }

  /// Keep mobile/app/widget typography in lockstep with the server renderer.
  /// The server always supplies a quoted Chinese note and an em-dash English
  /// note; applying that normalization here also covers empty API fields.
  static String _captionZh(String? value) {
    final raw = (value ?? '').trim();
    final body = raw.isEmpty ? '今天，也值得看一眼。' : raw;
    return '「${body.replaceAll(RegExp(r'^[「」]|[「」]$'), '')}」';
  }

  static String _captionEn(String? value) {
    final raw = (value ?? '').trim().replaceFirst(RegExp(r'^[—–-]\s*'), '');
    return raw.isEmpty ? '' : '— $raw';
  }
}

class _MetadataLayout {
  const _MetadataLayout({this.date, this.location});

  final TextPainter? date;
  final TextPainter? location;

  double get height => math.max(date?.height ?? 0, location?.height ?? 0);

  void paint(Canvas canvas, Rect rect, double pad, double y) {
    date?.paint(canvas, Offset(rect.left + pad, y));
    final locationPainter = location;
    if (locationPainter != null) {
      locationPainter.paint(
        canvas,
        Offset(rect.right - pad - locationPainter.width, y),
      );
    }
  }
}
