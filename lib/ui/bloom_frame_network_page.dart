import 'dart:async';
import 'package:flutter/material.dart';
import 'package:bloom_provision/bloom_provision.dart';
import '../core/api/bloom_api_client.dart';
import '../core/provisioning/frame_setup_controller.dart';
import 'bloom_device_pages.dart';
import 'bloom_frame_setup_page.dart';
import 'bloom_glass_home.dart';
import 'bloom_confirmation_dialog.dart';

class BloomFrameNetworkPage extends StatefulWidget {
  const BloomFrameNetworkPage({
    super.key,
    required this.api,
    required this.token,
    required this.device,
  });
  final BloomApiClient api;
  final String token;
  final BloomDevice device;
  @override
  State<BloomFrameNetworkPage> createState() => _BloomFrameNetworkPageState();
}

class _BloomFrameNetworkPageState extends State<BloomFrameNetworkPage> {
  Map<String, dynamic>? _network;
  String? _error;
  bool _busy = false;
  String get _base => 'devices/${Uri.encodeComponent(widget.device.deviceId)}';
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.userRequest(widget.token, '$_base/wifi');
      if (mounted) {
        setState(() {
          _network = data['network'] as Map<String, dynamic>?;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = frameSetupError(e));
    }
  }

  Future<void> _add() async {
    if (_busy) return;
    setState(() => _busy = true);
    String? job;
    try {
      final result = await widget.api.userRequest(
        widget.token,
        '$_base/commands/open_wifi',
        method: 'POST',
      );
      job = (result['command'] as Map)['id'] as String;
      if (!mounted) return;
      await Navigator.push<FrameSetupResult>(
        context,
        MaterialPageRoute(
          builder:
              (_) => BloomFrameSetupPage(
                api: widget.api,
                token: widget.token,
                deviceId: widget.device.deviceId,
                deviceName: widget.device.name,
              ),
        ),
      );
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = frameSetupError(e));
    } finally {
      if (job != null) {
        try {
          await widget.api.userRequest(
            widget.token,
            '$_base/commands/$job',
            method: 'DELETE',
          );
        } catch (_) {
          /* A completed command or expired login needs no cancellation. */
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(String ssid) async {
    if (_busy) return;
    if (!await confirmBloomAction(
      context,
      title: '移除这个 Wi-Fi？',
      message: '「$ssid」的密码会从相框中移除。如果这是当前网络，相框会寻找其他已保存网络或保持蓝牙配网。',
      confirmLabel: '移除',
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    const bridge = BloomProvisionBridge();
    String? job;
    try {
      final command = await widget.api.userRequest(
        widget.token,
        '$_base/commands/open_wifi',
        method: 'POST',
      );
      job = (command['command'] as Map)['id'] as String;
      final list = await bridge.scan();
      final name = _network?['ble_name'] as String?;
      if (name == null || !list.any((n) => n['ble_name'] == name)) {
        throw StateError('device_not_found');
      }
      final credentials = await widget.api.userRequest(
        widget.token,
        'frame-setup/$name',
      );
      if (credentials['device_id'] != widget.device.deviceId) {
        throw StateError('identity_mismatch');
      }
      await bridge.connect(name, credentials['pop'] as String);
      final hello = await bridge.data({'op': 'hello'});
      if (hello['device_id'] != widget.device.deviceId) {
        throw StateError('identity_mismatch');
      }
      final ticket = await widget.api.userRequest(
        widget.token,
        '$_base/setup-ticket',
        method: 'POST',
        body: {'nonce': hello['nonce'], 'action': 'forget'},
      );
      await bridge.data({'op': 'forget', 'ssid': ssid, ...ticket});
      bool removed = false;
      for (int i = 0; i < 20; ++i) {
        final status = await bridge.data({'op': 'status'});
        if (status['saved_networks'] is List &&
            !(status['saved_networks'] as List).contains(ssid)) {
          removed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (!removed) throw StateError('network_remove_failed');
      if (mounted) {
        setState(
          () =>
              _network = {
                ...?_network,
                'saved_networks': [
                  for (final s in (_network?['saved_networks'] as List? ?? []))
                    if (s != ssid) s,
                ],
              },
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = frameSetupError(e));
    } finally {
      await bridge.disconnect();
      if (job != null) {
        try {
          await widget.api.userRequest(
            widget.token,
            '$_base/commands/$job',
            method: 'DELETE',
          );
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BloomInk.page,
    appBar: AppBar(
      backgroundColor: BloomInk.page,
      foregroundColor: BloomInk.text,
      title: const Text('Wi-Fi', style: BloomType.pageTitle),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(widget.device.name, style: BloomType.sectionTitle),
        const SizedBox(height: 12),
        Text(
          _network?['wifi_ssid'] != null
              ? '最近连接 · ${_network!['wifi_ssid']}'
              : '尚未收到网络状态',
          style: BloomType.body,
        ),
        if (_network?['seen_at'] != null)
          Text(
            '相框上次报告：${DateTime.tryParse(_network!['seen_at'] as String)?.toLocal() ?? _network!['seen_at']}',
            style: BloomType.meta,
          ),
        const SizedBox(height: 20),
        const Text('已保存网络', style: BloomType.rowTitle),
        const SizedBox(height: 12),
        for (final ssid in (_network?['saved_networks'] as List? ?? []))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: BloomPanel(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(ssid as String, style: BloomType.body),
                trailing: IconButton(
                  onPressed: _busy ? null : () => _forget(ssid),
                  icon: const Icon(
                    Icons.remove_circle_outline,
                    color: BloomInk.textMuted,
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        BloomPrimaryButton(
          label: '添加 Wi-Fi',
          loading: _busy,
          onPressed: _busy ? null : _add,
        ),
        const SizedBox(height: 14),
        const Text(
          '离线相框会持续开放蓝牙。已联网但正在休眠时，请等待下一次联网接收请求，或重新上电后再试。',
          style: BloomType.meta,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text(_error!, style: BloomType.body),
          ),
      ],
    ),
  );
}

class BloomFrameResetPage extends StatefulWidget {
  const BloomFrameResetPage({
    super.key,
    required this.api,
    required this.token,
    required this.device,
  });
  final BloomApiClient api;
  final String token;
  final BloomDevice device;
  @override
  State<BloomFrameResetPage> createState() => _BloomFrameResetPageState();
}

class _BloomFrameResetPageState extends State<BloomFrameResetPage> {
  Map<String, dynamic>? _job;
  String? _error;
  Timer? _timer;
  bool _polling = false;
  String get _base => 'devices/${Uri.encodeComponent(widget.device.deviceId)}';
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final data = await widget.api.userRequest(
        widget.token,
        '$_base/commands/reset',
        method: 'POST',
      );
      if (mounted) {
        setState(() => _job = data['command'] as Map<String, dynamic>);
        _timer = Timer.periodic(
          const Duration(seconds: 3),
          (_) => unawaited(_poll()),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = frameSetupError(e));
    }
  }

  Future<void> _poll() async {
    if (_polling || _job == null) return;
    _polling = true;
    try {
      final data = await widget.api.userRequest(
        widget.token,
        '$_base/commands/${_job!['id']}',
      );
      if (!mounted) return;
      setState(() {
        _job = data['command'] as Map<String, dynamic>;
        _error = null;
      });
      if (_job!['state'] == 'succeeded') {
        _timer?.cancel();
        Navigator.pop(context, true);
      }
      if (_job!['state'] == 'failed') {
        _timer?.cancel();
        setState(() => _error = '相框重置未完成，主人关系仍保留。请检查相框后重试。');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法获取进度，重置任务会保留，正在重试。');
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BloomInk.page,
    appBar: AppBar(
      backgroundColor: BloomInk.page,
      foregroundColor: BloomInk.text,
      title: const Text('解绑并重置', style: BloomType.pageTitle),
    ),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 36),
          const Icon(
            Icons.restart_alt_rounded,
            size: 58,
            color: BloomInk.accent,
          ),
          const SizedBox(height: 28),
          Text(
            _job?['state'] == 'running' ? '正在清理相框' : '等待相框连接',
            style: BloomType.sectionTitle,
          ),
          const SizedBox(height: 16),
          const Text(
            '相框会清理保存的 Wi-Fi、私人照片和设置，并恢复欢迎页。设备确认完成后，会移除主人及所有供图关系。每个人的云端图库都保留。',
            style: BloomType.body,
          ),
          const SizedBox(height: 20),
          const LinearProgressIndicator(),
          const SizedBox(height: 20),
          const Text('可以离开本页，任务会继续。再次打开“解绑并重置”可查看进度。', style: BloomType.meta),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(_error!, style: BloomType.body),
            ),
        ],
      ),
    ),
  );
}
