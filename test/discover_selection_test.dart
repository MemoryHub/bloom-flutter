import 'dart:async';
import 'dart:convert';
import 'package:bloom/core/api/bloom_api_client.dart';
import 'package:bloom/ui/bloom_discover_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const work = {
    'id': 'work-id',
    'title': 'Almond Blossom',
    'artist': 'Van Gogh',
    'year': '1890',
    'position': 0,
    'image_url': '/preview',
    'story': 'A new beginning.',
    'artist_country_code': 'NL',
  };
  const collection = {
    'id': 'collection-id',
    'title': '日常里的美术馆',
    'subtitle': '把艺术带回家',
    'introduction': '慢慢欣赏。',
    'work_count': 1,
    'cover': work,
  };

  Future<void> open(WidgetTester tester, BloomApiClient api) async {
    final previous = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.exception is! NetworkImageLoadException) previous?.call(d);
    };
    addTearDown(() => FlutterError.onError = previous);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: BloomDiscoverPage(
            api: api,
            frames: const [GalleryFrame('phone', '小米测试手机', isMobile: true)],
            userToken: 'test-session',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('走进展览'));
    await tester.tap(find.text('走进展览'));
    await tester.pumpAndSettle();
  }

  BloomApiClient client(
    Map<String, dynamic> Function() selection,
    void Function(Map<String, dynamic>) write, {
    Future<void> Function()? beforeWrite,
    bool failWrite = false,
  }) => BloomApiClient(
    client: MockClient((r) async {
      Object result;
      if (r.method == 'PATCH') {
        await beforeWrite?.call();
        if (failWrite) return http.Response('{}', 503);
        write(jsonDecode(r.body) as Map<String, dynamic>);
        result = selection();
      } else if (r.url.path.endsWith('/content-selections')) {
        result = selection();
      } else if (r.url.path.endsWith('/collections/collection-id')) {
        result = {
          ...collection,
          'items': [work],
          'has_more': false,
        };
      } else {
        result = {
          'items': [collection],
          'has_more': false,
        };
      }
      return http.Response(
        jsonEncode(result),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );

  testWidgets('取消整展必须确认，保留不写接口，弹层可以下滑关闭', (tester) async {
    var subscribed = true;
    final writes = <Map<String, dynamic>>[];
    Map<String, dynamic> state() => {
      'items':
          subscribed
              ? [
                {'kind': 'collection', 'id': 'collection-id'},
              ]
              : [],
      'effective_artwork_ids': subscribed ? ['work-id'] : [],
      'artwork_origins': {},
    };
    await open(
      tester,
      client(state, (r) {
        writes.add(r);
        subscribed = r['selected'] as bool;
      }),
    );
    await tester.tap(find.text('发送整个展览到设备'));
    await tester.pumpAndSettle();
    expect(find.text('已发送 ✓'), findsOneWidget);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    expect(find.text('取消发送这个展览？'), findsOneWidget);
    expect(writes, isEmpty);
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认取消'));
    await tester.pumpAndSettle();
    expect(writes.single['selected'], false);
    expect(find.text('发送'), findsOneWidget);
    await tester.drag(find.text('选择展示设备'), const Offset(0, 650));
    await tester.pumpAndSettle();
    expect(find.text('选择展示设备'), findsNothing);
    expect(writes, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('来自整展的单幅显示已发送，点击不产生错误撤销或重复发送', (tester) async {
    final writes = <Map<String, dynamic>>[];
    Map<String, dynamic> state() => {
      'items': [
        {'kind': 'collection', 'id': 'collection-id'},
      ],
      'effective_artwork_ids': ['work-id'],
      'artwork_origins': {
        'work-id': {
          'direct': false,
          'collections': [
            {'id': 'collection-id', 'title': '日常里的美术馆'},
          ],
        },
      },
    };
    await open(tester, client(state, writes.add));
    await tester.ensureVisible(find.text('Almond Blossom'));
    await tester.tap(find.text('Almond Blossom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送这幅作品到设备'));
    await tester.pumpAndSettle();
    expect(find.text('已发送 ✓'), findsOneWidget);
    expect(find.textContaining('来自展览：日常里的美术馆'), findsOneWidget);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    expect(find.text('这幅作品已发送'), findsOneWidget);
    expect(writes, isEmpty);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('选择展示设备'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单幅和整展同时选择，取消单独发送后仍显示来自展览', (tester) async {
    var direct = true;
    final writes = <Map<String, dynamic>>[];
    Map<String, dynamic> state() => {
      'items': [
        {'kind': 'collection', 'id': 'collection-id'},
        if (direct) {'kind': 'artwork', 'id': 'work-id'},
      ],
      'effective_artwork_ids': ['work-id'],
      'artwork_origins': {
        'work-id': {
          'direct': direct,
          'collections': [
            {'id': 'collection-id', 'title': '日常里的美术馆'},
          ],
        },
      },
    };
    await open(
      tester,
      client(state, (r) {
        writes.add(r);
        direct = r['selected'] as bool;
      }),
    );
    await tester.ensureVisible(find.text('Almond Blossom'));
    await tester.tap(find.text('Almond Blossom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送这幅作品到设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    expect(find.text('取消单独发送这幅作品？'), findsOneWidget);
    expect(writes, isEmpty);
    expect(find.textContaining('因此会继续播放'), findsOneWidget);
    await tester.tap(find.text('确认取消'));
    await tester.pumpAndSettle();
    expect(writes.single['selected'], false);
    expect(find.text('已发送 ✓'), findsOneWidget);
    expect(find.textContaining('来自展览：日常里的美术馆'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
  });

  Map<String, dynamic> sharedState(bool selected) => {
    'items':
        selected
            ? [
              {'kind': 'collection', 'id': 'collection-id'},
            ]
            : [],
    'effective_artwork_ids': selected ? ['work-id'] : [],
    'artwork_origins': {},
  };

  Future<void> sheet(WidgetTester tester) async {
    await tester.tap(find.text('发送整个展览到设备'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('另一个用户已发送，第二用户打开同一设备显示已发送；取消有主次按钮', (tester) async {
    final writes = <Map<String, dynamic>>[];
    await open(tester, client(() => sharedState(true), writes.add));
    expect(find.text('荷兰'), findsOneWidget);
    await sheet(tester);
    expect(find.text('已发送 ✓'), findsOneWidget);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, '保留'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '确认取消'), findsOneWidget);
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await close(tester);
  });

  testWidgets('弹层打开时家人发送，五秒刷新状态；过期发送点击不会误取消', (tester) async {
    var selected = false;
    final writes = <Map<String, dynamic>>[];
    await open(tester, client(() => sharedState(selected), writes.add));
    await sheet(tester);
    selected = true;
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    expect(find.text('已发送 ✓'), findsOneWidget);
    expect(find.textContaining('无需重复发送'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(writes, isEmpty);
    selected = false;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('发送'), findsOneWidget);
    await close(tester);
  });

  testWidgets('发送先确认，可放弃；真实请求期间有动画，成功后等待同步', (tester) async {
    var selected = false;
    final writes = <Map<String, dynamic>>[];
    final pending = Completer<void>();
    await open(
      tester,
      client(() => sharedState(selected), (r) {
        writes.add(r);
        selected = r['selected'] as bool;
      }, beforeWrite: () => pending.future),
    );
    await sheet(tester);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    expect(find.text('把这个展览送过去？'), findsOneWidget);
    expect(writes, isEmpty);
    await tester.tap(find.text('再看看'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('正在送往「小米测试手机」'), findsOneWidget);
    expect(find.text('已发送，等待设备同步。'), findsNothing);
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('小米测试手机'),
              matching: find.byType(ListTile),
            ),
          )
          .onTap,
      isNull,
    );
    pending.complete();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('让艺术，在日常里相遇。'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(find.text('让艺术，在日常里相遇。'), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('已发送 ✓'), findsOneWidget);
    await close(tester);
  });

  testWidgets('确认发送期间家人已发送，不再重复写入；确认取消期间已撤销也不反向发送', (tester) async {
    var selected = false;
    final writes = <Map<String, dynamic>>[];
    await open(tester, client(() => sharedState(selected), writes.add));
    await sheet(tester);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    selected = true;
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.text('已发送 ✓'), findsOneWidget);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    selected = false;
    await tester.tap(find.text('确认取消'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.text('发送'), findsOneWidget);
    await close(tester);
  });

  testWidgets('发送失败不会播放成功反馈，重新读取失败状态仍可重试', (tester) async {
    final writes = <Map<String, dynamic>>[];
    await open(
      tester,
      client(() => sharedState(false), writes.add, failWrite: true),
    );
    await sheet(tester);
    await tester.tap(find.text('小米测试手机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂时无法确认保存结果'), findsOneWidget);
    expect(find.text('让艺术，在日常里相遇。'), findsNothing);
    expect(writes, isEmpty);
    await tester.tap(find.text('返回设备列表'));
    await tester.pumpAndSettle();
    expect(find.text('发送'), findsOneWidget);
    await close(tester);
  });

  test('国籍优先可靠国家码，历史地区保留，无资料不猜', () {
    expect(galleryArtistNationality({'artist_country_code': 'JP'}), '日本');
    expect(
      galleryArtistNationality({'artist_nationality': 'Netherlandish'}),
      '尼德兰地区',
    );
    expect(galleryArtistNationality({}), '');
  });
}
