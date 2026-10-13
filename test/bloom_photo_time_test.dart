import 'dart:async';
import 'dart:convert';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/ui/bloom_photo_time_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'capture timestamp carries local offset and preserves the same instant',
    () {
      for (final instant in [
        DateTime.utc(2020, 5, 20, 16, 15),
        DateTime.utc(2021, 12, 31, 23, 59, 32),
      ]) {
        final encoded = bloomCaptureTimestamp(instant);
        expect(RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(encoded), isTrue);
        expect(encoded.contains('Z'), isFalse);
        expect(DateTime.parse(encoded).toUtc(), instant);
      }
    },
  );

  Future<void> open(
    WidgetTester tester,
    BloomApiClient api, {
    void Function(Map<String, dynamic>?)? result,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    final value = await Navigator.push<Map<String, dynamic>>(
                      context,
                      MaterialPageRoute(
                        builder:
                            (_) => BloomPhotoTimePage(
                              api: api,
                              token: 'account-token',
                              assetId: 'photo',
                              takenAt:
                                  DateTime(
                                    2020,
                                    5,
                                    20,
                                    10,
                                    30,
                                    12,
                                  ).toIso8601String(),
                            ),
                      ),
                    );
                    result?.call(value);
                  },
                  child: const Text('open'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'date and clock edits save one authorized offset-aware PATCH and return photo',
    (tester) async {
      final requests = <http.Request>[];
      Map<String, dynamic>? result;
      final api = BloomApiClient(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'photo': {'id': 'photo', 'taken_at': '2020-05-21T11:45:00+08:00'},
            }),
            200,
          );
        }),
      );
      await open(tester, api, result: (value) => result = value);
      await tester.tap(find.byKey(const ValueKey('bloom-photo-edit-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('21').last);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('2020年5月21日'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bloom-photo-edit-clock')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '11');
      await tester.enterText(fields.at(1), '45');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('11:45'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/api/frame/users/me/photos/photo/time');
      expect(request.headers['Authorization'], 'Bearer account-token');
      final stamp = jsonDecode(request.body)['taken_at'] as String;
      expect(DateTime.parse(stamp).toLocal(), DateTime(2020, 5, 21, 11, 45));
      expect(result?['id'], 'photo');
    },
  );

  testWidgets('cancelling the picker and leaving the page does not save', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final api = BloomApiClient(
      client: MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 200);
      }),
    );
    await open(tester, api);
    await tester.tap(find.byKey(const ValueKey('bloom-photo-edit-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('21').last);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('2020年5月20日'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
  });

  testWidgets(
    'saving disables duplicate submit; failure retains edits and allows retry',
    (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final api = BloomApiClient(
        client: MockClient((r) {
          calls++;
          return pending.future;
        }),
      );
      await open(tester, api);
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(find.text('正在保存…'), findsOneWidget);
      await tester.tap(find.text('正在保存…'));
      await tester.pump();
      expect(calls, 1);
      pending.complete(http.Response('{"detail":"photo_time_changed"}', 409));
      await tester.pumpAndSettle();
      expect(find.text('时间刚刚被更新，请返回照片详情刷新后再试。'), findsOneWidget);
      expect(find.text('2020年5月20日'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
    },
  );
}
