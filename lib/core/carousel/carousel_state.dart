/// 轮播状态契约（两端唯一共享的数据结构）。
///
/// 字段名、类型、语义在 iOS 与安卓上必须完全一致。序列化一律使用本文件中的
/// snake_case 键名，两端都把整份状态作为**一个 JSON 字符串**存储，避免字段级
/// 键名漂移。
///
/// 所有时间字段一律为 UTC 纪元毫秒（int）。禁止存储本地时间字符串作为参与
/// 计算的依据；本地格式化只允许出现在渲染的最后一步。
library;

/// 此刻照片的状态。仅用于界面提示，不影响时间推进。
enum CurrentStatus {
  /// 正常显示该格照片。
  ok,

  /// 接口正常，但该格照片损坏或超时，且替补也不可用。
  downloadFailed,

  /// 手机没网或服务端不可达。
  offline,

  /// 尚未取到照片（例如刚切换、照片还在下载）。
  pending;

  static CurrentStatus fromWire(String? value) {
    switch (value) {
      case 'ok':
        return CurrentStatus.ok;
      case 'download_failed':
        return CurrentStatus.downloadFailed;
      case 'offline':
        return CurrentStatus.offline;
      case 'pending':
        return CurrentStatus.pending;
      default:
        return CurrentStatus.pending;
    }
  }

  String get wire {
    switch (this) {
      case CurrentStatus.ok:
        return 'ok';
      case CurrentStatus.downloadFailed:
        return 'download_failed';
      case CurrentStatus.offline:
        return 'offline';
      case CurrentStatus.pending:
        return 'pending';
    }
  }
}

/// 「下次更新」的来源。决定界面是否需要对用户做降级提示。
enum NextSlotSource {
  /// 由本次联网取回的计划计算。主文案。
  plan,

  /// 由已缓存计划计算。取计划失败或断网时的备选文案。
  cached;

  static NextSlotSource fromWire(String? value) =>
      value == 'cached' ? NextSlotSource.cached : NextSlotSource.plan;

  String get wire => this == NextSlotSource.cached ? 'cached' : 'plan';
}

/// 计划身份。`planId` 与 `settingsHash` 任一变化即视为换代。
class PlanIdentity {
  const PlanIdentity({
    required this.planId,
    required this.settingsHash,
    required this.day,
  });

  final int planId;
  final String settingsHash;

  /// 计划所属本地日期，格式 YYYY-MM-DD。
  final String day;

  Map<String, Object?> toJson() => {
    'plan_id': planId,
    'settings_hash': settingsHash,
    'day': day,
  };

  static PlanIdentity? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final planId = (raw['plan_id'] as num?)?.toInt();
    final settingsHash = raw['settings_hash'] as String?;
    final day = raw['day'] as String?;
    if (planId == null || settingsHash == null || day == null) return null;
    return PlanIdentity(planId: planId, settingsHash: settingsHash, day: day);
  }

  @override
  bool operator ==(Object other) =>
      other is PlanIdentity &&
      other.planId == planId &&
      other.settingsHash == settingsHash &&
      other.day == day;

  @override
  int get hashCode => Object.hash(planId, settingsHash, day);

  @override
  String toString() => 'PlanIdentity($planId, $settingsHash, $day)';
}

/// 计划中的一个格子。格子时间由服务端给定，客户端不得自行推算。
class Slot {
  const Slot({
    required this.slotAtMs,
    required this.itemId,
    required this.assetId,
  });

  final int slotAtMs;
  final int itemId;
  final String assetId;

  Map<String, Object?> toJson() => {
    'slot_at_ms': slotAtMs,
    'item_id': itemId,
    'asset_id': assetId,
  };

  static Slot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final slotAtMs = (raw['slot_at_ms'] as num?)?.toInt();
    final itemId = (raw['item_id'] as num?)?.toInt();
    if (slotAtMs == null || itemId == null) return null;
    return Slot(
      slotAtMs: slotAtMs,
      itemId: itemId,
      assetId: raw['asset_id'] as String? ?? '',
    );
  }
}

/// 本地已缓存的一张照片。
class PhotoEntry {
  const PhotoEntry({
    required this.itemId,
    required this.assetId,
    required this.path,
    this.etag,
    required this.fetchedAtMs,
  });

  final int itemId;
  final String assetId;
  final String path;
  final String? etag;
  final int fetchedAtMs;

  Map<String, Object?> toJson() => {
    'item_id': itemId,
    'asset_id': assetId,
    'path': path,
    'etag': etag,
    'fetched_at_ms': fetchedAtMs,
  };

