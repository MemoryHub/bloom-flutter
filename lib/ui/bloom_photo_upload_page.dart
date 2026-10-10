import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../core/api/bloom_api_client.dart';
import 'bloom_glass_home.dart';
import 'bloom_confirmation_dialog.dart';

class BloomPhotoUploadPage extends StatefulWidget {
  const BloomPhotoUploadPage({
    super.key,
    required this.api,
    required this.token,
  });
  final BloomApiClient api;
  final String token;
  @override
  State<BloomPhotoUploadPage> createState() => _BloomPhotoUploadPageState();
}

class _UploadItem {
  _UploadItem(this.file);
  final XFile file;
  double progress = 0;
  String status = '等待上传';
  bool done = false, failed = false, active = false;
  PhotoUploadCancellation? cancellation;
}

class _BloomPhotoUploadPageState extends State<BloomPhotoUploadPage> {
  final _picker = ImagePicker();
  final List<_UploadItem> _items = [];
  int _workers = 0;
  bool _picking = false;
  bool _confirmingExit = false;
  String? _message;
  int get _completed => _items.where((i) => i.done).length;
  bool get _running => _workers > 0;

  Future<void> _removePickerCopy(XFile file) async {
    try {
      final temporary = await Directory.systemTemp.resolveSymbolicLinks();
      final selected = File(file.path);
      final path = await selected.resolveSymbolicLinks();
      // Only the picker-owned temporary copy, never a gallery/source file.
      if (path.startsWith('$temporary${Platform.pathSeparator}')) {
        await selected.delete();
      }
    } catch (_) {
      /* In-memory test files and already-purged cache need no cleanup. */
    }
  }

  @override
  void dispose() {
    for (final item in _items) {
      item.failed = !item.done;
      item.cancellation?.cancel();
    }
    for (final item in _items.where((item) => !item.active)) {
      unawaited(_removePickerCopy(item.file));
    }
    super.dispose();
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final files = await _picker.pickMultiImage(requestFullMetadata: true);
      if (!mounted) return;
      setState(() {
        _items.addAll(files.map(_UploadItem.new));
        _message = null;
      });
      _start();
    } catch (_) {
      if (mounted) setState(() => _message = '无法打开照片选择器，请检查照片访问权限后重试。');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _start() {
    while (_workers < 2 &&
        _items.any((i) => !i.done && !i.failed && !i.active)) {
      _workers++;
      unawaited(_work());
    }
  }

  Future<void> _work() async {
    try {
      while (mounted) {
        final pending = _items.where((i) => !i.done && !i.failed && !i.active);
        if (pending.isEmpty) break;
        final item = pending.first;
        item.active = true;
        item.cancellation = PhotoUploadCancellation();
        setState(() => item.status = '上传中');
        var notified = -1;
        try {
          final result = await widget.api.uploadLibraryPhoto(
            widget.token,
            item.file,
            cancellation: item.cancellation,
            onProgress: (progress) {
              if (!mounted || item.cancellation!.isCancelled) return;
              final percent = (progress * 100).floor();
              if (percent == notified) return;
              notified = percent;
              setState(() {
                item.progress = progress.clamp(0, 1);
                item.status = progress >= 1 ? '正在保存到图库…' : '上传中';
              });
            },
          );
          if (!mounted) {
            await _removePickerCopy(item.file);
            break;
          }
          setState(() {
            item.done = true;
            item.progress = 1;
            item.status = result['status'] == 'duplicate' ? '图库中已存在' : '上传完成';
          });
          await _removePickerCopy(item.file);
        } catch (error) {
          if (!mounted) {
            await _removePickerCopy(item.file);
            break;
          }
          setState(() {
            item.failed = true;
            item.status =
                error is BloomApiException && error.statusCode == 413
                    ? '照片超过 100 MB'
                    : error is BloomApiException &&
                        error.code == 'upload_cancelled'
                    ? '已取消，可重试'
                    : error is BloomApiException &&
                        error.code == 'upload_timeout'
                    ? '网络长时间无响应，可重试'
                    : '上传失败，可重试';
          });
        } finally {
          item.active = false;
        }
      }
    } finally {
      _workers--;
      if (mounted) setState(() {});
    }
  }

  void _retry(_UploadItem item) {
    if (item.active) return;
    setState(() {
      item.failed = false;
      item.progress = 0;
      item.status = '等待上传';
    });
    _start();
  }

  void _cancel(_UploadItem item) {
    if (item.done) return;
    setState(() {
      item.failed = true;
      item.status = '已取消，可重试';
      item.cancellation?.cancel();
    });
  }

  Future<void> _leave() async {
    if (_confirmingExit) return;
    if (_running) {
      _confirmingExit = true;
      final leave = await confirmBloomAction(
        context,
        title: '停止上传并返回？',
        message: '已完成的照片会保留。正在上传和等待的任务将停止；已送达服务器的照片可能已经入库，可返回图库确认。',
        confirmLabel: '停止并返回',
      );
      _confirmingExit = false;
      if (!mounted || !leave) return;
      for (final item in _items.where((i) => !i.done)) {
        item.failed = true;
        item.cancellation?.cancel();
      }
      // Let cancelled workers release their request and temporary file handles.
      while (mounted && _running) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    if (!mounted) return;
    setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context, _completed > 0);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _running) {
        unawaited(_leave());
      }
    },
    child: Scaffold(
      backgroundColor: BloomInk.page,
      appBar: AppBar(
        backgroundColor: BloomInk.page,
        foregroundColor: BloomInk.text,
        title: const Text('上传照片', style: BloomType.pageTitle),
        leading: IconButton(
          onPressed: _leave,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(BloomSurface.pageInset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _items.isEmpty
                    ? '把新的回忆带进来'
                    : '已完成 $_completed / ${_items.length}',
                style: BloomType.sectionTitle,
              ),
              const SizedBox(height: 10),
              const Text('可一次选择多张照片。上传完成后，回忆分析会自动开始。', style: BloomType.body),
              const SizedBox(height: 18),
              BloomPrimaryButton(
                label: _picking ? '正在选择…' : '选择照片',
                onPressed: _picking ? null : _pick,
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!, style: BloomType.meta),
                ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, index) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return BloomPanel(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            item.file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BloomType.labelStrong,
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: item.progress,
                              minHeight: 4,
                              color:
                                  item.failed
                                      ? BloomInk.textFaint
                                      : BloomInk.accent,
                              backgroundColor: BloomInk.recess,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: Text(item.status, style: BloomType.meta),
                              ),
                              if (item.active)
                                Text(
                                  '${(item.progress * 100).floor()}%',
                                  style: BloomType.meta,
                                ),
                              if (item.done)
                                const Icon(
                                  Icons.check_circle_outline,
                                  size: 18,
                                  color: BloomInk.accent,
                                ),
                              if (item.failed)
                                TextButton(
                                  onPressed:
                                      item.active ? null : () => _retry(item),
                                  child: const Text(
                                    '重试',
                                    style: BloomType.button,
                                  ),
                                ),
                              if (!item.done && !item.failed)
                                TextButton(
                                  onPressed: () => _cancel(item),
                                  child: const Text(
                                    '取消',
                                    style: BloomType.button,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
