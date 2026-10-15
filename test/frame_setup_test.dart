import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bloom_provision/bloom_provision.dart';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/provisioning/frame_setup_controller.dart';
import 'package:bloom/ui/bloom_device_pages.dart';
import 'package:bloom/ui/bloom_frame_setup_page.dart';

class LocalBridge extends BloomProvisionBridge {
  LocalBridge({
    this.actualId = 'frame-one',
    this.failWifi = false,
    this.standby = false,
  });
  final String actualId;
  final bool failWifi;
  final bool standby;
  final messages = <Map<String, dynamic>>[];
  bool claimed = false, closed = false;
  @override
  Future<List<Map<String, dynamic>>> scan() async => [
    {'ble_name': 'BLOOM_001122334455', 'rssi': -40},
    {'ble_name': 'BLOOM_AABBCCDDEEFF', 'rssi': -65},
  ];
  @override
  Future<void> connect(String name, String pop) async {}
  @override
  Future<List<Map<String, dynamic>>> networks() async => [
    {'ssid': 'Home', 'rssi': -50, 'auth': 3},
    {'ssid': 'Home', 'rssi': -35, 'auth': 3},
    {'ssid': 'Office', 'rssi': -70, 'auth': 3},
  ];
  @override
  Future<Map<String, dynamic>> data(Map<String, dynamic> value) async {
    messages.add(value);
    if (value['op'] == 'hello') {
      return {'device_id': actualId, 'nonce': 'a' * 32, 'ble_standby': standby};
    }
    if (value['op'] == 'setup_scan') return {'status': 'accepted'};
    if (value['op'] == 'setup_radio_status') return {'ready': true};
    if (value['op'] == 'connect') return {'status': 'accepted'};
    if (value['op'] == 'status') {
      return {
        'device_id': actualId,
        'phase':
            failWifi
                ? 'wifi_failed'
                : claimed
                ? 'ready'
                : 'waiting_owner',
        'owned': claimed,
        'pairing_code': '112233',
      };
    }
    throw PlatformException(code: 'unknown');
  }

  @override
  Future<void> disconnect() async {
    closed = true;
  }
}

class FinalizingResetBridge extends LocalBridge {
  @override
  Future<Map<String, dynamic>> data(Map<String, dynamic> value) async {
    if (value['op'] == 'hello') {
      return {
        ...await super.data(value),
        'reset_relay_version': 2,
        'reset_relay_stage': 5,
      };
    }
    messages.add(value);
    if (value['op'] == 'reset_status') {
      return {
        'job': 'old-reset',
        'relay_version': 2,
        'finished_receipt': 'b' * 64,
      };
    }
    if (value['op'] == 'reset_finish') return {'status': 'reset_finished'};
    throw PlatformException(code: 'unknown');
  }
}

class FailingConnectionBridge extends LocalBridge {
  int attempts = 0;
  @override
  Future<void> connect(String name, String pop) async {
    if (++attempts == 1) {
      throw PlatformException(code: 'bluetooth_connection_failed');
    }
  }
}

