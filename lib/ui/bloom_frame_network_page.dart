import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api/bloom_api_client.dart';
import '../core/provisioning/frame_setup_controller.dart';
import '../core/provisioning/frame_local_admin.dart';
import '../core/provisioning/frame_network_controller.dart';
import 'bloom_device_pages.dart';
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

class _BloomFrameNetworkPageState extends State<BloomFrameNetworkPage>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _network;
  String? _error;
  late final FrameNetworkController c;
  String get _base => 'devices/${Uri.encodeComponent(widget.device.deviceId)}';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c = FrameNetworkController(
      api: widget.api,
      token: widget.token,
      deviceId: widget.device.deviceId,
    )..addListener(_changed);
    unawaited(_load()); // HTTP/cache only. Never scan or connect on page entry.
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(c.cancel());
    }
  }

  Future<void> _load() async {
    Map<String, dynamic>? cached;
    try {
      final store = FrameAdminStore();
      final account = await store.accountId();
      if (account != null) {
        final value = await store.read(account, widget.device.deviceId);
        if (value?['network'] is Map) {
          cached = Map<String, dynamic>.from(value!['network'] as Map);
        }
      }
      if (mounted && cached != null) setState(() => _network = cached);
    } catch (_) {}
    try {
      final data = await widget.api.userRequest(widget.token, '$_base/wifi');
      final remote =
          data['network'] is Map
              ? Map<String, dynamic>.from(data['network'] as Map)
              : null;
      final localAt = DateTime.tryParse(cached?['seen_at'] as String? ?? '');
      final remoteAt = DateTime.tryParse(remote?['seen_at'] as String? ?? '');
      if (mounted) {
        setState(() {
          _network =
              localAt != null && (remoteAt == null || localAt.isAfter(remoteAt))
                  ? cached
                  : remote;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && cached == null) {
        setState(() => _error = frameSetupError(e));
      }
    }
  }

  Future<void> _add() async {
    final summary = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder:
            (_) => BloomFrameWifiAddPage(
              api: widget.api,
              token: widget.token,
              device: widget.device,
            ),
      ),
    );
    if (!mounted) return;
    if (summary != null) {
      setState(() {
        _network = summary;
        _error = null;
      });
    }
  }

  Future<void> _forget(String ssid) async {
    final last = (_network?['saved_networks'] as List? ?? []).length == 1;
    if (!await confirmBloomAction(
      context,
      title: '移除这个 Wi-Fi？',
      message:
          last
              ? '这是最后一个已保存网络。移除后相框将无法通过它联网；靠近相框即可重新添加 Wi-Fi。'
              : '「$ssid」的密码会从相框中移除。如果正在使用它，相框会尝试其他已保存网络。',
      confirmLabel: '移除',
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    if (await c.removeNetwork(ssid) && mounted) {
      setState(() {
        _network = c.summary;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_changed);
    c.dispose();
    super.dispose();
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
            '信息更新时间：${DateTime.tryParse(_network!['seen_at'] as String)?.toLocal() ?? _network!['seen_at']}',
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
                  onPressed: c.busy ? null : () => _forget(ssid),
                  icon: const Icon(
                    Icons.remove_circle_outline,
                    color: BloomInk.textMuted,
                  ),
                ),
              ),
            ),
          ),
        if (c.busy) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(c.progress, style: BloomType.body),
          const SizedBox(height: 16),
        ],
        BloomPrimaryButton(label: '添加 Wi-Fi', onPressed: c.busy ? null : _add),
        const SizedBox(height: 14),
        const Text('添加或移除网络时，请让手机靠近相框并开启蓝牙。', style: BloomType.meta),
        if (c.error ?? _error case final String message)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text(message, style: BloomType.body),
          ),
      ],
    ),
  );
}

class BloomFrameWifiAddPage extends StatefulWidget {
  const BloomFrameWifiAddPage({
    super.key,
    required this.api,
    required this.token,
    required this.device,
    this.controller,
  });
  final BloomApiClient api;
  final String token;
  final BloomDevice device;
  final FrameNetworkController? controller;
  @override
  State<BloomFrameWifiAddPage> createState() => _BloomFrameWifiAddPageState();
}

