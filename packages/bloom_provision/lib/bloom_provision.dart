import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';

class BloomProvisionBridge {
  const BloomProvisionBridge();
  static const _channel = MethodChannel('bloom/provision');
  Future<List<Map<String, dynamic>>> scan() async =>
      _maps(await _channel.invokeMethod<List<dynamic>>('scan'));
  Future<void> connect(String name, String pop) async {
    await _channel.invokeMethod('connect', {'ble_name': name, 'pop': pop});
  }

  Future<List<Map<String, dynamic>>> networks() async =>
      _maps(await _channel.invokeMethod<List<dynamic>>('networks'));
  Future<Map<String, dynamic>> data(Map<String, dynamic> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > 1024) {
      throw PlatformException(code: 'configuration_too_large');
    }
    if (bytes.length <= 240) return _sendText(utf8.decode(bytes));
    final random = Random.secure();
    final id =
        List.generate(
          8,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
    final count = (bytes.length + 99) ~/ 100;
    for (var index = 0; index < count; index++) {
      final end = min(bytes.length, (index + 1) * 100);
      final response = await _sendText(
        jsonEncode({
          'op': 'chunk',
          'id': id,
          'index': index,
          'count': count,
          'data': base64Encode(bytes.sublist(index * 100, end)),
        }),
      );
      if (index == count - 1) return response;
      if (response['status'] != 'chunk_received' ||
          response['index'] != index) {
        throw PlatformException(code: 'chunk_invalid');
      }
    }
    throw PlatformException(code: 'chunk_invalid');
  }

  Future<Map<String, dynamic>> _sendText(String text) async {
    final reply = await _channel.invokeMethod<String>('data', {'json': text});
    final result = Map<String, dynamic>.from(jsonDecode(reply!) as Map);
    if (result['error'] != null) {
      throw PlatformException(code: result['error'] as String);
    }
    return result;
  }

  Future<void> disconnect() => _channel.invokeMethod('disconnect');
  Future<void> settings() => _channel.invokeMethod('settings');
  static List<Map<String, dynamic>> _maps(List<dynamic>? list) =>
      (list ?? []).map((v) => Map<String, dynamic>.from(v as Map)).toList();
}
