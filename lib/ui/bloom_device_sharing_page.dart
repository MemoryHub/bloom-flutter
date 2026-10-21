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
  String token, {
  String? rawCode,
}) async {
  final raw =
      rawCode ??
      await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const BloomDeviceScannerPage()),
      );
  if (raw == null || !context.mounted) return false;
  return await joinBloomDeviceInvitation(context, api, token, raw) != null;
}

/// Both scan entry points await the same visible server result before leaving.
Future<Map<String, dynamic>?> joinBloomDeviceInvitation(
  BuildContext context,
  BloomApiClient api,
  String token,
  String raw,
) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _JoinDeviceDialog(api: api, token: token, raw: raw),
);

class _JoinDeviceDialog extends StatefulWidget {
  const _JoinDeviceDialog({
    required this.api,
    required this.token,
    required this.raw,
  });
  final BloomApiClient api;
  final String token, raw;
  @override
  State<_JoinDeviceDialog> createState() => _JoinDeviceDialogState();
}

class _JoinDeviceDialogState extends State<_JoinDeviceDialog> {
  bool _finished = false;
  Map<String, dynamic>? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_join());
    });
  }

  Future<void> _join() async {
    final code = bloomDeviceInvitationToken(widget.raw);
    Map<String, dynamic>? result;
    String? error;
    if (code == null) {
      error = '请扫描主人 App 中的设备二维码。';
    } else {
      try {
        final reply = await widget.api.userRequest(
          widget.token,
          'device-invitations/join',
          method: 'POST',
          body: {'token': code},
        );
        if (reply['status'] != 'joined' ||
            reply['device_id'] is! String ||
            (reply['device_id'] as String).isEmpty) {
          throw const FormatException('join not confirmed');
        }
        result = reply;
      } catch (e) {
        error =
            e is BloomApiException && e.code == 'device_code_invalid'
                ? '设备二维码已失效，请主人打开设备二维码页面后重新扫码。'
                : e is BloomApiException && e.statusCode == 401
                ? '登录已失效，请重新登录后扫码。'
                : '暂时无法确认加入结果，请检查手机网络。可在“设备 → 我加入的”查看，也可重新扫码确认。';
      }
    }
    if (!mounted) return;
    setState(() {
      _finished = true;
      _result = result;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final joined = _result != null;
    final owner = _result?['relationship'] == 'owner';
    final type = _result?['device_type'] == 'eink' ? '相框' : '手机小组件';
    final name = _result?['name'] as String? ?? '设备';
    return PopScope(
      canPop: _finished,
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: BloomPanel(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                child: SizedBox(
                  key: ValueKey(_finished ? joined : null),
                  height: 56,
                  child: Center(
                    child:
                        !_finished
                            ? const CircularProgressIndicator(
                              color: BloomInk.accent,
                            )
                            : Icon(
                              joined
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.error_outline_rounded,
                              size: 44,
                              color: BloomInk.accent,
                            ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                !_finished
                    ? '正在加入设备'
                    : joined
                    ? (owner ? '这是你的设备' : '已成功加入')
                    : '尚未确认加入',
                style: BloomType.sectionTitle,
              ),
              const SizedBox(height: 12),
              Text(
                !_finished
                    ? '正在向服务器确认，请稍候。'
                    : joined
                    ? owner
                        ? '「$name」已经在“我的设备”中。'
                        : '已加入$type「$name」。可在“设备 → 我加入的”查看。供图关系已保存，相框会在下次联网同步时获取新计划。'
                    : _error!,
                style: BloomType.body,
              ),
              if (_finished) ...[
                const SizedBox(height: 24),
                BloomPrimaryButton(
                  label: joined ? '完成' : '知道了',
                  onPressed: () => Navigator.pop(context, _result),
                ),
              ],
            ],
          ),
        ),
      ),
    );
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
      final response = await widget.api.userRequest(
        widget.token,
        'devices/${widget.device.deviceId}/contribution',
        method: 'DELETE',
      );
      if (response['status'] != 'left') {
        throw const FormatException('leave not confirmed');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        // A committed exit can lose its response. The existing server returns
        // this exact absence result on retry; other 404s remain errors.
        if (error is BloomApiException &&
            error.statusCode == 404 &&
            error.code == 'device_not_joined') {
          Navigator.pop(context, true);
          return;
        }
        setState(() => _busy = false);
        final message =
            error is BloomApiException && error.statusCode == 401
                ? '登录已失效，请重新登录后操作。'
                : error is BloomApiException &&
                    error.code == 'owner_cannot_leave'
                ? '设备主人无法通过此入口停止供图。'
                : error is BloomApiException && error.statusCode == 403
                ? '当前账号没有操作权限，请返回设备列表确认。'
                : '暂时无法确认退出结果，请检查网络后重试，也可返回设备列表查看。';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message, style: BloomType.body)));
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
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text('扫码加入后，你的个人图库将用于这台设备的展示', style: BloomType.meta),
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
