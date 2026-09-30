import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bloom/core/storage/device_identity_repository.dart';

/// 设备身份。
///
/// ⚠️ 这个仓库的行为在"登录即绑定"之后变过一次，测试跟着改：
/// 它以前要求身份**跨重装稳定**（iOS 走 Keychain、Android 走 ANDROID_ID），
/// 为此需要一个必须在启动后 2 秒内装上的平台通道 —— 那个竞态就是"全新安装
/// 首次启动卡在配对页"的成因。
///
/// 现在归属由登录决定，重装后换新设备 ID 也没关系，所以这里回到最朴素的做法。
/// 这几条用例钉的就是"朴素做法"本身。
void main() {
  DeviceIdentityRepository build(
    Map<String, String> secure, {
    List<List<String>>? mirrored,
  }) => DeviceIdentityRepository(
    readToken: (key) async => secure[key],
    writeToken: (key, value) async => secure[key] = value,
    // 记下镜像调用，用来钉住"什么时候该把令牌交给原生小组件"。
    mirrorToWidget: (deviceId, deviceToken) async =>
        mirrored?.add([deviceId, deviceToken]),
  );

  test('首次启动会生成一个本机设备身份', () async {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    final repository = build(secure);

    final first = await repository.initialize();
    expect(first.deviceId, startsWith('bloom-mobile-'));
    expect(first.deviceToken.length, 64);

    // 同一次安装内必须稳定：再取一次是同一个身份。
    final second = await repository.initialize();
    expect(second.deviceId, first.deviceId);
    expect(second.deviceToken, first.deviceToken);
  });

  test('两次全新安装会得到不同的设备 ID', () async {
    // 这条是**故意**的：身份不再跨重装稳定。所以不该有人指望重装后还是同一台
    // —— 重装后要重新登录一次，服务端会把它认领到同一个账号下。
    SharedPreferences.setMockInitialValues({});
    final a = await build(<String, String>{}).initialize();
    SharedPreferences.setMockInitialValues({});
    final b = await build(<String, String>{}).initialize();
    expect(a.deviceId, isNot(b.deviceId));
  });

  test('已存在的身份不会被覆盖', () async {
    SharedPreferences.setMockInitialValues({'bloom.device_id': 'old-id'});
    final secure = {'bloom.device_token': 'b' * 64};
    final result = await build(secure).initialize();
    expect(result.deviceId, 'old-id');
    expect(result.deviceToken, 'b' * 64);
  });

  test('令牌残缺时当作没有身份，重新生成', () async {
    // 半截令牌不能拿去打接口：服务端比对的是它的 sha256，一个被截断的值
    // 只会得到 401，而调用方会把它当成网络问题。
    SharedPreferences.setMockInitialValues({'bloom.device_id': 'old-id'});
    final secure = {'bloom.device_token': 'short'};
    final result = await build(secure).initialize();
    expect(result.deviceId, isNot('old-id'));
    expect(result.deviceToken.length, 64);
  });

  test('服务端下发的令牌会覆盖本地占位令牌，并被标记', () async {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    final repository = build(secure);
    final local = await repository.initialize();
    expect(await repository.hasServerToken(), isFalse);

    await repository.saveIssued(
      deviceId: local.deviceId,
      deviceToken: 'e' * 64,
    );

    expect(await repository.hasServerToken(), isTrue);
    final stored = await repository.read();
    expect(stored!.deviceToken, 'e' * 64);
    // 设备 ID 不变 —— 认领的是同一台机器，只是令牌换了。
    expect(stored.deviceId, local.deviceId);
  });

  test('登出清掉一切，包括"令牌来自服务端"这个标记', () async {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    final repository = build(secure);
    final local = await repository.initialize();
    await repository.saveIssued(deviceId: local.deviceId, deviceToken: 'f' * 64);

    await repository.clear();

    expect(await repository.read(), isNull);
    expect(await repository.hasServerToken(), isFalse);
    expect(secure['bloom.device_token'], anyOf(isNull, isEmpty));
  });

  test('本机自编的令牌不镜像给小组件', () async {
    // 服务端比对的是下发时记下的 sha256，本机自编的令牌必然 401。镜像过去只会
    // 让小组件拿着一个注定失败的令牌反复请求。
    SharedPreferences.setMockInitialValues({});
    final mirrored = <List<String>>[];
    await build(<String, String>{}, mirrored: mirrored).initialize();
    expect(mirrored, isEmpty);
  });

  test('服务端下发的令牌会镜像给小组件', () async {
    // iOS 的小组件扩展是独立进程，只认 App Group 里的令牌。漏掉这一步，
    // App 里一切正常而小组件静静地不再更新。
    SharedPreferences.setMockInitialValues({});
    final mirrored = <List<String>>[];
    final repository = build(<String, String>{}, mirrored: mirrored);
    final local = await repository.initialize();

    await repository.saveIssued(
      deviceId: local.deviceId,
      deviceToken: 'e' * 64,
    );

    expect(mirrored, hasLength(1));
    expect(mirrored.single[1], 'e' * 64);
  });

  test('登出会把原生侧那份令牌抹掉', () async {
    // 不抹的话，"登出即冻结"在 iOS 上根本不生效 —— 小组件照样能拉到新图。
    SharedPreferences.setMockInitialValues({});
    final mirrored = <List<String>>[];
    final repository = build(<String, String>{}, mirrored: mirrored);
    final local = await repository.initialize();
    await repository.saveIssued(deviceId: local.deviceId, deviceToken: 'f' * 64);

    await repository.clear();

    expect(mirrored, hasLength(2));
    expect(mirrored.last[1], isEmpty, reason: '登出必须清掉原生侧的令牌');
  });
}
