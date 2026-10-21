import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/bloom_api_client.dart';

class FramePlaybackJob {
  FramePlaybackJob(this.data);
  final Map<String, dynamic> data;
  String? get id => data['id'] as String?;
  String get deviceId => data['device_id'] as String;
  String get name => data['device_name'] as String? ?? '相框';
  String get state => data['state'] as String? ?? 'queued';
  String get phase => data['phase'] as String? ?? '';
  int get receivedBytes => (data['received_bytes'] as num?)?.toInt() ?? 0;
  int get totalBytes => (data['total_bytes'] as num?)?.toInt() ?? 0;
  double? get progress {
    if (totalBytes <= 0 || receivedBytes < 0) return null;
    if (active && receivedBytes == 0) return null;
    return ((receivedBytes / totalBytes).clamp(0.0, 1.0)).toDouble();
  }

  int? get percent {
    final value = progress;
    return value == null ? null : (value * 100).round().clamp(0, 100).toInt();
  }

  DateTime get createdAt =>
      DateTime.tryParse(data['created_at']?.toString() ?? '') ?? DateTime(1970);
  bool get pendingSetup => state == 'awaiting_start';
  bool get active => state == 'queued' || state == 'running';
  bool get complete => state == 'succeeded';
  bool get failed => state == 'failed' || state == 'cancelled';
  String get key => id ?? 'pending.$deviceId';
}

