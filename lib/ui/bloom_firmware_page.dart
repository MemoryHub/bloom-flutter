import 'dart:async';
import 'package:flutter/material.dart';
import '../core/firmware/firmware_update_controller.dart';
import '../core/models/firmware_models.dart';
import 'bloom_confirmation_dialog.dart';
import 'bloom_glass_home.dart';

Future<void> stopBloomFirmwareUpdate(
  BuildContext context,
  FirmwareUpdateController updates,
  FirmwareJob job,
) async {
  if (!job.canCancel) return;
  final confirmed = await confirmBloomAction(
    context,
    title: '停止固件更新？',
    message:
        job.state == 'queued'
            ? '相框还未开始更新。停止后可以从设备详情重新更新。'
            : '停止请求需要相框确认。确认停止前，请保留设备绑定；之后可以重新更新。',
    confirmLabel: '停止更新',
  );
  if (!confirmed || !context.mounted) return;
  try {
    await updates.cancel(job);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(firmwareErrorMessage(error))));
    }
  }
}

class BloomFirmwarePage extends StatefulWidget {
  const BloomFirmwarePage({
    super.key,
    required this.deviceId,
    required this.updates,
  });
  final String deviceId;
  final FirmwareUpdateController updates;
  @override
  State<BloomFirmwarePage> createState() => _BloomFirmwarePageState();
}

class _BloomFirmwarePageState extends State<BloomFirmwarePage> {
  FirmwareCheck? _check;
  String? _error;
  bool _loading = true;
  int _generation = 0;
  String? _observedJobState;
  @override
  void initState() {
    super.initState();
    widget.updates.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (!mounted) return;
    final job = widget.updates.jobFor(widget.deviceId);
    final previous = _observedJobState;
    _observedJobState = job?.state;
    setState(() {});
    if (job?.active == false && job?.state != previous && !_loading) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.updates.check(widget.deviceId);
      if (mounted && generation == _generation) setState(() => _check = result);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = firmwareErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _start(FirmwareRelease release) async {
    // Refresh capability/version/task immediately before sending a new command.
    await _load();
    if (!mounted || _error != null || _check?.ready != true) return;
    final latest = _check?.release;
    if (latest == null ||
        latest.id != release.id ||
        widget.updates.hasActiveFor(widget.deviceId)) {
      return;
    }
    try {
      await widget.updates.start(widget.deviceId, latest);
    } catch (error) {
      if (mounted) setState(() => _error = firmwareErrorMessage(error));
    }
  }

  @override
  void dispose() {
    ++_generation;
    widget.updates.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.updates.jobFor(widget.deviceId);
    final release = _check?.release;
    final busy = widget.updates.busy(widget.deviceId);
    return Scaffold(
      backgroundColor: BloomInk.page,
      appBar: AppBar(
        title: const Text('固件更新'),
        backgroundColor: BloomInk.page,
        actions: [
          IconButton(
            key: const ValueKey('bloom-firmware-check'),
            onPressed: _loading ? null : _load,
            tooltip: '检测更新',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
        children: [
          const Text('Bloom-Ink', style: BloomType.sectionTitle),
          const SizedBox(height: 12),
          Text(
            '当前版本  ${_check?.currentVersion ?? '尚未获取'}',
            style: BloomType.body,
          ),
          const SizedBox(height: 8),
          Text(
            _check?.presence == 'recently_seen'
                ? '相框最近已联网，开始更新时将再次确认连接'
                : '等待相框联网后开始更新',
            style: BloomType.meta,
          ),
          if (_check?.lastSeenAt != null) ...[
            const SizedBox(height: 4),
            Text('最近连接  ${_time(_check!.lastSeenAt!)}', style: BloomType.meta),
          ],
          if (_loading) ...[
            const SizedBox(height: 20),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 20),
            Text(
              _error!,
              style: BloomType.body.copyWith(color: BloomInk.danger),
            ),
          ],
          const SizedBox(height: 28),
          const Divider(color: BloomInk.divider),
          const SizedBox(height: 20),
          if (release != null) ...[
            Text('新版本  ${release.version}', style: BloomType.sectionTitle),
            const SizedBox(height: 12),
            Text(release.notes, style: BloomType.body),
            const SizedBox(height: 24),
          ] else if (!_loading && _check != null) ...[
            Text(
              _check!.currentVersion == null
                  ? '等待获取相框固件信息'
                  : _check!.ready
                  ? '当前已是最新版本'
                  : '固件更新暂未就绪',
              style: BloomType.body,
            ),
            const SizedBox(height: 24),
          ],
          if (job != null) ...[
            FirmwareTimeline(job: job),
            const SizedBox(height: 12),
            if (job.active &&
                (widget.updates.offline || job.reportIsStale(DateTime.now())))
              const Text('正在等待相框的最新状态，进度保留最近一次报告。', style: BloomType.meta),
            if (job.state == 'installing' || job.state == 'verifying')
              const Text('请保持相框供电，安装完成前无法停止更新或解除绑定。', style: BloomType.meta),
            if (job.canCancel) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed:
                    busy
                        ? null
                        : () => stopBloomFirmwareUpdate(
                          context,
                          widget.updates,
                          job,
                        ),
                child: const Text('停止更新'),
              ),
            ],
            const SizedBox(height: 24),
          ],
          if (release != null && job?.active != true)
            BloomPrimaryButton(
              key: const ValueKey('bloom-firmware-start'),
              label: '更新',
              loading: busy,
              loadingLabel: '正在检查…',
              onPressed:
                  busy || _loading || _check?.ready != true
                      ? null
                      : () => _start(release),
            ),
          if (release != null &&
              _check?.ready == true &&
              job?.active != true) ...[
            const SizedBox(height: 12),
            const Text(
              '更新期间请保持相框供电。退出 App 不会中断更新，再次打开可继续查看进度。',
              style: BloomType.meta,
            ),
          ],
          if (release != null && _check?.ready != true)
            const Text('相框的固件更新暂未就绪，暂时无法开始更新。', style: BloomType.meta),
        ],
      ),
    );
  }
}

