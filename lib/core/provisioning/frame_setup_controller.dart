import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:bloom_provision/bloom_provision.dart';
import '../api/bloom_api_client.dart';
import 'frame_local_admin.dart';

class FrameSetupCode {
  const FrameSetupCode(this.bleName, this.pop);
  final String bleName, pop;
  static FrameSetupCode? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'bloom' ||
        uri.host != 'setup' ||
        uri.pathSegments.length != 1) {
      return null;
    }
    final name = uri.pathSegments.single;
    final pop = uri.queryParameters['pop'] ?? '';
    if (!RegExp(r'^BLOOM_[A-F0-9]{12}$').hasMatch(name) ||
        !RegExp(r'^[A-Za-z0-9_-]{32,64}$').hasMatch(pop)) {
      return null;
    }
    return FrameSetupCode(name, pop);
  }
}

String frameSetupError(Object error) {
  final code =
      error is PlatformException
          ? error.code
          : error is BloomApiException
          ? error.code
          : null;
  return switch (code) {
    'configuration_busy' || 'busy' => '相框正在处理另一项操作，请稍后重试。',
    'device_busy' => '相框正在被其他手机操作，请稍后重试。',
    'permission_or_credentials_invalid' => '网络信息或管理授权无效，请检查后重新连接。',
    'frame_busy' || 'playback_interrupted' => '相框正在刷新画面，请稍后重试。',
    'cloud_check_unsupported' => '相框固件暂不支持立即连接，请更新相框固件。',
    'server_check_failed' => '相框未确认立即连接请求，请稍后重试。',
    'local_admin_unsupported' => '请先更新相框固件，再使用新的 Wi-Fi 管理功能。',
    'local_admin_denied' => '本机的相框管理授权已失效，请联网重新获取授权。',
    'account_changed' => '登录账号已改变，请返回设备页后重试。',
    'management_not_ready' => '相框网络管理尚未就绪，请重新连接。',
    'cancelled' => '操作已取消。',
    'bluetooth_off' => '请开启手机蓝牙，再寻找相框。',
    'permission_required' ||
    'permission_denied' => '请在 iPhone 设置 → Bloom 中允许蓝牙访问，然后重试。',
    'bluetooth_or_permission_unavailable' ||
    'bluetooth_initializing' => '手机蓝牙暂未就绪，请稍后重试。',
    'bluetooth_unsupported' => '这台手机不支持相框所需的蓝牙连接。',
    'bluetooth_scan_failed' => '蓝牙搜索未完成，请重新寻找相框。',
    'bluetooth_connection_failed' => '未能建立相框蓝牙连接，请靠近相框后重试。',
    'bluetooth_service_failed' => '未能读取相框的蓝牙接口，请重新连接。',
    'chunk_invalid' => '相框未能接收完整配置，请重新连接后重试。',
    'configuration_too_large' => '配置内容过长，请检查网络名称和密码。',
    'communication_failed' => '相框蓝牙通信中断，请重新连接后重试。',
    'wifi_scan_failed' => '相框未能返回 Wi-Fi 列表，请重新搜索。',
    'timeout' => '连接相框超时，请靠近相框后重试。',
    'disconnected' => '相框蓝牙连接已断开，请重新连接。',
    'device_not_owned' => '这台相框已有主人。加入供图请扫描主人 App 中的设备二维码。',
    'first_playback_baseline_required' => '相框需要先更新固件，才能开始首次播放。',
    'no_photos_available' => '图库暂时没有可播放的照片，请先添加照片。',
    'frame_not_prepared' ||
    'provision_baseline_required' => '相框需要先完成电脑预装，请使用新版准备工具。',
    'frame_setup_in_progress' => '这台相框正在由另一台手机添加，请稍后再试。',
    'frame_first_playback_in_progress' => '这台相框正在准备首次播放，请在原手机查看初始化进度，完成后再操作。',
    'firmware_update_in_progress' => '相框正在更新，完成后再连接 Wi-Fi。',
    'device_reset_in_progress' => '相框正在重置，请等待完成。',
    'reset_relay_unsupported' => '相框固件尚不支持手机协助重置，请先更新固件。',
    'reset_authorization_denied' => '重置授权未确认，任务已保留，请重新连接继续。',
    'reset_finalizing' => '重置结果已同步，相框正在完成清理并重启，请稍后重新连接。',
    'reset_commit_denied' => '重置同步尚未完成，请保持供电并重新连接继续。',
    'wifi_auth_failed' => '相框未通过 Wi-Fi 认证，请检查密码后重试。已有网络已保留。',
    'wifi_not_found' => '相框未找到这个 Wi-Fi，请确认网络可用并重新搜索。已有网络已保留。',
    'wifi_ip_failed' => '相框已连接路由器，但未取得 IP 地址，请检查路由器后重试。',
    'wifi_failed' => '未能连接 Wi-Fi，请检查密码及 2.4 GHz 网络后重试。',
    'storage_failed' => '网络未能保存，请重试。已有网络会保留。',
    'network_full' => '已保存 6 个网络，请先移除一个不再使用的网络。',
    'network_remove_failed' => '相框仍保存着这个 Wi-Fi，尚未确认移除，请重新连接后重试。',
    'device_not_found' => '暂未发现这台相框，请确认它已开机并靠近手机。',
    'setup_session_expired' || 'session_expired' => '连接已中断，请重新连接相框后继续。',
    'identity_verification_failed' ||
    'identity_mismatch' => '相框身份验证未通过，请扫描它的设备二维码后重试。',
    _ => '操作未完成，请检查手机网络和相框连接后重试。',
  };
}