/// Observes device-reported stages. Navigation and app suspension never cancel.
class FramePlaybackController extends ChangeNotifier
    with WidgetsBindingObserver {
  FramePlaybackController({BloomApiClient? api, this.poll = true})
    : api = api ?? BloomApiClient() {
    WidgetsBinding.instance.addObserver(this);
  }
  final BloomApiClient api;
  final bool poll;
  String? _token, _account;
  int _generation = 0, _revision = 0, _details = 0;
  bool _closed = false, _paused = false;
  int? _refreshGeneration;
  Timer? _timer;
  List<FramePlaybackJob> jobs = [];
  Set<String> _dismissed = {};
  final Set<String> _starting = {};
  Map<String, String> _requests = {};
  Map<String, String> _requestSetups = {};
  bool offline = false;
  void _changed() {
    if (!_closed) notifyListeners();
  }

  FramePlaybackJob? jobFor(String deviceId) {
    final list = jobs.where((j) => j.deviceId == deviceId).toList();
    if (list.isEmpty) return null;
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list.firstWhere((j) => j.active, orElse: () => list.first);
  }

  FramePlaybackJob? get bannerJob {
    if (_details > 0) return null;
    final latest =
        jobs
            .map((j) => j.deviceId)
            .toSet()
            .map(jobFor)
            .whereType<FramePlaybackJob>();
    for (final j in latest) {
      if (j.active) return j;
    }
    for (final j in latest) {
      if (!_dismissed.contains(j.key)) return j;
    }
    return null;
  }

  void openDetails() {
    _details++;
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  void closeDetails() {
    if (_details > 0) _details--;
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  bool starting(String deviceId) => _starting.contains(deviceId);
  Future<void> setSession(String? token, String? account) async {
    if (_token == token && _account == account) return;
    final g = ++_generation;
    _timer?.cancel();
    _revision++;
    _token = token;
    _account = account;
    jobs = [];
    _dismissed = {};
    _requests = {};
    _requestSetups = {};
    _starting.clear();
    _changed();
    if (token == null || account == null || _closed) return;
    final prefs = await SharedPreferences.getInstance();
    if (_closed || g != _generation) return;
    try {
      final raw = prefs.getString('bloom.first-playback.$account');
      if (raw != null) {
        final cached = jsonDecode(raw) as Map;
        jobs =
            (cached['jobs'] as List)
                .map(
                  (j) => FramePlaybackJob(Map<String, dynamic>.from(j as Map)),
                )
                .toList();
        _dismissed = (cached['dismissed'] as List).cast<String>().toSet();
        _requests = Map<String, String>.from(cached['requests'] as Map? ?? {});
        _requestSetups = Map<String, String>.from(
          cached['setups'] as Map? ?? {},
        );
      }
    } catch (_) {
      jobs = [];
    }
    _changed();
    await refresh();
  }

  Future<void> _persist(int g) async {
    final account = _account;
    if (_closed || g != _generation || account == null) return;
    final value = jsonEncode({
      'jobs': jobs.map((j) => j.data).toList(),
      'dismissed': _dismissed.toList(),
      'requests': _requests,
      'setups': _requestSetups,
    });
    final prefs = await SharedPreferences.getInstance();
    if (!_closed && g == _generation) {
      await prefs.setString('bloom.first-playback.$account', value);
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!poll || _closed || _paused || _token == null) return;
    _timer = Timer(
      Duration(seconds: jobs.any((j) => j.active) ? 2 : 30),
      () => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    final token = _token, g = _generation, revision = _revision;
    if (_closed || token == null || _refreshGeneration == g) return;
    _refreshGeneration = g;
    try {
      final response = await api.userRequest(token, 'first-playback-jobs');
      if (_closed || g != _generation || revision != _revision) return;
      jobs =
          (response['jobs'] as List)
              .map((j) => FramePlaybackJob(Map<String, dynamic>.from(j as Map)))
              .toList();
      jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      offline = false;
      _changed();
      unawaited(_persist(g));
    } catch (_) {
      if (!_closed && g == _generation) {
        offline = true;
        _changed();
      }
    } finally {
      if (_refreshGeneration == g) _refreshGeneration = null;
      if (g == _generation) _schedule();
    }
  }

  Future<void> start(
    String deviceId, {
    bool retry = false,
    bool newSetup = false,
  }) async {
    final token = _token, g = _generation;
    if (token == null) throw StateError('session_not_ready');
    if (_closed || starting(deviceId)) return;
    if (jobFor(deviceId)?.active == true && !newSetup) return;
    _starting.add(deviceId);
    if (newSetup) jobs.removeWhere((j) => j.deviceId == deviceId);
    _revision++;
    _changed();
    try {
      final current = jobFor(deviceId);
      final setup =
          current?.pendingSetup == true
              ? current!.createdAt.toIso8601String()
              : null;
      if (retry ||
          newSetup ||
          setup != null && _requestSetups[deviceId] != setup) {
        _requests.remove(deviceId);
      }
      if (setup != null) _requestSetups[deviceId] = setup;
      _requests.putIfAbsent(deviceId, () {
        final random = Random.secure();
        return List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
      });
      await _persist(g);
      if (_closed || g != _generation) return;
      final response = await api.userRequest(
        token,
        'devices/${Uri.encodeComponent(deviceId)}/first-playback',
        method: 'POST',
        body: {'request_id': _requests[deviceId]},
      );
      if (_closed || g != _generation) return;
      final job = FramePlaybackJob(
        Map<String, dynamic>.from(response['command'] as Map),
      );
      jobs = [
        job,
        ...jobs.where(
          (j) => j.deviceId != deviceId || !j.active && !j.pendingSetup,
        ),
      ];
      jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _revision++;
      _dismissed.remove(job.key);
      offline = false;
      _changed();
      await _persist(g);
      _schedule();
      unawaited(refresh());
    } finally {
      if (g == _generation) {
        _starting.remove(deviceId);
        _changed();
      }
    }
  }

  void dismiss(FramePlaybackJob job) {
    _dismissed.add(job.key);
    _changed();
    unawaited(_persist(_generation));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _timer?.cancel();
    } else {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class FramePlaybackScope extends InheritedNotifier<FramePlaybackController> {
  const FramePlaybackScope({
    super.key,
    required FramePlaybackController controller,
    required super.child,
  }) : super(notifier: controller);
  static FramePlaybackController? of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FramePlaybackScope>()
          ?.notifier;
}
