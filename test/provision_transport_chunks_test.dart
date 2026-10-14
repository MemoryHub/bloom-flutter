import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bloom_provision/bloom_provision.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bloom/provision');
  test(
    'signed Wi-Fi payload is reassembled unchanged from bounded secure writes',
    () async {
      final payload = {
        'op': 'connect',
        'ssid': '测试网络',
        'password': 'test-password',
        'reuse': false,
        'message': 'bloom-provision-v1|frame-one|${'a' * 32}|wifi',
        'signature': 's' * 344,
      };
      final received = <int>[];
      String? id;
      var index = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final text = (call.arguments as Map)['json'] as String;
            expect(utf8.encode(text).length, lessThanOrEqualTo(240));
            final chunk = jsonDecode(text) as Map;
            expect(chunk['op'], 'chunk');
            expect(chunk['index'], index);
            id ??= chunk['id'] as String;
            expect(chunk['id'], id);
            received.addAll(base64Decode(chunk['data'] as String));
            if (++index == chunk['count']) {
              return jsonEncode({'status': 'accepted'});
            }
            return jsonEncode({'status': 'chunk_received', 'index': index - 1});
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(await const BloomProvisionBridge().data(payload), {
        'status': 'accepted',
      });
      expect(jsonDecode(utf8.decode(received)), payload);
      expect(index, greaterThan(2));
    },
  );
  test(
    'incorrect chunk acknowledgement stops before any final configuration',
    () async {
      var writes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            writes++;
            return jsonEncode({'status': 'chunk_received', 'index': 4});
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await expectLater(
        const BloomProvisionBridge().data({
          'op': 'connect',
          'signature': 's' * 344,
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'chunk_invalid',
          ),
        ),
      );
      expect(writes, 1);
    },
  );
  test('oversized configuration is rejected without a native write', () async {
    await expectLater(
      const BloomProvisionBridge().data({'data': 's' * 1025}),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'configuration_too_large',
        ),
      ),
    );
  });
}
