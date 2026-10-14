class FirmwareRelease {
  const FirmwareRelease({
    required this.id,
    required this.version,
    required this.notes,
    required this.size,
  });
  final String id;
  final String version;
  final String notes;
  final int size;
  factory FirmwareRelease.fromJson(Map<String, dynamic> json) =>
      FirmwareRelease(
        id: json['id'] as String,
        version: json['version'] as String,
        notes: json['notes'] as String,
        size: (json['size'] as num).toInt(),
      );
}

class FirmwareJob {
  const FirmwareJob({
    required this.id,
    required this.deviceId,
    required this.releaseId,
    required this.state,
    required this.version,
    required this.size,
    required this.bytesDownloaded,
    required this.createdAt,
    this.reportedAt,
    this.errorCode,
  });
  final String id;
  final String deviceId;
  final String releaseId;
  final String state;
  final String version;
  final int size;
  final int bytesDownloaded;
  final DateTime createdAt;
  final DateTime? reportedAt;
  final String? errorCode;
  static const activeStates = {
    'queued',
    'downloading',
    'cancel_requested',
    'installing',
    'verifying',
  };
  static const states = {
    ...activeStates,
    'succeeded',
    'failed',
    'rolled_back',
    'cancelled',
  };
  bool get active => activeStates.contains(state);
  bool get canCancel => state == 'queued' || state == 'downloading';
  bool get succeeded => state == 'succeeded';
  double get progress =>
      size <= 0 ? 0 : (bytesDownloaded / size).clamp(0.0, 1.0);
  int get step => switch (state) {
    'queued' => 0,
    'downloading' || 'cancel_requested' || 'cancelled' => 1,
    'installing' => 2,
    'verifying' || 'succeeded' || 'rolled_back' => 3,
    _ => bytesDownloaded >= size && size > 0 ? 2 : 1,
  };
  String get label => switch (state) {
    'queued' => '等待相框联网',
    'downloading' => '下载固件 ${(progress * 100).floor()}%',
    'cancel_requested' => '等待相框确认停止',
    'installing' => '正在安装固件',
    'verifying' => '正在验证新版本',
    'succeeded' => '固件已更新',
    'rolled_back' => '更新未完成，已恢复原版本',
    'cancelled' => '已停止更新',
    _ => '更新未完成，可以重试',
  };
  bool reportIsStale(DateTime now) =>
      active &&
      state != 'queued' &&
      (reportedAt == null || now.difference(reportedAt!).inSeconds > 90);
  factory FirmwareJob.fromJson(Map<String, dynamic> json) {
    final state = json['state'] as String;
    if (!states.contains(state)) {
      throw const FormatException('Unknown firmware state');
    }
    return FirmwareJob(
      id: json['id'] as String,
      deviceId: json['device_id'] as String,
      releaseId: json['release_id'] as String,
      state: state,
      version: json['version'] as String,
      size: (json['size'] as num).toInt(),
      bytesDownloaded: (json['bytes_downloaded'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      reportedAt: DateTime.tryParse(json['reported_at'] as String? ?? ''),
      errorCode: json['error_code'] as String?,
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'device_id': deviceId,
    'release_id': releaseId,
    'state': state,
    'version': version,
    'size': size,
    'bytes_downloaded': bytesDownloaded,
    'created_at': createdAt.toIso8601String(),
    'reported_at': reportedAt?.toIso8601String(),
    'error_code': errorCode,
  };
}

class FirmwareCheck {
  const FirmwareCheck({
    this.currentVersion,
    required this.ready,
    required this.presence,
    this.lastSeenAt,
    this.reason,
    this.release,
    this.job,
  });
  final String? currentVersion;
  final bool ready;
  final String presence;
  final DateTime? lastSeenAt;
  final String? reason;
  final FirmwareRelease? release;
  final FirmwareJob? job;
  factory FirmwareCheck.fromJson(Map<String, dynamic> json) => FirmwareCheck(
    currentVersion: json['current_version'] as String?,
    ready: json['ota_ready'] == true,
    presence: json['presence'] as String? ?? 'waiting_for_device',
    lastSeenAt: DateTime.tryParse(json['last_seen_at'] as String? ?? ''),
    reason: json['reason'] as String?,
    release:
        json['release'] is Map
            ? FirmwareRelease.fromJson(
              Map<String, dynamic>.from(json['release'] as Map),
            )
            : null,
    job:
        json['job'] is Map
            ? FirmwareJob.fromJson(
              Map<String, dynamic>.from(json['job'] as Map),
            )
            : null,
  );
}
