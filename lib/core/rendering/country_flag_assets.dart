import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The artwork response carries its small flag; no extra request or token.
class CountryFlagAssets {
  static final _cache = <String, Uint8List>{};

  static String signature(Map<String, dynamic> metadata) {
    final flag = metadata['artist_flag'];
    if (flag is! Map ||
        flag['country'] != metadata['artist_country_code'] ||
        flag['media_type'] != 'image/png' ||
        flag['data_base64'] is! String ||
        flag['version'] is! String) {
      return '';
    }
    return '${flag['country']}:${flag['version']}:${(flag['data_base64'] as String).hashCode}';
  }

  static Uint8List? bytes(Map<String, dynamic> metadata) {
    final key = signature(metadata);
    if (key.isEmpty) return null;
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final encoded = (metadata['artist_flag'] as Map)['data_base64'] as String;
      if (encoded.length > 700000) return null;
      final data = base64Decode(encoded);
      const magic = [137, 80, 78, 71, 13, 10, 26, 10];
      if (data.length < 8 ||
          data.length > 512 * 1024 ||
          !magic.asMap().entries.every((e) => data[e.key] == e.value)) {
        return null;
      }
      _cache[key] = data;
      while (_cache.length > 32) {
        _cache.remove(_cache.keys.first);
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image?> load(Map<String, dynamic> metadata) async {
    final data = bytes(metadata);
    if (data == null) return null;
    try {
      final codec = await ui.instantiateImageCodec(data);
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }
}
