import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_models.dart';
import 'package:bloom_widget_bridge/bloom_widget_bridge.dart';

/// 本机 ID 与服务端令牌分别保存。原生稳定身份优先用于跨登录认领，
/// 临时通道失败时保留本地安全存储的认领凭据，不改变设备 ID。
class DeviceIdentityRepository {
  DeviceIdentityRepository({
    SharedPreferences? preferences,
    FlutterSecureStorage? secureStorage,
    Future<String?> Function(String key)? readToken,
    Future<void> Function(String key, String value)? writeToken,
    Future<void> Function(String deviceId, String deviceToken)? mirrorToWidget,
    Future<Map<String, String>?> Function()? stableCredentials,
  }) : _stableCredentialsOf =
           stableCredentials ??
           BloomWidgetBridgePlatform.stableDeviceCredentials,
       _preferences = preferences,
       _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _readToken = readToken,
       _writeToken = writeToken,
       _mirrorToWidget =
           mirrorToWidget ??
           // 包一层：桥接方法用的是命名参数，签名对不上位置参数的字段类型。
           ((deviceId, deviceToken) =>
               BloomWidgetBridgePlatform.writeDeviceCredentials(
                 deviceId: deviceId,
                 deviceToken: deviceToken,
               ));

  static const _deviceIdKey = 'bloom.device_id';
  static const _deviceTokenKey = 'bloom.device_token';
  static const _identityVersionKey = 'bloom.identity_version';
  static const _serverTokenKey = 'bloom.device_token_issued';
  SharedPreferences? _preferences;
  final FlutterSecureStorage _secureStorage;
  final Future<String?> Function(String key)? _readToken;
  final Future<void> Function(String key, String value)? _writeToken;

  /// 原生侧那份跨重装稳定的身份。见 [initialize]。
  final Future<Map<String, String>?> Function() _stableCredentialsOf;

  /// 把身份镜像到原生侧（iOS 的 App Group）。见 [save] 的说明。
  final Future<void> Function(String deviceId, String deviceToken)
  _mirrorToWidget;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  /// 读本机已保存的身份。没有（或残缺）返回 null，**不生成**。
  Future<DeviceCredentials?> read() async {
    final id = (await _prefs).getString(_deviceIdKey);
    final token =
        await (_readToken?.call(_deviceTokenKey) ??
            _secureStorage.read(key: _deviceTokenKey));
    if (id == null || token == null || token.length < 32) return null;
    return DeviceCredentials(deviceId: id, deviceToken: token);
  }

  /// 取回本机身份，没有就当场生成一个并持久化。
  ///
  /// ⚠️ **设备 ID 只生成一次，之后永远复用。** 它是"这台机器"的身份，不是一次
  /// 会话的凭证：登出、令牌过期、重启都不该让它变。变了就等于换了台设备 ——
  /// 服务端会新建一条记录（拿的是默认作息，而不是用户配好的那一套），设备列表
  /// 里不断堆出重复的手机，还会撞上每账号 10 台的额度。这个坑真实发生过：用户
  /// 登出再登录之后，首页的「下次更新」从自己的节奏变成了"明天 06:00"，因为新
  /// 记录的 `interval_minutes` 是服务端默认的 1440（一天一格）。
  ///
  /// **本方法不再抛异常，也不再碰原生通道。** 它以前在 iOS 上会因为
  /// `stableDeviceCredentials` 拿不到值而抛 `StateError`，而调用方只能把这个
  /// 异常当成"服务器连不上"来处理 —— 一个本地身份问题伪装成网络问题，
  /// 正是那个 bug 难查的原因。
  Future<DeviceCredentials> initialize() async {
    final prefs = await _prefs;
    final existingId = prefs.getString(_deviceIdKey);
    final storedToken =
        await (_readToken?.call(_deviceTokenKey) ??
            _secureStorage.read(key: _deviceTokenKey));
    final needsToken = storedToken == null || storedToken.length < 32;

    // 本机没存过 ID 时，先问原生侧要那个**跨重装稳定**的身份
    // （Android 用 ANDROID_ID 派生，iOS 走 Keychain）。这是用户模块之前的行为：
    // 重装 App 不该让服务端把你当成另一台设备 —— 否则你配好的轮播作息会留在旧
    // 记录上，新记录拿到默认的 1440（一天一格），首页就显示"明天 06:00"。
    //
    // ⚠️ 拿不到就**安静地退回随机**。以前这里是硬抛 `StateError`，调用方只能把它
    //    当成"连不上服务器"，一个本地身份问题伪装成网络问题 —— 那正是 iOS"全新
    //    安装首启卡在配对页"难查的原因。稳定性是**加分项**，不是启动的前提。
    var deviceId = existingId;
    var deviceToken = needsToken ? null : storedToken;
    if (deviceId == null || deviceToken == null) {
      final stable = await _stableCredentials();
      deviceId ??= stable?['deviceId'];
      if (stable?['deviceToken'] case final token? when token.length >= 32) {
        deviceToken ??= token;
      }
    }

    final credentials = DeviceCredentials(
      deviceId: deviceId ?? 'bloom-mobile-${_uuidV4()}',
      deviceToken: deviceToken ?? _randomHex(32),
    );
    // 只有确实缺东西时才写盘，省掉每次启动的存储写入。
    if (existingId != credentials.deviceId || needsToken) {
      await save(credentials);
    }
    // A failed platform-channel mirror must heal on the next launch. Only a
    // server-issued token is eligible; never publish a locally made placeholder.
    if (!needsToken && await hasServerToken()) {
      await _mirror(credentials.deviceId, credentials.deviceToken);
    }
    return credentials;
  }

