import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../platform/widget_bridge.dart';

enum PhotoTimeStage {
  opened,
  dateOpened,
  dateClosed,
  clockOpened,
  clockClosed,
  saveStarted,
  saveSucceeded,
  saveFailed,
  editorDisposed,
  detailReturned,
  libraryReturned,
  libraryIndexStarted,
  libraryIndexFinished,
  contentRefreshStarted,
  contentRefreshFinished,
  contentRefreshFailed,
  homeLoadStarted,
  homeLoadFinished,
  homeLoadFailed,
}

/// A bounded, private breadcrumb journal for native crashes, which bypass Dart
/// exception handlers. Contains only timestamps and fixed stage names; never
/// photo IDs, dates, credentials, network bodies, or exception text.
class PhotoTimeTrace {
  PhotoTimeTrace({required this.directory});

  static final shared = PhotoTimeTrace(
    directory: () => WidgetBridge().cacheDirectory(),
  );
  final Future<String?> Function() directory;
  static const maxEntries = 128;
  final List<String> _lines = [];
  File? _file;
  bool _started = false;

  void record(PhotoTimeStage stage) {
    _lines.add(
      jsonEncode({'at': DateTime.now().toIso8601String(), 'stage': stage.name}),
    );
    _bound();
    if (!_started) {
      _started = true;
      unawaited(_open());
    }
    _flush();
  }

  Future<void> _open() async {
    try {
      final path = await directory();
      if (path == null) return;
      final dir = Directory(path)..createSync(recursive: true);
      final file = File('${dir.path}/photo-time-trace.jsonl');
      if (file.existsSync() && file.lengthSync() <= 32768) {
        _lines.insertAll(0, file.readAsLinesSync());
        _bound();
      }
      _file = file;
      _flush();
    } catch (_) {
      // Diagnostics must never interrupt editing, saving, or navigation.
    }
  }

  void _bound() {
    if (_lines.length > maxEntries) {
      _lines.removeRange(0, _lines.length - maxEntries);
    }
  }

  void _flush() {
    final file = _file;
    if (file == null) return;
    try {
      // Tiny synchronous, atomic writes preserve the last completed stage even
      // when the Dart VM crashes before another async callback can run.
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync('${_lines.join('\n')}\n', flush: true);
      temporary.renameSync(file.path);
    } catch (_) {}
  }
}
