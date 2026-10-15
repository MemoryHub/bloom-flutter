import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api/bloom_api_client.dart';
import '../core/provisioning/frame_setup_controller.dart';
import '../core/provisioning/frame_playback_controller.dart';
import 'bloom_frame_playback_page.dart';
import 'bloom_device_sharing_page.dart';
import 'bloom_photo_upload_page.dart';

class FrameSetupResult {
  const FrameSetupResult(this.deviceId, this.name);
  final String deviceId, name;
}

/// One route for the four steps. Completed ownership cannot be revisited by
/// swiping back from the upload page; upload completion closes this route.
class BloomFrameSetupPage extends StatefulWidget {
  const BloomFrameSetupPage({
    super.key,
    required this.api,
    required this.token,
    this.code,
    this.deviceId,
    this.deviceName,
  });
  final BloomApiClient api;
  final String token;
  final FrameSetupCode? code;
  final String? deviceId, deviceName;
  @override
  State<BloomFrameSetupPage> createState() => _BloomFrameSetupPageState();
}

class _BloomFrameSetupPageState extends State<BloomFrameSetupPage>
    with SingleTickerProviderStateMixin {
  late final FrameSetupController c;
  late final AnimationController _ripple;
  late final TextEditingController _name;
  final _password = TextEditingController();
  String? _ssid;
  int _auth = 3;
  bool _obscure = true;
  bool _openingScanner = false;
  bool _qrRecognizedShown = false;
  FramePlaybackController? _progress;
  static const paper = Color(0xFFF4F1E9),
      ink = Color(0xFF353830),
      muted = Color(0xFF777B70),
      green = Color(0xFF648875);
  TextStyle style(double size, {Color color = ink}) => TextStyle(
    fontFamily: 'BloomSerif',
    fontSize: size,
    color: color,
    height: 1.5,
  );
  @override
  void initState() {
    super.initState();
    c = FrameSetupController(
      api: widget.api,
      token: widget.token,
      existingDeviceId: widget.deviceId,
      existingName: widget.deviceName,
    )..addListener(_changed);
    _name = TextEditingController(text: c.name);
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    unawaited(c.discover(code: widget.code));
  }

  void _changed() {
    if (mounted) {
      if (c.step == 1 && _name.text != c.name) _name.text = c.name;
      setState(() {});
      if (c.step == 1 &&
          c.scannedCode != null &&
          !_qrRecognizedShown &&
          c.error == null) {
        _qrRecognizedShown = true;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已识别相框二维码')));
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final progress = FramePlaybackScope.of(context);
    if (identical(progress, _progress)) return;
    _progress?.closeDetails();
    _progress = progress;
    _progress?.openDetails();
  }

  @override
  void dispose() {
    _progress?.closeDetails();
    c.removeListener(_changed);
    c.dispose();
    _ripple.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  void _finish() {
    Navigator.pop(context, FrameSetupResult(c.deviceId!, c.name));
  }

  Future<void> _scan() async {
    if (_openingScanner || c.busy) return;
    setState(() => _openingScanner = true);
    try {
      await c.pauseDiscovery();
      if (!mounted) return;
      final raw = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const BloomDeviceScannerPage()),
      );
      if (!mounted) return;
      if (raw == null) {
        await c.discover(code: c.scannedCode);
        return;
      }
      final code = FrameSetupCode.parse(raw);
      if (code != null) {
        await c.discover(code: code);
        return;
      }
      final token = bloomDeviceInvitationToken(raw);
      if (token == null) {
        setState(() => c.error = '请扫描相框或 App 中的设备二维码。');
        return;
      }
      try {
        final result = await widget.api.userRequest(
          widget.token,
          'device-invitations/join',
          method: 'POST',
          body: {'token': token},
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已加入${result['device_type'] == 'eink' ? '相框' : '小组件'}「${result['name'] ?? '设备'}」',
            ),
          ),
        );
        Navigator.pop(
          context,
          FrameSetupResult(
            result['device_id'] as String,
            result['name'] as String? ?? '设备',
          ),
        );
      } catch (e) {
        if (mounted) setState(() => c.error = frameSetupError(e));
      }
    } catch (e) {
      if (mounted) setState(() => c.error = frameSetupError(e));
    } finally {
      if (mounted) setState(() => _openingScanner = false);
    }
  }

  Future<void> _upload() async {
    final completed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder:
            (_) => BloomPhotoUploadPage(
              api: widget.api,
              token: widget.token,
              onCompleted: () => Navigator.pop(context, true),
            ),
      ),
    );
    if (completed == true && mounted) _finish();
  }

  Widget button(String text, VoidCallback? action, {bool secondary = false}) =>
      SizedBox(
        height: 52,
        child:
            secondary
                ? OutlinedButton(
                  onPressed: action,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ink,
                    side: const BorderSide(color: Color(0xFFCBD0C5)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: Text(text, style: style(17)),
                )
                : FilledButton(
                  onPressed: action,
                  style: FilledButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child:
                      c.busy
                          ? const SizedBox(
                            width: 21,
                            height: 21,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : Text(text, style: style(17, color: Colors.white)),
                ),
      );
  Widget title(String value, String note) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: style(27)),
      const SizedBox(height: 10),
      Text(note, style: style(15, color: muted)),
      const SizedBox(height: 28),
    ],
  );
  Widget card(Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .58),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFE0E1D7)),
    ),
    child: child,
  );
  Widget steps() {
    const labels = ['找到相框', '给它取名', '连接 Wi-Fi', '第一张照片'];
    return Row(
      children: [
        for (int i = 0; i < 4; ++i)
          Expanded(
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: c.step >= i ? green : const Color(0xFFE3E5DB),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child:
                        i < c.step
                            ? const Icon(
                              Icons.check_rounded,
                              size: 17,
                              color: Colors.white,
                            )
                            : Text(
                              '${i + 1}',
                              style: style(
                                14,
                                color: c.step >= i ? Colors.white : muted,
                              ),
                            ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  labels[i],
                  style: style(11, color: i == c.step ? ink : muted),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget discover() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        title(
          c.managing ? '连接你的相框' : '让美好的日子，靠近一点',
          '请开启相框，靠近手机。可以同时找到多台相框，每次添加一台。',
        ),
        if (c.scannedCode != null)
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('已读取设备二维码', style: style(18)),
                Text(
                  '相框标识 · ${c.scannedCode!.bleName.substring(14)}',
                  style: style(14, color: muted),
                ),
                Text(
                  c.busy ? '正在通过蓝牙连接这台相框。' : '请重新连接这台相框。',
                  style: style(14, color: muted),
                ),
              ],
            ),
          ),
        SizedBox(
          height: 155,
          child: AnimatedBuilder(
            animation: _ripple,
            builder:
                (_, __) => CustomPaint(
                  painter: _RipplePainter(
                    MediaQuery.disableAnimationsOf(context) ? 0 : _ripple.value,
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.filter_frames_outlined,
                      size: 52,
                      color: muted,
                    ),
                  ),
                ),
          ),
        ),
        if (c.scanning)
          Center(child: Text('正在寻找附近的相框…', style: style(14, color: muted))),
        if (c.busy)
          Center(child: Text('正在连接相框…', style: style(14, color: muted))),
        const SizedBox(height: 20),
        for (final d in c.nearby)
          card(
            InkWell(
              onTap:
                  c.busy || d['busy'] == true
                      ? null
                      : () => c.select(d['ble_name'] as String),
              child: Row(
                children: [
                  const Icon(
                    Icons.filter_frames_outlined,
                    size: 35,
                    color: muted,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Bloom-Ink', style: style(20)),
                        Text(
                          d['busy'] == true
                              ? '正在被其他手机操作'
                              : '标识 · ${(d['ble_name'] as String).substring(14)}',
                          style: style(13, color: muted),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: muted),
                ],
              ),
            ),
          ),
        if (c.nearby.isEmpty && !c.scanning)
          Text(
            c.scannedCode != null
                ? '尚未连接这台相框。请确认相框已开启，并靠近手机后重试。'
                : '暂未找到相框。确认已开机；已绑定相框换网时可重新上电，或等它下一次联网接收请求。',
            style: style(14, color: muted),
          ),
        const SizedBox(height: 24),
        button('扫描设备二维码', c.busy || _openingScanner ? null : _scan),
        const SizedBox(height: 12),
        TextButton(
          onPressed:
              c.scanning || c.busy
                  ? null
                  : () => c.discover(code: c.scannedCode),
          child: Text('重新寻找', style: style(15, color: muted)),
        ),
        if (c.error?.contains('蓝牙') == true)
          TextButton(
            onPressed: () => c.bridge.settings(),
            child: Text('前往系统设置', style: style(15)),
          ),
      ],
    );
  }

  Widget naming() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      title('给它取个名字吧', '每一张照片，都有一个温暖的去处。以后设备列表中会显示这个名字。'),
      if (c.bleName != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '相框标识 · ${c.bleName!.substring(14)}',
            style: style(14, color: muted),
          ),
        ),
      card(
        TextField(
          controller: _name,
          maxLength: 32,
          style: style(24),
          decoration: InputDecoration(
            hintText: 'Bloom-Ink',
            hintStyle: style(24, color: muted),
            border: InputBorder.none,
            suffixIcon: IconButton(
              onPressed: _name.clear,
              icon: const Icon(Icons.close_rounded, color: muted),
            ),
          ),
          textInputAction: TextInputAction.next,
        ),
      ),
      button('下一步', c.busy ? null : () => c.chooseName(_name.text)),
    ],
  );
  Widget wifi() {
    if (c.completed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 50),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration:
                MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 420),
            builder:
                (_, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: const Icon(
              Icons.check_circle_rounded,
              size: 84,
              color: green,
            ),
          ),
          const SizedBox(height: 24),
          Text('Wi-Fi 配置成功', style: style(26), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text(
            '「${c.name}」已添加，接下来让第一张照片在这里安家。',
            style: style(16, color: muted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 36),
          button(c.managing ? '完成' : '下一步', c.managing ? _finish : c.photos),
        ],
      );
    }
    final reused = _ssid != null && c.savedNetworks.contains(_ssid);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        title('为相框连接 Wi-Fi', '选择相框找到的 2.4 GHz 网络。手机可以使用移动网络，密码只交给这台相框。'),
        if (c.busy)
          card(
            Column(
              children: [
                const CircularProgressIndicator(color: green, strokeWidth: 2),
                const SizedBox(height: 16),
                for (final node in [
                  if (c.phase == 'bluetooth_connecting' ||
                      c.phase == 'wifi_scanning') ...[
                    ('bluetooth_connecting', '连接相框蓝牙'),
                    ('wifi_scanning', '相框正在搜索 Wi-Fi'),
                  ] else ...[
                    ('wifi_connecting', '连接 Wi-Fi'),
                    ('service_connecting', '连接 Bloom 服务'),
                    ('waiting_owner', '添加到你的账号'),
                  ],
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      node.$2,
                      style: style(
                        16,
                        color: c.phase == node.$1 ? green : muted,
                      ),
                    ),
                  ),
              ],
            ),
          )
        else ...[
          for (final n in c.networks)
            card(
              InkWell(
                onTap:
                    () => setState(() {
                      _ssid = n['ssid'] as String;
                      _auth = (n['auth'] as num).toInt();
                      _password.clear();
                    }),
                child: Row(
                  children: [
                    Icon(
                      _ssid == n['ssid']
                          ? Icons.check_circle_rounded
                          : Icons.wifi_rounded,
                      color: _ssid == n['ssid'] ? green : muted,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(n['ssid'] as String, style: style(18)),
                    ),
                    if (c.savedNetworks.contains(n['ssid']))
                      Text('已保存', style: style(12, color: muted)),
                  ],
                ),
              ),
            ),
          if (c.networks.isEmpty)
            Text(
              c.connected
                  ? '暂未找到网络，可以重新搜索或输入隐藏网络的名称。'
                  : '请保持相框开启并靠近手机，点击下方按钮重新连接。',
              style: style(14, color: muted),
            ),
          TextButton(
            onPressed: () => c.chooseName(c.name),
            child: Text(
              c.connected ? '重新搜索 Wi-Fi' : '重新连接相框',
              style: style(14, color: muted),
            ),
          ),
          TextButton(
            onPressed:
                !c.connected
                    ? null
                    : () async {
                      final input = TextEditingController();
                      final value = await showDialog<String>(
                        context: context,
                        builder:
                            (ctx) => AlertDialog(
                              title: const Text('隐藏网络'),
                              content: TextField(
                                controller: input,
                                decoration: const InputDecoration(
                                  hintText: 'Wi-Fi 名称',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed:
                                      () => Navigator.pop(ctx, input.text),
                                  child: const Text('确定'),
                                ),
                              ],
                            ),
                      );
                      await Future<void>.delayed(
                        const Duration(milliseconds: 300),
                      );
                      input.dispose();
                      if (value != null && value.trim().isNotEmpty && mounted) {
                        setState(() {
                          _ssid = value.trim();
                          _auth = 3;
                        });
                      }
                    },
            child: Text('添加隐藏网络', style: style(14, color: muted)),
          ),
          if (_ssid != null && _auth != 0 && !reused)
            card(
              TextField(
                controller: _password,
                obscureText: _obscure,
                style: style(18),
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Wi-Fi 密码',
                  labelStyle: style(15, color: muted),
                  border: InputBorder.none,
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: muted,
                    ),
                  ),
                ),
              ),
            ),
          if (reused)
            Text('将使用相框已保存的密码。密码有变化时，可以重新输入。', style: style(13, color: muted)),
          if (reused)
            TextButton(
              onPressed: () => setState(() => c.savedNetworks.remove(_ssid)),
              child: Text('重新输入密码', style: style(14)),
            ),
          const SizedBox(height: 20),
          button(
            '连接 Wi-Fi',
            _ssid == null
                ? null
                : () {
                  final password = _password.text;
                  _password.clear();
                  unawaited(c.connectWifi(_ssid!, password, reuse: reused));
                },
          ),
        ],
      ],
    );
  }

  Future<void> _startPlayback() async {
    final progress = FramePlaybackScope.of(context);
    if (progress == null) {
      setState(() => c.error = '暂时无法打开播放准备，请重新打开 App 后继续。');
      return;
    }
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder:
            (_) => BloomFramePlaybackPage(
              controller: progress,
              deviceId: c.deviceId!,
              autoStart: true,
            ),
      ),
    );
    if (mounted) _finish();
  }

  Widget photos() =>
      c.hasExistingPhotos
          ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 45),
              const Icon(Icons.photo_library_outlined, size: 80, color: green),
              const SizedBox(height: 32),
              title('让已有照片，在这里安家', '你的图库里已经有照片了。点击完成，相框就会准备并刷新第一张照片。'),
              button('完成并开始播放', _startPlayback),
            ],
          )
          : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 45),
              const Icon(Icons.photo_outlined, size: 80, color: green),
              const SizedBox(height: 32),
              title(
                '让第一张照片，在这里安家',
                '去添加你的第一张照片吧。选好后，会回到原来的上传页面显示进度；上传完成再进入首页。',
              ),
              button('添加第一张照片', _upload),
              const SizedBox(height: 12),
              button('稍后添加', _finish, secondary: true),
            ],
          );
  @override
  Widget build(BuildContext context) => PopScope<FrameSetupResult>(
    canPop: c.step == 0,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) {
        if (c.completed) {
          _finish();
        } else {
          c.back();
        }
      }
    },
    child: Theme(
      data: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: green,
          brightness: Brightness.light,
        ),
        fontFamily: 'BloomSerif',
      ),
      child: Scaffold(
        backgroundColor: paper,
        appBar: AppBar(
          backgroundColor: paper,
          surfaceTintColor: Colors.transparent,
          foregroundColor: ink,
          title: Text(c.managing ? '连接 Wi-Fi' : '添加相框', style: style(20)),
          leading: IconButton(
            onPressed:
                c.busy
                    ? null
                    : () {
                      if (c.completed) {
                        _finish();
                      } else if (c.step > 0) {
                        c.back();
                      } else {
                        Navigator.pop(context);
                      }
                    },
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
                child: steps(),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 30),
                  children: [
                    AnimatedSwitcher(
                      duration:
                          MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 240),
                      child: KeyedSubtree(
                        key: ValueKey(c.step),
                        child: switch (c.step) {
                          0 => discover(),
                          1 => naming(),
                          2 => wifi(),
                          _ => photos(),
                        },
                      ),
                    ),
                    if (c.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Text(
                          c.error!,
                          style: style(14, color: const Color(0xFFA45F50)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RipplePainter extends CustomPainter {
  _RipplePainter(this.progress);
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < 3; ++i) {
      final t = (progress + i / 3) % 1;
      final p =
          Paint()
            ..color = const Color(0xFF858D7B).withValues(alpha: (1 - t) * .18)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1;
      canvas.drawCircle(
        Offset(size.width / 2, size.height / 2),
        22 + t * size.height * .48,
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.progress != progress;
}