  /// 问原生侧要稳定的设备身份。**任何失败都返回 null**（见 [initialize]）。
  Future<Map<String, String>?> _stableCredentials() async {
    try {
      return await _stableCredentialsOf();
    } catch (_) {
      // 平台通道还没装上、或原生侧拒绝了。退回随机，启动照常。
      return null;
    }
  }

  Future<String?> cachedAccountOwner() async =>
      (await _prefs).getString('bloom.photo_account_owner');
  Future<void> saveAccountOwner(String accountId) async =>
      (await _prefs).setString('bloom.photo_account_owner', accountId);

  Future<String> installClaimSecret() async {
    const key = 'bloom.install_claim_secret';
    final saved =
        await (_readToken?.call(key) ?? _secureStorage.read(key: key));
    if (saved != null && saved.length >= 32) return saved;
    final stable = await _stableCredentials();
    final secret = stable?['deviceToken'];
    final value =
        secret != null && secret.length >= 32 ? secret : _randomHex(32);
    await (_writeToken?.call(key, value) ??
        _secureStorage.write(key: key, value: value));
    return value;
  }

  /// 保存本机身份。
  ///
  /// 设备令牌由**服务端**在认领设备时下发（`claim_device`），所以登录之后要
  /// 用返回值覆盖掉本地那个占位令牌 —— 否则客户端拿着自己编的令牌去打
  /// `/carousel/plan`，服务端只会回 401。
  Future<void> save(DeviceCredentials credentials) async {
    await (await _prefs).setString(_deviceIdKey, credentials.deviceId);
    await (await _prefs).setInt(_identityVersionKey, 2);
    await (_writeToken?.call(_deviceTokenKey, credentials.deviceToken) ??
        _secureStorage.write(
          key: _deviceTokenKey,
          value: credentials.deviceToken,
        ));
    // ⚠️ 这里**刻意不镜像**给原生侧。本机自己编的那个令牌服务端不认（它比对
    // 的是下发时记下的 sha256），镜像过去只会让小组件拿着一个必然 401 的令牌
    // 反复请求。镜像只发生在服务端真的下发过令牌之后 —— 见 [saveIssued]。
  }

  /// 镜像进原生侧的共享存储。失败**不能**让保存失败 —— 身份已经落在 Dart 侧
  /// 了，原生那份只是给小组件读的副本。
  Future<void> _mirror(String deviceId, String deviceToken) async {
    try {
      await _mirrorToWidget(deviceId, deviceToken);
    } catch (_) {
      // 平台通道不可用（widget 测试、或原生还没挂上）。
    }
  }

  /// 服务端是否为这台设备下发过令牌。
  ///
  /// 用来回答"要不要再调一次认领接口"：注册那一刻服务端还在异步建 Immich
  /// 用户，登录响应里必然没有设备令牌，所以那一次必须补。没有这个标记的话，
  /// 客户端只能盲目地每次刷新都去认领一遍，而每次认领都会换一枚新令牌。
  Future<bool> hasServerToken() async =>
      (await _prefs).getBool(_serverTokenKey) ?? false;

  /// 保存服务端下发的设备令牌，并镜像给原生侧。
  ///
  /// 首次镜像在这里发生，后续 [initialize] 会用已下发令牌修复镜像。
  Future<void> saveIssued({
    required String deviceId,
    required String deviceToken,
  }) async {
    await save(DeviceCredentials(deviceId: deviceId, deviceToken: deviceToken));
    await (await _prefs).setBool(_serverTokenKey, true);
    // 小组件（iOS 上是独立进程）只认原生共享存储里的令牌，不读 Dart 的
    // SharedPreferences —— 漏掉这一步，App 里一切正常而小组件静静地不再更新。
    await _mirror(deviceId, deviceToken);
  }

  /// 登出：让本机再也拿不到图 —— 这就是"登出即冻结"的全部实现。
  ///
  /// ⚠️ **设备 ID 必须留下**（对比 [initialize] 的说明）。这里以前把它一起删
  /// 了，于是每次"登出→登录"都会变成一台全新的服务端设备：用户配好的作息留在
  /// 旧记录上，新记录拿服务端默认值（`interval_minutes=1440`，一天一格），首页
  /// 就会显示"明天 06:00"；同时设备列表里堆重复项、并很快撞上 10 台额度。
  ///
  /// 要冻结小组件，只需要三件事：清掉"令牌来自服务端"这个标记、删掉令牌本身、
  /// 把原生侧那份镜像抹掉。设备 ID 不在其中 —— 它没有取图能力，留着无害。
  Future<void> clear() async {
    await (await _prefs).remove(_serverTokenKey);
    await (_writeToken == null
        ? _secureStorage.delete(key: _deviceTokenKey)
        : _writeToken(_deviceTokenKey, ''));
    // 原生侧那份也必须抹掉：iOS 的小组件扩展不读 Dart 的存储，只认 App Group
    // 里的令牌。不抹的话"登出即冻结"在 iOS 上根本不生效。
    await _mirror('', '');
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
