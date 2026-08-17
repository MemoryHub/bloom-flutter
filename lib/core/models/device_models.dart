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
  const DeviceStatus({required this.paired, required this.hasAssets});

  final bool paired;
  final bool hasAssets;

  factory DeviceStatus.fromJson(Map<String, dynamic> json) => DeviceStatus(
    paired: json['paired'] as bool? ?? false,
    hasAssets: json['has_assets'] as bool? ?? false,
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
    this.captionZh,
    this.captionEn,
    this.capturedDateText,
    this.locationText,
    this.photoOrientation,
  });

  final int itemId;
  final DateTime displayAt;
  final PhotoAsset photo;
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
  });

  final int planId;
  final int currentItemId;
  final DateTime nextCheckAt;
  final List<CarouselItemContent> items;

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
