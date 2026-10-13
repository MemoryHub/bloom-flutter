import 'package:flutter/material.dart';
import '../core/api/bloom_api_client.dart';
import '../core/storage/photo_time_trace.dart';
import 'bloom_glass_home.dart';

/// Keep the chosen local wall time and its offset together across the API.
String bloomCaptureTimestamp(DateTime local) {
  local = local.toLocal();
  final offset = local.timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  final suffix =
      '${offset.isNegative ? '-' : '+'}'
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';
  return '${local.toIso8601String()}$suffix';
}

class BloomPhotoTimePage extends StatefulWidget {
  const BloomPhotoTimePage({
    super.key,
    required this.api,
    required this.token,
    required this.assetId,
    this.takenAt,
  });
  final BloomApiClient api;
  final String token, assetId;
  final String? takenAt;

  @override
  State<BloomPhotoTimePage> createState() => _BloomPhotoTimePageState();
}

class _BloomPhotoTimePageState extends State<BloomPhotoTimePage> {
  late DateTime _chosen;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    PhotoTimeTrace.shared.record(PhotoTimeStage.opened);
    final local =
        DateTime.tryParse(widget.takenAt ?? '')?.toLocal() ?? DateTime.now();
    _chosen = DateTime(
      local.year.clamp(1900, 2100),
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
      local.millisecond,
      local.microsecond,
    );
  }

  Future<void> _date() async {
    PhotoTimeTrace.shared.record(PhotoTimeStage.dateOpened);
    final date = await showDatePicker(
      context: context,
      initialDate: _chosen,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
      helpText: '选择拍摄日期',
      cancelText: '取消',
      confirmText: '确定',
      builder: _pickerTheme,
    );
    PhotoTimeTrace.shared.record(PhotoTimeStage.dateClosed);
    if (!mounted || date == null) return;
    setState(
      () =>
          _chosen = DateTime(
            date.year,
            date.month,
            date.day,
            _chosen.hour,
            _chosen.minute,
            _chosen.second,
            _chosen.millisecond,
            _chosen.microsecond,
          ),
    );
  }

  Future<void> _time() async {
    PhotoTimeTrace.shared.record(PhotoTimeStage.clockOpened);
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_chosen),
      helpText: '选择拍摄时间',
      cancelText: '取消',
      confirmText: '确定',
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: _pickerTheme(context, child),
          ),
    );
    PhotoTimeTrace.shared.record(PhotoTimeStage.clockClosed);
    if (!mounted || time == null) return;
    setState(
      () =>
          _chosen = DateTime(
            _chosen.year,
            _chosen.month,
            _chosen.day,
            time.hour,
            time.minute,
          ),
    );
  }

  Widget _pickerTheme(BuildContext context, Widget? child) => Theme(
    data: Theme.of(context).copyWith(
      colorScheme: const ColorScheme.dark(
        primary: BloomInk.accent,
        surface: BloomInk.panel,
        onSurface: BloomInk.text,
        onPrimary: BloomInk.page,
      ),
    ),
    child: child!,
  );

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    PhotoTimeTrace.shared.record(PhotoTimeStage.saveStarted);
    Map<String, dynamic> result;
    try {
      result = await widget.api.userRequest(
        widget.token,
        'photos/${widget.assetId}/time',
        method: 'PATCH',
        body: {'taken_at': bloomCaptureTimestamp(_chosen)},
      );
    } catch (error) {
      PhotoTimeTrace.shared.record(PhotoTimeStage.saveFailed);
      if (mounted) {
        setState(() {
          _saving = false;
          _error =
              error is BloomApiException && error.code == 'photo_time_changed'
                  ? '时间刚刚被更新，请返回照片详情刷新后再试。'
                  : '时间没有保存成功，请检查网络后重试。';
        });
      }
      return;
    }
    PhotoTimeTrace.shared.record(PhotoTimeStage.saveSucceeded);
    // Do not rebuild this route from a finally block after popping it. Error
    // recovery belongs to the failed request, successful navigation happens once.
    if (mounted) Navigator.pop(context, result['photo']);
  }

  @override
  void dispose() {
    PhotoTimeTrace.shared.record(PhotoTimeStage.editorDisposed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      backgroundColor: BloomInk.page,
      appBar: AppBar(
        backgroundColor: BloomInk.page,
        foregroundColor: BloomInk.text,
        title: const Text('拍摄时间', style: BloomType.pageTitle),
        leading: BackButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(BloomSurface.pageInset),
          children: [
            const Text('把回忆放回那一天', style: BloomType.sectionTitle),
            const SizedBox(height: 12),
            const Text('按手机当前时区设置日期和时间。', style: BloomType.meta),
            const SizedBox(height: 24),
            BloomPanel(
              child: Column(
                children: [
                  ListTile(
                    key: const ValueKey('bloom-photo-edit-date'),
                    title: const Text('日期', style: BloomType.meta),
                    subtitle: Text(
                      '${_chosen.year}年${_chosen.month}月${_chosen.day}日',
                      style: BloomType.labelStrong,
                    ),
                    trailing: const Icon(
                      Icons.calendar_today_outlined,
                      color: BloomInk.textMuted,
                    ),
                    onTap: _saving ? null : _date,
                  ),
                  ListTile(
                    key: const ValueKey('bloom-photo-edit-clock'),
                    title: const Text('时间', style: BloomType.meta),
                    subtitle: Text(
                      '${_chosen.hour.toString().padLeft(2, '0')}:${_chosen.minute.toString().padLeft(2, '0')}',
                      style: BloomType.labelStrong,
                    ),
                    trailing: const Icon(
                      Icons.schedule_outlined,
                      color: BloomInk.textMuted,
                    ),
                    onTap: _saving ? null : _time,
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_error!, style: BloomType.body),
              ),
            const SizedBox(height: 64),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(BloomSurface.pageInset),
        child: BloomPrimaryButton(
          label: _saving ? '正在保存…' : '保存',
          onPressed: _saving ? null : _save,
        ),
      ),
    ),
  );
}
