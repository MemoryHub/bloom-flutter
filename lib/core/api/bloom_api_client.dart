import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/auth_models.dart';
import '../models/device_models.dart';
import '../storage/display_preferences.dart';

class BloomApiException implements Exception {
  BloomApiException(this.statusCode, this.code, this.message);
  final int statusCode;
  final String? code;
  final String message;
  @override
  String toString() => 'BloomApiException($statusCode, $code): $message';
}

class BloomApiClient {
  static const _requestTimeout = Duration(seconds: 20);
  // Photo responses can be several megabytes and may be proxied from Immich.
  // They must not share the short timeout used by JSON status/plan calls.
  static const _photoRequestTimeout = Duration(seconds: 60);

  /// Carousel settings targets. The e-ink frame stores `eink`, the mobile
  /// widget stores `mobile`.
  static const settingsTargetEink = 'eink';
  static const settingsTargetMobile = 'mobile';

  BloomApiClient({http.Client? client, this.baseUrl = 'https://bloom.jihu.top'})
    : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$baseUrl$normalized').replace(queryParameters: query);
  }

  Map<String, String> _headers(String token, {String? etag}) => {
    'X-Frame-Token': token,
    'Accept': 'application/json',
    if (etag != null) 'If-None-Match': etag,
  };

  /// ⚠️ **App 里已经没有调用者了**，保留是为了对齐服务端仍然存在的接口
  /// （相框固件的注册/配对走的就是它）。
  ///
  /// App 不再走这条路：它靠激活码授权，建出来的是一台"未配对"设备，然后要
  /// 用户把设备号和六位码抄进 Immich 后台。现在归属由**登录**证明 ——
  /// 见 [claimDevice] 与 `AuthRepository.register`。
  Future<PairingInfo> register(
    DeviceCredentials credentials, {
    required String name,
    String timezone = 'Asia/Shanghai',
    String language = 'zh-CN',
  }) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/register',
          ),
          headers: {
            ..._headers(credentials.deviceToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'name': name,
            'device_type': 'mobile',
            'timezone': timezone,
            'language': language,
            'screen_profile': 'flutter-widget-v1',
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200, 201);
    return PairingInfo.fromJson(_json(response));
  }

  /// ⚠️ 同 [register]：App 里已经没有调用者了。它服务的"重新生成激活码"按钮
  /// 随配对页一起删掉了。
  Future<PairingInfo> refreshPairingCode(DeviceCredentials credentials) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/pairing-code',
          ),
          headers: _headers(credentials.deviceToken),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return PairingInfo.fromJson(_json(response));
  }

  Future<DeviceStatus> status(DeviceCredentials credentials) async {
    final response = await _client
        .get(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/status',
          ),
          headers: _headers(credentials.deviceToken),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return DeviceStatus.fromJson(_json(response));
  }

  Future<DailyContent> daily(
    DeviceCredentials credentials, {
    String target = 'mobile',
  }) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/daily',
          ),
          headers: {
            ..._headers(credentials.deviceToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'target': target}),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return DailyContent.fromJson(_json(response));
  }

  Future<http.Response> originalPhoto(
    DeviceCredentials credentials, {
    String? etag,
  }) async {
    final response = await _client
        .get(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/daily/photo',
          ),
          headers: {
            'X-Frame-Token': credentials.deviceToken,
            if (etag != null) 'If-None-Match': etag,
          },
        )
        .timeout(_photoRequestTimeout);
    if (response.statusCode != 200 && response.statusCode != 304) {
      _throw(response);
    }
    return response;
  }

  Future<CarouselItemEnvelope> carouselItem(
    DeviceCredentials credentials,
    BloomDisplaySettings settings, {
    bool next = false,
    int? currentItemId,
  }) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/carousel/item',
          ),
          headers: {
            ..._headers(credentials.deviceToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'target': 'mobile',
            'action': next ? 'next' : 'current',
            'timezone': 'Asia/Shanghai',
            'active_start': settings.activeStart,
            'active_end': settings.activeEnd,
            'interval_minutes': settings.intervalMinutes,
            if (currentItemId != null) 'current_item_id': currentItemId,
            if (next)
              'request_id':
                  '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return CarouselItemEnvelope.fromJson(_json(response));
  }

  /// One page of the day's carousel stream.
  ///
  /// [afterItemId] is the server's **paging cursor** — `after_item_id`, which
  /// has been in the API all along (`ge=1`) and which this app never sent. That
  /// omission is the whole "翻来覆去就那么两三张" bug: every request started at
  /// index 0 and got the same first four photos back. The batch size itself
  /// cannot be raised (`le=4` server-side), so the day is walked four at a time
  /// by handing back the last id each round.
  Future<CarouselPlanEnvelope> carouselPlan(
    DeviceCredentials credentials,
    BloomDisplaySettings settings, {
    int batchLimit = 4,
    int? afterItemId,
  }) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/carousel/plan',
          ),
          headers: {
            ..._headers(credentials.deviceToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'target': 'mobile',
            'timezone': 'Asia/Shanghai',
            'active_start': settings.activeStart,
            'active_end': settings.activeEnd,
            'interval_minutes': settings.intervalMinutes,
            // 上限 4 原本是相框固件的照片缓存深度，与计划元数据无关。手机端
            // 需要一次拿全天计划，因此不再按 4 截断；若服务端尚未放开上限，
            // 响应里的 has_more 会让调用方自行循环补齐。
            'batch_limit': batchLimit.clamp(1, 200),
            if (afterItemId != null) 'after_item_id': afterItemId,
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return CarouselPlanEnvelope.fromJson(_json(response));
  }

  Future<http.Response> carouselPhoto(
    DeviceCredentials credentials,
    int itemId, {
    String? etag,
  }) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/carousel/photo',
          ),
          headers: {
            'X-Frame-Token': credentials.deviceToken,
            'Content-Type': 'application/json',
            if (etag != null) 'If-None-Match': etag,
          },
          body: jsonEncode({'item_id': itemId}),
        )
        .timeout(_photoRequestTimeout);
    // 走同一个 `_ensure`，照片下载才会和其它接口一样留下「路径 + 状态」这条
    // 日志。它原来自己内联了状态判断，于是**唯独最需要计时的那条请求没有日志**
    // —— 首图慢的时候无法判断是下载慢还是渲染慢。
    _ensure(response, 200, 304);
    return response;
  }

  /// 替补：某格的原照片不可用时，请服务端换一张「当天计划之外」的合规照片。
  ///
  /// 服务端会在计划里就地替换该 item 的 asset（item_id 与格子时间不变），
  /// 因此替补之后重新取图即可。服务端接口尚未上线时本调用会抛异常，由调用方
  /// 按「替补不可用」降级处理（保持上一张 + 下载失败），不影响其余流程。
  Future<CarouselItemContent> substituteCarouselItem(
    DeviceCredentials credentials, {
    required int planId,
    required int itemId,
  }) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/carousel/item/substitute',
          ),
          headers: {
            ..._headers(credentials.deviceToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'target': 'mobile',
            'plan_id': planId,
            'item_id': itemId,
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    final json = _json(response);
    return CarouselItemContent.fromJson(json['item'] as Map<String, dynamic>);
  }

  /// Reads the carousel settings the server stores for [target].
  Future<String> frameOrientation(
    DeviceCredentials credentials, {
    required String frameDeviceId,
    String? mode,
  }) async {
    final action = mode == null ? 'get' : 'set';
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(frameDeviceId)}/orientation/settings/$action',
          ),
          headers: {
            ..._headers(credentials.deviceToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'caller_device_id': credentials.deviceId,
            if (mode != null) 'mode': mode,
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    final saved = _json(response)['mode'];
    if (saved != 'auto' && saved != 'locked') {
      throw const FormatException('invalid_orientation_mode');
    }
    return saved as String;
  }

  Future<DeviceCarouselSettingsEnvelope> getDeviceSettings(
    DeviceCredentials credentials, {
    required String target,
  }) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/carousel/settings/get',
          ),
          headers: {
            ..._headers(credentials.deviceToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'target': target}),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return DeviceCarouselSettingsEnvelope.fromJson(_json(response));
  }

  /// Writes the carousel settings the server stores for [target].
  ///
  /// [callerDeviceId] must be the device id that owns [credentials]: the app
  /// has no user login yet, so the server authorises the write by checking
  /// that the caller and the target device belong to the same account.
  ///
  /// [mode] is the display mode (`carousel` / `recommend`). It is **omitted
  /// from the request when `null`**, and the server then keeps the value it
  /// already stores — it does not reset it to the column default. That is the
  /// path for anything that must not touch a device's mode.
  ///
  /// Rejected writes are surfaced, never swallowed: 422 (interval not in the
  /// server's tier list, inverted active window, or a `mode` outside
  /// `carousel|recommend`) and 403 (the two devices are not on the same
  /// account) both throw a [BloomApiException] carrying the server's `detail`.
  Future<DeviceSettingsUpdateResult> setDeviceSettings(
    DeviceCredentials credentials, {
    required String target,
    required String timezone,
    required String activeStart,
    required String activeEnd,
    required int intervalMinutes,
    required String callerDeviceId,
    String? mode,
    List<Map<String, Object?>>? sources,
  }) async {
    final response = await _client
        .post(
          _uri(
            '/api/frame/devices/${Uri.encodeComponent(credentials.deviceId)}/carousel/settings/set',
          ),
          headers: {
            ..._headers(credentials.deviceToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'target': target,
            'timezone': timezone,
            'active_start': activeStart,
            'active_end': activeEnd,
            'interval_minutes': intervalMinutes,
            'caller_device_id': callerDeviceId,
            if (mode != null) 'mode': mode,
            // 不送 = 服务器保持已存的值（与 mode 同一规矩）。
            if (sources != null) 'sources': sources,
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return DeviceSettingsUpdateResult.fromJson(_json(response));
  }

  /// `POST /users/me/devices`, the devices bound to the signed-in user.
  ///
  /// F1 之前这里恒抛 [UnsupportedError]：那是用户会话接口，而 App 只有设备
  /// 令牌。现在账号体系落地，它变成真调用了 —— 响应形状也已对着服务端的
  /// `serialize_user_device` 核实过，不再是"待确认的猜测"。
  ///
  /// ⚠️ 用的是 [userToken]（账号会话），**不是**设备令牌。两者不能互换：
  /// 设备令牌只认自己那一台设备。
  Future<List<UserDevice>> listMyDevices(String userToken) async {
    final response = await _client
        .get(
          _uri('/api/frame/users/me/devices'),
          headers: _userHeaders(userToken),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    final devices = _json(response)['devices'];
    if (devices is! List) return const [];
    return devices
        .whereType<Map>()
        .map((item) => UserDevice.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  // ---------- F1 账号体系 ----------
  //
  // 会话用 Authorization: Bearer，与设备令牌（X-Frame-Token）并存。
  // 刻意分成两套头而不是合并成一个：合并之后任何一处调用都可能悄悄带上
  // 另一个身份，而"登录后小组件不再更新"这类症状极难定位。

  Map<String, String> _userHeaders(String userToken) => {
    'Authorization': 'Bearer $userToken',
    'Accept': 'application/json',
  };

  /// 下发短信验证码。`purpose` 为 `register` 或 `login`。
  ///
  /// 服务端在开发模式（`FRAME_SMS_PROVIDER=console`）下会在响应里带上
  /// `dev_code`，用于云片模板报备通过前联调；生产模式恒为 null。
  Future<SmsCodeResult> sendSmsCode({
    required String phone,
    required String purpose,
  }) async {
    final response = await _client
        .post(
          _uri('/api/frame/auth/sms/send'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({'phone': phone, 'purpose': purpose}),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return SmsCodeResult.fromJson(_json(response));
  }

  Future<AuthResult> registerAccount({
    required String phone,
    required String code,
    String? nickname,
    DeviceClaim? device,
  }) async {
    final response = await _client
        .post(
          _uri('/api/frame/auth/register'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'phone': phone,
            'code': code,
            if (nickname != null && nickname.trim().isNotEmpty)
              'nickname': nickname.trim(),
            if (device != null) 'device': device.toJson(),
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 201);
    return AuthResult.fromJson(_json(response));
  }

  Future<AuthResult> loginAccount({
    required String phone,
    required String code,
    DeviceClaim? device,
  }) async {
    final response = await _client
        .post(
          _uri('/api/frame/auth/login'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'phone': phone,
            'code': code,
            if (device != null) 'device': device.toJson(),
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return AuthResult.fromJson(_json(response));
  }

  /// 把本机认领到当前账号下，取回服务端下发的设备令牌。
  ///
  /// 登录接口里已经尝试过一次；[AuthResult.device] 为 null 时（注册后
  /// provisioning 还没跑完）用它重试，通常几秒后就成功。
  Future<ClaimedDevice> claimDevice({
    required String userToken,
    required DeviceClaim claim,
  }) async {
    final response = await _client
        .post(
          _uri('/api/frame/users/me/devices/claim'),
          headers: {
            ..._userHeaders(userToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode(claim.toJson()),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    final claimed = ClaimedDevice.fromJson(_json(response));
    if (claimed == null) {
      throw BloomApiException(500, 'device_claim_malformed', '服务端没有返回可用的设备令牌');
    }
    return claimed;
  }

  /// 服务端只吊销这一个会话；其他设备上的登录不受影响。
  Future<void> logoutAccount(String userToken) async {
    final response = await _client
        .post(_uri('/api/frame/auth/logout'), headers: _userHeaders(userToken))
        .timeout(_requestTimeout);
    // 204 是正常结果；另外把 401 也当成成功 —— token 本来就无效时，
    // 本地登出必须照样完成，否则用户会卡在"退不出去"的状态里。
    if (response.statusCode == 401) return;
    _ensure(response, 204);
  }

  Future<AccountInfo> fetchAccount(String userToken) async {
    final response = await _client
        .get(
          _uri('/api/frame/users/me/account'),
          headers: _userHeaders(userToken),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    final account = _json(response)['account'];
    if (account is! Map) {
      throw const FormatException('account: response has no "account" object');
    }
    return AccountInfo.fromJson(account.cast<String, dynamic>());
  }

  Map<String, dynamic> _json(http.Response response) =>
      jsonDecode(response.body) as Map<String, dynamic>;
  void _ensure(http.Response response, int expected, [int? second]) {
    // **Every call, with its status, on one line.**
    //
    // Without this there was no way to answer "接口到底成没成功" on a real phone:
    // a release build keeps its token in private storage, so the server's record
    // cannot be read back from outside the app. `adb logcat` now shows the path
    // and the status of every request the app makes, which is the evidence a
    // settings change (or a carousel refill) actually landed.
    debugPrint(
      '[BloomApi] ${response.request?.method ?? '?'} '
      '${response.request?.url.path ?? '?'} -> ${response.statusCode}',
    );
    if (response.statusCode != expected && response.statusCode != second) {
      _throw(response);
    }
  }

  Never _throw(http.Response response) {
    String? code;
    var message = '请求失败';
    try {
      final data = _json(response);
      final detail = data['detail'];
      code = (data['code'] ?? detail)?.toString();
      final resolved = data['message'] ?? _detailMessage(detail);
      if (resolved != null) message = resolved.toString();
    } catch (_) {}
    throw BloomApiException(response.statusCode, code, message);
  }

  /// Renders the server's `detail` field, keeping the reason readable when
  /// FastAPI answers 422 with a list of validation objects instead of a
  /// string.
  static Object? _detailMessage(Object? detail) {
    if (detail is List) {
      final parts = detail
          .map(
            (entry) =>
                entry is Map
                    ? (entry['msg'] ?? entry['detail'] ?? entry)
                    : entry,
          )
          .where((entry) => entry != null)
          .map((entry) => entry.toString())
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
      return parts.isEmpty ? null : parts.join('; ');
    }
    return detail;
  }
}
