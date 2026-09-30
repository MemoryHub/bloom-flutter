class DeviceCredentials {
  const DeviceCredentials({required this.deviceId, required this.deviceToken});

  final String deviceId;
  final String deviceToken;
}

class PairingInfo {
  const PairingInfo({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  factory PairingInfo.fromJson(Map<String, dynamic> json) => PairingInfo(
    code: json['pairing_code'] as String,
    expiresAt: DateTime.parse(json['pairing_expires_at'] as String),
  );
}

class DeviceStatus {
  const DeviceStatus({
    required this.paired,
    required this.hasAssets,
    this.mode,
  });

  final bool paired;
  final bool hasAssets;

  /// **The mode the server wants this device in** — the raw wire value
  /// (`DeviceCarouselSettings.modeCarousel` / `modeRecommend`).
  ///
  /// `/status` always carries it (the server defaults it to `carousel` when the
  /// device has no settings row yet), and it is the authoritative answer to
  /// "which mode is this device in". The local mirror the home-screen widget
  /// reads is only this phone's *copy* of that answer.
  ///
  /// It used to be dropped on the floor here, and the home page read the mirror
  /// instead — which is exactly how the same phone ended up showing 推荐模式 on
  /// the home page and 轮播模式 on its own device page.
  final String? mode;

  factory DeviceStatus.fromJson(Map<String, dynamic> json) => DeviceStatus(
    paired: json['paired'] as bool? ?? false,
    hasAssets: json['has_assets'] as bool? ?? false,
    mode: json['mode'] as String?,
  );
}

class WidgetAsset {
  const WidgetAsset({required this.url, this.etag, this.contentVersion});

  final String url;
  final String? etag;
  final String? contentVersion;

  factory WidgetAsset.fromJson(Map<String, dynamic> json) => WidgetAsset(
    url: json['url'] as String,
    etag: json['etag'] as String?,
    contentVersion: json['content_version'] as String?,
  );
}

class PhotoAsset {
  const PhotoAsset({
    required this.url,
    this.format,
    this.width,
    this.height,
    this.orientation,
    this.focusX,
    this.focusY,
  });
  final String url;
  final String? format;
  final int? width;
  final int? height;
  final String? orientation;
  final double? focusX;
  final double? focusY;
  factory PhotoAsset.fromJson(Map<String, dynamic> json) => PhotoAsset(
    url: (json['url'] ?? json['post_url']) as String,
    format: json['format'] as String?,
    width: (json['width'] as num?)?.toInt(),
    height: (json['height'] as num?)?.toInt(),
    orientation: json['orientation'] as String?,
    focusX: (json['focus_x'] as num?)?.toDouble(),
    focusY: (json['focus_y'] as num?)?.toDouble(),
  );
}

class CarouselItemContent {
  const CarouselItemContent({
    required this.itemId,
    required this.displayAt,
    required this.photo,
    this.assetId = '',
    this.captionZh,
    this.captionEn,
    this.capturedDateText,
    this.locationText,
    this.photoOrientation,
  });

  final int itemId;
  final DateTime displayAt;
  final PhotoAsset photo;

  /// 该格照片对应的相册 asset。计划换代时按 item_id 求交集，替补时需要把
  /// 当天计划里已出现的 asset 全部排除，因此必须保留。
  final String assetId;

  final String? captionZh;
  final String? captionEn;
  final String? capturedDateText;
  final String? locationText;
  final String? photoOrientation;

  factory CarouselItemContent.fromJson(Map<String, dynamic> json) {
    final caption = json['caption'] as Map<String, dynamic>? ?? const {};
    return CarouselItemContent(
      itemId: (json['item_id'] as num).toInt(),
      displayAt: DateTime.parse(json['display_at'] as String),
      photo: PhotoAsset.fromJson(json['photo'] as Map<String, dynamic>),
      assetId: json['asset_id'] as String? ?? '',
      captionZh: caption['zh'] as String?,
      captionEn: caption['en'] as String?,
      capturedDateText: json['captured_date_text'] as String?,
      locationText: json['location_text'] as String?,
      photoOrientation: json['photo_orientation'] as String?,
    );
  }

  DailyContent asDailyContent() => DailyContent(
    date: displayAt.toLocal().toIso8601String().substring(0, 10),
    recommendationId: itemId,
    photo: photo,
    captionZh: captionZh,
    captionEn: captionEn,
    capturedDateText: capturedDateText,
    locationText: locationText,
    photoOrientation: photoOrientation,
  );
}

class CarouselItemEnvelope {
  const CarouselItemEnvelope({required this.item, required this.nextCheckAt});

  final CarouselItemContent item;
  final DateTime nextCheckAt;

  factory CarouselItemEnvelope.fromJson(Map<String, dynamic> json) =>
      CarouselItemEnvelope(
        item: CarouselItemContent.fromJson(
          json['item'] as Map<String, dynamic>,
        ),
        nextCheckAt: DateTime.parse(json['next_check_at'] as String),
      );
}

class CarouselPlanEnvelope {
  const CarouselPlanEnvelope({
    required this.planId,
    required this.currentItemId,
    required this.nextCheckAt,
    required this.items,
    this.hasMore = false,
    this.settingsHash,
    this.localDate,
    this.intervalMinutes,
    this.activeStart,
    this.activeEnd,
  });

  final int planId;
  final int currentItemId;
  final DateTime nextCheckAt;
  final List<CarouselItemContent> items;

  /// 本页之后是否还有条目。全天拉取据此循环。
  final bool hasMore;

  /// 计划身份的一部分：与 planId 共同判定是否换代。
  final String? settingsHash;

  /// 计划所属本地日期，格式 YYYY-MM-DD。
  final String? localDate;

  final int? intervalMinutes;
  final String? activeStart;
  final String? activeEnd;

  factory CarouselPlanEnvelope.fromJson(Map<String, dynamic> json) =>
      CarouselPlanEnvelope(
        planId: (json['plan_id'] as num).toInt(),
        currentItemId: (json['current_item_id'] as num).toInt(),
        nextCheckAt: DateTime.parse(json['next_check_at'] as String),
        items:
            (json['items'] as List<dynamic>)
                .map(
                  (value) => CarouselItemContent.fromJson(
                    value as Map<String, dynamic>,
                  ),
                )
                .toList(growable: false),
        hasMore: json['has_more'] as bool? ?? false,
        settingsHash: json['settings_hash'] as String?,
        localDate: json['local_date'] as String?,
        intervalMinutes: (json['interval_minutes'] as num?)?.toInt(),
        activeStart: json['active_start'] as String?,
        activeEnd: json['active_end'] as String?,
      );
}

class DailyContent {
  const DailyContent({
    required this.date,
    required this.recommendationId,
    this.widgets = const {},
    this.photo,
    this.captionZh,
    this.captionEn,
    this.capturedDateText,
    this.locationText,
    this.photoOrientation,
  });

  final String date;
  final int recommendationId;
  final Map<String, WidgetAsset> widgets;
  final PhotoAsset? photo;
  final String? captionZh;
  final String? captionEn;
  final String? capturedDateText;
  final String? locationText;
  final String? photoOrientation;

  factory DailyContent.fromJson(Map<String, dynamic> json) {
    final widgets = ((json['widgets'] as Map<String, dynamic>?) ?? const {})
        .map(
          (key, value) => MapEntry(
            key,
            WidgetAsset.fromJson(value as Map<String, dynamic>),
          ),
        );
    return DailyContent(
      date: json['date'] as String,
      recommendationId: (json['recommendation_id'] as num).toInt(),
      widgets: widgets,
      photo:
          json['photo'] is Map<String, dynamic>
              ? PhotoAsset.fromJson(json['photo'] as Map<String, dynamic>)
              : null,
      captionZh: (json['caption'] as Map<String, dynamic>?)?['zh'] as String?,
      captionEn: (json['caption'] as Map<String, dynamic>?)?['en'] as String?,
      capturedDateText: json['captured_date_text'] as String?,
      locationText: json['location_text'] as String?,
      photoOrientation: json['photo_orientation'] as String?,
    );
  }
}

/// Server-side carousel settings for one target (`eink` frame or `mobile`
/// widget). Mirrors the `settings` object of
/// `POST /devices/{device_id}/carousel/settings/get`.
class DeviceCarouselSettings {
  const DeviceCarouselSettings({
    required this.timezone,
    required this.activeStart,
    required this.activeEnd,
    required this.intervalMinutes,
    this.mode,
    this.sources = const <String>[],
    this.dailySlotCount,
    this.settingsHash,
    this.updatedAt,
  });

  static const defaultTimezone = 'Asia/Shanghai';

  /// The two display modes the server stores in `frame_device_settings.mode`.
  ///
  /// These are the **wire** values. The local mirror read by the native
  /// widgets uses `carousel` / `recommendation` instead (see
  /// `DisplayPreferences.cacheLocal`); the two spellings must not be mixed up.
  static const modeCarousel = 'carousel';
  static const modeRecommend = 'recommend';

  /// The retired spelling of [modeRecommend], used only by the local mirror on
  /// installs that predate the rename. Read-only: never write this value again.
  static const modeRecommendLegacy = 'recommendation';


  final String timezone;
  final String activeStart;
  final String activeEnd;
  final int intervalMinutes;

  /// Display mode stored with the schedule (`carousel` or `recommend`).
  ///
  /// `null` when the server did not send one, or sent something outside the two
  /// allowed values: callers must fall back to a known value instead of
  /// guessing (the server rejects anything else with 422).
  final String? mode;

  /// 这台设备的内容来源（协议名字，如 `personal` / `art`）。
  ///
  /// 与 [mode] 一样存协议字符串而不是枚举：这个模型是 wire 形状的镜像，
  /// 不认识的名字（服务器加了新来源而 App 还没跟上）应当【原样保留】，
  /// 而不是在这里被悄悄丢掉 —— 丢掉会让用户看到"我选的来源没了"。
  /// 界面侧再用 BloomPhotoSource.fromWire 去认。
  final List<String> sources;

  /// Photos the server scheduled for one day (`daily_slot_count`).
  ///
  /// Kept `null` when the server does not report it (or reports a
  /// non-positive value) so callers fall back to their own estimate instead of
  /// showing a bogus `0`.
  final int? dailySlotCount;
  final String? settingsHash;
  final DateTime? updatedAt;

  /// Parses the server payload.
  ///
  /// The scheduling fields are required: a missing `interval_minutes`,
  /// `active_start` or `active_end` throws a [FormatException] rather than
  /// silently becoming `0`/`1440`. `timezone` falls back to
  /// [defaultTimezone] (the value the app already hardcodes for its other
  /// carousel calls) and the optional fields stay `null`.
  ///
  /// `mode` is optional: it is `null` when absent and also when the server
  /// sends a value outside `carousel` / `recommend`, so a future server value
  /// can never be mistaken for one of the two the app knows how to render.
  /// 从一个 sources 条目里取协议名字。
  ///
  /// 服务器两种形状都可能回：`{'name': 'art', 'weight': 2}` 与 `'art'`。
  /// 认不出来返回 null，由调用方跳过 —— 不抛异常。
  static String? _sourceNameOf(Object? entry) => switch (entry) {
    final Map map => (map['name'] ?? map['id']) as String?,
    final String name => name,
    _ => null,
  };

  factory DeviceCarouselSettings.fromJson(Map<String, dynamic> json) {
    final interval = (json['interval_minutes'] as num?)?.toInt();
    if (interval == null || interval <= 0) {
      throw FormatException(
        'carousel settings: interval_minutes is missing or not a positive '
        'integer (got ${json['interval_minutes']})',
      );
    }
    final rawSlots = (json['daily_slot_count'] as num?)?.toInt();
    final rawTimezone = (json['timezone'] as String?)?.trim();
    final rawMode = json['mode'];
    return DeviceCarouselSettings(
      timezone:
          rawTimezone == null || rawTimezone.isEmpty
              ? defaultTimezone
              : rawTimezone,
      activeStart: _requireClock(json, 'active_start'),
      activeEnd: _requireClock(json, 'active_end'),
      intervalMinutes: interval,
      mode:
          rawMode == modeCarousel || rawMode == modeRecommend
              ? rawMode as String
              : null,
      sources: switch (json['sources']) {
        // 服务器回的是 [{name, weight}]，但也接受纯字符串 ——
        // 与请求侧"两种写法都吃"保持一致。
        final List<dynamic> raw => <String>[
          for (final entry in raw)
            if (_sourceNameOf(entry) case final String name when name.isNotEmpty)
              name,
        ],
        _ => const <String>[],
      },
      dailySlotCount: rawSlots != null && rawSlots > 0 ? rawSlots : null,
      settingsHash: json['settings_hash'] as String?,
      updatedAt: _parseDateTime(json['updated_at']),
    );
  }
}

/// Envelope of `POST /devices/{device_id}/carousel/settings/get`.
class DeviceCarouselSettingsEnvelope {
  const DeviceCarouselSettingsEnvelope({
    required this.settings,
    this.apiVersion,
    this.allowedIntervalMinutes = const <int>[],
    this.nextCheckAt,
  });

  final DeviceCarouselSettings settings;
  final int? apiVersion;

  /// The server's authoritative tier list (`allowed_interval_minutes`).
  ///
  /// Empty when the server did not send one; callers must not quietly
  /// substitute their own list in that case.
  final List<int> allowedIntervalMinutes;
  final DateTime? nextCheckAt;

  factory DeviceCarouselSettingsEnvelope.fromJson(Map<String, dynamic> json) {
    final settings = json['settings'];
    if (settings is! Map<String, dynamic>) {
      throw const FormatException(
        'carousel settings: response has no "settings" object',
      );
    }
    return DeviceCarouselSettingsEnvelope(
      settings: DeviceCarouselSettings.fromJson(settings),
      apiVersion: (json['api_version'] as num?)?.toInt(),
      allowedIntervalMinutes: <int>[
        for (final value
            in (json['allowed_interval_minutes'] as List<dynamic>?) ??
                const <dynamic>[])
          if (value is num) value.toInt(),
      ],
      nextCheckAt: _parseDateTime(json['next_check_at']),
    );
  }
}

/// Result of `POST /devices/{device_id}/carousel/settings/set`.
class DeviceSettingsUpdateResult {
  const DeviceSettingsUpdateResult({
    required this.status,
    required this.settings,
    this.purgedPlans,
    this.nextCheckAt,
  });

  final String status;
  final DeviceCarouselSettings settings;

  /// Carousel plans the server invalidated because the schedule changed.
  final int? purgedPlans;
  final DateTime? nextCheckAt;

  factory DeviceSettingsUpdateResult.fromJson(Map<String, dynamic> json) {
    final settings = json['settings'];
    if (settings is! Map<String, dynamic>) {
      throw const FormatException(
        'carousel settings: update response has no "settings" object',
      );
    }
    return DeviceSettingsUpdateResult(
      status: (json['status'] as String?) ?? 'unknown',
      settings: DeviceCarouselSettings.fromJson(settings),
      purgedPlans: (json['purged_plans'] as num?)?.toInt(),
      nextCheckAt: _parseDateTime(json['next_check_at']),
    );
  }
}

String _requireClock(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('carousel settings: $key is missing (got $value)');
  }
  return value.trim();
}

DateTime? _parseDateTime(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

class CachedWidgetImage {
  const CachedWidgetImage({
    required this.path,
    required this.orientation,
    this.etag,
    this.contentVersion,
    this.date,
    this.recommendationId,
  });

  final String path;
  final String orientation;
  final String? etag;
  final String? contentVersion;
  final String? date;
  final int? recommendationId;
}

/// 内联在某台设备上的当前作息，来自服务端的 `serialize_user_device`。
///
/// 服务端在设备列表里就把作息一起返回了（`list_user_devices` 里那次
/// LEFT JOIN），所以设备列表不需要为每一行再发一次请求。字段全部可空：
/// 设置行缺失时服务端整个 `settings` 对象都不给。
class UserDeviceSettings {
  const UserDeviceSettings({
    required this.intervalMinutes,
    this.activeStart,
    this.activeEnd,
    this.updatedAt,
  });

  final int intervalMinutes;
  final String? activeStart;
  final String? activeEnd;
  final DateTime? updatedAt;

  factory UserDeviceSettings.fromJson(Map<String, dynamic> json) =>
      UserDeviceSettings(
        intervalMinutes: (json['interval_minutes'] as num?)?.toInt() ?? 0,
        activeStart: json['active_start'] as String?,
        activeEnd: json['active_end'] as String?,
        updatedAt: _parseDateTime(json['updated_at']),
      );
}

/// 一个绑在当前账号下的设备，来自 `GET /users/me/devices`。
///
/// F1 之前这里是一个恒抛 [UnsupportedError] 的占位：那个接口要"用户会话"，
/// 而 App 只有设备令牌。现在账号体系落地，它是真的了。
class UserDevice {
  const UserDevice({
    required this.deviceId,
    this.name,
    required this.deviceType,
    required this.enabled,
    this.lastSeenAt,
    this.boundAt,
    this.boundUserCount = 1,
    this.settings,
  });

  final String deviceId;
  final String? name;

  /// `eink`（相框）/ `mobile`（这台手机的小组件）/ `web`。
  final String deviceType;

  /// 服务端侧是否启用。注意这与用户的"小组件开关"不是一回事：
  /// 那个开关只控制本机是否联网，服务器并不知情。
  final bool enabled;

  final DateTime? lastSeenAt;
  final DateTime? boundAt;

  /// 有几条绑定关系指向这台设备 —— 大于 1 说明是家庭共用。
  final int boundUserCount;

  final UserDeviceSettings? settings;

  bool get isFrame => deviceType == 'eink';

  factory UserDevice.fromJson(Map<String, dynamic> json) {
    final settings = json['settings'];
    return UserDevice(
      deviceId: json['device_id'] as String,
      name: json['name'] as String?,
      deviceType: (json['device_type'] as String?) ?? 'eink',
      enabled: json['enabled'] as bool? ?? true,
      lastSeenAt: _parseDateTime(json['last_seen_at']),
      boundAt: _parseDateTime(json['bound_at']),
      boundUserCount: (json['bound_user_count'] as num?)?.toInt() ?? 1,
      settings: settings is Map<String, dynamic>
          ? UserDeviceSettings.fromJson(settings)
          : null,
    );
  }
}
