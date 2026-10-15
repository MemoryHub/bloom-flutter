import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:bloom_provision/bloom_provision.dart';
import '../api/bloom_api_client.dart';
import 'frame_local_admin.dart';
import 'frame_setup_controller.dart';

class FrameNetworkController extends ChangeNotifier {
  FrameNetworkController({
    required this.api,
    required this.token,
    required this.deviceId,
    BloomProvisionBridge? bridge,
    FrameAdminStore? store,
    this.pause = _pause,
  }) : bridge = bridge ?? const BloomProvisionBridge(),
       store = store ?? FrameAdminStore();
  static Future<void> _pause(Duration time) => Future<void>.delayed(time);
  final BloomApiClient api;
  final String token, deviceId;
  final BloomProvisionBridge bridge;
  final FrameAdminStore store;
  final Future<void> Function(Duration) pause;
  static FrameNetworkController? _lease;
  bool busy = false, connected = false, success = false, _closed = false;
  int _generation = 0;
  String phase = 'idle';
  String? error, _account;
  List<Map<String, dynamic>> networks = [];
  Map<String, dynamic>? summary;
  String get progress => switch (phase) {
    'bluetooth_connecting' => '正在连接相框…',
    'authenticating' => '正在验证相框…',
    'scanning' => '正在获取 Wi-Fi 列表…',
    'wifi_connecting' => '正在连接 Wi-Fi…',
    'network_removing' => '正在移除网络…',
    'success' => '操作已完成',
    _ => '正在准备…',
  };
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> _check(int generation) async {
    if (_closed || generation != _generation || _lease != this) {
      throw PlatformException(code: 'cancelled');
    }
    if (_account != null && await store.accountId() != _account) {
      throw PlatformException(code: 'account_changed');
    }
    if (_closed || generation != _generation) {
      throw PlatformException(code: 'cancelled');
    }
  }