  static PhotoEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final itemId = (raw['item_id'] as num?)?.toInt();
    final path = raw['path'] as String?;
    if (itemId == null || path == null) return null;
    return PhotoEntry(
      itemId: itemId,
      assetId: raw['asset_id'] as String? ?? '',
      path: path,
      etag: raw['etag'] as String?,
      fetchedAtMs: (raw['fetched_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 烘焙好的一个时间线条目：某一格到点后应当显示什么。
///
/// **两端共用同一个列表，且两端都只做查表，不做决策。** 条目由 Dart 单写者
/// 在 tick 里烘焙好（照片已落盘、路径已确定），原生侧到点后只回答一个问题：
/// 「`date_ms` 不晚于此刻的最后一条是谁」。这就把历史上安卓的
/// `latestDueEntry`（并列打破 + `lastShownItemId` 地板 + 防倒退）与 iOS 各自的
/// 选取逻辑合并成了同一条规则。
///
/// 扩展在条目展示时不会被唤醒，因此「此刻屏幕上是谁」必须由本列表与当前时间
/// 推算，不能用扩展回写的 current 指针（见方案第二章规则五）。
class TimelineEntry {
  const TimelineEntry({
    required this.dateMs,
    required this.itemId,
    this.portraitPath = '',
    this.squarePath = '',
    this.largeSquarePath = '',
    this.originalPath = '',
    this.date = '',
    this.captionZh,
    this.captionEn,
    this.capturedDateText,
    this.locationText,
    this.sourceName = 'personal',
    this.artwork = const {},
    this.photoMetadata = const {},
  });

  /// 该格应当上屏的时刻（UTC 纪元毫秒）。
  final int dateMs;

  final int itemId;

  /// 已渲染好的三个规格与原始照片的本地绝对路径。
  final String portraitPath;
  final String squarePath;
  final String largeSquarePath;
  final String originalPath;

  /// 展示用日期，格式 YYYY-MM-DD。
  final String date;

  final String? captionZh;
  final String? captionEn;
  final String? capturedDateText;
  final String? locationText;
  final String sourceName;
  final Map<String, dynamic> artwork;
  final Map<String, dynamic> photoMetadata;

  /// 该条目的照片是否真的在本地。
  bool get hasPhoto => portraitPath.isNotEmpty || originalPath.isNotEmpty;

  Map<String, Object?> toJson() => {
    'date_ms': dateMs,
    'item_id': itemId,
    'portrait_path': portraitPath,
    'square_path': squarePath,
    'large_square_path': largeSquarePath,
    'original_path': originalPath,
    'date': date,
    'caption_zh': captionZh,
    'caption_en': captionEn,
    'captured_date_text': capturedDateText,
    'location_text': locationText,
    'source_name': sourceName,
    'content_snapshot': artwork,
    'photo_metadata': photoMetadata,
  };

  static TimelineEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final dateMs = (raw['date_ms'] as num?)?.toInt();
    final itemId = (raw['item_id'] as num?)?.toInt();
    if (dateMs == null || itemId == null) return null;
    return TimelineEntry(
      dateMs: dateMs,
      itemId: itemId,
      portraitPath: raw['portrait_path'] as String? ?? '',
      squarePath: raw['square_path'] as String? ?? '',
      largeSquarePath: raw['large_square_path'] as String? ?? '',
      originalPath: raw['original_path'] as String? ?? '',
      date: raw['date'] as String? ?? '',
      captionZh: raw['caption_zh'] as String?,
      captionEn: raw['caption_en'] as String?,
      capturedDateText: raw['captured_date_text'] as String?,
      locationText: raw['location_text'] as String?,
      sourceName: raw['source_name'] as String? ?? 'personal',
      photoMetadata: Map<String, dynamic>.from(
        raw['photo_metadata'] as Map? ?? const {},
      ),
      artwork: Map<String, dynamic>.from(
        raw['content_snapshot'] as Map? ?? const {},
      ),
    );
  }
}

/// 共享状态的完整快照。
class CarouselState {
  const CarouselState({
    this.plan,
    this.grid = const [],
    this.revision = 0,
    this.updatedAtMs = 0,
    this.writer = '',
    this.currentSlotAtMs,
    this.currentItemId,
    this.currentPhotoPath,
    this.previousItemId,
    this.previousPhotoPath,
    this.status = CurrentStatus.pending,
    this.nextSlotAtMs,
    this.nextSlotSource = NextSlotSource.plan,
    this.photos = const [],
    this.timelineEntries = const [],
  });

  /// 空状态：尚未取得任何计划。
  static const CarouselState empty = CarouselState();

  final PlanIdentity? plan;
  final List<Slot> grid;
  final int revision;
  final int updatedAtMs;
  final String writer;

  final int? currentSlotAtMs;
  final int? currentItemId;
  final String? currentPhotoPath;
  final int? previousItemId;
  final String? previousPhotoPath;
  final CurrentStatus status;

  final int? nextSlotAtMs;
  final NextSlotSource nextSlotSource;

  final List<PhotoEntry> photos;

  final List<TimelineEntry> timelineEntries;

  // 这里曾有 `lastShownItemId` / `last_shown_item_id`。它是重写前「不得倒退到
  // 已看过的照片」那道地板阈值，选取改由时间线纯查表之后**没有任何读者**，
  // 只剩写入。已删除：一个只写不读的字段最容易误导后来人以为它还在起作用。

  CarouselState copyWith({
    PlanIdentity? plan,
    List<Slot>? grid,
    int? revision,
    int? updatedAtMs,
    String? writer,
    int? currentSlotAtMs,
    int? currentItemId,
    String? currentPhotoPath,
    int? previousItemId,
    String? previousPhotoPath,
    CurrentStatus? status,
    int? nextSlotAtMs,
    NextSlotSource? nextSlotSource,
    List<PhotoEntry>? photos,
    List<TimelineEntry>? timelineEntries,
    bool clearCurrentSlot = false,
    bool clearCurrentPhoto = false,
    bool clearPrevious = false,
    bool clearNextSlot = false,
  }) {
    return CarouselState(
      plan: plan ?? this.plan,
      grid: grid ?? this.grid,
      revision: revision ?? this.revision,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      writer: writer ?? this.writer,
      currentSlotAtMs:
          clearCurrentSlot ? null : (currentSlotAtMs ?? this.currentSlotAtMs),
      currentItemId:
          clearCurrentSlot ? null : (currentItemId ?? this.currentItemId),
      currentPhotoPath:
          clearCurrentPhoto
              ? null
              : (currentPhotoPath ?? this.currentPhotoPath),
      previousItemId:
          clearPrevious ? null : (previousItemId ?? this.previousItemId),
      previousPhotoPath:
          clearPrevious ? null : (previousPhotoPath ?? this.previousPhotoPath),
      status: status ?? this.status,
      nextSlotAtMs: clearNextSlot ? null : (nextSlotAtMs ?? this.nextSlotAtMs),
      nextSlotSource: nextSlotSource ?? this.nextSlotSource,
      photos: photos ?? this.photos,
      timelineEntries: timelineEntries ?? this.timelineEntries,
    );
  }

  Map<String, Object?> toJson() => {
    'plan': plan?.toJson(),
    'grid': [for (final slot in grid) slot.toJson()],
    'revision': revision,
    'updated_at_ms': updatedAtMs,
    'writer': writer,
    'current_slot_at_ms': currentSlotAtMs,
    'current_item_id': currentItemId,
    'current_photo_path': currentPhotoPath,
    'previous_item_id': previousItemId,
    'previous_photo_path': previousPhotoPath,
    'current_status': status.wire,
    'next_slot_at_ms': nextSlotAtMs,
    'next_slot_source': nextSlotSource.wire,
    'photos': [for (final photo in photos) photo.toJson()],
    'timeline_entries': [for (final entry in timelineEntries) entry.toJson()],
  };

  static CarouselState fromJson(Object? raw) {
    if (raw is! Map) return CarouselState.empty;
    return CarouselState(
      plan: PlanIdentity.fromJson(raw['plan']),
      grid: [
        for (final entry in (raw['grid'] as List? ?? const []))
          if (Slot.fromJson(entry) != null) Slot.fromJson(entry)!,
      ],
      revision: (raw['revision'] as num?)?.toInt() ?? 0,
      updatedAtMs: (raw['updated_at_ms'] as num?)?.toInt() ?? 0,
      writer: raw['writer'] as String? ?? '',
      currentSlotAtMs: (raw['current_slot_at_ms'] as num?)?.toInt(),
      currentItemId: (raw['current_item_id'] as num?)?.toInt(),
      currentPhotoPath: raw['current_photo_path'] as String?,
      previousItemId: (raw['previous_item_id'] as num?)?.toInt(),
      previousPhotoPath: raw['previous_photo_path'] as String?,
      status: CurrentStatus.fromWire(raw['current_status'] as String?),
      nextSlotAtMs: (raw['next_slot_at_ms'] as num?)?.toInt(),
      nextSlotSource: NextSlotSource.fromWire(
        raw['next_slot_source'] as String?,
      ),
      photos: [
        for (final entry in (raw['photos'] as List? ?? const []))
          if (PhotoEntry.fromJson(entry) != null) PhotoEntry.fromJson(entry)!,
      ],
      timelineEntries: [
        for (final entry in (raw['timeline_entries'] as List? ?? const []))
          if (TimelineEntry.fromJson(entry) != null)
            TimelineEntry.fromJson(entry)!,
      ],
    );
  }
}
