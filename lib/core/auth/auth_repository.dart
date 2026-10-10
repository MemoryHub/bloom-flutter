import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/bloom_api_client.dart';
import '../models/auth_models.dart';
import '../models/device_models.dart';

/// 账号会话的本地存放与读写。
///
/// 与设备身份仓库（`DeviceIdentityRepository`）刻意分成两个仓库：那个存的是
/// "这台手机的小组件"的身份，这个存的是"这个人"的账号会话。
///
/// ⚠️ 两者的生命周期**在"登录即绑定"之后不再独立**：设备令牌由服务端在登录/
/// 认领设备时下发，而登出会把它一起清掉（小组件因此冻结在最后一张）。这个
/// 顺序由调用方（main.dart）协调 —— 本仓库只管会话，不碰设备身份。
///
/// 一条贯穿全文件的原则：**只有服务端明确说 401 才清除本地会话。**
/// 断网、超时、服务端 5xx 都不能把用户登出 —— 那会让"地铁里打开 App 就被
/// 踢回登录页"这种事发生，而重新登录并不能解决网络问题。
class AuthRepository {
  AuthRepository({
    BloomApiClient? api,
    FlutterSecureStorage? secureStorage,
    Future<String?> Function(String key)? readValue,
    Future<void> Function(String key, String value)? writeValue,
    Future<void> Function(String key)? deleteValue,
  }) : _api = api ?? BloomApiClient(),
       _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _readValue = readValue,
       _writeValue = writeValue,
       _deleteValue = deleteValue;

  static const tokenKey = 'bloom.account_token';
  static const accountKey = 'bloom.account_info';

  final BloomApiClient _api;
  final FlutterSecureStorage _secureStorage;
  final Future<String?> Function(String key)? _readValue;
  final Future<void> Function(String key, String value)? _writeValue;
  final Future<void> Function(String key)? _deleteValue;

  String? _token;
  AccountInfo? _account;

  /// 当前会话令牌；未登录时为 null。
  String? get token => _token;

  /// 最近一次已知的账号信息（可能来自本地缓存，因此可能是过期的）。
  AccountInfo? get account => _account;

  bool get isSignedIn => _token != null;

  Future<String?> _read(String key) =>
      _readValue?.call(key) ?? _secureStorage.read(key: key);

  Future<void> _write(String key, String value) =>
      _writeValue?.call(key, value) ??
      _secureStorage.write(key: key, value: value);

  Future<void> _delete(String key) =>
      _deleteValue?.call(key) ?? _secureStorage.delete(key: key);

  /// 从本地存储恢复会话。不发网络请求，因此可以离线、可以放在首帧之前。
  Future<AccountInfo?> load() async {
    final token = await _read(tokenKey);
    if (token == null || token.isEmpty) {
      _token = null;
      _account = null;
      return null;
    }
    _token = token;
    final raw = await _read(accountKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _account = AccountInfo.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
      } catch (_) {
        // 缓存形状不对就当没有 —— 它是纯展示用的，不值得让启动失败。
        _account = null;
      }
    }
    return _account;
  }

  /// 向服务端确认会话仍然有效，并刷新 provisioning 状态。
  ///
  /// 只有 401 才登出。网络错误一律保留本地会话并返回缓存，调用方据此决定
  /// 是显示"离线"还是继续用旧数据。
  Future<AccountInfo?> refresh() async {
    final token = _token;
    if (token == null) return null;
    try {
      final account = await _api.fetchAccount(token);
      if (_token != token) return _account;
      _account = account;
      await _persistAccount(account);
      return account;
    } on BloomApiException catch (error) {
      if (_token != token) return _account;
      if (error.statusCode == 401) {
        await clear();
        return null;
      }
      return _account;
    } catch (_) {
      return _account;
    }
  }

  Future<SmsCodeResult> sendCode({
    required String phone,
    required bool forRegister,
  }) => _api.sendSmsCode(
    phone: phone,
    purpose: forRegister ? 'register' : 'login',
  );

  /// 注册并登录。[device] 非空时顺带上报本机，服务端会在这一步认领它。
  ///
  /// 返回整个 [AuthResult] 而不只是账号 —— 里面可能带着服务端下发的设备令牌，
  /// 调用方需要把它存进设备身份仓库。
  Future<AuthResult> register({
    required String phone,
    required String code,
    String? nickname,
    DeviceClaim? device,
  }) async {
    final result = await _api.registerAccount(
      phone: phone,
      code: code,
      nickname: nickname,
      device: device,
    );
    await _adopt(result);
    return result;
  }

  Future<AuthResult> login({
    required String phone,
    required String code,
    DeviceClaim? device,
  }) async {
    final result = await _api.loginAccount(
      phone: phone,
      code: code,
      device: device,
    );
    await _adopt(result);
    return result;
  }

  /// 重试认领本机设备。
  ///
  /// 注册的那一刻服务端还在异步建 Immich 用户，所以登录响应里的 `device`
  /// 必然是 null。等 `/users/me/account` 报 `immich_ready` 之后调这里。
  Future<ClaimedDevice> claimDevice(DeviceClaim claim) async {
    final token = _token;
    if (token == null) {
      throw BloomApiException(401, 'not_signed_in', '还没有登录');
    }
    return _api.claimDevice(userToken: token, claim: claim);
  }

  /// 登出。
  ///
  /// 无论服务端是否响应成功，本地状态一定清干净 —— 用户点了"退出登录"却
  /// 因为一次网络超时而留在登录态，是最让人不信任的一类 bug。服务端那边
  /// 这个会话会在过期后自然失效。
  Future<void> signOut({DeviceCredentials? device}) async {
    final token = _token;
    await clear();
    if (token != null) {
      try {
        await _api.logoutAccount(token, device: device);
      } catch (_) {
        // 刻意吞掉：本地登出必须完成。
      }
    }
  }

  /// 只清本地，不通知服务端。令牌失效时用。
  Future<void> clear() async {
    _token = null;
    _account = null;
    await _delete(tokenKey);
    await _delete(accountKey);
  }

  Future<void> _adopt(AuthResult result) async {
    _token = result.token;
    _account = result.account;
    await _write(tokenKey, result.token);
    await _persistAccount(result.account);
  }

  Future<void> _persistAccount(AccountInfo account) async {
    await _write(
      accountKey,
      jsonEncode({
        'id': account.id,
        'phone': account.phone,
        'nickname': account.nickname,
        'provision_status': account.provisionStatus,
        'immich_ready': account.immichReady,
      }),
    );
  }
}
