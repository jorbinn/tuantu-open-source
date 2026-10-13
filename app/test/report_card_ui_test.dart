/// 报告配置页 + 纪念卡预览页 UI 回归。Dio 假 adapter，不碰真网络。
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/report_card_page.dart';
import 'package:tuantu_app/pages/report_config_page.dart';
import 'package:tuantu_app/report/report_policy.dart';

Uint8List _jpegBytes([int v = 120]) {
  final img = im.Image(width: 40, height: 40);
  im.fill(img, color: im.ColorRgb8(v, v + 40, v + 80));
  return Uint8List.fromList(im.encodeJpg(img, quality: 60));
}

Map<String, dynamic> _poolItem(int id, {int likes = 0, int comments = 0}) => {
      'id': id,
      'thumb': '/api/asset/$id/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'uploader': '甲',
      'uploader_id': 11,
      'avatar': null,
      'likes': likes,
      'comments': comments,
      'has_thumb': 1,
      'taken_w': 1000.0 + id * 500,
      'persons': const [1],
    };

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    this.persons = const [],
    this.report,
    this.status,
  });

  final List<Map<String, dynamic>> persons;
  final Map<String, dynamic>? report;
  final Map<String, dynamic>? status;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.path;
    if (path.contains('/api/status')) {
      return _json(status ?? {'service': 'tuantu', 'report': 1});
    }
    if (path.contains('/api/persons')) {
      return _jsonList(persons);
    }
    if (path.contains('/api/report/data')) {
      if (report == null) {
        return _json({'detail': 'Not Found'}, 404);
      }
      return _json(report!);
    }
    if (path.contains('/thumb') ||
        path.contains('/report-preview') ||
        path.contains('/cover') ||
        path.contains('/avatar')) {
      final bytes = _jpegBytes();
      return ResponseBody.fromBytes(bytes, 200, headers: {
        Headers.contentTypeHeader: ['image/jpeg'],
      });
    }
    return _json({'ok': true});
  }

  ResponseBody _json(Object body, [int status = 200]) {
    return ResponseBody.fromBytes(utf8.encode(jsonEncode(body)), status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }

  ResponseBody _jsonList(List<Object> body) {
    return ResponseBody.fromBytes(utf8.encode(jsonEncode(body)), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void _wire(_FakeAdapter adapter) {
  Api.I.configure('http://box.test:8000', 'token');
  Api.I.dio.httpClientAdapter = adapter;
}

Future<void> _drain(WidgetTester tester) async {
  // Dio Timer(0) 链 + 图片解码都要走完；转圈动画无限帧，加载完成前别用 pumpAndSettle。
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Uint8List _png1x1() {
  final img = im.Image(width: 1, height: 1);
  im.fill(img, color: im.ColorRgb8(255, 128, 64));
  return Uint8List.fromList(im.encodePng(img));
}

Map<String, dynamic> _teamReport({int photos = 8, int videos = 2}) => {
      'generated_at': 1770000000,
      'counts': {'photos': photos, 'videos': videos},
      'likes': 5,
      'comments': 3,
      'time_note': false,
      'members': [
        {
          'person_id': 1,
          'name': '甲',
          'user_id': 11,
          'avatar': 0,
          'cover': '/api/person/1/cover',
          'photos': 6
        },
      ],
      'pairs': [],
      'uploaders': [
        {
          'user_id': 11,
          'name': '甲',
          'avatar': null,
          'photos': photos,
          'videos': videos
        },
      ],
      'pool': [
        for (var i = 1; i <= photos; i++) _poolItem(i, likes: i == 1 ? 4 : 0),
      ],
    };

Map<String, dynamic> _personalReport() => {
      'generated_at': 1770000000,
      'counts': {'photos': 18, 'videos': 2},
      'likes': 12,
      'comments': 4,
      'time_note': false,
      'members': [
        {
          'person_id': 1,
          'name': '一个稍微有点长的中文昵称',
          'user_id': 11,
          'avatar': 0,
          'cover': '/api/person/1/cover',
          'photos': 10
        },
        {
          'person_id': 2,
          'name': '乙',
          'user_id': 12,
          'avatar': 0,
          'cover': '/api/person/2/cover',
          'photos': 7
        },
      ],
      'pairs': [
        {'a': 1, 'b': 2, 'n': 6},
      ],
      'uploaders': [
        {'user_id': 11, 'name': '甲', 'photos': 8, 'videos': 1},
        {'user_id': 12, 'name': '乙', 'photos': 10, 'videos': 1},
      ],
      'pool': [
        for (var i = 1; i <= 5; i++)
          {
            ..._poolItem(i, likes: i == 1 ? 5 : 0),
            'persons': [1, if (i <= 3) 2],
            'uploader_id': i == 5 ? 11 : 12,
          },
      ],
      'person': {
        'person_id': 1,
        'name': '一个稍微有点长的中文昵称',
        'user_id': 11,
        'photos': 10,
        'others_photos': 8,
        'photographers': [
          {'user_id': 12, 'name': '乙', 'photos': 8},
          {'user_id': 11, 'name': '甲', 'photos': 2},
        ],
        'partners': [
          {'person_id': 2, 'photos': 6},
        ],
      },
    };

late ui.Image _fakeImage;

void main() {
  // 真实解码走 IO 线程，fake async 里永远不返回；测试统一注入 1×1 假图。
  setUpAll(() async {
    final png = _png1x1();
    final codec = await ui.instantiateImageCodec(png);
    _fakeImage = (await codec.getNextFrame()).image;
  });
  setUp(() {
    ReportCardPage.decodeOverrideForTest =
        (bytes, target) async => _fakeImage.clone();
  });
  tearDown(() {
    ReportCardPage.decodeOverrideForTest = null;
  });
  tearDownAll(() => _fakeImage.dispose());

  testWidgets('配置页：无团员时个人报告给出引导提示', (tester) async {
    _wire(_FakeAdapter(persons: [
      {
        'id': 9,
        'name': '路人',
        'member': 0,
        'count': 3,
        'cover': '/api/person/9/cover',
        'claimed_by_me': false,
        'pending': []
      },
    ]));
    await tester.pumpWidget(const MaterialApp(home: ReportConfigPage()));
    await _drain(tester);
    await tester.tap(find.text('个人报告'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有团员人物'), findsOneWidget);
  });

  testWidgets('配置页：默认我们的今天 + 今天范围，可直接生成', (tester) async {
    _wire(_FakeAdapter(persons: []));
    await tester.pumpWidget(const MaterialApp(home: ReportConfigPage()));
    await _drain(tester);
    expect(find.widgetWithText(TextField, '我们的今天'), findsOneWidget);
    expect(find.text('开始'), findsNothing);
    expect(find.text('结束'), findsNothing);
    expect(find.text('日期'), findsOneWidget);
    expect(find.textContaining('23:59:59'), findsOneWidget);
    final now = DateTime.now();
    expect(find.text('${now.year}年${now.month}月${now.day}日'), findsOneWidget);
    final page = tester.widget<ReportConfigPage>(find.byType(ReportConfigPage));
    expect(page, isNotNull);
    expect(ReportRange.defaultRange().isValid, isTrue);
  });

  testWidgets('团队报告：渲染 1080×1350、显示精简数据并可独立换版式', (tester) async {
    _wire(_FakeAdapter(report: _teamReport()));
    final config = ReportConfig(
      personal: false,
      title: '川西小环线',
      location: '稻城',
      range: ReportRange(
          start: DateTime(2026, 9, 1, 8, 0), end: DateTime(2026, 9, 3, 20, 30)),
    );
    await tester.pumpWidget(MaterialApp(home: ReportCardPage(config: config)));
    await tester.pump();
    await _drain(tester);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('川西小环线'), findsOneWidget);
    expect(find.text('稻城'), findsNothing, reason: '导出图不显示地点文字');
    expect(find.text('8'), findsWidgets, reason: '照片总数');
    expect(find.text('照片总数'), findsOneWidget);
    expect(find.text('换底景'), findsOneWidget);
    expect(find.text('换版式'), findsOneWidget);
    expect(find.text('换照片'), findsOneWidget);
    expect(find.text('重新统计'), findsOneWidget);
    expect(find.text('保存到相册'), findsOneWidget);
    expect(find.textContaining('人物数据基于已识别照片'), findsOneWidget);

    // 卡片根容器按 1080×1350 逻辑尺寸布局（FittedBox 只缩放绘制）
    final size =
        tester.getSize(find.byKey(const ValueKey('team-report-card-root')));
    expect(size.width, 1080);
    expect(size.height, 1350);
  });

  testWidgets('换照片后仍可渲染（不重新请求快照，数字不变）', (tester) async {
    _wire(_FakeAdapter(report: _teamReport()));
    final config = ReportConfig(
      personal: false,
      title: '我们的旅行',
      range:
          ReportRange(start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 2)),
    );
    await tester.pumpWidget(MaterialApp(home: ReportCardPage(config: config)));
    await _drain(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('换照片'));
    await _drain(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('我们的旅行'), findsOneWidget);
    expect(find.text('8'), findsWidgets, reason: '同一快照数字不变');
  });

  testWidgets('个人纪念卡：丰富内容与长昵称仍完整渲染', (tester) async {
    _wire(_FakeAdapter(report: _personalReport()));
    final config = ReportConfig(
      personal: true,
      personId: 1,
      personName: '一个稍微有点长的中文昵称',
      title: '我们的川西秋日自驾旅行',
      location: '稻城亚丁',
      range: ReportRange(
          start: DateTime(2026, 9, 1, 8), end: DateTime(2026, 9, 3, 20, 30)),
    );
    await tester.pumpWidget(MaterialApp(home: ReportCardPage(config: config)));
    await _drain(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('personal-report-card-root')),
        findsOneWidget);
    expect(find.text('出镜照片'), findsOneWidget);
    expect(find.text('10'), findsWidgets, reason: '个人出镜照片数');
    expect(find.text('保存到相册'), findsOneWidget);
    final size =
        tester.getSize(find.byKey(const ValueKey('personal-report-card-root')));
    expect(size, const Size(1080, 1350));
  });

  testWidgets('范围内没有媒体：空状态提示调整范围，不出卡', (tester) async {
    _wire(_FakeAdapter(report: _teamReport(photos: 0, videos: 0)));
    final config = ReportConfig(
      personal: false,
      title: '我们的旅行',
      range:
          ReportRange(start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 2)),
    );
    await tester.pumpWidget(MaterialApp(home: ReportCardPage(config: config)));
    await _drain(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('这段时间相册里还没有照片'), findsOneWidget);
    expect(find.text('返回调整时间'), findsOneWidget);
    expect(find.text('保存到相册'), findsNothing);
  });

  testWidgets('旧盒子（status 无 report 字段）提示升级', (tester) async {
    _wire(_FakeAdapter(status: {'service': 'tuantu'}));
    final fut = Api.I.boxSupportsReport();
    await _drain(tester);
    expect(await fut, isFalse);
  });

  test('后台导出的 JPEG 是固定 1080×1350，且不跨 isolate 传 ui.Image', () async {
    final rgba = ByteData(1080 * 1350 * 4);
    final jpeg = await encodeReportJpegOffload(rgba, 1080, 1350);
    final decoded = im.decodeImage(Uint8List.fromList(jpeg));
    expect(decoded, isNotNull);
    expect(decoded!.width, 1080);
    expect(decoded.height, 1350);
  });
}
