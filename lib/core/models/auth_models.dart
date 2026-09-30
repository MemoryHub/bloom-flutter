/// F1 账号体系的模型。
///
/// 与设备令牌（`DeviceCredentials`）刻意分开：那是"这台手机的小组件"的身份，
/// 这是"这个人"的身份。两者并存，谁也不顶掉谁 —— 小组件的后台刷新仍然只用
/// 设备令牌，登录与否都不影响它继续换图。
library;

class AccountInfo {
  const AccountInfo({
    required this.id,
    required this.phone,
    this.nickname,
    required this.provisionStatus,
    required this.immichReady,
  });

  final String id;

  /// E.164，例如 +8613800138000。展示时才打码。
  final String phone;
  final String? nickname;

  /// `pending` / `ready` / `failed`。
  ///
  /// 注册后它是 `pending`：账号已经可用，但服务端还在异步建对应的 Immich
  /// 用户。界面据此显示"正在准备你的相册"，而不是一个看着像出错的空列表。
  final String provisionStatus;

  /// 服务端是否已经建好对应的 Immich 用户。
  final bool immichReady;

  bool get isProvisioning => !immichReady && provisionStatus != 'failed';
  bool get provisionFailed => provisionStatus == 'failed';

  /// 打码后的手机号，界面上永远用它，不打完整号码。
  ///
  /// ⚠️ 服务端存的是 E.164（`+8618611137800`），直接取前 3 位会得到
  /// `861****7800` —— 那是把**国码当成号码开头**显示给用户看。先剥掉 `+86`
  /// 再打码，才是 `186****7800` 这种一眼能认出来的形式。
  String get maskedPhone {
    var digits = phone.startsWith('+') ? phone.substring(1) : phone;
    if (digits.length == 13 && digits.startsWith('86')) {
      digits = digits.substring(2);
    }
    if (digits.length < 7) return digits;
    return '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}';
  }

  String get displayName {
    final name = nickname?.trim();
    if (name != null && name.isNotEmpty) return name;
    return maskedPhone;
  }

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
    id: json['id'] as String,
    phone: json['phone'] as String? ?? '',
    nickname: json['nickname'] as String?,
    provisionStatus: json['provision_status'] as String? ?? 'pending',
    immichReady: json['immich_ready'] as bool? ?? false,
  );
}

/// 注册或登录成功后的结果。
class AuthResult {
  const AuthResult({
    required this.token,
    required this.expiresAt,
    required this.account,
  });

  final String token;
  final DateTime expiresAt;
  final AccountInfo account;

  factory AuthResult.fromJson(Map<String, dynamic> json) => AuthResult(
    token: json['token'] as String,
    expiresAt: DateTime.parse(json['expires_at'] as String),
    account: AccountInfo.fromJson(
      (json['account'] as Map).cast<String, dynamic>(),
    ),
  );
}

/// 下发验证码的结果。
///
/// [devCode] 只会在服务端处于开发模式（`FRAME_SMS_PROVIDER=console`）时返回，
/// 用于云片签名/模板报备通过之前联调。生产环境恒为 null。
class SmsCodeResult {
  const SmsCodeResult({required this.expiresIn, this.devCode});

  final int expiresIn;
  final String? devCode;

  factory SmsCodeResult.fromJson(Map<String, dynamic> json) => SmsCodeResult(
    expiresIn: json['expires_in'] as int? ?? 300,
    devCode: json['dev_code'] as String?,
  );
}
