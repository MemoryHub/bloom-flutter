import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api/bloom_api_client.dart';
import '../core/auth/auth_repository.dart';
import '../core/models/auth_models.dart';
import 'bloom_glass_home.dart';

/// 登录 / 注册页（F1）。
///
/// 手机号 + 短信验证码，与大多数国内 App 一样：一个输入框、一个倒计时按钮。
/// 不设密码，因此也没有"忘记密码"这条支线。
///
/// 「登录」和「注册」在服务端是两个接口，但在这里是同一个页面的两种模式 ——
/// 用户不该先自己判断"我注册过没有"。默认登录；如果服务端回 404
/// `account_not_found`，页面自动切到注册并说明原因。
class BloomAuthPage extends StatefulWidget {
  const BloomAuthPage({
    super.key,
    required this.auth,
    this.onSignedIn,
    this.onCancel,
    this.initialRegisterMode = false,
  });

  final AuthRepository auth;
  final ValueChanged<AccountInfo>? onSignedIn;

  /// 有值时会显示一个返回入口。作为开屏门禁时传 null。
  final VoidCallback? onCancel;

  final bool initialRegisterMode;

  @override
  State<BloomAuthPage> createState() => _BloomAuthPageState();
}

class _BloomAuthPageState extends State<BloomAuthPage> {
  late final TextEditingController _phone = TextEditingController();
  late final TextEditingController _code = TextEditingController();
  late final TextEditingController _nickname = TextEditingController();

  late bool _registerMode = widget.initialRegisterMode;

  bool _sending = false;
  bool _submitting = false;
  String? _error;

  /// 开发模式提示。服务端处于 console 短信模式时会回带验证码，
  /// 这里显示出来 —— 云片模板报备通过之前，这是唯一能联调的方式。
  String? _devCode;

  int _cooldown = 0;
  Timer? _timer;

  /// 两条短信之间的最短等待。服务端也按这个值限流，两边一致，
  /// 用户不会遇到"倒计时走完了但服务端还说你发太快"。
  static const _resendSeconds = 60;

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    _nickname.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');

  /// 客户端先挡一道，避免为一个必然被服务端拒绝的号付一条短信。
  bool get _phoneLooksValid =>
      _digits.length == 11 && _digits.startsWith('1') && _digits[1] != '0';

