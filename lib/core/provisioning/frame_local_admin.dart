import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:bloom_provision/bloom_provision.dart';
import '../api/bloom_api_client.dart';
import '../auth/auth_repository.dart';

class FrameAdminStore {
  FrameAdminStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage storage;
  Future<String?> accountId() async {
    if (await storage.read(key: AuthRepository.tokenKey) == null) return null;
    final raw = await storage.read(key: AuthRepository.accountKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map)['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  String _key(String account, String device) =>
      'bloom.frame_admin.${sha256.convert(utf8.encode('$account|$device'))}';
  Future<Map<String, dynamic>?> read(String account, String device) async {
    final raw = await storage.read(key: _key(account, device));
    if (raw == null) return null;
    try {
      final value = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (value['account_id'] != account || value['device_id'] != device) {
        return null;
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    String account,
    String device,
    Map<String, dynamic> value,
  ) async {
    if (value['account_id'] != account || value['device_id'] != device) {
      throw PlatformException(code: 'identity_mismatch');
    }
    await storage.write(key: _key(account, device), value: jsonEncode(value));
  }

  Future<void> remove(String account, String device) =>
      storage.delete(key: _key(account, device));
}

String frameAdminChallenge(Map<String, dynamic> access, String nonce) {
  final hex = access['key'] as String;
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hex) ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(nonce)) {
    throw PlatformException(code: 'local_admin_denied');
  }
  final message =
      'bloom-local-admin-auth-v1|${access['device_id']}|$nonce|${access['epoch']}';
  return message;
}

/// Only called by explicit user operations or successful first pairing.
/// Reading a cached credential never scans, connects or changes device state.
class FrameLocalAdmin {
  FrameLocalAdmin({
    required this.api,
    required this.token,
    FrameAdminStore? store,
  }) : store = store ?? FrameAdminStore();
  final BloomApiClient api;
  final String token;
  final FrameAdminStore store;
  String path(String id) => 'devices/${Uri.encodeComponent(id)}/local-admin';
  Future<Map<String, dynamic>> access(String id, String account) async {
    final cached = await store.read(account, id);
    if (cached != null) return cached;
    final value = await api.userRequest(token, path(id));
    await store.write(account, id, value);
    return value;
  }

  Future<Map<String, dynamic>> install(
    String id,
    String account,
    BloomProvisionBridge bridge,
    Map<String, dynamic> hello,
  ) async {
    if (await store.accountId() != account) {
      throw PlatformException(code: 'account_changed');
    }
    if (hello['device_id'] != id) {
      throw PlatformException(code: 'identity_mismatch');
    }
    if (hello['local_admin_capable'] != true) {
      throw PlatformException(code: 'local_admin_unsupported');
    }
    final grant = await api.userRequest(
      token,
      path(id),
      method: 'POST',
      body: {'nonce': hello['nonce']},
    );
    if (await store.accountId() != account) {
      throw PlatformException(code: 'account_changed');
    }
    if (grant['account_id'] != account || grant['device_id'] != id) {
      throw PlatformException(code: 'identity_mismatch');
    }
    await bridge.data({
      'op': 'install_admin',
      'epoch': grant['epoch'],
      'public_key': grant['public_key'],
      'message': grant['message'],
      'signature': grant['signature'],
    });
    final cached =
        Map<String, dynamic>.from(grant)
          ..remove('message')
          ..remove('signature');
    await store.write(account, id, cached);
    return cached;
  }

  Future<void> prime(String id, BloomProvisionBridge bridge) async {
    final account = await store.accountId();
    if (account == null) return;
    final hello = await bridge.data({'op': 'hello'});
    if (hello['local_admin_capable'] != true) return;
    await install(id, account, bridge, hello);
  }
}
