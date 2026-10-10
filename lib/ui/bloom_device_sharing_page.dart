import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/api/bloom_api_client.dart';
import 'bloom_device_pages.dart';
import 'bloom_glass_home.dart';
import 'bloom_confirmation_dialog.dart';

String? bloomDeviceInvitationToken(String raw) {
  final text = raw.trim();
  final uri = Uri.tryParse(text);
  final candidate =
      uri?.scheme == 'bloom' &&
              uri?.host == 'device' &&
              uri!.pathSegments.length == 1
          ? uri.pathSegments.single
          : text;
  return RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(candidate)
      ? candidate
      : null;
}

String _sharingError(Object error) =>
    error is BloomApiException && error.code == 'device_code_invalid'
        ? '设备二维码已失效，请设备主人重新提供。'
        : '操作未完成，请检查网络后重试。';

Future<bool> joinBloomDevice(
  BuildContext context,
  BloomApiClient api,
  String token,
) async {
  final raw = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const BloomDeviceScannerPage()),
  );
  if (raw == null || !context.mounted) return false;
  final code = bloomDeviceInvitationToken(raw);
  if (code == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('请扫描设备二维码。', style: BloomType.body)),
    );
    return false;
  }
  try {
    final preview = await api.userRequest(
      token,
      'device-invitations/preview',
      method: 'POST',
      body: {'token': code},
    );
    if (!context.mounted) return false;
    if (!await confirmBloomAction(
      context,
      title: '向「${preview['name'] ?? '设备'}」提供照片？',
      message: '你的整个个人图库将加入这台设备的播放内容。你仍只查看自己的照片；播放时间与艺术作品由设备主人设置。',
      confirmLabel: '加入设备',
    )) {
      return false;
    }
    await api.userRequest(
      token,
      'device-invitations/join',
      method: 'POST',
      body: {'token': code},
    );
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: BloomInk.panel,
          content: Text(_sharingError(error), style: BloomType.body),
        ),
      );
    }
    return false;
  }
}

class BloomDeviceSharingPage extends StatefulWidget {
  const BloomDeviceSharingPage({
    super.key,
    required this.api,
    required this.token,
    required this.device,
  });
  final BloomApiClient api;
  final String token;
  final BloomDevice device;
  @override
  State<BloomDeviceSharingPage> createState() => _BloomDeviceSharingPageState();
}

class _BloomDeviceSharingPageState extends State<BloomDeviceSharingPage> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.userRequest(
        widget.token,
        'devices/${widget.device.deviceId}/sharing',
      );
      if (mounted) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _sharingError(error));
    }
  }

  Future<void> _remove(Map member) async {
    if (_busy ||
        !await confirmBloomAction(
          context,
          title: '停止接收${member['name']}的照片？',
          message: '之后的播放计划将移除对方图库，旧二维码也会失效。请向需要加入的人提供新的二维码。',
          confirmLabel: '移除',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.userRequest(
        widget.token,
        'devices/${widget.device.deviceId}/contributors/${member['user_id']}',
        method: 'DELETE',
      );
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = _sharingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BloomInk.page,
    appBar: AppBar(
      backgroundColor: BloomInk.page,
      foregroundColor: BloomInk.text,
      title: const Text('设备二维码', style: BloomType.pageTitle),
    ),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(BloomSurface.pageInset),
        children: [
          Text(widget.device.name, style: BloomType.sectionTitle),
          const SizedBox(height: 12),
          const Text('让家人扫码，把他们自己的照片带到这台设备上。', style: BloomType.body),
          const SizedBox(height: 24),
          if (_data == null && _error == null)
            const Center(
              child: CircularProgressIndicator(
                color: BloomInk.accent,
                strokeWidth: 2,
              ),
            ),
          if (_data != null) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(18),
                color: Colors.white,
                child: QrImageView(data: _data!['qr'] as String, size: 220),
              ),
            ),
            const SizedBox(height: 20),
            BloomPrimaryButton(
              label: '复制设备码',
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: _data!['qr'] as String),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('设备码已复制', style: BloomType.body),
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 30),
            const Text('提供照片的人', style: BloomType.sectionTitle),
            const SizedBox(height: 14),
            const Text('你自己的图库始终包含在内。', style: BloomType.meta),
            for (final member in _data!['members'] as List)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: BloomPanel(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          member['name'] as String,
                          style: BloomType.rowTitle,
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _remove(member as Map),
                        child: const Text('移除', style: BloomType.button),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          if (_error != null) ...[
            Text(_error!, style: BloomType.body),
            TextButton(
              onPressed: _load,
              child: const Text('重试', style: BloomType.button),
            ),
          ],
        ],
      ),
    ),
  );
}