class _BloomFrameWifiAddPageState extends State<BloomFrameWifiAddPage>
    with WidgetsBindingObserver {
  late final FrameNetworkController c;
  final password = TextEditingController();
  Map<String, dynamic>? selected;
  bool obscure = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c =
        (widget.controller ??
              FrameNetworkController(
                api: widget.api,
                token: widget.token,
                deviceId: widget.device.deviceId,
              ))
          ..addListener(_changed);
    unawaited(c.startAdding()); // This route is entered only by the Add button.
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(c.cancel());
    }
  }

  Future<void> _connect() async {
    if (selected == null) return;
    if (await c.connectWifi(selected!['ssid'] as String, password.text) &&
        mounted) {
      password.clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_changed);
    c.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BloomInk.page,
    appBar: AppBar(
      backgroundColor: BloomInk.page,
      foregroundColor: BloomInk.text,
      title: const Text('添加 Wi-Fi', style: BloomType.pageTitle),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(widget.device.name, style: BloomType.sectionTitle),
        const SizedBox(height: 12),
        if (c.success) ...[
          const Icon(
            Icons.check_circle_outline,
            color: BloomInk.accent,
            size: 56,
          ),
          const SizedBox(height: 20),
          const Text('Wi-Fi 配置成功', style: BloomType.sectionTitle),
          const SizedBox(height: 24),
          BloomPrimaryButton(
            label: '完成',
            onPressed: () => Navigator.pop(context, c.summary),
          ),
        ] else if (c.busy) ...[
          const SizedBox(height: 40),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 24),
          Text(
            c.progress,
            style: BloomType.sectionTitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            '请保持手机靠近相框。',
            style: BloomType.body,
            textAlign: TextAlign.center,
          ),
        ] else if (c.error != null) ...[
          const Icon(Icons.error_outline, color: BloomInk.textMuted, size: 48),
          const SizedBox(height: 20),
          const Text('连接未完成', style: BloomType.sectionTitle),
          const SizedBox(height: 12),
          if (selected != null)
            Text(selected!['ssid'] as String, style: BloomType.rowTitle),
          const SizedBox(height: 12),
          Text(c.error!, style: BloomType.body),
          const SizedBox(height: 24),
          BloomPrimaryButton(
            label: selected != null ? '重试连接' : '重新连接并搜索',
            onPressed:
                selected != null ? _connect : () => unawaited(c.startAdding()),
          ),
          if (selected != null)
            TextButton(
              onPressed: () {
                setState(() => selected = null);
                c.clearError();
              },
              child: const Text('重新选择网络'),
            ),
        ] else ...[
          const Text('选择 2.4 GHz Wi-Fi', style: BloomType.rowTitle),
          const SizedBox(height: 16),
          for (final network in c.networks)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: BloomPanel(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(network['ssid'] as String, style: BloomType.body),
                  leading: Icon(
                    selected?['ssid'] == network['ssid']
                        ? Icons.check_circle
                        : Icons.wifi,
                    color: BloomInk.accent,
                  ),
                  onTap:
                      () => setState(() {
                        selected = network;
                        password.clear();
                      }),
                ),
              ),
            ),
          if (c.networks.isEmpty && c.error == null)
            const Text('暂未发现网络，请重新搜索。', style: BloomType.body),
          if (selected != null) ...[
            const SizedBox(height: 16),
            Text(selected!['ssid'] as String, style: BloomType.rowTitle),
            if (selected!['auth'] != 0)
              TextField(
                controller: password,
                obscureText: obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Wi-Fi 密码',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => obscure = !obscure),
                    icon: Icon(
                      obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            BloomPrimaryButton(label: '连接 Wi-Fi', onPressed: _connect),
          ],
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => unawaited(c.startAdding()),
            child: Text(c.error == null ? '重新搜索' : '重新连接并搜索'),
          ),
          if (c.error != null) Text(c.error!, style: BloomType.body),
        ],
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
