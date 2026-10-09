import 'dart:convert';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/ui/bloom_discover_page.dart';
import 'package:bloom/ui/bloom_glass_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('中文展示优先翻译、英文原文保留，缺少翻译回退原文', () {
    final work = <String, dynamic>{
      'title': 'Sunflowers',
      'artist': 'Vincent van Gogh',
      'app_translations': {
        'zh-CN': {'title': '向日葵', 'artist': '文森特·梵高'},
      },
    };
    expect(galleryArtworkText(work, 'title'), '向日葵');
    expect(galleryArtworkText(work, 'title', language: 'en'), 'Sunflowers');
    expect(galleryArtworkText({'title': 'Original'}, 'title'), 'Original');
    expect(work['title'], 'Sunflowers');
  });

  void ignoreTestImageRequests() {
    final reportError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is! NetworkImageLoadException) {
        reportError?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = reportError);
  }

  testWidgets('滑动自动接续50幅，分页失败可重试，加入入口始终可见', (tester) async {
    ignoreTestImageRequests();
    final offsets = <int>[];
    var failSecondPage = true;
    final works = List.generate(
      50,
      (i) => <String, dynamic>{
        'id': 'work-$i',
        'title': 'Work ${i + 1}',
        'artist': 'Artist',
        'year': '1888',
        'position': i,
        'image_url': '/preview/$i',
        'short_description': 'A quiet work.',
      },
    );
    final collection = <String, dynamic>{
      'id': 'collection-id',
      'title': 'A Gallery for Everyday',
      'subtitle': 'A quiet exhibition.',
      'introduction': 'Art belongs at home.',
      'work_count': 50,
      'cover': works.first,
    };
    final api = BloomApiClient(
      client: MockClient((r) async {
        if (!r.url.path.endsWith('/collections/collection-id')) {
          return http.Response(
            jsonEncode({
              'items': [collection],
              'has_more': false,
            }),
            200,
          );
        }
        final offset = int.parse(r.url.queryParameters['offset']!);
        offsets.add(offset);
        if (offset == 12 && failSecondPage) {
          failSecondPage = false;
          return http.Response('{}', 503);
        }
        final end = (offset + 12).clamp(0, works.length);
        return http.Response(
          jsonEncode({
            ...collection,
            'items': works.sublist(offset, end),
            'has_more': end < works.length,
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: BloomDiscoverPage(api: api, frames: const [])),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('走进展览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('走进展览'));
    await tester.pumpAndSettle();
    expect(offsets, [0]);
    expect(find.byType(BloomAtmosphere), findsOneWidget);
    final join = find.byKey(const ValueKey('gallery-join-frame'));
    expect(join.hitTestable(), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(
      find.ancestor(of: join, matching: find.byType(Scaffold)).first,
    );
    expect(scaffold.backgroundColor, BloomInk.page);
    expect(
      tester.widgetList<GalleryImage>(find.byType(GalleryImage)).length,
      lessThan(12),
    );
    final list = find.byKey(const ValueKey('gallery-collection-scroll'));
    final scroll = tester.widget<ListView>(list).controller!;
    for (
      var i = 0;
      i < 16 && find.text('作品暂时没有加载成功。').evaluate().isEmpty;
      i++
    ) {
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(offsets, [0, 12]);
    expect(find.text('作品暂时没有加载成功。'), findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 16; i++) {
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(join.hitTestable(), findsOneWidget);
      if (offsets.last == 48 && find.text('Work 50').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(offsets, [0, 12, 12, 24, 36, 48]);
    expect(find.text('Work 50'), findsOneWidget);
    expect(find.text('加载更多作品'), findsNothing);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(offsets, hasLength(6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('首帧未到就显示占位，加载失败也保留图片区域和说明', (tester) async {
    ignoreTestImageRequests();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GalleryImage(
            api: BloomApiClient(),
            path: '/pending-image-placeholder',
            height: 280,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('gallery-image-loading')), findsOneWidget);
    expect(find.text('作品加载中'), findsOneWidget);
    expect(tester.getSize(find.byType(GalleryImage)).height, 280);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gallery-image-error')), findsOneWidget);
    expect(find.text('图片暂时无法加载'), findsOneWidget);
    expect(tester.getSize(find.byType(GalleryImage)).height, 280);
    expect(tester.takeException(), isNull);
  });

  testWidgets('浏览不加入；登录后的展览使用新会话，仅把所选作品集加入目标相框', (tester) async {
    final writes = <http.Request>[];
    final targetReads = <String>[];
    // Widget-test HTTP deliberately rejects Image.network with HTTP 400.
    // Continue reporting all other errors, including layout and navigation.
    final reportError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is! NetworkImageLoadException) {
        reportError?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = reportError);
    String? token;
    var signInRequests = 0;
    final work = {
      'id': 'work-id',
      'title': 'Sunflowers',
      'artist': 'Vincent van Gogh',
      'year': '1888',
      'position': 0,
      'image_url': '/preview',
      'story': 'A bright still life.',
    };
    final collection = {
      'id': 'collection-id',
      'title': 'A Gallery for Everyday',
      'subtitle': 'A quiet exhibition.',
      'introduction': 'Art belongs at home.',
      'work_count': 1,
      'cover': work,
    };
    final api = BloomApiClient(
      client: MockClient((request) async {
        Object data;
        if (request.method == 'PATCH') {
          writes.add(request);
          data = {'items': [], 'status': 'waiting_for_sync'};
        } else if (request.url.path.endsWith('/content-selections')) {
          expect(request.headers['Authorization'], 'Bearer new-session');
          targetReads.add(request.url.path);
          data = {'items': []};
        } else if (request.url.path.endsWith('/collections/collection-id')) {
          data = {
            ...collection,
            'items': [work],
            'has_more': false,
          };
        } else {
          data = {
            'items': [collection],
            'has_more': false,
          };
        }
        return http.Response(jsonEncode(data), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BloomDiscoverPage(
            api: api,
            frames: const [],
            userToken: 'stale-snapshot',
            onSignIn: () => signInRequests++,
            session: GallerySession(
              token: () => token,
              frames:
                  () =>
                      token == null
                          ? []
                          : [
                            const GalleryFrame('frame-id', '客厅'),
                            const GalleryFrame('second-frame', '书房'),
                            const GalleryFrame(
                              'mobile-id',
                              '我的手机',
                              isMobile: true,
                            ),
                          ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('走进展览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('走进展览'));
    await tester.pumpAndSettle();
    expect(find.text('Art belongs at home.'), findsOneWidget);
    expect(writes, isEmpty);
    await tester.tap(find.text('发送整个展览到设备').first);
    await tester.pumpAndSettle();
    expect(signInRequests, 1);
    expect(writes, isEmpty);
    token = 'new-session';
    await tester.tap(find.text('发送整个展览到设备').first);
    await tester.pumpAndSettle();
    expect(find.text('书房'), findsOneWidget);
    expect(find.text('手机小组件'), findsOneWidget);
    await tester.tap(find.text('我的手机'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(
      writes.first.url.path,
      '/api/frame/devices/mobile-id/content-selections',
    );
    expect(targetReads.any((p) => p.contains('mobile-id')), isTrue);
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(2));
    expect(
      writes.last.url.path,
      '/api/frame/devices/frame-id/content-selections',
    );
    expect(jsonDecode(writes.last.body), {
      'kind': 'collection',
      'reference_id': 'collection-id',
      'selected': true,
    });
    expect(find.text('已发送，等待设备同步。'), findsNothing);
    Navigator.of(tester.element(find.text('客厅'))).pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sunflowers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sunflowers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送这幅作品到设备').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(3));
    expect(jsonDecode(writes.last.body), {
      'kind': 'artwork',
      'reference_id': 'work-id',
      'selected': true,
    });
    Navigator.of(tester.element(find.text('客厅'))).pop();
    await tester.pumpAndSettle();
    token = null;
    await tester.tap(find.text('发送这幅作品到设备').first);
    await tester.pumpAndSettle();
    expect(signInRequests, 2);
    expect(writes, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机宽度下展览按左右中交错排图文，中文复用字体', (tester) async {
    ignoreTestImageRequests();
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final works = List.generate(
      3,
      (i) => <String, dynamic>{
        'id': 'layout-$i',
        'title': 'English $i',
        'artist': 'Artist',
        'year': '1888',
        'position': i,
        'image_url': '/layout/$i',
        'image_width': 1200,
        'image_height': 1600,
        'app_translations': {
          'zh-CN': {
            'title': '中文作品$i',
            'artist': '中文作者',
            'short_description': '留意光与颜色，在日常里慢慢欣赏。',
          },
        },
      },
    );
    final collection = {
      'id': 'layout-collection',
      'title': '日常里的美术馆',
      'subtitle': '把艺术带回家',
      'introduction': '一场日常里的展览。',
      'cover': works.first,
      'work_count': 3,
    };
    final api = BloomApiClient(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path.endsWith('/collections/layout-collection')
                ? {...collection, 'items': works, 'has_more': false}
                : {
                  'items': [collection],
                  'has_more': false,
                },
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BloomDiscoverPage(api: api, frames: const [])),
      ),
    );
    await tester.pumpAndSettle();
    final title = tester.widget<Text>(find.text('发现'));
    expect(title.style?.fontFamily, BloomType.serifFamily);
    expect(title.style?.fontSize, BloomType.pageTitle.fontSize);
    await tester.ensureVisible(find.text('走进展览'));
    await tester.tap(find.text('走进展览'));
    await tester.pumpAndSettle();
    expect(find.byType(BloomPrimaryButton), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      final image = find.byKey(ValueKey('gallery-image-layout-$i'));
      final copy = find.byKey(ValueKey('gallery-copy-layout-$i'));
      await tester.scrollUntilVisible(
        image,
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      final pictureRect = tester.getRect(image);
      final copyRect = tester.getRect(copy);
      if (i == 0) expect(pictureRect.right, lessThan(copyRect.left));
      if (i == 1) expect(copyRect.right, lessThan(pictureRect.left));
      if (i == 2) expect(pictureRect.bottom, lessThan(copyRect.top));
      expect(
        tester.widget<Text>(find.text('中文作品$i')).style?.fontFamily,
        BloomType.serifFamily,
      );
      expect(tester.takeException(), isNull);
    }
    // 未登录时只引导登录，不创建内容选择。
    await tester.tap(find.text('发送整个展览到设备'));
    await tester.pumpAndSettle();
    expect(find.text('登录后，可以把展览或作品发送到你的设备。'), findsOneWidget);
  });
}