class FrameSetupController extends ChangeNotifier {
  FrameSetupController({
    required this.api,
    required this.token,
    this.bridge = const BloomProvisionBridge(),
    this.existingDeviceId,
    String? existingName,
  }) : name = existingName ?? 'Bloom-Ink';
  final BloomApiClient api;
  final String token;
  final BloomProvisionBridge bridge;
  final String? existingDeviceId;
  bool _standbyCapable = false;
  String name;
  int step = 0;
  bool busy = false, scanning = false, connected = false, completed = false;
  String? error, deviceId, bleName;
  String phase = '';
  bool hasExistingPhotos = false;
  FrameSetupCode? scannedCode;
  Map<String, dynamic>? _credentials;
  List<Map<String, dynamic>> nearby = [], networks = [];
  final List<String> savedNetworks = [];
  bool _closed = false;
  int _generation = 0;
  Timer? _rescan, _leaseTimer;
  String? _setupAttempt;
  String? _leaseDeviceId, _renewingAttempt;
  DateTime? _leaseValidUntil;
  bool _leaseLost = false;

  Future<void> _endSetupAttempt({String? only}) async {
    final attempt = _setupAttempt, id = _leaseDeviceId;
    if (attempt == null || (only != null && attempt != only)) return;
    _setupAttempt = null;
    _leaseDeviceId = null;
    _leaseValidUntil = null;
    _leaseTimer?.cancel();
    if (id != null) await _releaseAttempt(attempt, id);
  }

  Future<Map<String, dynamic>?> _reserveCredentials(
    String selectedName,
    int g,
  ) async {
    await _endSetupAttempt();
    if (!_valid(g)) return null;
    final random = Random.secure();
    final attempt =
        List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
    _setupAttempt = attempt;
    final requestedAt = DateTime.now();
    try {
      final credentials = await api.userRequest(
        token,
        'frame-setup/${Uri.encodeComponent(selectedName)}/session',
        method: 'POST',
        body: {'attempt_id': attempt},
      );
      final id = credentials['device_id'] as String;
      if (!_valid(g) || _setupAttempt != attempt) {
        // Disposal can precede the response that grants the lease.
        await _releaseAttempt(attempt, id);
        return null;
      }
      _leaseDeviceId = id;
      _leaseValidUntil = requestedAt.add(const Duration(seconds: 60));
      _leaseLost = false;
      _startLeaseHeartbeat(attempt, id);
      return credentials;
    } catch (_) {
      await _endSetupAttempt(only: attempt);
      rethrow;
    }
  }

