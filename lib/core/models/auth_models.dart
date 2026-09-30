/// 账号体系的模型。
///
/// 与设备令牌（`DeviceCredentials`）刻意分开：那是"这台手机的小组件"的身份，
/// 这是"这个人"的身份。
///
/// ⚠️ 两者的关系在"登录即绑定"之后变了：设备令牌**由服务端在登录/认领设备时
/// 下发**，所以未登录时本机根本没有可用的设备令牌，小组件也就取不到新图
/// （这正是"登出即冻结"的实现方式）。设备 ID 仍是本机生成的，它只是被**上报**
/// 给服务端，用来把这条设备记录挂到账号下。
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

/// 登录/注册时上报的"这台手机是谁"。
///
/// [deviceId] 必须是 `bloom-mobile-` 开头：服务端拿它当安全边界（正则 + 再查
/// 一次 device_type），挡住"报一个墨水屏相框的 ID 把它抢过来"。
class DeviceClaim {
  const DeviceClaim({
    required this.deviceId,
    this.name,
    this.timezone = 'Asia/Shanghai',
    this.language = 'zh-CN',
    this.screenProfile = 'default',
  });

  final String deviceId;

  /// 设备名。**只在服务端首次插入时生效** —— 之后在库里改过的名字不会被
  /// 重新登录覆盖（以前会，于是四台设备全叫"Bloom 手机"）。
  final String? name;

  final String timezone;
  final String language;
  final String screenProfile;

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    if (name != null && name!.trim().isNotEmpty) 'name': name!.trim(),
    'timezone': timezone,
    'language': language,
    'screen_profile': screenProfile,
  };
}

/// 服务端认领设备后下发的信息。
///
/// [deviceToken] **只在响应里出现这一次**（服务端只存 sha256），客户端必须自己
/// 存好；丢了就再调一次认领接口换一枚新的。
class ClaimedDevice {
  const ClaimedDevice({required this.deviceId, required this.deviceToken});

  final String deviceId;
  final String deviceToken;

  static ClaimedDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final id = map['device_id'] as String?;
    final token = map['device_token'] as String?;
    if (id == null || token == null || token.length < 32) return null;
    return ClaimedDevice(deviceId: id, deviceToken: token);
  }
}

/// 注册或登录成功后的结果。
class AuthResult {
  const AuthResult({
    required this.token,
    required this.expiresAt,
    required this.account,
    this.device,
  });

  final String token;
  final DateTime expiresAt;
  final AccountInfo account;

  /// 服务端在这次登录里认领成功的设备。
  ///
  /// **为 null 是常态**：注册的那一刻服务端还在异步建 Immich 用户，没有
  /// `immich_user_id` 就绑不了设备。客户端据此判断"稍后再调一次认领接口"，
  /// 而不是把登录当成失败。
  final ClaimedDevice? device;

  factory AuthResult.fromJson(Map<String, dynamic> json) => AuthResult(
    token: json['token'] as String,
    expiresAt: DateTime.parse(json['expires_at'] as String),
    account: AccountInfo.fromJson(
      (json['account'] as Map).cast<String, dynamic>(),
    ),
    device: ClaimedDevice.fromJson(json['device']),
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