class PendingScanBridge extends LocalBridge {
  final first = Completer<List<Map<String, dynamic>>>();
  int scans = 0;
  @override
  Future<List<Map<String, dynamic>>> scan() =>
      ++scans == 1 ? first.future : super.scan();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pop = '0123456789abcdef0123456789abcdef';
  FrameSetupController controller(
    LocalBridge bridge,
    List<http.Request> requests, {
    bool denied = false,
    bool hasPhotos = false,
    String? existing,
  }) {
    final api = BloomApiClient(
      client: MockClient((request) async {
        requests.add(request);
        if (denied) {
          return http.Response(jsonEncode({'detail': 'device_not_owned'}), 403);
        }
        if (request.url.path.contains('frame-setup')) {
          return http.Response(
            jsonEncode({
              'device_id': 'frame-one',
              'ble_name': 'BLOOM_001122334455',
              'pop': pop,
              'owned': false,
            }),
            200,
          );
        }
        if (request.url.path.endsWith('ble-reset/finish')) {
          return http.Response(
            jsonEncode({'message': 'signed-seal', 'signature': 'signed-proof'}),
            200,
          );
        }
        if (request.url.path.endsWith('setup-ticket')) {
          return http.Response(
            jsonEncode({
              'message': 'signed-session',
              'signature': 'signed-proof',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('complete-setup')) {
          bridge.claimed = true;
          return http.Response(
            jsonEncode({
              'device_id': 'frame-one',
              'status': 'owned',
              'has_existing_photos': hasPhotos,
            }),
            200,
          );
        }
        throw StateError('unexpected request');
      }),
    );
    return FrameSetupController(
      api: api,
      token: 'account-test-session',
      bridge: bridge,
      existingDeviceId: existing,
    );
  }

  test(
    'new setup can finish a lost reset seal without local admin access',
    () async {
      final bridge = FinalizingResetBridge(), requests = <http.Request>[];
      final c = controller(bridge, requests);
      await c.select('BLOOM_001122334455');
      expect(c.connected, false);
      expect(c.error, contains('重置结果已同步'));
      expect(
        requests.any(
          (r) => r.url.path.endsWith('/commands/old-reset/ble-reset/finish'),
        ),
        true,
      );
      expect(bridge.messages.any((m) => m['op'] == 'reset_finish'), true);
      expect(bridge.claimed, false);
      c.dispose();
    },
  );
  test(
    'persistent setup QR is separate from contributor QR and never carries a device token',
    () {
      final c = FrameSetupCode.parse(
        'bloom://setup/BLOOM_001122334455?pop=$pop',
      );
      expect(c!.bleName, 'BLOOM_001122334455');
      expect(c.pop, pop);
      expect(FrameSetupCode.parse('bloom://device/$pop'), isNull);
      expect(
        FrameSetupCode.parse('bloom://setup/BLOOM_001122334455?pop=bad'),
        isNull,
      );
      expect(
        FrameSetupCode.parse('https://setup/BLOOM_001122334455?pop=$pop'),
        isNull,
      );
    },
  );
  test(
    'first setup enables Wi-Fi only after the user advances past naming',
    () async {
      final bridge = LocalBridge(standby: true);
      final c = controller(bridge, []);
      await c.discover(code: const FrameSetupCode('BLOOM_001122334455', pop));
      expect(bridge.messages.any((m) => m['op'] == 'setup_scan'), false);
      await c.chooseName('客厅');
      expect(bridge.messages.any((m) => m['op'] == 'setup_scan'), true);
      expect(bridge.messages.any((m) => m['op'] == 'setup_radio_status'), true);
      expect(c.networks, isNotEmpty);
      c.dispose();
    },
  );
  test(
    'QR discovery replaces an active search and ignores its late result',
    () async {
      final bridge = PendingScanBridge();
      final c = controller(bridge, []);
      addTearDown(c.dispose);
      final original = c.discover();
      expect(c.scanning, isTrue);
      await c.pauseDiscovery();
      expect(c.scanning, isFalse);
      await c.discover(code: const FrameSetupCode('BLOOM_001122334455', pop));
      expect(c.scannedCode!.bleName, 'BLOOM_001122334455');
      expect(c.step, 1);
      expect(c.connected, isTrue);
      await c.chooseName('客厅');
      expect(c.step, 2);
      bridge.first.complete([
        {'ble_name': 'BLOOM_AABBCCDDEEFF'},
      ]);
      await original;
      expect(c.nearby, isEmpty);
      expect(c.connected, isTrue);
    },
  );
  test(
    'QR recognition requires a secure physical identity before naming',
    () async {
      final bridge = LocalBridge(actualId: 'wrong-frame');
      final c = controller(bridge, []);
      addTearDown(c.dispose);
      await c.discover(code: const FrameSetupCode('BLOOM_001122334455', pop));
      expect(c.step, 0);
      expect(c.connected, isFalse);
      expect(c.error, contains('身份'));
      expect(c.networks, isEmpty);
      expect(bridge.messages.where((v) => v['op'] == 'connect'), isEmpty);
    },
  );
  test('nearby selection cancels search and connects before naming', () async {
    final bridge = PendingScanBridge();
    final c = controller(bridge, []);
    addTearDown(c.dispose);
    final old = c.discover();
    expect(c.scanning, isTrue);
    await c.select('BLOOM_001122334455');
    expect(c.connected, isTrue);
    expect(c.step, 1);
    expect(c.busy, isFalse);
    bridge.first.complete([]);
    await old;
    expect(c.connected, isTrue);
    await c.chooseName('客厅');
    expect(c.step, 2);
  });
  test(
    'failed BLE recognition stays on discovery and can retry without Wi-Fi',
    () async {
      final bridge = FailingConnectionBridge();
      final c = controller(bridge, []);
      addTearDown(c.dispose);
      await c.select('BLOOM_001122334455');
      expect(c.step, 0);
      expect(c.connected, isFalse);
      expect(c.error, contains('蓝牙连接'));
      expect(c.completed, isFalse);
      expect(bridge.messages, isEmpty);
      await c.select('BLOOM_001122334455');
      expect(c.step, 1);
      expect(c.connected, isTrue);
      final next = c.chooseName('客厅');
      expect(c.step, 2);
      expect(c.name, '客厅');
      await next;
      expect(c.networks, isNotEmpty);
      expect(c.error, isNull);
      expect(bridge.attempts, 2); // naming reuses the already verified BLE link
    },
  );
  test('empty scan is distinct from a denied Bluetooth permission', () async {
    expect(
      frameSetupError(PlatformException(code: 'device_not_found')),
      isNot(contains('允许')),
    );
    expect(
      frameSetupError(PlatformException(code: 'permission_denied')),
      contains('设置'),
    );
    expect(
      frameSetupError(PlatformException(code: 'bluetooth_off')),
      contains('开启手机蓝牙'),
    );
  });
  testWidgets(
    'scanner and found card stay enabled during an automatic rescan',
    (tester) async {
      const channel = MethodChannel('bloom/provision');
      final scan = Completer<List<dynamic>>();
      int calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'scan') {
              if (++calls == 1) {
                return [
                  {'ble_name': 'BLOOM_001122334455', 'rssi': -40},
                ];
              }
              return scan.future;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BloomFrameSetupPage(api: BloomApiClient(), token: 'test'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('正在寻找附近的相框…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '扫描设备二维码'),
      );
      expect(button.onPressed, isNotNull);
      final card =
          find
              .ancestor(
                of: find.text('标识 · 4455'),
                matching: find.byType(InkWell),
              )
              .first;
      expect(tester.widget<InkWell>(card).onTap, isNotNull);
      await tester.pumpWidget(const SizedBox());
      scan.complete([]);
      await tester.pump();
    },
  );
  test('custom frame name is used everywhere with an empty-name fallback', () {
    expect(
      const BloomDevice(deviceId: 'one', name: '客厅', type: 'eink').name,
      '客厅',
    );
    expect(
      const BloomDevice(deviceId: 'one', name: '  ', type: 'eink').name,
      'Bloom-Ink',
    );
  });

  test(
    'multiple frames are discovered and Wi-Fi list is de-duplicated by SSID',
    () async {
      final c = controller(LocalBridge(), []);
      addTearDown(c.dispose);
      await c.discover();
      expect(c.nearby.length, 2);
      await c.select('BLOOM_001122334455');
      expect(c.step, 1);
      await c.chooseName('  客厅相框  ');
      expect(c.name, '客厅相框');
      expect(c.networks.length, 2);
      expect(c.networks.first['rssi'], -35);
    },
  );
  test(
    'BLE selection is verified against the authenticated cloud identity before any Wi-Fi write',
    () async {
      final bridge = LocalBridge(actualId: 'frame-other');
      final c = controller(bridge, []);
      addTearDown(c.dispose);
      await c.discover();
      await c.select('BLOOM_001122334455');
      expect(c.connected, isFalse);
      expect(c.step, 0);
      expect(c.error, contains('身份'));
      expect(bridge.messages.where((v) => v['op'] == 'connect'), isEmpty);
    },
  );
  test('non-owner is blocked before opening a secure device session', () async {
    final bridge = LocalBridge();
    final c = controller(bridge, [], denied: true);
    addTearDown(c.dispose);
    await c.discover();
    await c.select('BLOOM_001122334455');
    expect(c.connected, isFalse);
    expect(c.error, contains('主人'));
    expect(bridge.messages, isEmpty);
  });
  test('wrong password never binds or shows the green success state', () async {
    final requests = <http.Request>[];
    final c = controller(LocalBridge(failWifi: true), requests);
    addTearDown(c.dispose);
    await c.discover();
    await c.select('BLOOM_001122334455');
    await c.chooseName('相框');
    await c.connectWifi('Home', 'wrong-password');
    expect(c.completed, isFalse);
    expect(c.error, contains('密码'));
    expect(requests.any((r) => r.url.path.endsWith('complete-setup')), isFalse);
  });
  test(
    'password travels only through secure local BLE, and success waits for owner confirmation',
    () async {
      final requests = <http.Request>[];
      final bridge = LocalBridge();
      final c = controller(bridge, requests);
      addTearDown(c.dispose);
      await c.discover();
      await c.select('BLOOM_001122334455');
      await c.chooseName('Home');
      await c.connectWifi('Home', 'private-wifi-password');
      expect(c.completed, isTrue);
      expect(c.phase, 'success');
      expect(
        requests.every((r) => !r.body.contains('private-wifi-password')),
        isTrue,
      );
      expect(
        bridge.messages.singleWhere((v) => v['op'] == 'connect')['password'],
        'private-wifi-password',
      );
      c.photos();
      expect(c.step, 3);
      c.back();
      expect(c.step, 3);
    },
  );
  test('已有照片显示首播路径，没有照片保持上传路径', () async {
    for (final hasPhotos in [false, true]) {
      final c = controller(LocalBridge(), [], hasPhotos: hasPhotos);
      await c.discover();
      await c.select('BLOOM_001122334455');
      await c.chooseName('相框');
      await c.connectWifi('Home', 'valid-password');
      expect(c.completed, isTrue);
      expect(c.hasExistingPhotos, hasPhotos);
      c.dispose();
    }
  });
}
