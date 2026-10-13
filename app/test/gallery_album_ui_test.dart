/// 相册网格：打开查看器上下滑后，返回时定位到最后浏览的那一张。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/gallery_page.dart';

Map<String, dynamic> _card(int id, {required int takenAt}) => {
      'id': id,
      'thumb': '/api/asset/$id/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 0,
      'orig_name': 'IMG_$id.jpg',
      'width': 100,
      'height': 100,
      'taken_at': takenAt,
      'created_at': takenAt.toDouble(),
      'uploader': '甲',
      'uploader_id': 1,
      'avatar': null,
      'mine': false,
      'likes': 0,
      'liked': false,
      'comments': 0,
      'has_live': 0,
    };

class _FakeAdapter implements HttpClientAdapter {
  final coverPosts = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST' && options.path.contains('/cover')) {
      coverPosts.add(Map<String, dynamic>.from(options.data as Map));
      return ResponseBody.fromBytes(
        utf8.encode(jsonEncode({
          'ok': true,
          'cover': '/api/person/7/cover?c=11',
          'cover_face_id': 11,
        })),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final items = [
      for (var i = 1; i <= 12; i++) _card(i, takenAt: 1770000000),
      for (var i = 13; i <= 24; i++) _card(i, takenAt: 1770086400),
    ];
    final body = {
      'items': items,
      'cursor': 1770000000.0,
      'cursor_id': 1,
    };
    final bytes = utf8.encode(jsonEncode(body));
    return ResponseBody.fromBytes(bytes, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _drainNet(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('从相册打开后上下滑，返回时列表滚到最后看的那张', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = _FakeAdapter();

    await tester.pumpWidget(const MaterialApp(
      home: GalleryAlbumPage(title: '最近项目', view: 'all'),
    ));
    await _drainNet(tester);

    expect(find.byKey(const ValueKey('album-cell-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('album-cell-24')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('album-cell-1')));
    await tester.pumpAndSettle();

    final pager = tester
        .widget<PageView>(find.byKey(const ValueKey('feed-viewer-pager')));
    expect(pager.scrollDirection, Axis.vertical);
    pager.controller!.jumpToPage(23);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('album-cell-24')), findsOneWidget,
        reason: '返回相册后应定位到最后浏览的那张');
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.controller, isNotNull);
    expect(list.controller!.offset, greaterThan(0));
  });

  testWidgets('看完同一张再返回，来源网格不滚动', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = _FakeAdapter();

    await tester.pumpWidget(const MaterialApp(
      home: GalleryAlbumPage(title: '最近项目', view: 'all'),
    ));
    await _drainNet(tester);

    final before =
        tester.widget<ListView>(find.byType(ListView)).controller!.offset;
    await tester.tap(find.byKey(const ValueKey('album-cell-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).controller!.offset,
      before,
    );
    expect(find.byKey(const ValueKey('album-cell-1')), findsOneWidget);
  });

  testWidgets('人物相册右上角可更换封面，并从该人物照片里挑选', (tester) async {
    final adapter = _FakeAdapter();
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(const MaterialApp(
      home: GalleryAlbumPage(title: '小明', view: 'person:7'),
    ));
    await _drainNet(tester);

    expect(find.text('更换封面'), findsOneWidget);
    await tester.tap(find.text('更换封面'));
    await tester.pump();
    expect(find.text('选择一张照片作为封面'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('album-cell-1')));
    await _drainNet(tester);
    expect(adapter.coverPosts, hasLength(1));
    expect(adapter.coverPosts.single['asset_id'], 1);
    expect(find.text('封面已更换'), findsOneWidget);
    expect(find.text('更换封面'), findsOneWidget);
  });

  testWidgets('普通相册没有更换封面', (tester) async {
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = _FakeAdapter();
    await tester.pumpWidget(const MaterialApp(
      home: GalleryAlbumPage(title: '最近项目', view: 'all'),
    ));
    await _drainNet(tester);
    expect(find.text('更换封面'), findsNothing);
  });
}
