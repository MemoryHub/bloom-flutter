import 'dart:convert';
import 'dart:io';
import 'package:bloom/core/storage/photo_time_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'breadcrumbs survive reopening, stay bounded, and contain only stages',
    () async {
      final dir = Directory.systemTemp.createTempSync('bloom-time-trace-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final trace = PhotoTimeTrace(directory: () async => dir.path);
      trace.record(PhotoTimeStage.saveSucceeded);
      await Future<void>.delayed(Duration.zero);
      final reopened = PhotoTimeTrace(directory: () async => dir.path);
      reopened.record(PhotoTimeStage.libraryReturned);
      await Future<void>.delayed(Duration.zero);
      final file = File('${dir.path}/photo-time-trace.jsonl');
      expect(file.readAsLinesSync().map((l) => jsonDecode(l)['stage']), [
        'saveSucceeded',
        'libraryReturned',
      ]);
      for (var i = 0; i < 200; i++) {
        reopened.record(PhotoTimeStage.contentRefreshStarted);
      }
      final lines = file.readAsLinesSync();
      expect(lines, hasLength(PhotoTimeTrace.maxEntries));
      for (final line in lines) {
        expect(
          (jsonDecode(line) as Map).keys,
          unorderedEquals(['at', 'stage']),
        );
      }
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    },
  );

  test('unavailable storage cannot interrupt the operation', () async {
    final trace = PhotoTimeTrace(
      directory: () async => throw StateError('no storage'),
    );
    trace.record(PhotoTimeStage.opened);
    await Future<void>.delayed(Duration.zero);
    expect(() => trace.record(PhotoTimeStage.saveSucceeded), returnsNormally);
  });
}
