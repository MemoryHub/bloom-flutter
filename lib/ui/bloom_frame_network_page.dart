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
    this.wakeOnStart = false,
  });
  final BloomApiClient api;
  final String token;
  final BloomDevice device;
  // Only a confirmed reset action may initiate a nearby connection.
  final bool wakeOnStart;
  @override
  State<BloomFrameResetPage> createState() => _BloomFrameResetPageState();
}

class _BloomFrameResetPageState extends State<BloomFrameResetPage> {
  Map<String, dynamic>? _job;
  String? _error, _connection;
  Timer? _timer;
  bool _polling = false,
      _connecting = false,
      _cancelling = false,
      _starting = true;
  int _revision = 0;
  FrameNetworkController? _resetController;
  String get _base => 'devices/${Uri.encodeComponent(widget.device.deviceId)}';
  String? get _state => _job?['state'] as String?;
  bool get _terminal => {'succeeded', 'failed', 'cancelled'}.contains(_state);
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  void _apply(Map<String, dynamic> job) {
    if (!mounted) return;
    setState(() {
      _job = job;
      _error = null;
    });
    if (_terminal) _timer?.cancel();
    if (_state == 'succeeded') {
      Navigator.pop(context, true);
    } else if (_state == 'failed') {
      setState(() => _error = '相框报告重置未完成，请保留供电并检查相框状态。');
    }
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final data = await widget.api.userRequest(
        widget.token,
        '$_base/commands/reset',
        method: 'POST',
      );
      if (!mounted) return;
      _apply(data['command'] as Map<String, dynamic>);
      if (!_terminal) {
        _timer?.cancel();
        _timer = Timer.periodic(
          const Duration(seconds: 3),
          (_) => unawaited(_poll()),
        );
        if (widget.wakeOnStart &&
            (_state == 'queued' ||
                _job?['phase'] == 'ble_reset' ||
                _job?['phase'] == 'ble_commit')) {
          unawaited(_wake());
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = frameSetupError(e));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _wake() async {
    if (_connecting || _cancelling || _terminal || _job == null) return;
    setState(() {
      _connecting = true;
      _connection = '正在连接相框…';
    });
    final controller = FrameNetworkController(
      api: widget.api,
      token: widget.token,
      deviceId: widget.device.deviceId,
    );
    _resetController = controller;
    void progress() {
      if (mounted) setState(() => _connection = controller.progress);
    }

    controller.addListener(progress);
    final done = await controller.resetThroughPhone(_job!['id'] as String);
    final result =
        done
            ? '相框已重置，服务器已确认解绑，云端照片保留。'
            : '尚未完成：${controller.error ?? '请重新连接继续'}。任务已保留，重新连接会从已完成的步骤继续。';
    controller.removeListener(progress);
    controller.dispose();
    if (_resetController == controller) _resetController = null;
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _connection = result;
    });
    await _poll();
  }

  Future<void> _poll() async {
    if (_polling || _job == null || _terminal) return;
    _polling = true;
    final revision = _revision;
    try {
      final data = await widget.api.userRequest(
        widget.token,
        '$_base/commands/${_job!['id']}',
      );
      if (!mounted || revision != _revision) return;
      if (_connecting && (data['command'] as Map?)?['state'] == 'succeeded') return;
      _apply(data['command'] as Map<String, dynamic>);
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _error = '暂时无法获取进度，任务仍保留，将继续查询。');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _cancel() async {
    if (_cancelling || _state != 'queued') return;
    // Ignore a stale GET completing after this cancellation response.
    ++_revision;
    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      final data = await widget.api.userRequest(
        widget.token,
        '$_base/commands/${_job!['id']}',
        method: 'DELETE',
      );
      if (!mounted) return;
      _apply(data['command'] as Map<String, dynamic>);
    } catch (e) {
      if (!mounted) return;
      setState(
        () =>
            _error =
                e is BloomApiException && e.statusCode == 409
                    ? '相框已开始重置，无法取消。正在获取最新状态。'
                    : '尚未确认取消，任务仍保留。请检查网络后重试。',
      );
      // Refresh after a claim/cancel race; never mark cancelled locally.
      if (e is BloomApiException && e.statusCode == 409) await _poll();
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _resetController?.dispose();
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
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 36),
        const Icon(Icons.restart_alt_rounded, size: 58, color: BloomInk.accent),
        const SizedBox(height: 28),
        Text(switch (_state) {
          'running' => '正在清理相框',
          'cancelled' => '已取消重置',
          'failed' => '重置未完成',
          _ => _starting ? '正在提交重置请求' : '等待连接相框',
        }, style: BloomType.sectionTitle),
        const SizedBox(height: 16),
        Text(
          _state == 'cancelled'
              ? '等待任务已取消，绑定关系和云端照片均保留。'
              : _state == 'queued'
              ? '相框尚未开始清理。手机联网并靠近相框后，可通过蓝牙完成重置，相框无需连接 Wi-Fi。开始前可以取消。'
              : '相框会清理保存的 Wi-Fi、私人照片缓存和设置，恢复欢迎页。只有相框确认完成后才移除主人和供图关系；每个人的云端图库都保留。',
          style: BloomType.body,
        ),
        const SizedBox(height: 20),
        if (_starting ||
            _connecting ||
            _cancelling ||
            (_state == 'running' &&
                !{'ble_reset', 'ble_commit'}.contains(_job?['phase']))) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 20),
        ],
        if (_state == 'queued' ||
            (_state == 'running' &&
                {'ble_reset', 'ble_commit'}.contains(_job?['phase']))) ...[
          BloomPrimaryButton(
            label: _state == 'queued' ? '通过蓝牙重置相框' : '重新连接并继续重置',
            loading: _connecting,
            loadingLabel: _connection ?? '正在连接…',
            onPressed: _connecting || _cancelling ? null : _wake,
          ),
          const SizedBox(height: 12),
          if (_state == 'queued')
            TextButton(
              onPressed: _cancelling ? null : _cancel,
              child: const Text('取消等待并保留绑定'),
            ),
        ],
        if (_connection != null && _state != 'cancelled')
          Text(_connection!, style: BloomType.meta),
        if (!_terminal)
          const Text('可以离开本页，退出页面不会取消任务。再次打开可查看进度。', style: BloomType.meta),
        if (_state == 'cancelled')
          BloomPrimaryButton(
            label: '返回设备详情',
            onPressed: () => Navigator.pop(context, false),
          ),
        if (_state == 'failed')
          TextButton(
            onPressed: _starting ? null : _start,
            child: const Text('重新提交重置'),
          ),
        if (_job == null && !_starting)
          TextButton(onPressed: _start, child: const Text('重新提交请求')),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text(_error!, style: BloomType.body),
          ),
      ],
    ),
  );
}
