import 'dart:convert';

import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/ui/bloom_photo_library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'saved time reindexes the library once; refresh failure does not retry or escape',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var saved = false, indexRequests = 0, refreshes = 0;
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGPoXznnPwgzwBgAYzgLTcqgbmMAAAAASUVORK5CYII=',
      );
      Map<String, dynamic> photo() => {
        'id': 'photo',
        'taken_at': saved ? '2020-05-21T10:30:00' : '2020-05-20T10:30:00',
        'analysis': {'status': 'completed'},
      };
      final api = BloomApiClient(
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/thumbnail') || path.endsWith('/preview')) {
            return http.Response.bytes(png, 200);
          }
          if (path.endsWith('/time')) {
            saved = true;
            return http.Response(jsonEncode({'photo': photo()}), 200);
          }
          if (path.endsWith('/days')) {
            indexRequests++;
            return http.Response(
              jsonEncode({
                'days': [
                  {'day': saved ? '2020-05-21' : '2020-05-20', 'count': 1},
                ],
              }),
              200,
            );
          }
          if (path.endsWith('/photos')) {
            return http.Response(
              jsonEncode({
                'photos': [photo()],
              }),
              200,
            );
          }
          if (path.endsWith('/photos/photo')) {
            return http.Response(jsonEncode({'photo': photo()}), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BloomPhotoLibraryPage(
              api: api,
              token: 'fixture-token',
              onChanged: () async {
                refreshes++;
                throw StateError('separate background refresh failed');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('photo-1-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bloom-photo-time-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bloom-photo-edit-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('21').last);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back_rounded).first);
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      expect(indexRequests, 2);
      expect(refreshes, 1);
      expect(find.byKey(const ValueKey('photo-2-photo')), findsOneWidget);
      expect(find.text('2020年5月21日'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