  Future<bool> _run(
    Future<void> Function(int) action, {
    bool release = false,
  }) async {
    if (busy || _closed) return false;
    if (_lease != null && _lease != this) {
      error = '另一项相框操作正在进行，请稍后重试。';
      _notify();
      return false;
    }
    _lease = this;
    busy = true;
    success = false;
    error = null;
    final generation = ++_generation;
    _notify();
    try {
      await action(generation);
      await _check(generation);
      return true;
    } catch (e) {
      if (!_closed && generation == _generation) {
        error = frameSetupError(e);
        success = false;
        await _release();
      }
      return false;
    } finally {
      if (release) await _release();
      if (!_closed && generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> _connect(int generation) async {
    _account = await store.accountId();
    if (_account == null) throw PlatformException(code: 'account_changed');
    await _check(generation);
    phase = 'bluetooth_connecting';
    _notify();
    final admin = FrameLocalAdmin(api: api, token: token, store: store);
    var access = await admin.access(deviceId, _account!);
    await _check(generation);
    await bridge.disconnect();
    await _check(generation);
    final found = await bridge.scan();
    await _check(generation);
    if (!found.any((device) => device['ble_name'] == access['ble_name'])) {
      throw PlatformException(code: 'device_not_found');
    }
    if (found.any(
      (device) =>
          device['ble_name'] == access['ble_name'] && device['busy'] == true,
    )) {
      throw PlatformException(code: 'device_busy');
    }
    await bridge.connect(access['ble_name'] as String, access['pop'] as String);
    await _check(generation);
    var hello = await bridge.data({'op': 'hello'});
    await _check(generation);
    if (hello['device_id'] != deviceId) {
      throw PlatformException(code: 'identity_mismatch');
    }
    if (hello['local_admin_capable'] != true || hello['ble_standby'] != true) {
      throw PlatformException(code: 'local_admin_unsupported');
    }
    phase = 'authenticating';
    _notify();
    if (hello['local_admin_epoch'] != access['epoch']) {
      access = await admin.install(deviceId, _account!, bridge, hello);
      await _check(generation);
      hello = await bridge.data({'op': 'hello'});
      await _check(generation);
    }
    final signature = await bridge.signAdmin(
      frameAdminChallenge(access, hello['nonce'] as String),
      access['key'] as String,
    );
    await _check(generation);
    await bridge.data({
      'op': 'admin_auth',
      'epoch': access['epoch'],
      'signature': signature,
    });
    await _check(generation);
    connected = true;
    await bridge.data({'op': 'admin_begin'});
    await _check(generation);
    for (var attempt = 0; attempt < 25; attempt++) {
      final status = await bridge.data({'op': 'status'});
      await _check(generation);
      if (status['business_busy'] == true) {
        throw PlatformException(code: 'frame_busy');
      }
      if (status['management_ready'] == true) {
        await _saveSummary(status);
        return;
      }
      await pause(const Duration(milliseconds: 200));
      await _check(generation);
    }
    throw PlatformException(code: 'timeout');
  }

  Future<void> _saveSummary(Map<String, dynamic> status) async {
    if (_account == null) return;
    final value = await store.read(_account!, deviceId);
    if (value == null) return;
    final previous =
        summary ??
        (value['network'] is Map
            ? Map<String, dynamic>.from(value['network'] as Map)
            : <String, dynamic>{});
    final saved = status['saved_networks'] ?? previous['saved_networks'] ?? [];
    final recent =
        status['wifi_ssid'] != '' ? status['wifi_ssid'] : previous['wifi_ssid'];
    summary = {
      'ble_name': value['ble_name'],
      'wifi_ssid': (saved as List).contains(recent) ? recent : null,
      'saved_networks': saved,
      'seen_at': DateTime.now().toUtc().toIso8601String(),
    };
    value['network'] = summary;
    await store.write(_account!, deviceId, value);
  }

  Future<bool> startAdding() => _run((generation) async {
    await _connect(generation);
    phase = 'scanning';
    _notify();
    networks = [];
    await bridge.data({'op': 'admin_scan'});
    await _check(generation);
    Map<String, dynamic>? result;
    for (var attempt = 0; attempt < 60; attempt++) {
      result = await bridge.data({'op': 'admin_scan_result', 'offset': 0});
      await _check(generation);
      if (result['finished'] == true) break;
      await pause(const Duration(milliseconds: 300));
      await _check(generation);
    }
    if (result?['finished'] != true) {
      throw PlatformException(code: 'wifi_scan_failed');
    }
    final count = (result!['count'] as num).toInt();
    for (var offset = 0; offset < count; offset += 2) {
      if (offset != 0) {
        result = await bridge.data({
          'op': 'admin_scan_result',
          'offset': offset,
        });
        await _check(generation);
      }
      for (final entry in result!['networks'] as List) {
        final network = Map<String, dynamic>.from(entry as Map);
        if ((network['ssid'] as String).isNotEmpty) {
          final existing = networks.indexWhere(
            (n) => n['ssid'] == network['ssid'],
          );
          if (existing < 0) {
            networks.add(network);
          } else if ((network['rssi'] as num) >
              (networks[existing]['rssi'] as num)) {
            networks[existing] = network;
          }
        }
      }
    }
    networks.sort((a, b) => (b['rssi'] as num).compareTo(a['rssi'] as num));
    phase = 'network_ready';
  });
  Future<bool> connectWifi(String ssid, String password) => _run((
    generation,
  ) async {
    if (!connected) await _connect(generation);
    phase = 'wifi_connecting';
    _notify();
    await bridge.data({'op': 'connect', 'ssid': ssid, 'password': password});
    await _check(generation);
    await _waitResult(generation, 'wifi_success');
    success = true;
    phase = 'success';
  }, release: true);
  Future<bool> removeNetwork(String ssid) => _run((generation) async {
    await _connect(generation);
    phase = 'network_removing';
    _notify();
    await bridge.data({'op': 'forget', 'ssid': ssid});
    await _check(generation);
    final status = await _waitResult(generation, 'network_removed');
    if ((status['saved_networks'] as List).contains(ssid)) {
      throw PlatformException(code: 'network_remove_failed');
    }
    success = true;
    phase = 'success';
  }, release: true);
  Future<Map<String, dynamic>> _waitResult(
    int generation,
    String expected,
  ) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final status = await bridge.data({'op': 'status'});
      await _check(generation);
      if (status['business_busy'] == true) {
        throw PlatformException(code: 'frame_busy');
      }
      final stage = status['phase'];
      if (stage == expected) {
        await _saveSummary(status);
        return status;
      }
      if ({
        'wifi_failed',
        'storage_failed',
        'playback_interrupted',
        'network_full',
      }.contains(stage)) {
        throw PlatformException(code: stage as String);
      }
      await pause(const Duration(milliseconds: 250));
      await _check(generation);
    }
    throw PlatformException(code: 'timeout');
  }

  Future<void> _release() async {
    if (_lease != this) return;
    try {
      if (connected) await bridge.data({'op': 'admin_end'});
    } catch (_) {}
    try {
      await bridge.disconnect();
    } catch (_) {}
    connected = false;
    if (_lease == this) _lease = null;
  }

  Future<void> cancel() async {
    ++_generation;
    await _release();
    if (!_closed) {
      busy = false;
      phase = 'idle';
      _notify();
    }
  }

  @override
  void dispose() {
    _closed = true;
    ++_generation;
    unawaited(_release());
    super.dispose();
  }
}
