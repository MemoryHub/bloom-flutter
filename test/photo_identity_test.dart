import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bloom/core/storage/daily_content_repository.dart';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/carousel/photo_store.dart';
import 'package:bloom/core/models/device_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bloom-photo-identity');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.bloom/widget'),
          (call) async => call.method == 'cacheDirectory' ? dir.path : null,
        );
  });
  tearDown(() async {
    await dir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.bloom/widget'),
          null,
        );
  });
  test(
    'new caption cannot claim old mutable bytes or an already composed portrait',
    () async {
      final repository = DailyContentRepository(api: BloomApiClient());
      await File(
        '${dir.path}/daily.json',
      ).writeAsString('{"recommendation_id":2,"date":"2026-10-09"}');
      await File('${dir.path}/original.photo').writeAsBytes([1]);
      await File('${dir.path}/mobile-local-portrait-2.png').writeAsBytes([1]);
      expect(await repository.photoPathFor(2), isNull);
      final correct = File('${dir.path}/carousel-original-2.photo');
      await correct.writeAsBytes([2]);
      expect(
        await repository.photoPathFor(2),
        isNull,
        reason: 'unbound legacy bytes cannot prove asset identity',
      );
      await File(
        '${dir.path}/mobile-original-2.json',
      ).writeAsString(jsonEncode({'asset': 'a2', 'source': 'personal'}));
      expect(await repository.photoPathFor(2), correct.path);
    },
  );

  test(
    'missing source recovery replaces stale composites and omits old ETag',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff456789), ui.BlendMode.src);
      final input = await recorder.endRecording().toImage(10, 10);
      final bytes =
          (await input.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List();
      input.dispose();
      for (final family in ['portrait', 'square', 'largeSquare']) {
        await CarouselPhotoStore.renderedFile(
          dir,
          family,
          2,
        ).writeAsBytes([1, 2, 3]);
      }
      final api = BloomApiClient(
        client: MockClient((request) async {
          expect(
            request.headers['if-none-match'],
            isNull,
            reason: 'a missing file cannot satisfy a 304 response',
          );
          return http.Response.bytes(bytes, 200);
        }),
      );
      final result = await CarouselPhotoStore(api: api).prepare(
        dir: dir,
        item: CarouselItemContent(
          itemId: 2,
          assetId: 'a2',
          displayAt: DateTime(2026, 10, 9),
          photo: const PhotoAsset(url: 'unused'),
          sourceName: 'art',
          artwork: const {'title': 'A painting'},
        ),
        credentials: const DeviceCredentials(
          deviceId: 'test',
          deviceToken: 'test',
        ),
        etag: 'obsolete-source-etag',
      );
      expect(result.isReady, isTrue);
      for (final family in ['portrait', 'square', 'largeSquare']) {
        final png =
            await CarouselPhotoStore.renderedFile(dir, family, 2).readAsBytes();
        expect(png.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
      }
    },
  );
}
