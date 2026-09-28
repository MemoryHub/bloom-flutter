/// 全天计划拉取：服务端尚未放开 `batch_limit` 时的降级。
///
/// 这里钉住的是一个**很容易想当然**的地方：旧服务端的 `batch_limit` 是
/// Pydantic 的 `le=4` 校验，请求 200 会被**直接 422 拒绝**——不是「按自己的
/// 上限返回并置 has_more」。早先的注释正是后一种假设，照那个假设，新客户端
/// 装到未升级的服务端上会一张计划都拿不到，比改动前更糟。
///
/// 所以客户端必须能自己降级。这条测试用真实的 422 响应模拟旧服务端。
library;

import 'dart:convert';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/core/carousel/plan_client.dart';
import 'package:bloom/core/models/device_models.dart';
import 'package:bloom/core/storage/display_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// 旧服务端的真实拒绝：FastAPI 的 422 校验错误体。
http.Response _rejected() => http.Response.bytes(
  utf8.encode('{"detail":[{"loc":["body","batch_limit"],"msg":"bad"}]}'),
  422,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _item(int id, int minuteOffset) {
  final at = DateTime(2026, 9, 28, 11, 15).add(
    Duration(minutes: minuteOffset),
  );
  String two(int v) => v.toString().padLeft(2, '0');
  return {
    'item_id': id,
    'display_at':
        '${at.year}-${two(at.month)}-${two(at.day)}'
        'T${two(at.hour)}:${two(at.minute)}:00',
    'asset_id': 'asset-$id',
    'photo': {'url': '/carousel/photo', 'format': 'jpeg'},
    'caption': {'zh': '中文$id', 'en': 'en$id'},
  };
}

void main() {
  const credentials = DeviceCredentials(deviceId: 'dev-1', deviceToken: 'tok');
  const settings = BloomDisplaySettings(intervalMinutes: 15);

  /// 造一个「只认 4 条」的旧服务端。
  ///
  /// [accepted] 记录它实际接受过的 batch_limit，用来证明客户端先试了 200。
  BloomApiClient legacyServer(
    List<int> accepted, {
    int total = 10,
    int serverLimit = 4,
  }) => BloomApiClient(
    client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final limit = body['batch_limit'] as int;
      final after = body['after_item_id'] as int?;
      if (limit > serverLimit) {
        // 关键：旧服务端是**拒绝**，不是宽容地按 4 返回。
        return _rejected();
      }
      accepted.add(limit);
      // `after_item_id` 是**条目 id**，不是下标；服务端返回它之后的条目。
      final start = after == null ? 0 : (after - 1000) + 1;
      final end = (start + limit).clamp(0, total);
      final items = <Map<String, dynamic>>[
        for (var i = start; i < end; i++) _item(1000 + i, i * 15),
      ];
      return _ok(
        jsonEncode({
          'plan_id': 900,
          'current_item_id': 1000,
          'next_check_at': '2026-09-28T11:30:00',
          'has_more': end < total,
          'settings_hash': 'h1',
          'local_date': '2026-09-28',
          'items': items,
        }),
      );
    }),
  );

  test('旧服务端 422 拒绝 batch_limit=200：降级到 4 并翻完整天', () async {
    final accepted = <int>[];
    final client = CarouselPlanClient(api: legacyServer(accepted));

    final plan = await client.fetchFullDay(credentials, settings);

    expect(
      plan.grid.length,
      10,
      reason: '降级后必须仍然拿到整天栅格，而不是半截',
    );
    expect(
      plan.grid.map((slot) => slot.itemId).toList(),
      [for (var i = 0; i < 10; i++) 1000 + i],
      reason: '游标翻页必须按顺序补齐，不能重不能漏',
    );
    expect(
      accepted,
      [4, 4, 4],
      reason: '降级后就一直用 4，不再每页都去撞一次 200（4+4+2 = 10 格）',
    );
    expect(
      plan.requestCount,
      3,
      reason: '被拒的那次不计入成功请求数',
    );
  });

  test('新服务端接受 200：一次请求拿完全天', () async {
    final accepted = <int>[];
    final client = CarouselPlanClient(
      api: legacyServer(accepted, serverLimit: 200),
    );

    final plan = await client.fetchFullDay(credentials, settings);

    expect(plan.grid.length, 10);
    expect(accepted, [200], reason: '服务端已放开时不应有多余请求');
    expect(plan.requestCount, 1);
  });

  test('降级只发生一次：非校验类错误照常抛出', () async {
    final api = BloomApiClient(
      client: MockClient((request) async {
        // 500 不是「上限不被接受」，不能靠降级掩盖。
        return http.Response('boom', 500);
      }),
    );
    final client = CarouselPlanClient(api: api);

    await expectLater(
      client.fetchFullDay(credentials, settings),
      throwsA(isA<BloomApiException>()),
    );
  });
}
