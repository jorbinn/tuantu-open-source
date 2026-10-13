import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/gallery_page.dart';
import 'package:tuantu_app/pages/persons_page.dart';
import 'package:tuantu_app/pages/me_page.dart';

class _Adapter implements HttpClientAdapter {
  bool fail = true;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? s, Future<void>? cancel) async {
    if (fail) {
      throw DioException(
          requestOptions: o, type: DioExceptionType.connectionError);
    }
    final Object data = o.path.contains('persons')
        ? []
        : {
            'items': [
              for (var i = 1; i <= 50; i++)
                {
                  'id': i,
                  'thumb': '/thumb/$i',
                  'has_thumb': 0,
                  'kind': 'image',
                  'ext': 'jpg',
                  'taken_at': 1770000000,
                  'uploader': '自动测试',
                  'width': 100,
                  'height': 100,
                }
            ],
            'cursor': null,
          };
    return ResponseBody.fromString(jsonEncode(data), 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  late _Adapter adapter;
  setUp(() {
    Api.listAttempts = 1;
    Api.I.configure('http://box.test:8000', 'token');
    adapter = _Adapter();
    Api.I.dio.httpClientAdapter = adapter;
  });
  tearDown(() {
    Api.listAttempts = 2;
  });
  testWidgets('视频列表网络失败不能冒充空相册，重试在原页显示内容', (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: GalleryAlbumPage(title: '视频', view: 'video')));
    await drain(tester);
    expect(find.text('还没有照片'), findsNothing);
    expect(find.text('重新加载'), findsOneWidget);
    final state = tester.state(find.byType(GalleryAlbumPage));
    adapter.fail = false;
    await tester.tap(find.text('重新加载'));
    await drain(tester);
    expect(tester.state(find.byType(GalleryAlbumPage)), same(state));
    expect(find.byKey(const ValueKey('album-cell-1')), findsOneWidget);
  });
  testWidgets('连接恢复广播保留相册路由、State 和滚动位置', (tester) async {
    adapter.fail = false;
    await tester.pumpWidget(
        const MaterialApp(home: GalleryAlbumPage(title: '视频', view: 'video')));
    await drain(tester);
    final state = tester.state(find.byType(GalleryAlbumPage));
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    controller.jumpTo(400);
    await tester.pump();
    final offset = controller.offset;
    Api.endpointChanges.value++;
    await drain(tester);
    expect(tester.state(find.byType(GalleryAlbumPage)), same(state));
    expect(controller.offset, offset);
    expect(find.text('视频'), findsOneWidget);
  });
  testWidgets('人物请求失败显示重试，不显示尚未识别人脸的误导提示', (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: PersonsPage())));
    await drain(tester);
    expect(find.textContaining('还没识别出人物'), findsNothing);
    expect(find.text('重新加载'), findsOneWidget);
    adapter.fail = false;
    Api.endpointChanges.value++;
    await drain(tester);
    expect(find.textContaining('还没识别出人物'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
  });
  testWidgets('子页面打开期间恢复连接不会把我的页误认为可返回页面', (tester) async {
    adapter.fail = false;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator, home: const MePage()));
    await drain(tester);
    expect(find.byTooltip('设置'), findsOneWidget);
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('测试子页面'))));
    await drain(tester);
    Api.endpointChanges.value++;
    await drain(tester);
    navigator.currentState!.pop();
    await drain(tester);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });
}
