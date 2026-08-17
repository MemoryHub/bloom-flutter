import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bloom/core/storage/device_identity_repository.dart';

void main() {
  test('initializes stable id and 64-char token', () async {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    final repository = DeviceIdentityRepository(
      readToken: (key) async => secure[key],
      writeToken: (key, value) async => secure[key] = value,
      stableCredentials:
          () async => {
            'deviceId': 'bloom-mobile-stable-device',
            'deviceToken': 'a' * 64,
          },
    );
    final first = await repository.initialize();
    final second = await repository.initialize();
    expect(first.deviceId, 'bloom-mobile-stable-device');
    expect(first.deviceToken.length, 64);
    expect(second.deviceId, first.deviceId);
    expect(second.deviceToken, first.deviceToken);
  });

  test('keeps an existing identity when upgrading identity version', () async {
    SharedPreferences.setMockInitialValues({'bloom.device_id': 'old-id'});
    final secure = {'bloom.device_token': 'b' * 64};
    final repository = DeviceIdentityRepository(
      readToken: (key) async => secure[key],
      writeToken: (key, value) async => secure[key] = value,
      stableCredentials:
          () async => {'deviceId': 'new-stable-id', 'deviceToken': 'c' * 64},
    );
    final result = await repository.initialize();
    expect(result.deviceId, 'old-id');
    expect(result.deviceToken, 'b' * 64);
  });
}