String _time(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

class FirmwareTimeline extends StatelessWidget {
  const FirmwareTimeline({super.key, required this.job});
  final FirmwareJob job;
  static const labels = ['等待连接', '下载固件', '安装固件', '启动验证'];
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        job.label,
        key: const ValueKey('bloom-firmware-status'),
        style: BloomType.sectionTitle,
      ),
      const SizedBox(height: 20),
      for (var i = 0; i < labels.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      i == job.step && job.active
                          ? BloomInk.text
                          : Colors.transparent,
                  border: Border.all(
                    color:
                        i <= job.step ? BloomInk.textMuted : BloomInk.divider,
                  ),
                ),
                child: Text(
                  job.succeeded || i < job.step ? '✓' : '${i + 1}',
                  style: BloomType.meta.copyWith(
                    color:
                        i == job.step && job.active
                            ? BloomInk.inverseInk
                            : BloomInk.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      labels[i],
                      style: BloomType.body.copyWith(
                        color:
                            i <= job.step ? BloomInk.text : BloomInk.textMuted,
                      ),
                    ),
                    if (i == 1 && job.bytesDownloaded > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        key: const ValueKey('bloom-firmware-download-progress'),
                        value: job.progress,
                        backgroundColor: BloomInk.divider,
                        color: BloomInk.textMuted,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${(job.progress * 100).floor()}%',
                        style: BloomType.meta,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// Placed above the root Navigator; routes, sheets and tab changes share it.
class BloomFirmwareOverlay extends StatefulWidget {
  const BloomFirmwareOverlay({
    super.key,
    required this.updates,
    required this.navigatorKey,
    required this.child,
  });
  final FirmwareUpdateController updates;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  @override
  State<BloomFirmwareOverlay> createState() => _BloomFirmwareOverlayState();
}

class _BloomFirmwareOverlayState extends State<BloomFirmwareOverlay> {
  bool _collapsed = false;
  void _open(FirmwareJob job) {
    widget.navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder:
            (_) => BloomFirmwarePage(
              deviceId: job.deviceId,
              updates: widget.updates,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.updates,
    builder: (context, _) {
      final job = widget.updates.bannerJob;
      return Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
              top:
                  job == null
                      ? 0
                      : _collapsed
                      ? 52
                      : 100,
            ),
            child: widget.child,
          ),
          if (job != null)
            Positioned(
              top: 0,
              left: 12,
              right: 12,
              child: SafeArea(
                bottom: false,
                child: Material(
                  key: const ValueKey('bloom-firmware-global-banner'),
                  color: BloomInk.page,
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: const BorderSide(color: BloomInk.divider),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _open(job),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 6, 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.system_update_alt_rounded,
                                size: 18,
                                color: BloomInk.textMuted,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  job.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: BloomType.meta.copyWith(
                                    color: BloomInk.text,
                                  ),
                                ),
                              ),
                              if (job.active && !_collapsed)
                                TextButton(
                                  onPressed:
                                      !job.canCancel ||
                                              widget.updates.busy(job.deviceId)
                                          ? null
                                          : () {
                                            final ctx =
                                                widget
                                                    .navigatorKey
                                                    .currentState
                                                    ?.overlay
                                                    ?.context;
                                            if (ctx != null) {
                                              unawaited(
                                                stopBloomFirmwareUpdate(
                                                  ctx,
                                                  widget.updates,
                                                  job,
                                                ),
                                              );
                                            }
                                          },
                                  child: const Text('停止'),
                                ),
                              IconButton(
                                iconSize: 18,
                                onPressed:
                                    job.active
                                        ? () => setState(
                                          () => _collapsed = !_collapsed,
                                        )
                                        : () => widget.updates.dismiss(job),
                                icon: Icon(
                                  job.active
                                      ? (_collapsed
                                          ? Icons.expand_more
                                          : Icons.expand_less)
                                      : Icons.close,
                                  semanticLabel:
                                      job.active
                                          ? (_collapsed ? '展开进度' : '收起进度')
                                          : '关闭更新结果',
                                ),
                              ),
                            ],
                          ),
                          if (!_collapsed) ...[
                            Row(
                              children: [
                                for (var i = 0; i < 4; i++)
                                  Expanded(
                                    child: Text(
                                      '${i + 1} ${FirmwareTimeline.labels[i]}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color:
                                            i == job.step
                                                ? BloomInk.text
                                                : BloomInk.textMuted,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            LinearProgressIndicator(
                              value: job.state == 'queued' ? 0 : job.progress,
                              backgroundColor: BloomInk.divider,
                              color: BloomInk.textMuted,
                              minHeight: 2,
                            ),
                            if (job.active &&
                                (widget.updates.offline ||
                                    job.reportIsStale(DateTime.now()))) ...[
                              const SizedBox(height: 4),
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '等待最新状态',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: BloomInk.textMuted,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
