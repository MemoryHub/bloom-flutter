import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/bloom_api_client.dart';
import '../models/firmware_models.dart';

/// Account-scoped observer. Closing routes/app never sends an OTA cancellation.
class FirmwareUpdateController extends ChangeNotifier
    with WidgetsBindingObserver {
  FirmwareUpdateController({BloomApiClient? api, this.poll = true})
    : api = api ?? BloomApiClient() {
    WidgetsBinding.instance.addObserver(this);
  }
  final BloomApiClient api;
  final bool poll;
  String? _token;
  String? _accountId;
  int _generation = 0;
  int _revision = 0;
  int? _refreshGeneration;
  bool _disposed = false;
  bool _paused = false;
  Timer? _timer;
  List<FirmwareJob> _jobs = const [];
  Set<String> _dismissed = {};
  final Set<String> _mutations = {};
  bool offline = true;
  String? error;
  List<FirmwareJob> get jobs => List.unmodifiable(_jobs);
  bool get signedIn => _token != null;
  bool busy(String deviceId) => _mutations.contains(deviceId);
  bool hasActiveFor(String deviceId) =>
      _jobs.any((j) => j.deviceId == deviceId && j.active);
  FirmwareJob? jobFor(String deviceId) {
    final matching = _jobs.where((j) => j.deviceId == deviceId).toList();
    if (matching.isEmpty) return null;
    return matching.firstWhere((j) => j.active, orElse: () => matching.first);
  }

  FirmwareJob? get bannerJob {
    final active = _jobs.where((j) => j.active);
    if (active.isNotEmpty) return active.first;
    for (final job in _jobs) {
      if (!_dismissed.contains(job.id)) return job;
    }
    return null;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> setSession(String? token, String? accountId) async {
    if (token == _token && accountId == _accountId) return;
    final generation = ++_generation;
    _timer?.cancel();
    _token = token;
    _accountId = accountId;
    _jobs = const [];
    _dismissed = {};
    _mutations.clear();
    offline = true;
    error = null;
    _changed();
    if (token == null || accountId == null || _disposed) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || generation != _generation) return;
      _dismissed =
          prefs.getStringList('bloom.ota.dismissed.$accountId')?.toSet() ?? {};
      final raw = prefs.getString('bloom.ota.jobs.$accountId');
      if (raw != null) {
        _jobs =
            (jsonDecode(raw) as List)
                .map(
                  (v) =>
                      FirmwareJob.fromJson(Map<String, dynamic>.from(v as Map)),
                )
                .toList();
        _changed();
      }
    } catch (_) {
      /* Malformed cache cannot manufacture an update. */
    }
    if (!_disposed && generation == _generation) await refresh();
  }

  Future<void> _persist(int generation) async {
    final accountId = _accountId;
    if (_disposed || generation != _generation || accountId == null) return;
    final raw = jsonEncode(_jobs.map((j) => j.toJson()).toList());
    final dismissed = _dismissed.toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || generation != _generation) return;
      await prefs.setString('bloom.ota.jobs.$accountId', raw);
      await prefs.setStringList('bloom.ota.dismissed.$accountId', dismissed);
    } catch (_) {
      // Server jobs remain authoritative when local storage is unavailable.
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || _paused || !poll || _token == null) return;
    _timer = Timer(
      Duration(seconds: _jobs.any((j) => j.active) ? 4 : 30),
      () => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    final token = _token, generation = _generation;
    final revision = _revision;
    if (_disposed || token == null || _refreshGeneration == generation) return;
    _refreshGeneration = generation;
    try {
      final jobs = await api.firmwareJobs(token);
      if (_disposed ||
          generation != _generation ||
          token != _token ||
          revision != _revision) {
        return;
      }
      _jobs = jobs;
      _dismissed.removeWhere((id) => !jobs.any((j) => j.id == id));
      offline = false;
      error = null;
      _changed();
      await _persist(generation);
    } on BloomApiException catch (e) {
      if (_disposed || generation != _generation) return;
      offline = true;
      error = firmwareErrorMessage(e);
      if (e.statusCode == 401 || e.statusCode == 403) {
        _jobs = const [];
        await _persist(generation);
      }
      _changed();
    } catch (_) {
      if (_disposed || generation != _generation) return;
      offline = true;
      error = '暂时无法同步，正在等待更新状态';
      _changed();
    } finally {
      if (_refreshGeneration == generation) _refreshGeneration = null;
      if (generation == _generation) _schedule();
    }
  }

  Future<FirmwareCheck> check(String deviceId) async {
    final token = _token, generation = _generation;
    final revision = _revision;
    if (token == null) throw StateError('请先登录');
    final result = await api.checkFirmware(token, deviceId);
    if (_disposed || generation != _generation) throw StateError('账号已变化，请重新打开');
    if (result.job != null && revision == _revision) _upsert(result.job!);
    return result;
  }

  void _upsert(FirmwareJob job) {
    ++_revision;
    _jobs = [
      job,
      ..._jobs.where(
        (j) =>
            j.id != job.id &&
            !(job.active && j.deviceId == job.deviceId && j.active),
      ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (job.active) _dismissed.remove(job.id);
    _changed();
    _schedule();
    unawaited(_persist(_generation));
  }

  Future<void> start(String deviceId, FirmwareRelease release) async {
    final token = _token, generation = _generation;
    if (token == null || busy(deviceId)) return;
    _mutations.add(deviceId);
    _changed();
    try {
      final job = await api.startFirmwareUpdate(token, deviceId, release.id);
      if (!_disposed && generation == _generation) {
        _upsert(job);
        unawaited(refresh());
      }
    } finally {
      if (generation == _generation) {
        _mutations.remove(deviceId);
        _changed();
      }
    }
  }

  Future<void> cancel(FirmwareJob job) async {
    final token = _token, generation = _generation;
    if (token == null || busy(job.deviceId) || !job.canCancel) return;
    _mutations.add(job.deviceId);
    _changed();
    try {
      final result = await api.cancelFirmwareUpdate(token, job);
      if (!_disposed && generation == _generation) _upsert(result);
    } on BloomApiException catch (e) {
      if (!_disposed && generation == _generation) {
        error = firmwareErrorMessage(e);
        _changed();
        unawaited(refresh());
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        _mutations.remove(job.deviceId);
        _changed();
      }
    }
  }

  Future<void> dismiss(FirmwareJob job) async {
    if (job.active) return;
    _dismissed.add(job.id);
    _changed();
    await _persist(_generation);
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
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

String firmwareErrorMessage(Object e) {
  if (e is! BloomApiException) return '暂时无法连接，请稍后重试';
  return switch (e.code) {
    'firmware_update_in_progress' => '相框正在更新，请等待完成或确认停止后再操作',
    'firmware_install_cannot_cancel' => '固件已经开始安装，请等待更新完成',
    'ota_baseline_required' => '相框的固件更新暂未就绪',
    'firmware_already_current' => '相框已是当前版本，请重新检测',
    'firmware_release_unavailable' => '此更新暂不可用，请重新检测',
    'device_not_owned' => '只有相框主人可以更新固件',
    _ =>
      e.statusCode == 404
          ? '固件更新服务暂未启用，请稍后重试'
          : e.statusCode == 401
          ? '登录状态已失效，请重新登录'
          : '暂时无法连接，请稍后重试',
  };
}
