import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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
    if (response.statusCode != 200 && response.statusCode != 304) {
      _throw(response);
    }
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
          }),
        )
        .timeout(_requestTimeout);
    _ensure(response, 200);
    return DeviceSettingsUpdateResult.fromJson(_json(response));
  }

  /// `POST /users/me/devices`, the devices bound to the signed-in user.
  ///
  /// This is a **user session** endpoint. The app only has a device token today
  /// (login is F1), which cannot authenticate it, so the call is intentionally
  /// not implemented: it always fails with [UnsupportedError] instead of
  /// pretending to work. The signature is declared so calling code and tests
  /// can be written against the intended shape; the exact response schema is
  /// unverified and must be confirmed against the backend when F1 lands.
  Future<List<Map<String, dynamic>>> listMyDevices() async {
    throw UnsupportedError(
      'listMyDevices 需要用户登录态（F1），当前设备令牌无法调用 users/me/devices。',
    );
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
      final parts =
          detail
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
