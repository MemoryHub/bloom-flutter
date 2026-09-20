import 'dart:convert';
import 'dart:math';
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

  Future<CarouselPlanEnvelope> carouselPlan(
    DeviceCredentials credentials,
    BloomDisplaySettings settings, {
    int batchLimit = 4,
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
            'batch_limit': batchLimit.clamp(1, 4),
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

  Map<String, dynamic> _json(http.Response response) =>
      jsonDecode(response.body) as Map<String, dynamic>;
  void _ensure(http.Response response, int expected, [int? second]) {
    if (response.statusCode != expected && response.statusCode != second) {
      _throw(response);
    }
  }

  Never _throw(http.Response response) {
    String? code;
    var message = '请求失败';
    try {
      final data = _json(response);
      code = (data['code'] ?? data['detail'])?.toString();
      message = (data['message'] ?? data['detail'] ?? message).toString();
    } catch (_) {}
    throw BloomApiException(response.statusCode, code, message);
  }
}
