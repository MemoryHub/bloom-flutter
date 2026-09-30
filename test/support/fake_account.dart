import 'dart:convert';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/auth/auth_repository.dart';
import 'package:bloom/core/models/auth_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 测试用的已登录账号。
///
/// 四个页面现在都有"未登录"分支，所以测试必须**显式说明**它要验哪一种状态 ——
/// 不传账号就是未登录，看不到内容。这个工厂给那些"验已登录内容"的用例用。
AccountInfo fakeAccount({
  String id = 'acc-test',
  String phone = '+8613800138000',
  String? nickname = '测试用户',
  String provisionStatus = 'ready',
  bool immichReady = true,
}) => AccountInfo(
  id: id,
  phone: phone,
  nickname: nickname,
  provisionStatus: provisionStatus,
  immichReady: immichReady,
);

/// 正在 provisioning 的账号（注册后那一小段时间）。
AccountInfo fakeProvisioningAccount() =>
    fakeAccount(provisionStatus: 'pending', immichReady: false);

/// 一个"本地已存有会话"的 [AuthRepository]。
///
/// 给那些直接 pump 真实 `BloomHomePage` 的测试用：[BloomHomePage] 从
/// `AuthRepository` 读登录态，所以不给它一份会话，页面就会停在未登录提示上，
/// 那些本该验首页内容的用例会全部假失败。
///
/// `load()` 不发网络请求（这是它的设计），所以这里只需要把存储喂进去；
/// 后续 `refresh()` 撞上 404 也无所谓 —— 它会退回本地缓存而不是登出。
AuthRepository signedInAuthRepository({AccountInfo? account}) {
  final value = account ?? fakeAccount();
  final cached = jsonEncode({
    'id': value.id,
    'phone': value.phone,
    'nickname': value.nickname,
    'provision_status': value.provisionStatus,
    'immich_ready': value.immichReady,
  });
  return AuthRepository(
    api: BloomApiClient(
      client: MockClient((_) async => http.Response('{}', 404)),
    ),
    readValue: (key) async =>
        key == AuthRepository.tokenKey ? 'test-session-token' : cached,
    writeValue: (_, _) async {},
    deleteValue: (_) async {},
  );
}
