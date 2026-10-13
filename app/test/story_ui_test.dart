import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/report_list_page.dart';
import 'package:tuantu_app/pages/report_story_page.dart';
import 'package:tuantu_app/report/report_card.dart';
import 'package:tuantu_app/report/story_chapter.dart';
import 'package:tuantu_app/report/story_model.dart';
import 'package:tuantu_app/widgets/box_image.dart';

import 'fixtures/story_sample.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter({this.claimed = true, this.old = false});
  final bool claimed, old;
  final paths = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    final code = old
        ? 404
        : claimed
        ? 200
        : 409;
    final Object body = old
        ? {'detail': 'Not Found'}
        : !claimed
        ? {'code': 'claim_required'}
        : options.path.endsWith('/story')
        ? storySample()
        : {
            'identity': {'person_id': 1, 'name': '小雨'},
            'days': [
              {
                'day': '2026-09-20',
                'photos': 18,
                'videos': 2,
                'mine': 7,
                'cover_id': 9,
              },
            ],
            'next': null,
          };
    return ResponseBody.fromString(
      jsonEncode(body),
      code,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _wire(_Adapter adapter) {
  Api.I.configure('http://story.test:8000', 'token');
  Api.I.dio.httpClientAdapter = adapter;
}

void main() {
  testWidgets(
    'claim gate and old-box guidance are distinct and do not make up personal data',
    (tester) async {
      final adapter = _Adapter(claimed: false);
      _wire(adapter);
      await tester.pumpWidget(const MaterialApp(home: ReportListPage()));
      await drain(tester);
      expect(find.text('先让故事认识你'), findsOneWidget);
      expect(find.text('去认领「这是我」'), findsOneWidget);
      expect(adapter.paths, ['/api/report/days']);
      await tester.pumpWidget(const SizedBox());
      _wire(_Adapter(old: true));
      await tester.pumpWidget(const MaterialApp(home: ReportListPage()));
      await drain(tester);
      expect(find.textContaining('盒子还需要更新'), findsOneWidget);
      expect(find.text('先让故事认识你'), findsNothing);
    },
  );

  testWidgets(
    'day list opens both personal and team scroll stories without raw downloads',
    (tester) async {
      final adapter = _Adapter();
      _wire(adapter);
      await tester.pumpWidget(const MaterialApp(home: ReportListPage()));
      await drain(tester);
      expect(find.text('7 张照片里有你 →'), findsOneWidget);
      final cover = tester.widget<BoxImage>(find.byType(BoxImage));
      expect(cover.url, 'http://story.test:8000/api/asset/9/thumb');
      await tester.tap(find.text('2026年9月20日'));
      await drain(tester);
      expect(find.byType(ReportStoryPage), findsOneWidget);
      expect(find.text('小雨的\n这一天'), findsOneWidget);
      await tester.tap(find.text('我们的这一天'));
      await drain(tester);
      expect(find.text('我们的\n这一天'), findsOneWidget);
      expect(find.text('保存完整故事长图'), findsOneWidget);
      expect(adapter.paths.any((p) => p.endsWith('/raw')), false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('small screen and large text keep all chapters scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = StoryModel(storySample());
    final chapters = model.chapters(true);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.5),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < chapters.length; i++)
                    StoryChapterView(
                      chapter: chapters[i],
                      model: model,
                      assets: ReportCardAssets(),
                      personal: true,
                      index: i,
                      revealed: true,
                      exporting: true,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.textContaining('团 图  /'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('关系网头像点击展开合照，再次点击收起', (tester) async {
    final raw = storySample();
    raw['pool'] = [
      for (var id = 1; id <= 6; id++)
        {
          'id': id,
          'kind': 'image',
          'uploader_id': 12,
          'persons': [1, 2],
          'likes': 0,
          'comments': 0,
          'taken_w': id * 1000,
        },
    ];
    final model = StoryModel(raw);
    final chapter = model
        .chapters(true)
        .firstWhere((c) => c.kind == StoryChapterKind.connections);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StoryChapterView(
              chapter: chapter,
              model: model,
              assets: ReportCardAssets(),
              personal: true,
              index: 2,
              revealed: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final node = find.byKey(const ValueKey('relationship-node-2'));
    expect(node, findsOneWidget);
    await tester.drag(node, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(node);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('relationship-detail-2')), findsOneWidget);
    await tester.tap(node);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('relationship-detail-2')), findsNothing);
  });

  testWidgets(
    'long-image boundary includes the closing chapter even when screen is at the top',
    (tester) async {
      final key = GlobalKey();
      final scroll = ScrollController();
      final model = StoryModel(storySample());
      final chapters = model.chapters(true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 360,
                  child: Column(
                    children: [
                      for (var i = 0; i < chapters.length; i++)
                        StoryChapterView(
                          chapter: chapters[i],
                          model: model,
                          assets: ReportCardAssets(),
                          personal: true,
                          index: i,
                          revealed: true,
                          exporting: true,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      Uint8List? first;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: .25);
        expect(image.height, greaterThan(700));
        first = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
        image.dispose();
      });
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: .25);
        final second = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        expect(
          second,
          first,
          reason: 'complete image must not depend on scroll position',
        );
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