  bool get _canSubmit =>
      _phoneLooksValid && _code.text.length == 6 && !_submitting;

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = _resendSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldown -= 1);
      if (_cooldown <= 0) timer.cancel();
    });
  }

  Future<void> _sendCode() async {
    if (_sending || _cooldown > 0) return;
    if (!_phoneLooksValid) {
      setState(() => _error = '请输入 11 位手机号');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final result = await widget.auth.sendCode(
        phone: _digits,
        forRegister: _registerMode,
      );
      if (!mounted) return;
      setState(() => _devCode = result.devCode);
      // 开发模式下直接把码填好：报备通过前每次联调都要手抄一遍六位数，
      // 而这段代码只在服务端处于 console 模式时才会拿到 devCode。
      if (result.devCode != null) {
        _code.text = result.devCode!;
      }
      _startCooldown();
    } on BloomApiException catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } catch (_) {
      if (mounted) setState(() => _error = '网络异常，请稍后重试');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final account = _registerMode
          ? await widget.auth.register(
              phone: _digits,
              code: _code.text,
              nickname: _nickname.text,
            )
          : await widget.auth.login(phone: _digits, code: _code.text);
      if (!mounted) return;
      widget.onSignedIn?.call(account);
    } on BloomApiException catch (error) {
      if (!mounted) return;
      setState(() {
        // 未注册时自动切到注册模式。注意服务端是【先验码再查账号】的，
        // 所以这次尝试已经把验证码消费掉了 —— 必须明确告诉用户要重新获取，
        // 否则他会照着旧码反复点"注册"。
        if (error.code == 'account_not_found') {
          _registerMode = true;
          _code.clear();
          _error = '该手机号还没有注册过，已切到注册。请重新获取验证码。';
        } else {
          _error = _messageFor(error);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = '网络异常，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _switchMode(bool register) {
    if (_submitting) return;
    setState(() {
      _registerMode = register;
      _error = null;
      _devCode = null;
    });
  }

  /// 服务端的 message 已经是具体中文，优先用它；这里只补它给不出的上下文。
  static String _messageFor(BloomApiException error) {
    switch (error.code) {
      case 'code_expired':
        return '验证码已过期，请重新获取';
      case 'code_used':
        return '验证码已被使用，请重新获取';
      case 'code_locked':
        return '验证码错误次数过多，请重新获取';
      case 'code_not_found':
        return '请先获取验证码';
      case 'phone_registered':
        return '该手机号已注册，请直接登录';
      case 'account_disabled':
        return '账号已被停用，请联系我们';
      case 'account_not_provisioned':
        return '正在准备你的相册，请稍后重试';
      default:
        final message = error.message.trim();
        if (message.isNotEmpty && message != '请求失败') return message;
        return '操作失败，请稍后重试';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: BloomAtmosphere(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              BloomSurface.pageInset,
              8,
              BloomSurface.pageInset,
              32,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.onCancel != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: BloomIconButton(
                      icon: Icons.arrow_back_rounded,
                      loading: false,
                      onTap: widget.onCancel,
                    ),
                  ),
                const SizedBox(height: 18),
                BloomPageTitle(
                  title: _registerMode ? '创建账号' : '登录 Bloom',
                  subtitle: '登录后可管理你的相框、小组件与照片',
                ),
                const SizedBox(height: 26),
                _phoneField(),
                const SizedBox(height: 12),
                _codeField(),
                if (_registerMode) ...[
                  const SizedBox(height: 12),
                  _nicknameField(),
                ],
                const SizedBox(height: 18),
                BloomPrimaryButton(
                  label: _registerMode ? '注册并登录' : '登录',
                  loading: _submitting,
                  loadingLabel: '请稍候…',
                  onPressed: _canSubmit ? _submit : null,
                ),
                const SizedBox(height: 14),
                _modeSwitchLink(),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  BloomMessage(message: _error!, isError: true),
                ],
                if (_devCode != null) ...[
                  const SizedBox(height: 12),
                  BloomMessage(
                    message:
                        '开发模式：验证码 ${_devCode!} 已自动填入'
                        '（短信模板报备通过前用于联调）',
                  ),
                ],
                const SizedBox(height: 22),
                Text(
                  '登录即表示你同意我们为提供服务而保存你的手机号。'
                  '短信验证码 5 分钟内有效，请勿转告他人。',
                  style: BloomType.meta,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeSwitchLink() => Align(
    alignment: Alignment.center,
    child: TextButton(
      onPressed: _submitting ? null : () => _switchMode(!_registerMode),
      child: Text(
        _registerMode ? '已有账号？去登录' : '还没有账号？去注册',
        style: BloomType.labelStrong,
      ),
    ),
  );

  Widget _phoneField() => BloomPanel(
    lifted: false,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(
      children: [
        const Text('+86', style: BloomType.labelStrong),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            // 只收数字：粘贴进来的带空格/横线的号码服务端也能归一，
            // 没必要让它们先进输入框再被抱怨格式不对。
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            style: BloomType.body,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: '手机号',
              hintStyle: BloomType.meta,
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
        ),
      ],
    ),
  );

  Widget _codeField() => BloomPanel(
    lifted: false,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            style: BloomType.body,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: '6 位验证码',
              hintStyle: BloomType.meta,
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: (_sending || _cooldown > 0) ? null : _sendCode,
          child: Text(
            _cooldown > 0 ? '$_cooldown s' : (_sending ? '发送中…' : '获取验证码'),
            style: BloomType.labelStrong,
          ),
        ),
      ],
    ),
  );

  Widget _nicknameField() => BloomPanel(
    lifted: false,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: TextField(
      controller: _nickname,
      maxLength: 100,
      style: BloomType.body,
      decoration: const InputDecoration(
        border: InputBorder.none,
        isDense: true,
        counterText: '',
        hintText: '昵称（选填）',
        hintStyle: BloomType.meta,
      ),
    ),
  );
}
