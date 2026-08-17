import 'dart:math';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_models.dart';
import 'package:bloom_widget_bridge/bloom_widget_bridge.dart';

class DeviceIdentityRepository {
  DeviceIdentityRepository({
    SharedPreferences? preferences,
    FlutterSecureStorage? secureStorage,
    Future<String?> Function(String key)? readToken,
    Future<void> Function(String key, String value)? writeToken,
    Future<Map<String, String>?> Function()? stableCredentials,
  }) : _preferences = preferences,
       _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _readToken = readToken,
       _writeToken = writeToken,
       _stableCredentials = stableCredentials;

  static const _deviceIdKey = 'bloom.device_id';
  static const _deviceTokenKey = 'bloom.device_token';
  static const _identityVersionKey = 'bloom.identity_version';
  SharedPreferences? _preferences;
  final FlutterSecureStorage _secureStorage;
  final Future<String?> Function(String key)? _readToken;
  final Future<void> Function(String key, String value)? _writeToken;
  final Future<Map<String, String>?> Function()? _stableCredentials;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<DeviceCredentials?> read() async {
    if (Platform.isIOS) {
      final stable = await _iosStableCredentials();
      final id = stable?['deviceId'];
      final token = stable?['deviceToken'];
      if (id == null || token == null || token.length < 32) return null;
      return DeviceCredentials(deviceId: id, deviceToken: token);
    }
    final id = (await _prefs).getString(_deviceIdKey);
    final token =
        await (_readToken?.call(_deviceTokenKey) ??
            _secureStorage.read(key: _deviceTokenKey));
    if (id == null || token == null || token.length < 32) return null;
    return DeviceCredentials(deviceId: id, deviceToken: token);
  }

  Future<DeviceCredentials> initialize() async {
    if (Platform.isIOS) {
      final stable = await _iosStableCredentials();
      final id = stable?['deviceId'];
      final token = stable?['deviceToken'];
      if (id == null || token == null || token.length < 32) {
        throw StateError('无法创建稳定设备身份');
      }
      return DeviceCredentials(deviceId: id, deviceToken: token);
    }
    final prefs = await _prefs;
    final existing = await read();
    if (existing != null && prefs.getInt(_identityVersionKey) == 2) {
      return existing;
    }
    Map<String, String>? stable;
    try {
      stable =
          await (_stableCredentials?.call() ??
              BloomWidgetBridgePlatform.stableDeviceCredentials());
    } catch (_) {}
    // Once a credential has been registered, keep it. Changing an existing
    // device ID would orphan its server-side binding. Stable credentials are
    // used only for a fresh install with no prior local identity.
    final id =
        existing?.deviceId ??
        stable?['deviceId'] ??
        'bloom-mobile-${_uuidV4()}';
    final token =
        existing?.deviceToken ?? stable?['deviceToken'] ?? _randomHex(32);
    await (await _prefs).setString(_deviceIdKey, id);
    await (await _prefs).setInt(_identityVersionKey, 2);
    await (_writeToken?.call(_deviceTokenKey, token) ??
        _secureStorage.write(key: _deviceTokenKey, value: token));
    return DeviceCredentials(deviceId: id, deviceToken: token);
  }

  Future<Map<String, String>?> _iosStableCredentials() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        final value = await BloomWidgetBridgePlatform.stableDeviceCredentials();
        if (value != null) return value;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  String _randomHex(int bytes) {
    final random = Random.secure();
    return List.generate(
      bytes,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  String _uuidV4() {
    final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
