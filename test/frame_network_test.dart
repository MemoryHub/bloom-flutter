import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bloom_provision/bloom_provision.dart';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/provisioning/frame_local_admin.dart';
import 'package:bloom/core/provisioning/frame_network_controller.dart';
import 'package:bloom/ui/bloom_device_pages.dart';
import 'package:bloom/ui/bloom_frame_network_page.dart';

final access = <String, dynamic>{
  'account_id': 'owner-1',
  'device_id': 'frame-1',
  'ble_name': 'BLOOM_001122334455',
  'pop': 'test-only-proof',
  'key': '0' * 63 + '1',
  'epoch': 1,
};

class Store extends FrameAdminStore {
  String? owner = 'owner-1';
  Map<String, dynamic>? value = Map.of(access);
  @override
  Future<String?> accountId() async => owner;
  @override
  Future<Map<String, dynamic>?> read(String account, String device) async =>
      value == null ? null : Map.of(value!);
  @override
  Future<void> write(
    String account,
    String device,
    Map<String, dynamic> data,
  ) async {
    value = Map.of(data);
  }

  @override
  Future<void> remove(String account, String device) async {
    value = null;
  }
}

class RelayBridge extends Bridge {
  int resetStage = 0;
  int starts = 0;
  bool supported = true;
  int version = 1;
  bool loseSeal = false;
  final List<String> events;
  RelayBridge(this.events);
  @override
  Future<Map<String, dynamic>> data(Map<String, dynamic> command) async {
    switch (command['op']) {
      case 'hello':
        return {
          ...await super.data(command),
          'reset_relay_capable': supported,
          'reset_relay_version': version,
          'reset_relay_job': resetStage > 0 ? 'reset-1' : '',
          'reset_relay_stage': resetStage,
        };
      case 'admin_reset':
        events.add('device_start');
        starts++;
        resetStage = 3;
        return {'status': 'reset_accepted'};
      case 'reset_status':
        return {
          'job': 'reset-1',
          'stage': resetStage,
          'relay_version': version,
          'receipt': 'a' * 64,
          if (resetStage == 5) 'finished_receipt': 'b' * 64,
        };
      case 'reset_finish':
        events.add('device_finish');
        if (loseSeal) throw PlatformException(code: 'disconnected');
        resetStage = 7;
        return {'status': 'reset_finished'};
      case 'reset_commit':
        events.add('device_commit');
        resetStage = 5;
        return {'status': 'reset_committed'};
      default:
        return super.data(command);
    }
  }
}

class RelayApi extends BloomApiClient {
  final List<String> events;
  String? failAt;
  RelayApi(this.events);
  @override
  Future<Map<String, dynamic>> userRequest(
    String token,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? deviceToken,
    Map<String, String>? query,
  }) async {
    final step =
        path.endsWith('/finish')
            ? 'finish'
            : path.endsWith('/complete')
            ? 'complete'
            : 'authorize';
    events.add('server_$step');
    if (failAt == step) throw BloomApiException(503, 'offline', 'offline');
    return {
      'command': {
        'id': 'reset-1',
        'state': step == 'finish' ? 'succeeded' : 'running',
      },
      'message': 'signed-fixture',
      'signature': 'signature-fixture',
    };
  }
}

class Api extends BloomApiClient {
  int requests = 0;
  @override
  Future<Map<String, dynamic>> userRequest(
    String token,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? deviceToken,
    Map<String, String>? query,
  }) async {
    requests++;
    if (path.endsWith('/wifi')) {
      return {
        'network': {
          'wifi_ssid': 'Home',
          'saved_networks': ['Home'],
          'seen_at': '2026-10-15T00:00:00Z',
        },
      };
    }
    throw StateError('A local network operation must not request HTTP: $path');
  }
}

class ResetApi extends BloomApiClient {
  String state = 'queued';
  int deletes = 0, gets = 0;
  bool claimRace = false;
  Completer<Map<String, dynamic>>? pendingGet;
  @override
  Future<Map<String, dynamic>> userRequest(
    String token,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? deviceToken,
    Map<String, String>? query,
  }) async {
    if (method == 'DELETE') {
      deletes++;
      if (claimRace) {
        state = 'running';
        throw BloomApiException(
          409,
          'device_reset_cannot_cancel',
          'cannot cancel',
        );
      }
      state = 'cancelled';
    }
    if (method == 'GET') {
      gets++;
      if (pendingGet != null) return pendingGet!.future;
    }
    return {
      'command': {'id': 'reset-1', 'state': state},
    };
  }
}