  Future<void> _releaseAttempt(String attempt, String id) async {
    try {
      await api
          .userRequest(
            token,
            'devices/${Uri.encodeComponent(id)}/setup-lease/release',
            method: 'POST',
            body: {'attempt_id': attempt},
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // A killed/offline phone cannot promise cleanup. The lease expires.
    }
  }

  void _startLeaseHeartbeat(String attempt, String id) {
    _leaseTimer?.cancel();
    _leaseTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_closed || _setupAttempt != attempt || _renewingAttempt == attempt) {
        return;
      }
      _renewingAttempt = attempt;
      final requestedAt = DateTime.now();
      try {
        await api.userRequest(
          token,
          'devices/${Uri.encodeComponent(id)}/setup-lease/renew',
          method: 'POST',
          body: {'attempt_id': attempt},
        );
        if (!_closed && _setupAttempt == attempt) {
          _leaseValidUntil = requestedAt.add(const Duration(seconds: 60));
        }
      } catch (e) {
        if (!_closed &&
            _setupAttempt == attempt &&
            e is BloomApiException &&
            e.statusCode == 409) {
          _leaseLost = true;
        }
      } finally {
        if (_renewingAttempt == attempt) _renewingAttempt = null;
      }
    });
  }

  bool get managing => existingDeviceId != null;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  bool _valid(int g) => !_closed && g == _generation;

  Future<void> pauseDiscovery() async {
    if (_closed) return;
    _rescan?.cancel();
    _generation++;
    scanning = false;
    _notify();
    // Both native implementations cancel their pending scan and finish its
    // MethodChannel result. Late callbacks belong to the previous generation.
    await bridge.disconnect();
  }

  Future<void> discover({FrameSetupCode? code}) async {
    if (code != null) {
      await recognizeQr(code);
      return;
    }
    if (busy || scanning || _closed) return;
    _rescan?.cancel();
    scannedCode = code;
    scanning = true;
    error = null;
    _notify();
    final g = _generation;
    try {
      final list = await bridge.scan();
      if (!_valid(g)) return;
      nearby = list;
      scanning = false;
      _notify();
    } catch (e) {
      if (_valid(g)) error = frameSetupError(e);
    } finally {
      if (_valid(g)) {
        scanning = false;
        _notify();
      }
    }
    if (code == null && _valid(g) && step == 0 && error == null) {
      _rescan = Timer(const Duration(seconds: 2), () => unawaited(discover()));
    }
  }

  Future<void> recognizeQr(FrameSetupCode code) async {
    if (busy || _closed) return;
    busy = true;
    error = null;
    await pauseDiscovery();
    if (_closed) return;
    scannedCode = code;
    final g = _generation;
    _notify();
    try {
      final credentials = await _reserveCredentials(code.bleName, g);
      if (!_valid(g) || credentials == null) return;
      if (credentials['pop'] != code.pop ||
          (existingDeviceId != null &&
              credentials['device_id'] != existingDeviceId)) {
        throw PlatformException(code: 'identity_mismatch');
      }
      _credentials = credentials;
      deviceId = credentials['device_id'] as String;
      bleName = code.bleName;
      connected = false;
      if (credentials['saved_networks'] is List) {
        savedNetworks
          ..clear()
          ..addAll((credentials['saved_networks'] as List).cast<String>());
      }
      if (credentials['owned'] == true) {
        name = credentials['name'] as String? ?? name;
      }
      await _connectAndVerify(g);
      if (!_valid(g)) return;
      step =
          1; // Recognition succeeds only after the physical secure BLE hello.
      if (managing) await chooseName(name);
    } catch (e) {
      if (_valid(g)) {
        error = frameSetupError(e);
        connected = false;
        await bridge.disconnect();
        await _endSetupAttempt();
      }
    } finally {
      if (_valid(g)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> select(String selectedName, {String? expectedPop}) async {
    if (busy || _closed) return;
    _rescan?.cancel();
    busy = true;
    error = null;
    _notify();
    await pauseDiscovery();
    if (_closed) return;
    final g = _generation;
    try {
      final credentials = await _reserveCredentials(selectedName, g);
      if (!_valid(g) || credentials == null) return;
      if (expectedPop != null && credentials['pop'] != expectedPop) {
        throw PlatformException(code: 'identity_mismatch');
      }
      if (existingDeviceId != null &&
          credentials['device_id'] != existingDeviceId) {
        throw PlatformException(code: 'identity_mismatch');
      }
      _credentials = credentials;
      connected = false;
      deviceId = credentials['device_id'] as String;
      bleName = selectedName;
      if (credentials['saved_networks'] is List) {
        savedNetworks
          ..clear()
          ..addAll((credentials['saved_networks'] as List).cast<String>());
      }
      if (!managing && credentials['owned'] == true) {
        name = credentials['name'] as String? ?? name;
      }
      await _connectAndVerify(g);
      if (!_valid(g)) return;
      step = 1;
      if (managing) await chooseName(name);
    } catch (e) {
      if (_valid(g)) {
        error = frameSetupError(e);
        connected = false;
        await bridge.disconnect();
        await _endSetupAttempt();
      }
    } finally {
      if (_valid(g)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> _connectAndVerify(int g) async {
    phase = 'bluetooth_connecting';
    _notify();

    final selectedName = bleName;
    final credentials = _credentials;
    if (selectedName == null || credentials == null) {
      throw PlatformException(code: 'identity_verification_failed');
    }
    await bridge.disconnect();
    if (!_valid(g)) return;
    final found = await bridge.scan();
    if (!_valid(g)) return;
    if (!found.any((v) => v['ble_name'] == selectedName)) {
      throw PlatformException(code: 'device_not_found');
    }
    if (found.any((v) => v['ble_name'] == selectedName && v['busy'] == true)) {
      throw PlatformException(code: 'device_busy');
    }
    await bridge.connect(selectedName, credentials['pop'] as String);
    if (!_valid(g)) return;
    final hello = await bridge.data({'op': 'hello'});
    if (hello['device_id'] != deviceId) {
      throw PlatformException(code: 'identity_mismatch');
    }
    if (!_valid(g)) return;
    _standbyCapable = hello['ble_standby'] == true;
    // Cloud finish may have succeeded just before the phone lost BLE. The
    // next explicit setup attempt can deliver the signed final seal without
    // an old local admin key; no credentials are exposed by the receipt.
    final pendingStage = hello['reset_relay_stage'] as num? ?? 0;
    if (hello['reset_relay_version'] == 2 &&
        pendingStage >= 5 &&
        pendingStage < 7) {
      final status = await bridge.data({'op': 'reset_status'});
      if (!_valid(g)) return;
      if (status['relay_version'] == 2 &&
          status['finished_receipt'] is String) {
        final job = status['job'] as String;
        final seal = await api.userRequest(
          token,
          'devices/${Uri.encodeComponent(deviceId!)}/commands/${Uri.encodeComponent(job)}/ble-reset/finish',
          method: 'POST',
          body: {'relay_version': 2, 'receipt': status['finished_receipt']},
        );
        if (!_valid(g)) return;
        await bridge.data({
          'op': 'reset_finish',
          'message': seal['message'],
          'signature': seal['signature'],
        });
        if (!_valid(g)) return;
        throw PlatformException(code: 'reset_finalizing');
      }
    }
    connected = true;
  }

  Future<void> chooseName(String value) async {
    final cleaned = value.trim();
    if (cleaned.isEmpty || cleaned.runes.length > 32) {
      error = '给相框取一个 1–32 字的名字吧。';
      _notify();
      return;
    }
    if (busy && !managing || _closed) return;
    name = cleaned;
    step = 2;
    busy = true;
    networks = [];
    phase = 'bluetooth_connecting';
    error = null;
    _notify();
    final g = _generation;
    try {
      if (!connected) await _connectAndVerify(g);
      if (!_valid(g)) return;
      phase = 'wifi_scanning';
      _notify();
      if (_standbyCapable) {
        await bridge.data({'op': 'setup_scan'});
        if (!_valid(g)) return;
        var ready = false;
        for (var attempt = 0; attempt < 25; attempt++) {
          final status = await bridge.data({'op': 'setup_radio_status'});
          if (!_valid(g)) return;
          if (status['ready'] == true) {
            ready = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (!ready) throw PlatformException(code: 'wifi_scan_failed');
      }
      final found = await bridge.networks();
      if (!_valid(g)) return;
      final unique = <String, Map<String, dynamic>>{};
      for (final network in found) {
        final ssid = network['ssid'] as String? ?? '';
        if (ssid.isEmpty) continue;
        if (!unique.containsKey(ssid) ||
            (network['rssi'] as num) > (unique[ssid]!['rssi'] as num)) {
          unique[ssid] = network;
        }
      }
      networks =
          unique.values.toList()
            ..sort((a, b) => (b['rssi'] as num).compareTo(a['rssi'] as num));
      step = 2;
    } catch (e) {
      if (_valid(g)) {
        error = frameSetupError(e);
        connected = false;
        await bridge.disconnect();
      }
    } finally {
      if (_valid(g)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> connectWifi(
    String ssid,
    String password, {
    bool reuse = false,
  }) async {
    if (busy || deviceId == null || _closed || !connected) return;
    busy = true;
    error = null;
    phase = 'wifi_connecting';
    _notify();
    final g = _generation;
    final id = deviceId!;
    String? attempt;
    try {
      // Wi-Fi retries may follow a released failed attempt. Reserve again
      // before issuing a new ticket, while the normal wizard keeps one lease.
      if (_setupAttempt == null) {
        final credentials = await _reserveCredentials(bleName!, g);
        if (!_valid(g) || credentials == null) return;
        attempt = _setupAttempt;
        if (credentials['device_id'] != id ||
            credentials['pop'] != _credentials?['pop']) {
          throw PlatformException(code: 'identity_mismatch');
        }
      }
      attempt = _setupAttempt;
      if (attempt == null ||
          _leaseLost ||
          _leaseValidUntil == null ||
          !DateTime.now().isBefore(_leaseValidUntil!)) {
        throw PlatformException(code: 'setup_session_expired');
      }
      final hello = await bridge.data({'op': 'hello'});
      if (!_valid(g)) return;
      if (hello['device_id'] != deviceId) {
        throw PlatformException(code: 'identity_mismatch');
      }
      final requestedAt = DateTime.now();
      final ticket = await api.userRequest(
        token,
        'devices/${Uri.encodeComponent(deviceId!)}/setup-ticket',
        method: 'POST',
        body: {
          'nonce': hello['nonce'],
          'action': 'wifi',
          'attempt_id': attempt,
        },
      );
      if (!_valid(g)) return;
      _leaseValidUntil = requestedAt.add(const Duration(seconds: 60));
      _startLeaseHeartbeat(attempt, id);
      await bridge.data({
        'op': 'connect',
        'ssid': ssid,
        'password': password,
        'reuse': reuse,
        ...ticket,
      });
      bool claimed = false;
      final started = DateTime.now();
      while (_valid(g) &&
          DateTime.now().difference(started) < const Duration(seconds: 150)) {
        if (!claimed &&
            (_leaseLost || !DateTime.now().isBefore(_leaseValidUntil!))) {
          throw PlatformException(code: 'setup_session_expired');
        }
        final status = await bridge.data({'op': 'status'});
        if (status['device_id'] != deviceId) {
          throw PlatformException(code: 'identity_mismatch');
        }
        if (!_valid(g)) return;
        phase = status['phase'] as String? ?? 'service_connecting';
        _notify();
        if (const {
          'wifi_failed',
          'wifi_auth_failed',
          'wifi_not_found',
          'wifi_ip_failed',
          'storage_failed',
          'network_full',
          'playback_interrupted',
        }.contains(phase)) {
          throw PlatformException(code: phase);
        }
        if (!claimed &&
            (phase == 'waiting_owner' && status['pairing_code'] != null ||
                phase == 'ready' && status['owned'] == true)) {
          final completedSetup = await api.userRequest(
            token,
            'devices/${Uri.encodeComponent(deviceId!)}/complete-setup',
            method: 'POST',
            body: {
              'name': name,
              'attempt_id': attempt,
              'pairing_code': status['pairing_code'] ?? '000000',
              'first_playback_capable': true,
            },
          );
          if (!_valid(g)) return;
          hasExistingPhotos = completedSetup['has_existing_photos'] == true;
          claimed = true;
          _leaseTimer?.cancel();
          _leaseLost = false;
          // Optional for older firmware/backends; it must not invalidate pairing.
          try {
            await FrameLocalAdmin(
              api: api,
              token: token,
            ).prime(deviceId!, bridge);
          } catch (_) {}
        }
        if (claimed && phase == 'ready' && status['owned'] == true) {
          completed = true;
          phase = 'success';
          _notify();
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      throw PlatformException(code: 'setup_session_expired');
    } catch (e) {
      if (_valid(g)) {
        error = frameSetupError(e);
        if (e is PlatformException &&
            const {
              'communication_failed',
              'disconnected',
              'timeout',
              'chunk_invalid',
              'session_expired',
              'setup_session_expired',
            }.contains(e.code)) {
          connected = false;
          networks = [];
          await bridge.disconnect();
        }
      }
    } finally {
      if (_setupAttempt == attempt) {
        _leaseTimer?.cancel();
        _setupAttempt = null;
        _leaseDeviceId = null;
        _leaseValidUntil = null;
      }
      if (attempt != null) await _releaseAttempt(attempt, id);
      if (_valid(g)) {
        busy = false;
        _notify();
      }
    }
  }

  void photos() {
    if (completed) {
      step = 3;
      _notify();
    }
  }

  void back() {
    if (busy || completed) return;
    if (step == 2 && !managing) {
      step = 1;
    } else {
      step = 0;
      connected = false;
      _generation++;
      unawaited(_endSetupAttempt());
      unawaited(bridge.disconnect());
    }
    error = null;
    _notify();
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _rescan?.cancel();
    _leaseTimer?.cancel();
    unawaited(_endSetupAttempt());
    unawaited(bridge.disconnect());
    super.dispose();
  }
}
