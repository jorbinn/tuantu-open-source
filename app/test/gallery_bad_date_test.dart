/// 人物相册灰块回归：没设时钟的相机把 EXIF 写成 0000:00:00，盒子存成公元前
/// 的负秒数。日期分组解析失败时 release 下整组变成 10 万像素高的灰色
/// ErrorWidget，盖住后面的照片。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/gallery_page.dart';

// DateTime.utc(0, 0, 0) —— EXIF "0000:00:00 00:00:00" 在盒子上的存法。
final _yearZero = DateTime.utc(0, 0, 0).millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> _card(int id, Object? takenAt,
        {Object? createdAt = 1770000000.0}) =>
    {
      'id': id,
      'thumb': '/api/asset/$id/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 0,
      'orig_name': 'IMG_$id.jpg',
      'width': 100,
      'height': 100,
      'taken_at': takenAt,
      'created_at': createdAt,
      'uploader': '甲',
      'uploader_id': 1,
      'avatar': null,
      'mine': false,
      'likes': 0,
      'liked': false,
      'comments': 0,
      'has_live': 0,
    };

class _Adapter implements HttpClientAdapter {
  _Adapter(this.pages);
  final List<List<Map<String, dynamic>>> pages;
  var calls = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final more = options.uri.queryParameters.containsKey('cursor');
    final page = more ? pages[1] : pages[0];
    calls++;
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode({
        'items': page,
        'cursor': more ? null : 1.0,
        'cursor_id': more ? null : 1,
      })),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('dayKey 对不合理时间返回 unknown 而不是不可解析的键', () {
    expect(dayKey(_yearZero), 'unknown');
    expect(dayKey(-30610224000 - 86400), 'unknown'); // 公元 999 年
    expect(dayKey(9000000000000), 'unknown'); // 超出 DateTime 范围
    expect(dayKey(1770000000), '2026-02-02');
    expect(DateTime.tryParse('${dayKey(1770000000)}T00:00:00Z'), isNotNull);
    expect(dayKey(null), 'unknown');
    expect(dayKey(0), 'unknown');
    expect(dayKey(1), '1970-01-01');
    expect(dayKey(-2208988800), '1900-01-01');
    expect(dayKey(253402300800), 'unknown'); // 公元 10000 年
    expect(fmtTime(9000000000000), '');
    expect(fmtTime(_yearZero), '');
    expect(fmtLastUpload(double.nan), '');
  });

  test('CardItem 容忍字符串、空串和缺失的时间字段', () {
    expect(CardItem(_card(1, '')).takenAt, 1770000000);
    expect(CardItem(_card(1, '1760000000')).takenAt, 1760000000);
    expect(CardItem(_card(1, null, createdAt: null)).takenAt, isNull);
    expect(CardItem(_card(1, 1.5e9, createdAt: '1.7e9')).createdAt, 1.7e9);
  });

  testWidgets('各种脏日期混在正常照片里：不出灰块，未知日期组在最后', (tester) async {
    final dirty = <Object?>[
      null,
      0,
      1,
      946684800,
      -2208988800,
      _yearZero,
      4102444800,
      253402300800,
      9000000000000,
      '',
      '1760000000',
    ];
    final page = <Map<String, dynamic>>[
      for (var i = 0; i < 20; i++) _card(500 - i, 1770000000 - i * 3600),
      for (var i = 0; i < dirty.length; i++)
        _card(100 + i, dirty[i],
            createdAt: dirty[i] == null ? null : 1770000000.0),
    ];
    tester.view.physicalSize = const Size(1080, 24000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = _Adapter([page, const []]);
    final errors = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = old);
    await tester.pumpWidget(const MaterialApp(
      home: GalleryAlbumPage(title: '人物3', view: 'person:3'),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    for (var i = 0; i < 20; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 30));
    }
    FlutterError.onError = old;
    expect(errors.map((e) => e.exceptionAsString()).toList(), isEmpty);
    expect(find.byType(ErrorWidget), findsNothing);
    for (var i = 0; i < dirty.length; i++) {
      expect(find.byKey(ValueKey('album-cell-${100 + i}')), findsOneWidget,
          reason: 'dirty[$i]=${dirty[i]}');
    }
    // 「时间未知」组是最后一个日期标题。
    final unknownY = tester.getTopLeft(find.text('时间未知')).dy;
    final lastNormalY =
        tester.getTopLeft(find.byKey(const ValueKey('album-cell-104'))).dy;
    expect(unknownY, greaterThan(lastNormalY));
  });

  testWidgets('人物相册含 0000 年照片和重复 id 时不出灰块，后面的照片照常显示', (tester) async {
    final first = [
      for (var i = 1; i <= 89; i++) _card(1000 - i, 1770000000 - i * 600),
      _card(1, _yearZero),
    ];
    // 第二页与第一页重叠一张（id 999），另有正常照片。
    final second = [_card(999, 1770000000 - 600), _card(2, 1760000000)];
    Api.I.configure('http://box.test:8000', 'token');
    Api.I.dio.httpClientAdapter = _Adapter([first, second]);
    final errors = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = old);

    await tester.pumpWidget(const MaterialApp(
      home: GalleryAlbumPage(title: '人物7', view: 'person:7'),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    for (var i = 0; i < 40; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 30));
    }
    FlutterError.onError = old;

    expect(errors.map((e) => e.exceptionAsString()).toList(), isEmpty);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('时间未知'), findsOneWidget);
    expect(find.byKey(const ValueKey('album-cell-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('album-cell-2')), findsOneWidget);
  });
}