class BloomJoinedDevicePage extends StatefulWidget {
  const BloomJoinedDevicePage({
    super.key,
    required this.api,
    required this.token,
    required this.device,
  });
  final BloomApiClient api;
  final String token;
  final BloomDevice device;
  @override
  State<BloomJoinedDevicePage> createState() => _BloomJoinedDevicePageState();
}

class _BloomJoinedDevicePageState extends State<BloomJoinedDevicePage> {
  bool _busy = false;
  Future<void> _leave() async {
    if (_busy ||
        !await confirmBloomAction(
          context,
          title: '退出这台设备？',
          message: '这台设备之后将不再播放你的图库，你自己的照片会保留。',
          confirmLabel: '停止供图',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.userRequest(
        widget.token,
        'devices/${widget.device.deviceId}/contribution',
        method: 'DELETE',
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_sharingError(error), style: BloomType.body)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BloomInk.page,
    appBar: AppBar(
      backgroundColor: BloomInk.page,
      foregroundColor: BloomInk.text,
      title: const Text('我加入的', style: BloomType.pageTitle),
    ),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(BloomSurface.pageInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BloomPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(widget.device.name, style: BloomType.sectionTitle),
                  const SizedBox(height: 14),
                  Text(widget.device.metaLabel, style: BloomType.meta),
                  const SizedBox(height: 20),
                  const Text(
                    '你正在向这台设备提供整个个人图库。播放作息、推荐模式与艺术作品由设备主人管理。',
                    style: BloomType.body,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            BloomPrimaryButton(
              label: _busy ? '正在退出…' : '停止供图',
              onPressed: _busy ? null : _leave,
            ),
          ],
        ),
      ),
    ),
  );
}

class BloomDeviceScannerPage extends StatefulWidget {
  const BloomDeviceScannerPage({super.key});
  @override
  State<BloomDeviceScannerPage> createState() => _BloomDeviceScannerPageState();
}

class _BloomDeviceScannerPageState extends State<BloomDeviceScannerPage>
    with WidgetsBindingObserver {
  final _camera = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _returned = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_camera.value.hasCameraPermission || _returned) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_camera.start());
    } else if (state == AppLifecycleState.inactive) {
      unawaited(_camera.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera.dispose());
    super.dispose();
  }

  void _complete(String value) {
    if (_returned || !mounted) return;
    _returned = true;
    unawaited(_camera.stop());
    Navigator.pop(context, value);
  }

  Future<void> _paste() async {
    unawaited(_camera.stop());
    final input = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder:
          (context) => Dialog(
            backgroundColor: Colors.transparent,
            child: BloomPanel(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('粘贴设备码', style: BloomType.sectionTitle),
                  const SizedBox(height: 16),
                  TextField(
                    controller: input,
                    autofocus: true,
                    style: BloomType.body,
                    decoration: const InputDecoration(
                      hintText: 'bloom://device/…',
                      hintStyle: BloomType.meta,
                    ),
                  ),
                  const SizedBox(height: 20),
                  BloomPrimaryButton(
                    label: '继续',
                    onPressed: () => Navigator.pop(context, input.text.trim()),
                  ),
                ],
              ),
            ),
          ),
    );
    // Wait for the dialog's exit animation before releasing its text controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (value != null && value.isNotEmpty) {
      _complete(value);
    } else if (mounted) {
      unawaited(_camera.start());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BloomInk.page,
    appBar: AppBar(
      backgroundColor: BloomInk.page,
      foregroundColor: BloomInk.text,
      title: const Text('扫描设备二维码', style: BloomType.pageTitle),
    ),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _camera,
            onDetect: (capture) {
              for (final code in capture.barcodes) {
                if (code.rawValue != null) {
                  _complete(code.rawValue!);
                  break;
                }
              }
            },
            errorBuilder:
                (_, error) => const Center(
                  child: Text('相机暂时不可用，可以粘贴设备码', style: BloomType.body),
                ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: BloomPrimaryButton(label: '粘贴设备码', onPressed: _paste),
          ),
        ),
      ],
    ),
  );
}