class EnrollmentApi extends BloomApiClient {
  EnrollmentApi(this.grant);
  final Map<String, dynamic> grant;
  @override
  Future<Map<String, dynamic>> userRequest(
    String token,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? deviceToken,
    Map<String, String>? query,
  }) async => grant;
}

class Bridge extends BloomProvisionBridge {
  int scans = 0, connects = 0, disconnects = 0;
  int emptyScans = 0;
  bool busyAdvert = false, cloudCapable = true, badCloudAck = false;
  bool management = false,
      failWifi = false,
      refreshing = false,
      unsupported = false;
  String actualId = 'frame-1', stage = 'network_ready';
  String failureStage = 'wifi_failed';
  List<String> saved = ['Home'];
  final commands = <Map<String, dynamic>>[];
  Completer<void>? scanGate;
  @override
  Future<List<Map<String, dynamic>>> scan() async {
    scans++;
    if (scanGate != null) await scanGate!.future;
    if (scans <= emptyScans) return [];
    return [
      {'ble_name': 'BLOOM_001122334455', 'rssi': -40, 'busy': busyAdvert},
    ];
  }

  @override
  Future<String> signAdmin(String message, String key) async {
    expect(message, 'bloom-local-admin-auth-v1|frame-1|${'a' * 32}|1');
    expect(key, '0' * 63 + '1');
    return 'MEUCICTfTlIYyG7ehKoFfWCx+VLMHWMwXIPw1azU0ypBfad9AiEAv+lD5wPggacMWYUS54LyJdYWjgRM4VEhHvmVyGXmogM=';
  }

