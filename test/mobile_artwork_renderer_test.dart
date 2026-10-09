import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/rendering/mobile_artwork_renderer.dart';
import 'package:bloom/core/rendering/mobile_letter_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('BloomGallery')
      ..addFont(rootBundle.load('assets/fonts/Arimo.ttf'));
    await loader.load();
    await (FontLoader('BloomHandwriting')
      ..addFont(rootBundle.load('assets/fonts/mmxj.ttf'))).load();
  });
  test(
    'all 50 curated labels fit every phone widget size, including approximate dates',
    () {
      final works =
          (jsonDecode(
                    File(
                      'test/fixtures/curated_artwork_labels.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<Map<String, dynamic>>();
      expect(
        works
            .where((w) => MobileArtworkRenderer.artistLifespan(w).isNotEmpty)
            .length,
        49,
      );
      for (final work in works) {
        for (final size in MobileArtworkRenderer.sizes.values) {
          final layout = MobileArtworkRenderer.layoutLabel(work, size);
          for (final run in layout.runs) {
            final card = run.card == 'note' ? layout.noteCard! : layout.card;
            expect(
              run.bounds.right,
              lessThanOrEqualTo(card.right + .01),
              reason: work['slug'],
            );
            expect(
              run.bounds.bottom,
              lessThanOrEqualTo(card.bottom + .01),
              reason: work['slug'],
            );
            expect(
              run.bounds.left,
              greaterThanOrEqualTo(card.left - .01),
              reason: work['slug'],
            );
          }
          for (final flag in layout.flags) {
            expect(
              layout.runs.any((r) => r.bounds.overlaps(flag.bounds)),
              isFalse,
              reason: work['slug'],
            );
            expect(
              flag.bounds.right,
              lessThanOrEqualTo(layout.card.right + .01),
            );
          }
          if (size.width == size.height) {
            expect(layout.noteCard, isNotNull);
            expect(layout.cards.length, 2);
            expect(layout.card.width, closeTo(340 * layout.scale, .01));
            expect(
              layout.cards.fold<double>(
                0,
                (area, card) => area + card.width * card.height,
              ),
              lessThan(size.width * size.height * .24),
            );
            expect(
              layout.card.width * layout.card.height,
              lessThan(size.width * size.height * .14),
            );
          } else {
            expect(layout.card.width, closeTo(336 * layout.scale, .01));
            expect(
              layout.cards.fold<double>(
                0,
                (area, card) => area + card.width * card.height,
              ),
              lessThan(size.width * size.height * .18),
            );
          }
          {
            final note = layout.runs.where((r) => r.role == 'note').single;
            expect(
              note.painter.didExceedMaxLines,
              isFalse,
              reason: work['slug'],
            );
          }
          layout.dispose();
        }
      }
      expect(
        MobileArtworkRenderer.artistLifespan({
          'artist_birth_year': '1497/8',
          'artist_death_year': 1543,
        }),
        '1497/8–1543',
      );
    },
  );
  test('bounded caption retains explicit context without changing the story', () {
    final metadata = {
      'label_caption':
          'Painted in Arles, these sunflowers celebrate the many shades of yellow.',
      'short_description': 'Longer story. ' * 80,
    };
    expect(
      MobileArtworkRenderer.shortCaption(metadata),
      metadata['label_caption'],
    );
    expect(
      MobileArtworkRenderer.shortCaption({
        'short_description': 'A word ' * 100,
      }).length,
      lessThanOrEqualTo(110),
    );
  });
  test('missing values collapse and lifespan never overlaps a long name', () {
    final cases = <Map<String, dynamic>>[
      {},
      {'title': null, 'artist': null, 'year': null, 'label_caption': null},
      {
        'title': 'A long title ' * 100,
        'artist': 'A long artist name ' * 100,
        'year': 'c. 1888',
        'artist_birth_year': '1853',
        'artist_death_year': '1890',
        'artist_country_code': 'NL',
        'bloom_note_zh': '朋友还没到，欢迎已经画好了。原来大师等人，也会先忙着布置屋子。',
        'label_caption': 'A short context. A quiet moment at home.',
      },
      {
        'title': ['invalid'],
        'artist': {'invalid': true},
        'year': true,
      },
      {
        'title': 'Sunflowers',
        'artist': 'Vincent van Gogh',
        'year': '1888',
        'artist_birth_year': '1890',
        'artist_death_year': '1853',
      },
    ];
    for (final size in MobileArtworkRenderer.sizes.values) {
      for (final metadata in cases) {
        final layout = MobileArtworkRenderer.layoutLabel(metadata, size);
        expect(
          layout.card.height,
          lessThanOrEqualTo(312 * layout.scale + 0.01),
        );
        final boxes = <ui.Rect>[];
        for (final run in layout.runs) {
          expect(
            run.painter.text!.toPlainText(),
            isNot(anyOf('null', 'None', 'undefined')),
          );
          final card = run.card == 'note' ? layout.noteCard! : layout.card;
          expect(run.bounds.left, greaterThanOrEqualTo(card.left));
          expect(run.bounds.right, lessThanOrEqualTo(card.right + 0.01));
          expect(run.bounds.top, greaterThanOrEqualTo(card.top));
          expect(run.bounds.bottom, lessThanOrEqualTo(card.bottom + 0.01));
          for (final box in boxes) {
            expect(run.bounds.overlaps(box), isFalse);
          }
          boxes.add(run.bounds);
        }
        for (final flag in layout.flags) {
          expect(flag.bounds.right, lessThanOrEqualTo(layout.card.right));
          expect(boxes.any(flag.bounds.overlaps), isFalse);
        }
        if (layout.noteCard != null) {
          expect(layout.noteCard!.top, greaterThanOrEqualTo(0));
          expect(layout.noteCard!.left, layout.card.left);
          expect(layout.noteCard!.width, layout.card.width);
          expect(layout.noteCard!.bottom, lessThan(layout.card.top));
        }
        expect(
          layout.runs.where((r) => r.role == 'author').length,
          lessThanOrEqualTo(1),
        );
        layout.dispose();
      }
    }
    expect(
      MobileArtworkRenderer.artistLifespan({
        'artist_birth_year': 1853,
        'artist_death_year': 1890,
      }),
      '1853–1890',
    );
    expect(
      MobileArtworkRenderer.artistLifespan({
        'artist_birth_year': 1890,
        'artist_death_year': 1853,
      }),
      '',
    );
    expect(
      MobileArtworkRenderer.shortCaption({
        'label_caption': 'A short context. A quiet moment at home.',
      }),
      'A short context. A quiet moment at home.',
    );
  });
  test(
    'all widget families fill the canvas and route art through its label',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff2d64a0), ui.BlendMode.src);
      final input = await recorder.endRecording().toImage(800, 400);
      final bytes =
          (await input.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List();
      for (final family in MobileArtworkRenderer.sizes.keys) {
        final content = DailyContent(
          date: '2026-10-09',
          recommendationId: 1,
          sourceName: 'art',
          photoOrientation: 'landscape',
          artwork: {
            'artist': 'Artist ' * 60,
            'title': 'Title ' * 60,
            'year': '1890',
            'short_description': 'A word ' * 100,
            'artist_birth_year': '1853',
            'artist_death_year': '1890',
            'artist_country_code': 'NL',
            'bloom_note_zh': '朋友还没到，欢迎已经画好了。',
          },
        );
        final result = await MobileLetterRenderer.render(
          bytes,
          content,
          family,
        );
        final codec = await ui.instantiateImageCodec(result);
        final image = (await codec.getNextFrame()).image;
        final size = MobileArtworkRenderer.sizes[family]!;
        expect(image.width, size.width.toInt());
        expect(image.height, size.height.toInt());
        final pixels =
            (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
        for (final point in [
          (0, 0),
          (image.width - 1, 0),
          (0, image.height - 1),
          (image.width - 1, image.height - 1),
        ]) {
          final i = (point.$2 * image.width + point.$1) * 4;
          expect(pixels.sublist(i, i + 3), Uint8List.fromList([45, 100, 160]));
        }
        image.dispose();
        codec.dispose();
      }
      input.dispose();
    },
  );
}
