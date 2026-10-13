/// 首页/相册 feed 竖滑翻页回归：用真实 SwipePage / FeedViewerPage 和
/// 真实 onZoomed 回调链路，模拟手指慢拖与快甩，检查动画结束后的最终页号。
///
/// 背景：FeedItem 每次单指松手都会发 onZoomed(false)，父页面若对相同
/// 状态也执行 _snapPage()（jumpToPage），会在松手路径上终止当前拖动、
/// 把页面强制吸回最近整页——表现为「上下滑滑不动、拖 10%~20% 松手弹回」。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/feed_viewer_page.dart';
import 'package:tuantu_app/pages/swipe_page.dart';

Map<String, dynamic> _card(int id) => {
      'id': id,
      'thumb': '/api/asset/$id/thumb',
      'kind': 'image',
      'ext': 'jpg',
      'has_thumb': 0,
      'orig_name': 'IMG_$id.jpg',
      'width': 100,
      'height': 100,
      'taken_at': 1770000000,
      'created_at': 1770000000.0,
      'uploader': '小明',
      'uploader_id': 1,
      'avatar': null,
      'mine': false,
      'likes': 0,
      'liked': false,
      'comments': 0,
      'has_live': 0,
    };

/// 首批返回 4 条，之后的翻页加载返回空批（end），避免列表中途增长。
class _HomeAdapter implements HttpClientAdapter {
  int galleryCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object body;
    if (options.path.contains('/api/gallery')) {
      final items = galleryCalls++ == 0
          ? [_card(1), _card(2), _card(3), _card(4)]
          : <Map<String, dynamic>>[];
      body = {'items': items, 'cursor': null, 'cursor_id': null};
    } else {
      body = {'ok': true};
    }
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 推进 fake 时钟，让 Dio 的 Timer(0) 链（请求→响应→markSeen）全部走完。
Future<void> _drainNet(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// 当前落点页号（动画结束后读）。
double _pageOf(WidgetTester tester) {
  final position =
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  return position.pixels / position.viewportDimension;
}

/// 慢拖 delta 后停住再松手：不带甩速，只验证行程吸附。
Future<void> _slowDrag(WidgetTester tester, Offset delta) async {
  final start = tester.getCenter(find.byType(PageView));
  final gesture = await tester.startGesture(start);
  const steps = 12;
  final stepDelta = Offset(delta.dx / steps, delta.dy / steps);
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(stepDelta);
    await tester.pump(const Duration(milliseconds: 16));
  }
  // 停住，让速度估计归零，模拟「拖完停住松手」。
  await tester.pump(const Duration(milliseconds: 120));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _openViewer(WidgetTester tester, int initialIndex) async {
  Api.I.configure('http://box.test:8000', 'token');
  final items = [
    CardItem(_card(11)),
    CardItem(_card(12)),
    CardItem(_card(13)),
  ];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => TextButton(
        onPressed: () => FeedViewerPage.open(ctx, items: items, initialIndex: initialIndex),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('首页 SwipePage 真实翻页', () {
    Future<void> pumpHome(WidgetTester tester) async {
      Api.I.configure('http://box.test:8000', 'token');
      Api.I.dio.httpClientAdapter = _HomeAdapter();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SwipePage())),
      );
      await _drainNet(tester);
      expect(_pageOf(tester), 0.0);
    }

    testWidgets('从页首慢拖约 15% 屏高停住松手，翻到下一页', (tester) async {
      await pumpHome(tester);
      // 600 屏高拖 90px ≈ 15%，远超 5% 吸附线。
      await _slowDrag(tester, const Offset(0, -90));
      expect(_pageOf(tester), 1.0, reason: '慢拖过 5% 屏高松手必须翻页，不得弹回');
    });

    testWidgets('连续往返翻页，最终页号正确', (tester) async {
      await pumpHome(tester);
      await _slowDrag(tester, const Offset(0, -90));
      expect(_pageOf(tester), 1.0);
      await _slowDrag(tester, const Offset(0, -90));
      expect(_pageOf(tester), 2.0);
      await _slowDrag(tester, const Offset(0, 90));
      expect(_pageOf(tester), 1.0, reason: '从中间页往回拉必须翻回上一页');
      await _slowDrag(tester, const Offset(0, 90));
      expect(_pageOf(tester), 0.0);
    });

    testWidgets('短距离快甩翻页，往回甩翻回', (tester) async {
      await pumpHome(tester);
      await tester.fling(find.byType(PageView), const Offset(0, -80), 900);
      await tester.pumpAndSettle();
      expect(_pageOf(tester), 1.0);
      await tester.fling(find.byType(PageView), const Offset(0, 80), 900);
      await tester.pumpAndSettle();
      expect(_pageOf(tester), 0.0);
    });

    testWidgets('行程不足 5% 且无甩速，留在本页', (tester) async {
      await pumpHome(tester);
      await _slowDrag(tester, const Offset(0, -20));
      expect(_pageOf(tester), 0.0, reason: '没过 5% 屏高不得翻页');
    });
  });

  group('相册 FeedViewerPage 真实翻页', () {
    testWidgets('从中间页慢拖翻上、翻回，最终页号正确', (tester) async {
      await _openViewer(tester, 1);
      expect(_pageOf(tester), 1.0);

      await _slowDrag(tester, const Offset(0, -90));
      expect(_pageOf(tester), 2.0, reason: '从中间页慢拖过 5% 必须翻到下一页');

      await _slowDrag(tester, const Offset(0, 90));
      expect(_pageOf(tester), 1.0, reason: '从中间页往回拉必须翻回上一页');
    });

    testWidgets('双指放大再缩回后，翻页恢复正常', (tester) async {
      await _openViewer(tester, 1);
      final center = tester.getCenter(find.byType(PageView));

      // 双指捏合放大（锁翻页，父页面 false→true 对齐整页）。
      final a = await tester.startGesture(center - const Offset(30, 0));
      final b = await tester.startGesture(center + const Offset(30, 0));
      await tester.pump();
      await a.moveBy(const Offset(-60, 0));
      await b.moveBy(const Offset(60, 0));
      await tester.pump();
      // 缩回约 1 倍再抬指（解锁只放锁，不得跳页）。
      await a.moveBy(const Offset(60, 0));
      await b.moveBy(const Offset(-60, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(_pageOf(tester), 1.0, reason: '缩回解锁不得改变当前页');

      // 解锁后翻页必须正常。
      await _slowDrag(tester, const Offset(0, -90));
      expect(_pageOf(tester), 2.0, reason: '放大缩回后翻页必须恢复');
    });

    testWidgets('第一指拖动中落下第二指，松手后翻页恢复', (tester) async {
      await _openViewer(tester, 1);
      final center = tester.getCenter(find.byType(PageView));
      final first = await tester.startGesture(center);
      await first.moveBy(const Offset(0, -40));
      await tester.pump();
      final second =
          await tester.startGesture(center + const Offset(40, 0), pointer: 2);
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(_pageOf(tester), 1.0, reason: '第二指打断翻页后不得把当前页带走');

      await _slowDrag(tester, const Offset(0, -90));
      expect(_pageOf(tester), 2.0, reason: '第一指拖动中落第二指后，新一轮翻页必须正常');
    });
  });
}
