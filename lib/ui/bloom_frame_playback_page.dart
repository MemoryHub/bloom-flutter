import 'dart:async';
import 'package:flutter/material.dart';
import '../core/provisioning/frame_playback_controller.dart';
import '../core/provisioning/frame_setup_controller.dart';

class BloomFramePlaybackPage extends StatefulWidget {
  const BloomFramePlaybackPage({
    super.key,
    required this.controller,
    required this.deviceId,
    this.autoStart = false,
  });
  final FramePlaybackController controller;
  final String deviceId;
  final bool autoStart;
  @override
  State<BloomFramePlaybackPage> createState() => _BloomFramePlaybackPageState();
}

class _BloomFramePlaybackPageState extends State<BloomFramePlaybackPage> {
  String? error;
  bool _initialRequest = false;
  static const green = Color(0xFF648875),
      ink = Color(0xFF353830),
      muted = Color(0xFF777B70);
  @override
  void initState() {
    super.initState();
    _initialRequest = widget.autoStart;
    widget.controller.addListener(_changed);
    widget.controller.openDetails();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.autoStart) {
        unawaited(_start(newSetup: true));
      } else {
        unawaited(widget.controller.refresh());
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _start({bool retry = false, bool newSetup = false}) async {
    setState(() => error = null);
    try {
      await widget.controller.start(
        widget.deviceId,
        retry: retry,
        newSetup: newSetup,
      );
    } catch (e) {
      if (mounted) setState(() => error = frameSetupError(e));
    } finally {
      if (mounted) setState(() => _initialRequest = false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.closeDetails();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.controller.jobFor(widget.deviceId);
    final completed =
        job?.complete == true &&
        !_initialRequest &&
        !widget.controller.starting(widget.deviceId) &&
        error == null;
    final pending = job?.pendingSetup == true;
    final phase = job?.phase ?? '';
    const phases = [
      'pulling_plan',
      'preparing_photo',
      'downloading_first',
      'refreshing_screen',
    ];
    const labels = ['获取轮播计划', '准备第一张照片', '下载第一张照片', '刷新相框屏幕'];
    final current =
        completed
            ? phases.length
            : (_initialRequest || widget.controller.starting(widget.deviceId))
            ? 0
            : phases.indexOf(phase);
    final failed = job?.failed == true;
    final idle =
        pending || job == null && !widget.controller.starting(widget.deviceId);
    return Theme(
      data: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: green),
        fontFamily: 'BloomSerif',
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F1E9),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: ink,
          title: const Text('第一张照片'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 30),
                        Icon(
                          completed
                              ? Icons.check_circle_rounded
                              : Icons.photo_outlined,
                          size: 72,
                          color: green,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          completed
                              ? '照片已经在相框里了'
                              : idle
                              ? '让已有照片，在这里安家'
                              : '第一张照片，正在路上',
                          style: const TextStyle(fontSize: 26, color: ink),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          completed
                              ? '相框已完成刷新，接下来会按轮播计划播放。'
                              : idle
                              ? '你的图库已有照片，点击开始，相框就会准备并显示第一张。'
                              : current < 0
                              ? '正在等待相框接收播放请求。'
                              : failed
                              ? '准备暂时中断了，可以重试或稍后回来查看。'
                              : '你可以留在这里查看进度，也可以先回首页。',
                          style: const TextStyle(fontSize: 15, color: muted),
                        ),
                        const SizedBox(height: 32),
                        for (var i = 0; i < labels.length; i++)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Column(
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 250),
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color:
                                          i <= current
                                              ? green
                                              : const Color(0xFFDFE2D8),
                                    ),
                                    child:
                                        i < current || completed
                                            ? const Icon(
                                              Icons.check,
                                              size: 17,
                                              color: Colors.white,
                                            )
                                            : i == current && failed
                                            ? const Icon(
                                              Icons.priority_high,
                                              size: 17,
                                              color: Colors.white,
                                            )
                                            : i == current
                                            ? const Padding(
                                              padding: EdgeInsets.all(6),
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            )
                                            : null,
                                  ),
                                  if (i < labels.length - 1)
                                    AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      height: 26,
                                      width: 2,
                                      color:
                                          i < current
                                              ? green
                                              : const Color(0xFFDFE2D8),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    i == 2 && job?.percent != null
                                        ? '${labels[i]} · ${job!.percent}%'
                                        : labels[i],
                                    style: TextStyle(
                                      fontSize: 17,
                                      color: i <= current ? ink : muted,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (job?.phase == 'downloading_first') ...[
                          const SizedBox(height: 18),
                          LinearProgressIndicator(
                            value: job?.progress,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(8),
                            backgroundColor: const Color(0xFFDFE2D8),
                            color: green,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            job?.percent != null
                                ? '正在下载第一张照片 · ${job!.percent}%'
                                : '正在下载第一张照片',
                            style: const TextStyle(color: muted),
                          ),
                        ],
                        if (widget.controller.offline)
                          const Padding(
                            padding: EdgeInsets.only(top: 16),
                            child: Text(
                              '暂时无法更新进度，相框会继续执行。',
                              style: TextStyle(color: muted),
                            ),
                          ),
                        if (failed || error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              error ?? '相框暂未完成刷新，请重试。',
                              style: const TextStyle(color: Color(0xFFA25343)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (completed)
                  FilledButton(
                    onPressed: () {
                      widget.controller.dismiss(job!);
                      Navigator.pop(context, true);
                    },
                    child: const Text('完成'),
                  )
                else if (idle || failed || error != null)
                  FilledButton(
                    onPressed:
                        widget.controller.starting(widget.deviceId)
                            ? null
                            : () => _start(retry: failed),
                    child: Text(failed || error != null ? '重试' : '完成并开始播放'),
                  ),
                if (!completed && !idle)
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('后台运行'),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BloomFramePlaybackOverlay extends StatelessWidget {
  const BloomFramePlaybackOverlay({
    super.key,
    required this.controller,
    required this.navigatorKey,
    required this.child,
  });
  final FramePlaybackController controller;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  @override
  Widget build(BuildContext context) => FramePlaybackScope(
    controller: controller,
    child: AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final job = controller.bannerJob;
        return Stack(
          children: [
            child,
            if (job != null)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 4,
                left: 16,
                right: 16,
                child: Material(
                  color: const Color(0xFFF4F1E9),
                  elevation: 3,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap:
                        () => navigatorKey.currentState?.push(
                          MaterialPageRoute(
                            builder:
                                (_) => BloomFramePlaybackPage(
                                  controller: controller,
                                  deviceId: job.deviceId,
                                ),
                          ),
                        ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            job.complete
                                ? Icons.check_circle_outline
                                : Icons.photo_outlined,
                            color: const Color(0xFF648875),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              job.pendingSetup
                                  ? '相框等待开始播放 · 继续设置'
                                  : job.complete
                                  ? '第一张照片已显示 · 查看'
                                  : job.failed
                                  ? '相框刷新暂未完成 · 查看'
                                  : '相框正在准备第一张照片 · 查看进度',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF353830),
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            color: Color(0xFF648875),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