  @override
  Future<void> connect(String name, String pop) async {
    connects++;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<Map<String, dynamic>> data(Map<String, dynamic> command) async {
    commands.add(command);
    switch (command['op']) {
      case 'install_admin':
        return {'status': 'admin_installed'};
      case 'hello':
        return {
          'device_id': actualId,
          'nonce': 'a' * 32,
          'local_admin_capable': true,
          'cloud_check_capable': cloudCapable,
          'ble_standby': !unsupported,
          'local_admin_epoch': 1,
        };
      case 'admin_auth':
        if (refreshing) throw PlatformException(code: 'frame_busy');
        expect(
          command['signature'],
          'MEUCICTfTlIYyG7ehKoFfWCx+VLMHWMwXIPw1azU0ypBfad9AiEAv+lD5wPggacMWYUS54LyJdYWjgRM4VEhHvmVyGXmogM=',
        );
        return {'status': 'authenticated'};
      case 'admin_check_server':
        return {'status': badCloudAck ? 'accepted' : 'server_check_requested'};
      case 'admin_begin':
        management = true;
        return {'status': 'accepted'};
      case 'admin_end':
        management = false;
        return {'status': 'released'};
      case 'admin_scan':
        return {'status': 'accepted'};
      case 'admin_scan_result':
        final all = [
          {'ssid': 'Office', 'rssi': -70, 'auth': 3},
          {'ssid': 'Home', 'rssi': -50, 'auth': 3},
          {'ssid': 'Home', 'rssi': -35, 'auth': 3},
          {'ssid': 'Open', 'rssi': -60, 'auth': 0},
        ];
        final offset = command['offset'] as int;
        return {
          'finished': true,
          'count': all.length,
          'networks': all.skip(offset).take(2).toList(),
        };
      case 'connect':
        stage = failWifi ? failureStage : 'wifi_success';
        if (!failWifi) saved.add(command['ssid'] as String);
        return {'status': 'accepted'};
      case 'forget':
        saved.remove(command['ssid']);
        stage = 'network_removed';
        return {'status': 'accepted'};
      case 'status':
        return {
          'phase': stage,
          'business_busy': false,
          'management_ready': management,
          'saved_networks': saved,
          'wifi_ssid': saved.isEmpty ? '' : saved.first,
        };
      default:
        throw StateError('Unexpected command');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FrameNetworkController relay(RelayApi api, RelayBridge bridge, Store store) =>
      FrameNetworkController(
        api: api,
        token: 'test',
        deviceId: 'frame-1',
        bridge: bridge,
        store: store,
        pause: (_) async {},
      );
  test(
    'just-disconnected frame is rediscovered before reset authorization',
    () async {
      final events = <String>[];
      final bridge = RelayBridge(events)..emptyScans = 1;
      final c = relay(RelayApi(events), bridge, Store());
      expect(await c.resetThroughPhone('reset-1'), true);
      expect(bridge.scans, 2);
      expect(bridge.starts, 1);
      c.dispose();
    },
  );

  test(
    'offline frame resets only after server authorization and both real receipts',
    () async {
      final events = <String>[], store = Store();
      final api = RelayApi(events), bridge = RelayBridge(events);
      final c = relay(api, bridge, store);
      expect(await c.resetThroughPhone('reset-1'), true);
      expect(events, [
        'server_authorize',
        'device_start',
        'server_complete',
        'device_commit',
        'server_finish',
      ]);
      expect(store.value, isNull);
      expect(bridge.management, false);
      c.dispose();
    },
  );
  test(
    'v2 delivers durable cloud seal before deleting local recovery access',
    () async {
      final events = <String>[], store = Store();
      final api = RelayApi(events), bridge = RelayBridge(events)..version = 2;
      final c = relay(api, bridge, store);
      expect(await c.resetThroughPhone('reset-1'), true);
      expect(events.sublist(events.length - 2), [
        'server_finish',
        'device_finish',
      ]);
      expect(bridge.resetStage, 7);
      expect(store.value, isNull);
      c.dispose();
    },
  );
  test(
    'lost v2 final seal keeps recovery access and resumes the same task',
    () async {
      final events = <String>[], store = Store();
      final api = RelayApi(events),
          bridge =
              RelayBridge(events)
                ..version = 2
                ..loseSeal = true;
      final c = relay(api, bridge, store);
      expect(await c.resetThroughPhone('reset-1'), false);
      expect(store.value, isNotNull);
      c.dispose();
      bridge.loseSeal = false;
      final resumed = relay(api, bridge, store);
      expect(await resumed.resetThroughPhone('reset-1'), true);
      expect(bridge.starts, 1);
      expect(bridge.resetStage, 7);
      resumed.dispose();
    },
  );
  test('phone without server access cannot begin destructive reset', () async {
    final events = <String>[], store = Store();
    final api = RelayApi(events)..failAt = 'authorize',
        bridge = RelayBridge(events);
    final c = relay(api, bridge, store);
    expect(await c.resetThroughPhone('reset-1'), false);
    expect(bridge.starts, 0);
    expect(store.value, isNotNull);
    c.dispose();
  });
  for (final failAt in ['complete', 'finish']) {
    test(
      'lost $failAt response resumes without wiping the frame again',
      () async {
        final events = <String>[], store = Store();
        final api = RelayApi(events)..failAt = failAt,
            bridge = RelayBridge(events);
        final first = relay(api, bridge, store);
        expect(await first.resetThroughPhone('reset-1'), false);
        expect(store.value, isNotNull);
        first.dispose();
        api.failAt = null;
        final second = relay(api, bridge, store);
        expect(await second.resetThroughPhone('reset-1'), true);
        expect(bridge.starts, 1);
        second.dispose();
      },
    );
  }
  FrameNetworkController make(Api api, Bridge bridge, Store store) =>
      FrameNetworkController(
        api: api,
        token: 'test-account-token',
        deviceId: 'frame-1',
        bridge: bridge,
        store: store,
        pause: (_) async {},
      );
  Future<void> resetPage(WidgetTester tester, ResetApi api) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BloomFrameResetPage(
          api: api,
          token: 'test',
          device: const BloomDevice(
            deviceId: 'frame-1',
            name: 'Frame',
            type: 'eink',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'queued reset shows no fake progress and cancels only after server acknowledgement',
    (tester) async {
      final api = ResetApi();
      await resetPage(tester, api);
      expect(find.text('等待连接相框'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.ensureVisible(find.text('取消等待并保留绑定'));
      await tester.tap(find.text('取消等待并保留绑定'));
      await tester.pumpAndSettle();
      expect(api.deletes, 1);
      expect(find.text('已取消重置'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(api.gets, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'reset claimed during cancellation stays running and cannot falsely cancel',
    (tester) async {
      final api = ResetApi()..claimRace = true;
      await resetPage(tester, api);
      await tester.ensureVisible(find.text('取消等待并保留绑定'));
      await tester.tap(find.text('取消等待并保留绑定'));
      await tester.pump();
      await tester.pump();
      expect(find.text('正在清理相框'), findsOneWidget);
      expect(find.text('已取消重置'), findsNothing);
      expect(find.text('取消等待并保留绑定'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('late queued poll cannot resurrect a cancelled reset', (
    tester,
  ) async {
    final api = ResetApi();
    await resetPage(tester, api);
    api.pendingGet = Completer<Map<String, dynamic>>();
    await tester.pump(const Duration(seconds: 3));
    expect(api.gets, 1);
    await tester.ensureVisible(find.text('取消等待并保留绑定'));
    await tester.tap(find.text('取消等待并保留绑定'));
    await tester.pumpAndSettle();
    api.pendingGet!.complete({
      'command': {'id': 'reset-1', 'state': 'queued'},
    });
    await tester.pumpAndSettle();
    expect(find.text('已取消重置'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'explicit cloud check authenticates but never scans Wi-Fi or sends settings',
    () async {
      final api = Api(), bridge = Bridge(), store = Store();
      final c = make(api, bridge, store);
      expect(await c.checkServer(), true);
      expect(bridge.commands.map((x) => x['op']), [
        'hello',
        'admin_auth',
        'admin_check_server',
        'admin_end',
      ]);
      expect(bridge.commands[2], {'op': 'admin_check_server'});
      expect(c.connected, false);
      expect(api.requests, 0);
      c.dispose();
    },
  );
  test('unsupported firmware cannot receive a wake request', () async {
    final api = Api(), bridge = Bridge()..cloudCapable = false, store = Store();
    final c = make(api, bridge, store);
    expect(await c.checkServer(), false);
    expect(c.error, contains('固件'));
    expect(bridge.commands.any((x) => x['op'] == 'admin_check_server'), false);
    c.dispose();
  });
  test(
    'a generic accepted reply is not a confirmed cloud-check request',
    () async {
      final api = Api(), bridge = Bridge()..badCloudAck = true, store = Store();
      final c = make(api, bridge, store);
      expect(await c.checkServer(), false);
      expect(c.success, false);
      expect(c.connected, false);
      c.dispose();
    },
  );
  test('constructor does not discover, connect or fetch credentials', () async {
    final api = Api(), bridge = Bridge(), store = Store();
    final c = make(api, bridge, store);
    expect(bridge.scans, 0);
    expect(bridge.connects, 0);
    expect(api.requests, 0);
    c.dispose();
    await Future<void>.delayed(Duration.zero);
  });
  test('owner enrollment sends only a public key to the frame', () async {
    final bridge = Bridge();
    final store = Store();
    final grant = {
      ...access,
      'public_key': '04${'a' * 128}',
      'message': 'signed-public-grant',
      'signature': 's' * 344,
    };
    final api = EnrollmentApi(grant);
    await FrameLocalAdmin(api: api, token: 'test', store: store).install(
      'frame-1',
      'owner-1',
      bridge,
      {'device_id': 'frame-1', 'local_admin_capable': true, 'nonce': 'a' * 32},
    );
    expect(bridge.commands.single['public_key'], grant['public_key']);
    expect(bridge.commands.single.containsKey('key'), false);
    expect(
      jsonEncode(bridge.commands).contains(access['key'] as String),
      false,
    );
    expect(store.value!['key'], access['key']);
  });
  test(
    'occupied advertisement is reported before a second connection',
    () async {
      final api = Api(), bridge = Bridge()..busyAdvert = true, store = Store();
      final c = make(api, bridge, store);
      expect(await c.startAdding(), false);
      expect(bridge.connects, 0);
      expect(c.error, contains('其他手机'));
      c.dispose();
    },
  );
  test(
    'cached owner uses local signature and paginated Wi-Fi scan without HTTP',
    () async {
      final api = Api(), bridge = Bridge(), store = Store();
      final c = make(api, bridge, store);
      expect(await c.startAdding(), true);
      expect(c.networks.map((n) => n['ssid']), ['Home', 'Open', 'Office']);
      expect(api.requests, 0);
      expect(await c.connectWifi('Office', 'test-only-password'), true);
      expect(c.success, true);
      expect(c.summary!['saved_networks'], contains('Office'));
      expect(c.serverCheckRequested, isTrue);
      final ops = bridge.commands.map((c) => c['op']).toList();
      expect(
        ops.indexOf('admin_check_server'),
        greaterThan(ops.indexOf('connect')),
      );
      expect(
        ops.lastIndexOf('admin_end'),
        greaterThan(ops.indexOf('admin_check_server')),
      );
      expect(bridge.management, false);
      expect(c.connected, false);
      expect(api.requests, 0);
      c.dispose();
    },
  );
  test(
    'lost cloud-check acknowledgement keeps a confirmed Wi-Fi save',
    () async {
      final api = Api(), bridge = Bridge()..badCloudAck = true, store = Store();
      final c = make(api, bridge, store);
      expect(await c.connectWifi('Office', 'test-only-password'), true);
      expect(c.success, true);
      expect(c.serverCheckRequested, false);
      expect(c.summary!['saved_networks'], contains('Office'));
      expect(bridge.management, false);
      c.dispose();
    },
  );
  test(
    'delete confirms device state and releases the local connection',
    () async {
      final api = Api(), bridge = Bridge(), store = Store();
      final c = make(api, bridge, store);
      expect(await c.removeNetwork('Home'), true);
      expect(c.summary!['saved_networks'], isEmpty);
      expect(bridge.management, false);
      expect(api.requests, 0);
      c.dispose();
    },
  );
  test(
    'wrong password does not announce success or replace saved networks',
    () async {
      final api = Api(), bridge = Bridge()..failWifi = true, store = Store();
      final c = make(api, bridge, store);
      expect(await c.startAdding(), true);
      expect(await c.connectWifi('Office', 'wrong-pass'), false);
      expect(c.success, false);
      expect(bridge.saved, ['Home']);
      expect(c.error, contains('密码'));
      expect(c.connected, false);
      c.dispose();
    },
  );
  for (final failure in [
    'wifi_auth_failed',
    'wifi_not_found',
    'wifi_ip_failed',
  ]) {
    test(
      'connection reason $failure fails without changing saved networks',
      () async {
        final api = Api(),
            bridge =
                Bridge()
                  ..failWifi = true
                  ..failureStage = failure,
            store = Store();
        final c = make(api, bridge, store);
        expect(await c.startAdding(), true);
        expect(await c.connectWifi('Office', 'test-password'), false);
        expect(c.success, false);
        expect(c.error, isNotEmpty);
        expect(c.error, isNot(contains('操作未完成')));
        expect(bridge.saved, ['Home']);
        expect(c.connected, false);
        c.dispose();
      },
    );
  }
  testWidgets(
    'failed connection stays on a visible result with retry and no false success',
    (tester) async {
      final api = Api(), bridge = Bridge()..failWifi = true, store = Store();
      final c = make(api, bridge, store);
      await tester.pumpWidget(
        MaterialApp(
          home: BloomFrameWifiAddPage(
            api: api,
            token: 'test',
            device: BloomDevice(
              deviceId: 'frame-1',
              name: 'Frame',
              type: 'eink',
            ),
            controller: c,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('连接 Wi-Fi'));
      await tester.tap(find.text('连接 Wi-Fi'));
      await tester.pumpAndSettle();
      expect(find.text('连接未完成'), findsOneWidget);
      expect(find.text('重试连接').hitTestable(), findsOneWidget);
      expect(find.text('Wi-Fi 配置成功'), findsNothing);
      expect(bridge.saved, ['Home']);
      await tester.tap(find.text('重新选择网络'));
      await tester.pumpAndSettle();
      expect(find.text('选择 2.4 GHz Wi-Fi'), findsOneWidget);
      expect(find.text('连接未完成'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  test(
    'physical identity mismatch is rejected before a network write',
    () async {
      final api = Api(),
          bridge = Bridge()..actualId = 'other-frame',
          store = Store();
      final c = make(api, bridge, store);
      expect(await c.removeNetwork('Home'), false);
      expect(bridge.commands.any((m) => m['op'] == 'forget'), false);
      c.dispose();
    },
  );
  test(
    'refreshing frame returns retry state and keeps saved networks',
    () async {
      final api = Api(), bridge = Bridge()..refreshing = true, store = Store();
      final c = make(api, bridge, store);
      expect(await c.removeNetwork('Home'), false);
      expect(c.error, contains('刷新'));
      expect(bridge.saved, ['Home']);
      c.dispose();
    },
  );
  test(
    'cancel while discovery is pending prevents a delayed connection',
    () async {
      final api = Api(),
          bridge = Bridge()..scanGate = Completer<void>(),
          store = Store();
      final c = make(api, bridge, store);
      final pending = c.startAdding();
      while (bridge.scans == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await c.cancel();
      bridge.scanGate!.complete();
      expect(await pending, false);
      expect(bridge.connects, 0);
      c.dispose();
    },
  );
  test(
    'account switch while discovery is pending blocks the previous owner',
    () async {
      final api = Api(),
          bridge = Bridge()..scanGate = Completer<void>(),
          store = Store();
      final c = make(api, bridge, store);
      final pending = c.startAdding();
      while (bridge.scans == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      store.owner = 'another-owner';
      bridge.scanGate!.complete();
      expect(await pending, false);
      expect(bridge.connects, 0);
      c.dispose();
    },
  );
  test('older firmware is not silently routed to first-time pairing', () async {
    final api = Api(), bridge = Bridge()..unsupported = true, store = Store();
    final c = make(api, bridge, store);
    expect(await c.startAdding(), false);
    expect(c.error, contains('固件'));
    expect(api.requests, 0);
    c.dispose();
  });
  testWidgets(
    'network page entry only reads a summary; Add is an explicit action',
    (tester) async {
      final native = <String>[];
      const provision = MethodChannel('bloom/provision');
      const secure = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(provision, (call) async {
        native.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(secure, (call) async => null);
      final api = Api();
      await tester.pumpWidget(
        MaterialApp(
          home: BloomFrameNetworkPage(
            api: api,
            token: 'test',
            device: const BloomDevice(
              deviceId: 'frame-1',
              name: '客厅',
              type: 'eink',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(native, isEmpty);
      expect(api.requests, 1);
      expect(find.text('添加 Wi-Fi'), findsOneWidget);
      expect(find.text('给它取名'), findsNothing);
      expect(find.text('第一张照片'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(provision, null);
      messenger.setMockMethodCallHandler(secure, null);
    },
  );
  for (final fail in [false, true]) {
    testWidgets(
      'remove Wi-Fi dialog waits for device confirmation (failure=$fail)',
      (tester) async {
        const secure = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(secure, (call) async => null);
        addTearDown(() => messenger.setMockMethodCallHandler(secure, null));
        final api = Api(),
            bridge = Bridge()..refreshing = fail,
            store = Store();
        final gate = Completer<void>();
        bridge.scanGate = gate;
        final c = make(api, bridge, store);
        await tester.pumpWidget(
          MaterialApp(
            home: BloomFrameNetworkPage(
              api: api,
              token: 'test',
              controller: c,
              device: const BloomDevice(
                deviceId: 'frame-1',
                name: '客厅',
                type: 'eink',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.remove_circle_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('正在移除 Wi-Fi'), findsOneWidget);
        expect(find.text('Wi-Fi 已移除'), findsNothing);
        expect(find.text('知道了'), findsNothing);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text(fail ? '尚未确认移除' : 'Wi-Fi 已移除'), findsOneWidget);
        expect(bridge.saved, fail ? ['Home'] : isEmpty);
        if (!fail) expect(find.textContaining('当前没有已保存网络'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
