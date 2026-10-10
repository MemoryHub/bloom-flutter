import 'dart:async';
import 'dart:convert';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/auth/auth_repository.dart';
import 'package:bloom/core/models/auth_models.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 内存版安全存储。AuthRepository 把读写抽成了三个可注入的函数，
/// 所以这里不需要 mock 平台通道。
class _MemoryStore {
  final Map<String, String> values = {};

  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async => values[key] = value;
  Future<void> delete(String key) async => values.remove(key);
}

AuthRepository _repo(
  _MemoryStore store, {
  required Future<http.Response> Function(http.Request) handler,
}) => AuthRepository(
  api: BloomApiClient(
    baseUrl: 'https://bloom.jihu.top',
    client: MockClient(handler),
  ),
  readValue: store.read,
  writeValue: store.write,
  deleteValue: store.delete,
);

Map<String, dynamic> _accountJson({bool ready = false}) => {
  'id': 'acc-1',
  'phone': '+8613800138000',
  'nickname': 'Alex',
  'provision_status': ready ? 'ready' : 'pending',
  'immich_ready': ready,
};

void main() {
  test('load returns null when there is no stored token', () async {
    final store = _MemoryStore();
    final auth = _repo(store, handler: (_) async => http.Response('{}', 500));

    expect(await auth.load(), isNull);
    expect(auth.isSignedIn, isFalse);
  });

  test(
    'load restores the session from local storage without any request',
    () async {
      // 本地恢复必须不发网络请求：离线启动也要立刻知道"我登录过"。
      final store =
          _MemoryStore()
            ..values[AuthRepository.tokenKey] = 'stored-token'
            ..values[AuthRepository.accountKey] = jsonEncode(_accountJson());

      var called = false;
      final auth = _repo(
        store,
        handler: (_) async {
          called = true;
          return http.Response('{}', 200);
        },
      );

      final account = await auth.load();
      expect(account?.phone, '+8613800138000');
      expect(auth.isSignedIn, isTrue);
      expect(auth.token, 'stored-token');
      expect(called, isFalse, reason: 'load() 不该发请求');
    },
  );

  test('a corrupt cached account does not break startup', () async {
    // 缓存只用于展示，形状不对就当没有 —— 不该让启动失败。
    final store =
        _MemoryStore()
          ..values[AuthRepository.tokenKey] = 'stored-token'
          ..values[AuthRepository.accountKey] = 'not json at all';

    final auth = _repo(store, handler: (_) async => http.Response('{}', 200));
    expect(await auth.load(), isNull);
    // 但令牌还在，所以仍然是登录态 —— 一次 refresh 就能把档案补回来。
    expect(auth.isSignedIn, isTrue);
  });

  test('refresh keeps the session when the network fails', () async {
    // ⚠️ 这条是整套设计里最要紧的一条：断网不能把人登出。
    // 否则"地铁里打开 App 就被踢回登录页"，而重新登录并不能解决网络问题。
    final store =
        _MemoryStore()
          ..values[AuthRepository.tokenKey] = 'stored-token'
          ..values[AuthRepository.accountKey] = jsonEncode(_accountJson());

    final auth = _repo(
      store,
      handler: (_) async => throw const SocketExceptionStub(),
    );
    await auth.load();

    final account = await auth.refresh();
    expect(account?.phone, '+8613800138000');
    expect(auth.isSignedIn, isTrue, reason: '网络失败把用户登出了');
    expect(store.values[AuthRepository.tokenKey], 'stored-token');
  });

  test('refresh clears the session only on an explicit 401', () async {
    final store =
        _MemoryStore()
          ..values[AuthRepository.tokenKey] = 'stale-token'
          ..values[AuthRepository.accountKey] = jsonEncode(_accountJson());

    final auth = _repo(
      store,
      handler:
          (_) async => http.Response(
            jsonEncode({'detail': 'authentication_required'}),
            401,
          ),
    );
    await auth.load();

    expect(await auth.refresh(), isNull);
    expect(auth.isSignedIn, isFalse);
    expect(store.values.containsKey(AuthRepository.tokenKey), isFalse);
    expect(store.values.containsKey(AuthRepository.accountKey), isFalse);
  });

  test('a 500 does not clear the session', () async {
    final store =
        _MemoryStore()
          ..values[AuthRepository.tokenKey] = 't'
          ..values[AuthRepository.accountKey] = jsonEncode(_accountJson());

    final auth = _repo(store, handler: (_) async => http.Response('boom', 500));
    await auth.load();
    await auth.refresh();
    expect(auth.isSignedIn, isTrue, reason: '服务端 5xx 不该把用户登出');
  });

  test('login stores the token and the account', () async {
    final store = _MemoryStore();
    final auth = _repo(
      store,
      handler: (request) async {
        expect(request.url.path, '/api/frame/auth/login');
        return http.Response(
          jsonEncode({
            'token': 'fresh-token',
            'expires_at': '2030-01-01T00:00:00Z',
            'account': _accountJson(ready: true),
          }),
          200,
        );
      },
    );

    // login 现在回传整个 AuthResult（里面可能带服务端下发的设备令牌），
    // 账号档案在 .account 上。
    final result = await auth.login(phone: '13800138000', code: '123456');
    expect(result.account.immichReady, isTrue);
    expect(auth.token, 'fresh-token');
    expect(store.values[AuthRepository.tokenKey], 'fresh-token');
    // 账号档案也要落盘，下次冷启动才有东西可显示。
    expect(store.values[AuthRepository.accountKey], contains('+8613800138000'));
  });

  test('register posts to the register endpoint with the nickname', () async {
    final store = _MemoryStore();
    late http.Request captured;
    final auth = _repo(
      store,
      handler: (request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'token': 't',
            'expires_at': '2030-01-01T00:00:00Z',
            'account': _accountJson(),
          }),
          201,
        );
      },
    );

    await auth.register(phone: '13800138000', code: '123456', nickname: '小明');
    expect(captured.url.path, '/api/frame/auth/register');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['nickname'], '小明');
    expect(body['code'], '123456');
  });

  test('sendCode picks the purpose from the mode', () async {
    final store = _MemoryStore();
    final purposes = <String>[];
    final auth = _repo(
      store,
      handler: (request) async {
        purposes.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['purpose']
              as String,
        );
        return http.Response(
          jsonEncode({'expires_in': 300, 'dev_code': '000000'}),
          200,
        );
      },
    );

    await auth.sendCode(phone: '13800138000', forRegister: true);
    await auth.sendCode(phone: '13800138000', forRegister: false);
    expect(purposes, ['register', 'login']);
  });

  test('signOut clears local state even when the server call fails', () async {
    // 用户点了"退出登录"却因为一次网络超时而留在登录态，是最让人不信任的
    // 一类 bug。本地必须无条件清干净。
    final store =
        _MemoryStore()
          ..values[AuthRepository.tokenKey] = 't'
          ..values[AuthRepository.accountKey] = jsonEncode(_accountJson());

    final auth = _repo(
      store,
      handler: (_) async => throw const SocketExceptionStub(),
    );
    await auth.load();

    await auth.signOut();
    expect(auth.isSignedIn, isFalse);
    expect(store.values, isEmpty);
  });

  test(
    'logout sends JSON and device proof so the server can pause only this phone',
    () async {
      final store = _MemoryStore()..values[AuthRepository.tokenKey] = 'session';
      final auth = _repo(
        store,
        handler: (request) async {
          expect(request.headers['content-type'], contains('application/json'));
          expect(request.headers['x-frame-token'], 'device-proof');
          expect(jsonDecode(request.body), {'device_id': 'bloom-mobile-local'});
          return http.Response('', 204);
        },
      );
      await auth.load();
      await auth.signOut(
        device: const DeviceCredentials(
          deviceId: 'bloom-mobile-local',
          deviceToken: 'device-proof',
        ),
      );
      expect(auth.isSignedIn, isFalse);
    },
  );

  test('logout treats 401 as success', () async {
    // 令牌本来就失效时，登出仍应完成 —— 否则用户卡在"退不出去"。
    final store = _MemoryStore()..values[AuthRepository.tokenKey] = 't';
    final auth = _repo(
      store,
      handler:
          (_) async => http.Response(
            jsonEncode({'detail': 'authentication_required'}),
            401,
          ),
    );
    await auth.load();

    await auth.signOut();
    expect(auth.isSignedIn, isFalse);
    expect(store.values, isEmpty);
  });

  test('退出立即清本地，不等待服务器退出响应', () async {
    final store = _MemoryStore()..values[AuthRepository.tokenKey] = 't';
    final entered = Completer<void>();
    final reply = Completer<http.Response>();
    final auth = _repo(
      store,
      handler: (_) {
        entered.complete();
        return reply.future;
      },
    );
    await auth.load();
    final logout = auth.signOut();
    await entered.future;
    expect(auth.isSignedIn, isFalse);
    expect(store.values, isEmpty);
    reply.complete(http.Response('', 204));
    await logout;
  });

  test('退出前发出的账号刷新不能恢复旧账号', () async {
    final store = _MemoryStore()..values[AuthRepository.tokenKey] = 't';
    final entered = Completer<void>();
    final reply = Completer<http.Response>();
    final auth = _repo(
      store,
      handler: (request) {
        if (request.url.path.endsWith('/logout')) {
          return Future.value(http.Response('', 204));
        }
        entered.complete();
        return reply.future;
      },
    );
    await auth.load();
    final refresh = auth.refresh();
    await entered.future;
    await auth.signOut();
    reply.complete(http.Response(jsonEncode({'account': _accountJson()}), 200));
    await refresh;
    expect(auth.isSignedIn, isFalse);
    expect(auth.account, isNull);
    expect(store.values, isEmpty);
  });

  group('登录即认领设备', () {
    test('登录时上报的设备信息会进 JSON 体', () async {
      final store = _MemoryStore();
      Map<String, dynamic>? sent;
      final auth = _repo(
        store,
        handler: (request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'token': 't1',
              'expires_at': '2030-01-01T00:00:00Z',
              'account': _accountJson(ready: true),
              'device': {
                'device_id': 'bloom-mobile-abc',
                'device_token': 'd' * 64,
              },
            }),
            200,
          );
        },
      );

      final result = await auth.login(
        phone: '13800138000',
        code: '123456',
        device: const DeviceClaim(deviceId: 'bloom-mobile-abc'),
      );

      expect(sent!['device']['device_id'], 'bloom-mobile-abc');
      // 令牌只在响应里出现一次，必须原样带回来交给上层去存。
      expect(result.device!.deviceToken, 'd' * 64);
    });

    test('服务端认领失败时 device 为 null，但登录照样成功', () async {
      // 注册那一刻服务端还在异步建 Immich 用户，必然绑不上设备 —— 这是常态。
      // 把它当成登录失败，就会得到"注册成功却当场登录不上"。
      final store = _MemoryStore();
      final auth = _repo(
        store,
        handler:
            (_) async => http.Response(
              jsonEncode({
                'token': 't1',
                'expires_at': '2030-01-01T00:00:00Z',
                'account': _accountJson(),
                'device': null,
              }),
              201,
            ),
      );

      final result = await auth.register(
        phone: '13800138000',
        code: '123456',
        device: const DeviceClaim(deviceId: 'bloom-mobile-abc'),
      );

      expect(result.device, isNull);
      expect(auth.isSignedIn, isTrue, reason: '认领失败不该影响登录');
      expect(store.values[AuthRepository.tokenKey], 't1');
    });

    test('未登录时调认领接口直接报错，不发请求', () async {
      var called = false;
      final auth = _repo(
        _MemoryStore(),
        handler: (_) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      await expectLater(
        auth.claimDevice(const DeviceClaim(deviceId: 'bloom-mobile-abc')),
        throwsA(isA<BloomApiException>()),
      );
      expect(called, isFalse);
    });

    test('认领接口回传畸形数据时报错，而不是静默返回空令牌', () async {
      // 空令牌一旦被存进设备身份仓库，小组件会拿着它去打 /carousel/plan，
      // 得到 401 之后表现为"小组件不换图"，而没有一条线索指向这里。
      final store =
          _MemoryStore()
            ..values[AuthRepository.tokenKey] = 'tok'
            ..values[AuthRepository.accountKey] = jsonEncode(
              _accountJson(ready: true),
            );
      await _repo(store, handler: (_) async => http.Response('{}', 500)).load();

      final auth = _repo(
        store,
        handler:
            (_) async => http.Response(
              jsonEncode({'device_id': 'bloom-mobile-abc'}),
              200,
            ),
      );
      await auth.load();

      await expectLater(
        auth.claimDevice(const DeviceClaim(deviceId: 'bloom-mobile-abc')),
        throwsA(isA<BloomApiException>()),
      );
    });
  });
}

/// 用一个自定义异常冒充网络层失败，避免为 dart:io 的 SocketException
/// 引入平台依赖。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketExceptionStub: 网络不可达';
}
