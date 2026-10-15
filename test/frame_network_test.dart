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
  bool busyAdvert = false;
  bool management = false,
      failWifi = false,
      refreshing = false,
      unsupported = false;
  String actualId = 'frame-1', stage = 'network_ready';
  List<String> saved = ['Home'];
  final commands = <Map<String, dynamic>>[];
  Completer<void>? scanGate;
  @override
  Future<List<Map<String, dynamic>>> scan() async {
    scans++;
    if (scanGate != null) await scanGate!.future;
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
        stage = failWifi ? 'wifi_failed' : 'wifi_success';
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
  FrameNetworkController make(Api api, Bridge bridge, Store store) =>
      FrameNetworkController(
        api: api,
        token: 'test-account-token',
        deviceId: 'frame-1',
        bridge: bridge,
        store: store,
        pause: (_) async {},
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
      expect(bridge.management, false);
      expect(c.connected, false);
      expect(api.requests, 0);
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
}
